// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

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

contract SolvencyOracle is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    ISolvencyBondVault public immutable bondVault;
    ISolvencyCapacityOracle public immutable capacityOracle;
    IERC20Balance public immutable lumina;
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

    constructor(address _bondVault, address _capacityOracle, address _admin) {
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
        uint256 momentumBps = 10000; // Simplified: neutral momentum (no TWAP30d available yet)
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
            return price > 0;
        } catch {
            return false;
        }
    }

    function _calculateSolvencyRatio() internal view returns (uint256) {
        uint256 obligations = bondVault.totalCommittedUSD();
        if (obligations == 0) return type(uint256).max;
        uint256 bal = lumina.balanceOf(address(bondVault));
        uint256 price = capacityOracle.getLuminaPrice();
        uint256 valueUSD = (bal * price) / 1e18;
        return (valueUSD * 10000) / obligations;
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
}
