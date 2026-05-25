// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev [V5.1] UUPS upgradeable proxy pattern.

interface ISolvencyBondVault {
    function totalCommittedUSD() external view returns (uint256);
    function lumina() external view returns (address);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

interface ISolvencyCapacityOracle {
    function getLuminaPrice() external view returns (uint256);
}

contract SolvencyOracle is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    ISolvencyBondVault public bondVault;
    ISolvencyCapacityOracle public capacityOracle;
    IERC20Balance public lumina;
    uint256 public constant EVALUATION_INTERVAL = 1 days;
    uint256 public constant COOLDOWN_BETWEEN_QUADRANT_CHANGES = 7 days;
    uint256 public constant SOLVENCY_ULTRA_BPS = 20000;
    uint256 public constant SOLVENCY_HEALTHY_BPS = 10000;
    uint256 public constant SOLVENCY_STRESSED_BPS = 7000;
    uint256 public constant MOMENTUM_RALLY_BPS = 11000;
    uint256 public constant MOMENTUM_STABLE_LOW_BPS = 9500;
    uint256 public constant MOMENTUM_DECLINE_BPS = 8500;
    uint256[3] public solvencyHistory;
    uint256[3] public momentumHistory;
    uint8 public historyIndex;
    uint8 public currentSolvencyLevel;
    uint8 public currentMomentumLevel;
    uint256 public lastEvaluation;
    uint256 public lastQuadrantChange;
    bool public emergencyPaused;
    event QuadrantChanged(uint8 oldS, uint8 oldM, uint8 newS, uint8 newM, uint256 sBps, uint256 mBps);
    event EvaluationExecuted(uint256 solvencyBps, uint256 momentumBps);
    event EmergencyPauseToggled(bool paused);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _bondVault, address _capacityOracle, address _admin) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();

        require(_bondVault != address(0), "BondVault zero");
        require(_capacityOracle != address(0), "CapacityOracle zero");
        require(_admin != address(0), "Admin zero");
        bondVault = ISolvencyBondVault(_bondVault);
        capacityOracle = ISolvencyCapacityOracle(_capacityOracle);
        lumina = IERC20Balance(ISolvencyBondVault(_bondVault).lumina());
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        currentSolvencyLevel = 1;
        currentMomentumLevel = 1;
        lastEvaluation = block.timestamp;
        lastQuadrantChange = block.timestamp;
    }

    function evaluate() external returns (bool quadrantChanged) {
        require(!emergencyPaused, "Oracle paused");
        require(block.timestamp >= lastEvaluation + EVALUATION_INTERVAL, "Evaluation interval not reached");
        uint256 solvencyBps = _calculateSolvencyRatio();
        uint256 momentumBps = 10000;
        solvencyHistory[historyIndex] = solvencyBps;
        momentumHistory[historyIndex] = momentumBps;
        historyIndex = (historyIndex + 1) % 3;
        lastEvaluation = block.timestamp;
        emit EvaluationExecuted(solvencyBps, momentumBps);
        uint256 avgS = (solvencyHistory[0] + solvencyHistory[1] + solvencyHistory[2]) / 3;
        uint256 avgM = (momentumHistory[0] + momentumHistory[1] + momentumHistory[2]) / 3;
        uint8 newS = _classifySolvency(avgS);
        uint8 newM = _classifyMomentum(avgM);
        if (
            (newS != currentSolvencyLevel || newM != currentMomentumLevel)
                && block.timestamp >= lastQuadrantChange + COOLDOWN_BETWEEN_QUADRANT_CHANGES
        ) {
            uint8 oldS = currentSolvencyLevel;
            uint8 oldM = currentMomentumLevel;
            currentSolvencyLevel = newS;
            currentMomentumLevel = newM;
            lastQuadrantChange = block.timestamp;
            emit QuadrantChanged(oldS, oldM, newS, newM, avgS, avgM);
            return true;
        }
        return false;
    }

    function setEmergencyPause(bool _paused) external onlyRole(ADMIN_ROLE) {
        emergencyPaused = _paused;
        emit EmergencyPauseToggled(_paused);
    }

    function getSolvencyRatio() external view returns (uint256) {
        return _calculateSolvencyRatio();
    }

    function getCurrentQuadrant() external view returns (uint8, uint8) {
        return (currentSolvencyLevel, currentMomentumLevel);
    }

    function isHealthy() external view returns (bool) {
        if (emergencyPaused) return false;
        if (block.timestamp > lastEvaluation + 7 days) return false;
        try ISolvencyCapacityOracle(capacityOracle).getLuminaPrice() returns (uint256 price) {
            if (price == 0) return false;
            // [MR-L06 fix] Tighten: healthy requires a live price AND a non-stressed
            //              solvency ratio (>= SOLVENCY_STRESSED_BPS), not merely price > 0.
            return _calculateSolvencyRatio() >= SOLVENCY_STRESSED_BPS;
        } catch {
            return false;
        }
    }

    function _calculateSolvencyRatio() internal view returns (uint256) {
        uint256 obligations = bondVault.totalCommittedUSD();
        if (obligations == 0) return type(uint256).max;
        uint256 bal = lumina.balanceOf(address(bondVault));
        // [MR-L06 fix] A fail-closed capacity oracle reverting on price deviation must
        //              NOT brick evaluate(). Treat a revert as the worst-case (stressed)
        //              reading: solvency = 0 bps, which classifies into the lowest
        //              quadrant (level 3, below SOLVENCY_STRESSED_BPS) so the daily
        //              quadrant history keeps advancing during volatility.
        try capacityOracle.getLuminaPrice() returns (uint256 price) {
            uint256 valueUSD = (bal * price) / 1e18;
            return (valueUSD * 10000) / obligations;
        } catch {
            return 0; // worst-case / stressed sentinel
        }
    }

    function _classifySolvency(uint256 bps) internal pure returns (uint8) {
        if (bps >= SOLVENCY_ULTRA_BPS) return 0;
        if (bps >= SOLVENCY_HEALTHY_BPS) return 1;
        if (bps >= SOLVENCY_STRESSED_BPS) return 2;
        return 3;
    }

    function _classifyMomentum(uint256 bps) internal pure returns (uint8) {
        if (bps >= MOMENTUM_RALLY_BPS) return 0;
        if (bps >= MOMENTUM_STABLE_LOW_BPS) return 1;
        if (bps >= MOMENTUM_DECLINE_BPS) return 2;
        return 3;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private __gap;
}
