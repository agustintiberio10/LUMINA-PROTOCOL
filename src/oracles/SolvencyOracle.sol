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
    /// @dev [Audit fix H-10] Reused for momentum calculation. CapacityOracle
    ///      already wraps `IUniswapV3Pool.observe` with try/catch + emergency
    ///      fallback, so SolvencyOracle does not need its own pool plumbing.
    function getTWAP(uint32 secondsAgo) external view returns (uint256);
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

    /// @notice [Audit fix H-10] TWAP windows (in seconds) used by
    ///         `_calculateMomentum`. Short = 30 minutes, long = 24 hours.
    uint32 public constant TWAP_SHORT_SECONDS = 30 minutes;
    uint32 public constant TWAP_LONG_SECONDS = 1 days;
    /// @notice Caps on the computed `momentumBps` so an oracle that returns
    ///         a wildly out-of-range price cannot push the system past the
    ///         intended classification thresholds.
    uint256 public constant MOMENTUM_BPS_FLOOR = 5000;
    uint256 public constant MOMENTUM_BPS_CEILING = 15000;
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

    /// @notice [Audit fix H-10] Emitted by `evaluate()` when the TWAP-based
    ///         momentum calculation could not produce a usable ratio (either
    ///         leg returned zero from the upstream oracle's emergency
    ///         fallback). Momentum stays at STABLE (10000) so the rest of
    ///         the evaluation continues uninterrupted.
    event OracleFailure(string indexed source, string reason);

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
        // [Audit fix H-10] Replaces the previous hardcoded `momentumBps = 10000`
        // with a TWAP-based ratio (short / long). On any TWAP read failure
        // the helper returns `(10000, true)` so the rest of `evaluate()`
        // proceeds with a STABLE classification — no flow break.
        (uint256 momentumBps, bool momFailed) = _calculateMomentum();
        if (momFailed) {
            emit OracleFailure("TWAP", "TWAP unavailable, momentum defaulted to STABLE");
        }
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

    /// @dev [Audit fix H-10] Computes momentum bps from a short/long TWAP
    ///      ratio. Mapping to the 4-level classifier downstream:
    ///        ratio  < 0.85 → bps 7000  → mLevel 3 (CRISIS, max buyback)
    ///        ≥ 0.85 < 0.95 → bps 8500  → mLevel 2 (DECLINE)
    ///        ≥ 0.95 < 1.05 → bps 10000 → mLevel 1 (STABLE)
    ///        ≥ 1.05 < 1.15 → bps 11500 → mLevel 0 (RALLY, max burn)
    ///        ≥ 1.15        → bps 12500 → mLevel 0 (PUMP saturates RALLY)
    ///      `_classifyMomentum` already partitions on these constants so
    ///      every existing classification slot is reachable from a
    ///      well-formed TWAP. The 5th label (PUMP) collapses into RALLY
    ///      because the existing 4×4 distribution matrix has no slot for
    ///      a 5th momentum level — distinguishing them would require a
    ///      matrix expansion which is explicitly out of scope per the
    ///      founder ("NO tocar la matriz 4x4 del AdaptiveFeeDistributor").
    ///
    ///      Failure modes:
    ///        - capacityOracle returns 0 for either leg → fail-safe to STABLE.
    ///        - any external call reverts → fail-safe to STABLE via try/catch.
    ///      Either path makes `momFailed == true` so `evaluate()` can emit
    ///      `OracleFailure` for off-chain monitors.
    ///      A defensive cap to [MOMENTUM_BPS_FLOOR, MOMENTUM_BPS_CEILING]
    ///      shields the classifier from values that would only arise from
    ///      an oracle bug or a manipulation attempt.
    function _calculateMomentum() internal view returns (uint256 bps, bool failed) {
        try this._readTwapPair() returns (uint256 shortTwap, uint256 longTwap) {
            if (shortTwap == 0 || longTwap == 0) {
                return (10000, true);
            }
            uint256 ratioE18 = (shortTwap * 1e18) / longTwap;
            if (ratioE18 < 0.85e18) bps = 7000;
            else if (ratioE18 < 0.95e18) bps = 8500;
            else if (ratioE18 < 1.05e18) bps = 10000;
            else if (ratioE18 < 1.15e18) bps = 11500;
            else bps = 12500;

            if (bps < MOMENTUM_BPS_FLOOR) bps = MOMENTUM_BPS_FLOOR;
            if (bps > MOMENTUM_BPS_CEILING) bps = MOMENTUM_BPS_CEILING;
            return (bps, false);
        } catch {
            return (10000, true);
        }
    }

    /// @dev External wrapper used purely so `_calculateMomentum` can wrap
    ///      both TWAP reads in a single `try/catch`. Marked `external` and
    ///      called via `this.` so the catch covers any revert path inside
    ///      `capacityOracle.getTWAP` (including out-of-gas in the upstream
    ///      `observe` call). View-only — no state changes.
    function _readTwapPair() external view returns (uint256 shortTwap, uint256 longTwap) {
        require(msg.sender == address(this), "Internal helper");
        shortTwap = capacityOracle.getTWAP(TWAP_SHORT_SECONDS);
        longTwap = capacityOracle.getTWAP(TWAP_LONG_SECONDS);
    }

    /// @dev [Audit fix H-11] When `obligations == 0` (pre-trigger or after
    ///      every outstanding bond has been redeemed), the previous code
    ///      returned `type(uint256).max` to side-step the divide-by-zero.
    ///      That sentinel landed in `_classifySolvency` as `bps >= ULTRA`
    ///      → sLevel 0 (ULTRA SOLVENT), which then drove
    ///      AdaptiveFeeDistributor to its most aggressive burn quadrant
    ///      and let BuybackEngine treat a zero-bond state as "infinite
    ///      collateral surplus". Returning `SOLVENCY_HEALTHY_BPS` (= 10000)
    ///      keeps the division guard (no zero divide) AND classifies the
    ///      empty state as plain HEALTHY (sLevel 1) — the founder's
    ///      desired neutral baseline. Note that `_classifySolvency` uses
    ///      `>= SOLVENCY_HEALTHY_BPS` so 10000 is the LOW edge of the
    ///      HEALTHY bucket, not the high edge of STRESSED.
    function _calculateSolvencyRatio() internal view returns (uint256) {
        uint256 obligations = bondVault.totalCommittedUSD();
        if (obligations == 0) return SOLVENCY_HEALTHY_BPS;
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

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[50] private __gap;
}
