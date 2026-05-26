// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FounderVestingV2
/// @notice 8M LUMINA locked until AltSeason conditions, ETH-override threshold, or 3-year fallback.
///         Hardened successor to {FounderVesting} addressing audit finding F-12.
///
/// @dev Three independent unlock paths (first to satisfy wins):
///      PATH 1 — 2-of-3 AltSeason conditions, GENUINELY sustained 1 day:
///        A: ETH/BTC > 0.050
///        B: ETH > $4,000           (now computed INDEPENDENT of the BTC feed — see F-12)
///        C: Aave V3 USDC borrow rate > 7% APY
///      PATH 2 — ETH > $5,000 USD, GENUINELY sustained: at least 24h AND at least 24 spaced
///               observations, whichever is later (independent of PATH 1) — [INFO-6 fix]
///      PATH 3 — Fallback after 1095 days (3 years) from deploy
///      Release: 3 tranches every 31 days after trigger.
///
/// @dev ── F-12 FIXES vs. FounderVesting (v1) ──────────────────────────────────────────────
///      (1) "Sustained 1 day" no longer accepts just two snapshots 24h apart. A path may only
///          trigger after it has accumulated `MIN_OBSERVATIONS` (24) observations of the
///          condition being TRUE, each spaced at least `MIN_OBSERVATION_SPACING` (1h) apart, AND
///          the elapsed wall-clock window is >= SUSTAINED_DURATION. ANY observation where the
///          condition is false resets that path's accumulator to zero (start fresh). This makes a
///          single-block / single-snapshot oracle spike insufficient to unlock.
///      (2) condB (ETH > $4,000) is evaluated from the ETH/USD feed directly and is NO LONGER
///          gated behind `btcPrice > 0`. Only condA (the ETH/BTC ratio) needs the BTC feed.
///
/// @dev ── MIGRATION NOTE (from FounderVesting v1) ────────────────────────────────────────────
///      FounderVesting v1 is a plain (non-upgradeable) Ownable contract, so this fix ships as a
///      brand-new contract. Migration is a FOUNDER ACTION (no deployer key in CI):
///        1. Deploy FounderVestingV2 with the same (oracle, aavePool, luminaToken, usdc, recipient)
///           plus the v1 carry-over state (`_initialTranchesReleased`, `_initialTotalReleased`,
///           `_alreadyTriggered`, `_triggerTimestamp`) read from the live v1 contract.
///        2. Transfer the v1 LUMINA balance (8M minus anything already released) to V2.
///        3. Update all off-chain/on-chain references (LuminaTokenV2 was minted to the v1 address at
///           genesis; the balance move in step 2 is what matters operationally).
///        4. Record an ADR documenting the cutover and freeze v1 (renounce / leave dormant).
///      Storage semantics are preserved (recipient, trigger flags, tranche counters) so the carry
///      values map 1:1 from v1 `getStatus()`.
contract FounderVestingV2 is Ownable {
    // ═══════ ORACLE / AAVE INTERFACES ═══════
    // (kept identical to v1 so the same oracle + Aave pool addresses are reused)

    // ═══════ CONSTANTS ═══════
    uint256 public constant ETH_BTC_THRESHOLD = 50e15; // 0.050 in 18 decimals
    int256 public constant ETH_USD_THRESHOLD = 400_000_000_000; // $4,000 in 8 decimals
    uint256 public constant BORROW_RATE_THRESHOLD = 7e25; // 7% APY in RAY (27 decimals)
    uint256 public constant SUSTAINED_DURATION = 1 days;
    uint256 public constant TRANCHE_INTERVAL = 31 days;
    uint256 public constant TOTAL_TRANCHES = 3;
    uint256 public constant FALLBACK_DURATION = 1095 days; // 3 years
    uint256 public constant TOTAL_AMOUNT = 8_000_000 * 1e18; // 8M LUMINA
    uint256 public constant TRANCHE_AMOUNT = TOTAL_AMOUNT / TOTAL_TRANCHES; // ~2.666M per tranche
    uint256 public constant ETH_OVERRIDE_THRESHOLD = 500_000_000_000; // $5,000 USD * 1e8

    /// @notice [F-12] Minimum number of spaced TRUE observations required before a path can trigger.
    /// @dev    [INFO-6 fix] A path triggers only after at least 24h AND at least 24 spaced
    ///         observations, whichever is later — not exactly "24 hourly" snapshots. The
    ///         window matures on wall-clock time while spacing throttles the observation count.
    uint256 public constant MIN_OBSERVATIONS = 24;
    /// @notice [F-12] Minimum spacing between counted observations. Observations closer than this
    ///         are ignored for counting (but still re-validate the condition / can reset it),
    ///         preventing a flood of same-block / same-minute calls from satisfying the count.
    uint256 public constant MIN_OBSERVATION_SPACING = 1 hours;

    // ═══════ IMMUTABLES ═══════
    ILuminaOracleReader public immutable oracle;
    address public immutable aavePool;
    IERC20 public immutable luminaToken;
    address public immutable usdc;
    uint256 public immutable deployedAt;

    // ═══════ STATE (layout mirrors v1, with F-12 accumulators appended) ═══════
    address public recipient;
    bool public altSeasonTriggered;
    uint256 public triggerTimestamp;
    uint256 public tranchesReleased;
    uint256 public totalReleased;

    // ── PATH 1 accumulator ──
    uint256 public conditionsMetSince; // wall-clock start of the current sustained window (0 = none)
    uint256 public conditionsObservations; // count of spaced TRUE observations in current window
    uint256 public conditionsLastObservation; // timestamp of last COUNTED observation

    // ── PATH 2 (ETH override) accumulator ──
    uint256 public overrideMetSince;
    uint256 public overrideObservations;
    uint256 public overrideLastObservation;

    // ═══════ EVENTS ═══════
    event ConditionsChecked(bool condA, bool condB, bool condC, uint256 metCount, uint256 timestamp);
    event SustainedPeriodStarted(uint256 timestamp);
    event SustainedPeriodReset(uint256 timestamp);
    event ObservationCounted(uint8 indexed path, uint256 observationCount, uint256 timestamp);
    event AltSeasonTriggered(uint256 timestamp);
    event OverrideConditionMet(uint256 indexed ethPrice, uint256 timestamp);
    event OverrideConditionLost(uint256 indexed ethPrice, uint256 timestamp);
    event OverrideTriggered(uint256 indexed ethPrice, uint256 timestamp);
    event TrancheReleased(uint256 trancheNumber, uint256 amount, address recipient);
    event RecipientUpdated(address oldRecipient, address newRecipient);
    event FallbackTriggered(uint256 timestamp);
    event MigratedState(uint256 tranchesReleased, uint256 totalReleased, bool triggered, uint256 triggerTimestamp);

    /// @param _oracle                 Lumina oracle reader (same as v1).
    /// @param _aavePool               Aave V3 pool (same as v1).
    /// @param _luminaToken            LUMINA token.
    /// @param _usdc                   USDC address (Aave reserve key).
    /// @param _recipient              Vesting recipient.
    /// @param _initialTranchesReleased  v1 carry: tranches already released (0 for a clean deploy).
    /// @param _initialTotalReleased     v1 carry: LUMINA already released (0 for a clean deploy).
    /// @param _alreadyTriggered         v1 carry: whether a path already triggered in v1.
    /// @param _triggerTimestamp         v1 carry: the v1 trigger timestamp (0 if not triggered).
    constructor(
        address _oracle,
        address _aavePool,
        address _luminaToken,
        address _usdc,
        address _recipient,
        uint256 _initialTranchesReleased,
        uint256 _initialTotalReleased,
        bool _alreadyTriggered,
        uint256 _triggerTimestamp
    ) Ownable(msg.sender) {
        require(_oracle != address(0), "Zero oracle");
        require(_aavePool != address(0), "Zero aavePool");
        require(_luminaToken != address(0), "Zero token");
        require(_usdc != address(0), "Zero usdc");
        require(_recipient != address(0), "Zero recipient");
        require(_initialTranchesReleased <= TOTAL_TRANCHES, "Bad tranches carry");
        require(_initialTotalReleased <= TOTAL_AMOUNT, "Bad released carry");
        if (_alreadyTriggered) {
            require(_triggerTimestamp != 0, "Triggered w/o ts");
        } else {
            require(
                _triggerTimestamp == 0 && _initialTranchesReleased == 0 && _initialTotalReleased == 0, "Stale carry"
            );
        }

        oracle = ILuminaOracleReader(_oracle);
        aavePool = _aavePool;
        luminaToken = IERC20(_luminaToken);
        usdc = _usdc;
        recipient = _recipient;
        deployedAt = block.timestamp;

        // Migration carry-over from v1.
        tranchesReleased = _initialTranchesReleased;
        totalReleased = _initialTotalReleased;
        altSeasonTriggered = _alreadyTriggered;
        triggerTimestamp = _triggerTimestamp;

        emit MigratedState(_initialTranchesReleased, _initialTotalReleased, _alreadyTriggered, _triggerTimestamp);
    }

    // ═══════ CORE: checkAltSeason() ═══════
    /// @notice Evaluates PATH 1 (2-of-3 sustained) AND PATH 2 (ETH override sustained).
    ///         A path triggers only once it has accumulated MIN_OBSERVATIONS spaced TRUE
    ///         observations across a >= SUSTAINED_DURATION window. Any FALSE observation resets
    ///         that path's accumulator. First path to fully satisfy wins; later paths are no-ops.
    function checkAltSeason() external {
        require(!altSeasonTriggered, "Already triggered");

        (bool condA, bool condB, bool condC, int256 ethPrice) = _evaluateAllConditions();

        uint256 metCount = (condA ? 1 : 0) + (condB ? 1 : 0) + (condC ? 1 : 0);
        bool ethOverride = ethPrice > 0 && uint256(ethPrice) > ETH_OVERRIDE_THRESHOLD;

        emit ConditionsChecked(condA, condB, condC, metCount, block.timestamp);

        // ── PATH 1: 2-of-3, genuinely sustained 1 day ──
        if (metCount >= 2) {
            if (_observeAndCheck(1)) {
                altSeasonTriggered = true;
                triggerTimestamp = block.timestamp;
                emit AltSeasonTriggered(block.timestamp);
                return;
            }
        } else {
            _resetPath1();
        }

        // ── PATH 2: ETH > $5,000, genuinely sustained 1 day (independent of PATH 1) ──
        if (ethOverride) {
            if (overrideMetSince == 0) {
                emit OverrideConditionMet(uint256(ethPrice), block.timestamp);
            }
            if (_observeAndCheck(2)) {
                altSeasonTriggered = true;
                triggerTimestamp = block.timestamp;
                emit OverrideTriggered(uint256(ethPrice), block.timestamp);
                return;
            }
        } else {
            if (overrideMetSince != 0) {
                emit OverrideConditionLost(ethPrice > 0 ? uint256(ethPrice) : 0, block.timestamp);
            }
            _resetPath2();
        }
    }

    /// @dev [F-12] Records a TRUE observation for the given path and reports whether the path now
    ///      satisfies the sustained requirement (>= MIN_OBSERVATIONS spaced observations across a
    ///      >= SUSTAINED_DURATION window). Observations closer than MIN_OBSERVATION_SPACING to the
    ///      previous counted one do NOT increment the count (anti-spam), but the window keeps
    ///      maturing on wall-clock time.
    function _observeAndCheck(uint8 path) private returns (bool satisfied) {
        if (path == 1) {
            if (conditionsMetSince == 0) {
                conditionsMetSince = block.timestamp;
                conditionsObservations = 1;
                conditionsLastObservation = block.timestamp;
                emit SustainedPeriodStarted(block.timestamp);
                emit ObservationCounted(1, 1, block.timestamp);
            } else if (block.timestamp - conditionsLastObservation >= MIN_OBSERVATION_SPACING) {
                conditionsObservations += 1;
                conditionsLastObservation = block.timestamp;
                emit ObservationCounted(1, conditionsObservations, block.timestamp);
            }
            satisfied = conditionsObservations >= MIN_OBSERVATIONS
                && block.timestamp - conditionsMetSince >= SUSTAINED_DURATION;
        } else {
            if (overrideMetSince == 0) {
                overrideMetSince = block.timestamp;
                overrideObservations = 1;
                overrideLastObservation = block.timestamp;
                emit ObservationCounted(2, 1, block.timestamp);
            } else if (block.timestamp - overrideLastObservation >= MIN_OBSERVATION_SPACING) {
                overrideObservations += 1;
                overrideLastObservation = block.timestamp;
                emit ObservationCounted(2, overrideObservations, block.timestamp);
            }
            satisfied =
                overrideObservations >= MIN_OBSERVATIONS && block.timestamp - overrideMetSince >= SUSTAINED_DURATION;
        }
    }

    function _resetPath1() private {
        if (conditionsMetSince != 0 || conditionsObservations != 0) {
            conditionsMetSince = 0;
            conditionsObservations = 0;
            conditionsLastObservation = 0;
            emit SustainedPeriodReset(block.timestamp);
        }
    }

    function _resetPath2() private {
        if (overrideMetSince != 0 || overrideObservations != 0) {
            overrideMetSince = 0;
            overrideObservations = 0;
            overrideLastObservation = 0;
        }
    }

    // ═══════ PATH 3: triggerFallback() ═══════
    function triggerFallback() external {
        require(!altSeasonTriggered, "Already triggered");
        require(block.timestamp >= deployedAt + FALLBACK_DURATION, "Fallback not reached");

        altSeasonTriggered = true;
        triggerTimestamp = block.timestamp;
        emit FallbackTriggered(block.timestamp);
    }

    // ═══════ releaseTranche() ═══════
    function releaseTranche() external {
        require(altSeasonTriggered, "Not triggered");
        require(tranchesReleased < TOTAL_TRANCHES, "All tranches released");

        uint256 nextTranche = tranchesReleased;
        uint256 releaseTime = triggerTimestamp + (nextTranche * TRANCHE_INTERVAL);
        require(block.timestamp >= releaseTime, "Too early");

        tranchesReleased++;

        // Last tranche gets the remainder to avoid rounding dust.
        uint256 amount = (nextTranche == TOTAL_TRANCHES - 1) ? TOTAL_AMOUNT - totalReleased : TRANCHE_AMOUNT;

        totalReleased += amount;
        require(luminaToken.transfer(recipient, amount), "Transfer failed");

        emit TrancheReleased(tranchesReleased, amount, recipient);
    }

    // ═══════ updateRecipient() ═══════
    function updateRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Zero address");
        address old = recipient;
        recipient = newRecipient;
        emit RecipientUpdated(old, newRecipient);
    }

    // ═══════ VIEW FUNCTIONS ═══════
    function getConditions() external view returns (bool condA, bool condB, bool condC, bool ethOverride) {
        int256 ethPrice;
        (condA, condB, condC, ethPrice) = _evaluateAllConditions();
        ethOverride = ethPrice > 0 && uint256(ethPrice) > ETH_OVERRIDE_THRESHOLD;
    }

    function getStatus()
        external
        view
        returns (
            bool triggered,
            uint256 _triggerTimestamp,
            uint256 _tranchesReleased,
            uint256 _totalReleased,
            uint256 _conditionsMetSince,
            uint256 _overrideMetSince,
            uint256 nextReleaseAt,
            uint256 fallbackAt
        )
    {
        triggered = altSeasonTriggered;
        _triggerTimestamp = triggerTimestamp;
        _tranchesReleased = tranchesReleased;
        _totalReleased = totalReleased;
        _conditionsMetSince = conditionsMetSince;
        _overrideMetSince = overrideMetSince;
        fallbackAt = deployedAt + FALLBACK_DURATION;
        if (altSeasonTriggered && tranchesReleased < TOTAL_TRANCHES) {
            nextReleaseAt = triggerTimestamp + (tranchesReleased * TRANCHE_INTERVAL);
        }
    }

    /// @notice [F-12] Observation progress for the two sustained paths (for off-chain monitoring).
    function getSustainProgress()
        external
        view
        returns (uint256 path1Observations, uint256 path1Since, uint256 path2Observations, uint256 path2Since)
    {
        return (conditionsObservations, conditionsMetSince, overrideObservations, overrideMetSince);
    }

    // ═══════ INTERNAL ═══════
    /// @dev Returns the 3 PATH 1 conditions plus the raw ethPrice that PATH 2 needs.
    ///      [F-12] condB (ETH > $4,000) is computed from the ETH/USD feed DIRECTLY and is no longer
    ///      gated behind a valid BTC price. Only condA (the ETH/BTC ratio) requires the BTC feed.
    function _evaluateAllConditions() internal view returns (bool condA, bool condB, bool condC, int256 ethPriceOut) {
        int256 ethPrice;
        int256 btcPrice;

        try oracle.getLatestPrice(bytes32("ETH")) returns (int256 _eth) {
            if (_eth > 0) ethPrice = _eth;
        } catch {}

        try oracle.getLatestPrice(bytes32("BTC")) returns (int256 _btc) {
            if (_btc > 0) btcPrice = _btc;
        } catch {}

        // [F-12] condB depends ONLY on the ETH/USD feed — independent of the BTC feed.
        if (ethPrice > 0) {
            condB = ethPrice > ETH_USD_THRESHOLD;
        }

        // condA (ETH/BTC ratio) genuinely needs both feeds.
        if (ethPrice > 0 && btcPrice > 0) {
            uint256 ratio = uint256(ethPrice) * 1e18 / uint256(btcPrice);
            condA = ratio > ETH_BTC_THRESHOLD;
        }

        try IAaveV3PoolReader(aavePool).getReserveData(usdc) returns (IAaveV3PoolReader.ReserveData memory data) {
            condC = uint256(data.currentVariableBorrowRate) > BORROW_RATE_THRESHOLD;
        } catch {}

        ethPriceOut = ethPrice;
    }
}

interface ILuminaOracleReader {
    function getLatestPrice(bytes32 asset) external view returns (int256);
}

interface IAaveV3PoolReader {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    function getReserveData(address asset) external view returns (ReserveData memory);
}
