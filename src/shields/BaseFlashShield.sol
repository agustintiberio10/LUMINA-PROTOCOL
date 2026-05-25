// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShieldV2} from "../interfaces/IShieldV2.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IChainlinkL2SequencerUptimeFeed} from "../interfaces/IChainlinkL2SequencerUptimeFeed.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title BaseFlashShield
/// @author Lumina Protocol
/// @notice Abstract base for the Sprint T-30a flash-shield set.
///         Implements the "drop-from-purchase-price" mechanic with
///         direct Chainlink reads (NO EIP-712 signed proofs) plus an L2
///         sequencer-uptime guard.
///
///         ───────────────── TRIGGER MODEL (red-team F-01 fix) ─────────────────
///         The trigger is a *barrier* that must be observed below the strike
///         drop threshold across MULTIPLE BLOCKS — it is NOT a single-tx read.
///         A single `verifyAndCalculate` call records AT MOST ONE confirmation
///         observation, and a confirmation only counts when ALL of the following
///         hold relative to the previously stored observation:
///           - it is in a STRICTLY DIFFERENT block (`block.number` advanced),
///           - the Chainlink `updatedAt` is STRICTLY GREATER than the prior one
///             (a genuinely newer round), and
///           - at least `CONFIRMATION_INTERVAL` (60s) of wall-clock time has
///             elapsed since the prior accepted observation.
///         Only after `ORACLE_CONFIRMATIONS` (3) such spaced sub-barrier
///         observations have accrued does `triggered` become true and the
///         policy finalize with a payout. This makes the previous "free barrier
///         option" exploit (buy + trigger atomically off a single price read)
///         impossible: trigger eligibility now accrues across blocks/calls.
///
///         ───────────────── DWELL (red-team F-01 fix) ─────────────────
///         A policy additionally cannot be triggered/settled until
///         `block.timestamp >= startTimestamp + MIN_DWELL_PERIOD` (5 minutes),
///         independent of how fast confirmations could otherwise be gathered.
///
///         ───────────────── ORACLE FALLBACK (red-team F-03 fix) ─────────────────
///         Oracle-unavailable (stale / sequencer-down / incomplete-round) is
///         DISTINGUISHED from "did not trigger". When the oracle is not
///         evaluable, `verifyAndCalculate` reverts with `ORACLE_UNAVAILABLE`
///         (and `_oracleEvaluable()` returns false) rather than silently
///         finalizing a non-triggered payout. A policy whose window expired
///         while the oracle was unavailable is NEVER finalized as
///         `triggered=false`; it stays pending for retry once the oracle
///         recovers. An already-accrued (confirmed) trigger may still be
///         honored under a longer SETTLEMENT staleness tolerance.
///
///         NOTE (off-chain calibration): because the on-chain barrier now
///         requires sustained sub-barrier dwell, the realized trigger rate is
///         lower than the naive single-read model — `triggerProbBps` may be
///         recalibrated 5-10% lower off-chain. (Comment only; no on-chain knob.)
abstract contract BaseFlashShield is IShieldV2, Initializable, OwnableUpgradeable, UUPSUpgradeable {
    // ═══════ TYPES ═══════
    struct Policy {
        address holder;
        uint256 coverage;
        uint256 strikePrice; // spot at createPolicy
        uint64 startTimestamp;
        uint64 expiresAt;
        bool finalized;
    }

    /// @notice Accrued multi-block barrier confirmation state (F-01).
    /// @dev    `count` is the number of valid spaced sub-barrier observations
    ///         gathered so far. `lastUpdatedAt`/`lastBlock`/`lastObsTimestamp`
    ///         pin the previous accepted observation so the next one can be
    ///         validated as genuinely-newer-and-spaced.
    struct Confirmation {
        uint8 count; // valid spaced observations so far (max ORACLE_CONFIRMATIONS)
        uint64 lastObsTimestamp; // block.timestamp of last accepted observation
        uint64 lastUpdatedAt; // Chainlink updatedAt of last accepted observation
        uint64 lastBlock; // block.number of last accepted observation
    }

    // ═══════ STORAGE (was immutable pre-UUPS; set in initialize) ═══════
    address public router; // CoverRouterV2 / FlashShieldAdapter (onlyRouter)
    IChainlinkAggregator public priceFeed;
    IChainlinkL2SequencerUptimeFeed public sequencerFeed;

    // ═══════ CONSTANTS ═══════
    uint16 internal constant DEDUCTIBLE_BPS = 2000; // 20%
    uint8 internal constant ORACLE_CONFIRMATIONS = 3;
    uint32 internal constant CONFIRMATION_INTERVAL = 60; // >=60s between accepted observations (multi-block)
    uint32 internal constant MIN_DWELL_PERIOD = 5 minutes; // F-01: no trigger before start + 5min
    uint32 internal constant GRACE_PERIOD = 3600; // 1h grace after sequencer recovery
    uint32 internal constant MAX_PRICE_STALENESS = 3600; // updatedAt must be within 1h (live evaluation)
    uint32 internal constant SETTLEMENT_STALENESS = 86400; // F-03: longer tolerance to honor an already-confirmed trigger

    // ═══════ STATE ═══════
    mapping(uint256 => Policy) internal policies;
    /// @notice Per-policy accrued barrier confirmation state (F-01).
    mapping(uint256 => Confirmation) internal confirmations;

    // ═══════ EVENTS ═══════
    event PolicyCreated(
        uint256 indexed policyId,
        address indexed holder,
        uint256 coverage,
        uint256 strikePrice,
        uint64 startTimestamp,
        uint64 expiresAt
    );
    event PolicyVerified(uint256 indexed policyId, bool triggered, uint256 payout, uint256 dropBps, bytes32 reason);
    /// @notice Emitted each time a valid spaced sub-barrier observation is accrued (F-01).
    event ConfirmationObserved(uint256 indexed policyId, uint8 count, uint256 price, uint256 dropBps);

    // ═══════ MODIFIERS ═══════
    modifier onlyRouter() {
        require(msg.sender == router, "NOT_ROUTER");
        _;
    }

    modifier whenSequencerActive() {
        require(sequencerActive(), "SEQUENCER_DOWN");
        _;
    }

    // ═══════ INITIALIZER (UUPS) ═══════
    /// @dev Called once by each concrete shield's `initialize`. Sets the wiring
    ///      that used to be immutable, plus Ownable/UUPS. `_owner` becomes the
    ///      upgrade authority (the deployer/founder via the deploy script).
    function __BaseFlashShield_init(address _router, address _priceFeed, address _sequencerFeed, address _owner)
        internal
        onlyInitializing
    {
        require(_router != address(0), "ZERO_ROUTER");
        require(_priceFeed != address(0), "ZERO_PRICE_FEED");
        require(_owner != address(0), "ZERO_OWNER");
        // sequencerFeed can be address(0) on chains without one (Base mainnet has one)
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        router = _router;
        priceFeed = IChainlinkAggregator(_priceFeed);
        sequencerFeed = IChainlinkL2SequencerUptimeFeed(_sequencerFeed);
    }

    /// @dev UUPS upgrade authorization — only the owner may upgrade the shield.
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ═══════ ABSTRACT (per-shield) ═══════
    function _triggerDropBps() internal view virtual returns (uint16);
    function _window() internal view virtual returns (uint32);
    function asset() external view virtual returns (bytes32);

    // ═══════ INTERNAL ═══════

    /// @notice Returns true if the L2 sequencer is up AND past the grace period.
    /// @dev    If the sequencer feed is unset (address(0)), the chain is
    ///         assumed to be a non-L2 / testnet without an uptime feed and
    ///         the check passes.
    function sequencerActive() internal view returns (bool) {
        if (address(sequencerFeed) == address(0)) return true; // no feed => assume active (testnet)
        (, int256 answer, uint256 startedAt,,) = sequencerFeed.latestRoundData();
        if (answer != 0) return false; // 1 = sequencer down
        if (block.timestamp - startedAt <= GRACE_PERIOD) return false;
        return true;
    }

    /// @notice Raw, validated Chainlink read with round-completeness checks (F-06).
    /// @dev    Returns the price plus the round metadata needed by the multi-block
    ///         confirmation logic. Reverts on any malformed/incomplete round
    ///         BEFORE the staleness subtraction (so a future `updatedAt` cannot
    ///         underflow). Staleness itself is checked by the callers against
    ///         the appropriate window (live vs settlement).
    function _readFeed() internal view returns (uint256 price, uint256 updatedAt) {
        (uint80 roundId, int256 answer, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        startedAt_; // unused (kept for clarity of Chainlink tuple)
        require(answer > 0, "ORACLE_INVALID");
        // F-06: round-completeness checks BEFORE any timestamp arithmetic.
        require(answeredInRound >= roundId, "ORACLE_INCOMPLETE_ROUND");
        require(updatedAt_ != 0, "ORACLE_ROUND_NOT_COMPLETE");
        require(updatedAt_ <= block.timestamp, "ORACLE_FUTURE_TS");
        return (uint256(answer), updatedAt_);
    }

    /// @notice Reads the current Chainlink price, enforcing LIVE freshness
    ///         (`MAX_PRICE_STALENESS`). Used at policy creation and for accruing
    ///         live barrier confirmations.
    function _currentPrice() internal view returns (uint256) {
        (uint256 price, uint256 updatedAt) = _readFeed();
        require(block.timestamp - updatedAt <= MAX_PRICE_STALENESS, "ORACLE_STALE");
        return price;
    }

    /// @notice F-03: true iff the oracle is currently evaluable (sequencer up +
    ///         a fresh, complete round within the LIVE staleness window). Used
    ///         off-chain and by callers to distinguish "oracle unavailable" from
    ///         "did not trigger". Never reverts (returns false on any failure).
    function oracleEvaluable() public view returns (bool) {
        if (!sequencerActive()) return false;
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        if (answer <= 0) return false;
        if (answeredInRound < roundId) return false;
        if (updatedAt == 0 || updatedAt > block.timestamp) return false;
        if (block.timestamp - updatedAt > MAX_PRICE_STALENESS) return false;
        return true;
    }

    // ═══════ EXTERNAL: IShieldV2 ═══════

    function createPolicy(uint256 policyId, address holder, uint256 coverage, uint64 startTimestamp, uint64 expiresAt)
        external
        onlyRouter
        whenSequencerActive
    {
        require(policies[policyId].holder == address(0), "POLICY_EXISTS");
        require(expiresAt > startTimestamp, "INVALID_WINDOW");
        require(expiresAt - startTimestamp == _window(), "WINDOW_MISMATCH");
        uint256 strike = _currentPrice();
        policies[policyId] = Policy({
            holder: holder,
            coverage: coverage,
            strikePrice: strike,
            startTimestamp: startTimestamp,
            expiresAt: expiresAt,
            finalized: false
        });
        emit PolicyCreated(policyId, holder, coverage, strike, startTimestamp, expiresAt);
    }

    /// @notice Accrue (at most one) multi-block barrier confirmation and, once
    ///         enough spaced sub-barrier observations have accumulated, finalize
    ///         the policy as triggered.
    /// @dev    F-01: a single call records AT MOST ONE observation. Trigger
    ///         eligibility accrues across blocks/calls; it cannot be satisfied
    ///         within a single transaction.
    ///
    ///         Return semantics (the accrual path RETURNS rather than reverts
    ///         so that the recorded observation PERSISTS across calls — a revert
    ///         would roll back the SSTORE):
    ///         - `triggered=true`, reason "TRIGGER_DROP": only on the call that
    ///           reaches the 3rd spaced confirmation (policy finalized, payout set).
    ///         - `triggered=false`, reason "ACCRUING": a valid sub-barrier
    ///           observation was accrued (persisted) but the count is < 3.
    ///         - `triggered=false`, reason "RESET": price recovered above the
    ///           barrier; the accrual counter was cleared (persisted).
    ///         - `triggered=false`, reason "WINDOW_EXPIRED": window elapsed and
    ///           the oracle WAS evaluable; finalized non-triggered (F-29).
    ///         - reverts `DWELL_NOT_ELAPSED` before `start + MIN_DWELL_PERIOD`.
    ///         - reverts `SAME_BLOCK_OBSERVATION` / `STALE_ROUND_OBSERVATION` /
    ///           `CONFIRMATION_TOO_SOON`: an observation was rejected for
    ///           insufficient spacing (no state changes; prior observations from
    ///           earlier txs remain committed).
    ///         - reverts `ORACLE_*` (stale / incomplete / sequencer): the oracle
    ///           is unavailable; the adapter treats this as `ORACLE_UNAVAILABLE`
    ///           and NEVER settles the policy false (F-03).
    function verifyAndCalculate(uint256 policyId)
        external
        returns (bool triggered, uint256 payout, address holder, bytes32 reason)
    {
        require(msg.sender == router, "NOT_ROUTER");
        Policy storage p = policies[policyId];
        require(p.holder != address(0), "POLICY_NOT_FOUND");
        require(!p.finalized, "ALREADY_FINALIZED");
        holder = p.holder;

        // F-03: if the window has expired we must distinguish "expired & oracle
        // was usable" (→ legitimately settle false) from "expired & oracle was
        // unavailable" (→ do NOT finalize false; let it retry).
        bool windowExpired = block.timestamp > p.expiresAt;

        // F-01: dwell gate — no trigger/settlement before start + MIN_DWELL_PERIOD.
        // (A pre-dwell policy cannot have expired given any sane window >= dwell,
        //  but we check explicitly so the option cannot be exercised early.)
        if (!windowExpired) {
            require(block.timestamp >= uint256(p.startTimestamp) + MIN_DWELL_PERIOD, "DWELL_NOT_ELAPSED");
        }

        // F-03 + F-01: oracle availability gates BOTH accrual and a clean
        // window-expiry settlement. Sequencer must be up.
        require(sequencerActive(), "SEQUENCER_DOWN");

        if (windowExpired) {
            // Only settle false if the oracle is genuinely evaluable right now
            // (under the LONGER settlement staleness tolerance, so a brief
            // staleness blip does not deny a legitimate non-trigger settlement
            // while still refusing to finalize during a real outage). If the
            // oracle is unavailable we revert ORACLE_UNAVAILABLE and the policy
            // stays pending for retry — it is never finalized=false blindly.
            (uint256 sPrice, uint256 sUpdatedAt) = _readFeed();
            require(block.timestamp - sUpdatedAt <= SETTLEMENT_STALENESS, "ORACLE_UNAVAILABLE");

            // If a full trigger had already accrued (3 confirmations) we honor
            // it even at/after expiry using the last evaluated price.
            if (confirmations[policyId].count >= ORACLE_CONFIRMATIONS) {
                return _finalizeTriggered(policyId, p, _dropBps(p.strikePrice, sPrice));
            }
            // Otherwise the window expired without a sustained barrier breach.
            p.finalized = true;
            reason = bytes32("WINDOW_EXPIRED");
            emit PolicyVerified(policyId, false, 0, 0, reason);
            return (false, 0, holder, reason);
        }

        // ── LIVE path: accrue one spaced confirmation ──
        // CRITICAL (F-01): accrual MUST persist across calls, so this path does
        // NOT revert when it merely needs more confirmations — it RETURNS
        // `triggered=false` with reason "ACCRUING" (or "RESET") so the recorded
        // observation is committed to storage. Only a NEW, accepted observation
        // advances the count; a full trigger (3 spaced sub-barrier observations
        // across distinct blocks) is the ONLY way `triggered=true` is returned.
        //
        // Spacing VIOLATIONS (same block / not-newer round / <60s) DO revert:
        // there is no state to lose (the observation is rejected, prior
        // observations remain committed from their own earlier txs), and the
        // revert tells the keeper "retry later". An oracle-unavailable read also
        // reverts here (ORACLE_STALE / round checks) → treated as
        // ORACLE_UNAVAILABLE by the adapter and never settled false.
        (uint256 price, uint256 updatedAt) = _currentPrice2();

        uint256 dropBps = _dropBps(p.strikePrice, price);
        Confirmation storage c = confirmations[policyId];

        if (dropBps < _triggerDropBps()) {
            // Price above the barrier — reset accrual (must be CONSECUTIVE
            // sustained breaches). Persist the reset; do NOT revert.
            if (c.count != 0) delete confirmations[policyId];
            reason = bytes32("RESET");
            emit PolicyVerified(policyId, false, 0, dropBps, reason);
            return (false, 0, holder, reason);
        }

        // Sub-barrier observation. Validate spacing vs the previous one.
        if (c.count == 0) {
            _recordObservation(policyId, c, updatedAt);
        } else {
            require(block.number > c.lastBlock, "SAME_BLOCK_OBSERVATION");
            require(updatedAt > c.lastUpdatedAt, "STALE_ROUND_OBSERVATION");
            require(block.timestamp >= uint256(c.lastObsTimestamp) + CONFIRMATION_INTERVAL, "CONFIRMATION_TOO_SOON");
            _recordObservation(policyId, c, updatedAt);
        }

        if (c.count >= ORACLE_CONFIRMATIONS) {
            return _finalizeTriggered(policyId, p, dropBps);
        }

        // Valid observation accrued but not enough yet — persist (no revert).
        reason = bytes32("ACCRUING");
        emit PolicyVerified(policyId, false, 0, dropBps, reason);
        return (false, 0, holder, reason);
    }

    // ═══════ INTERNAL HELPERS ═══════

    function _dropBps(uint256 strike, uint256 price) internal pure returns (uint256) {
        if (price >= strike) return 0;
        return ((strike - price) * 10_000) / strike;
    }

    function _recordObservation(uint256 policyId, Confirmation storage c, uint256 updatedAt) internal {
        c.count += 1;
        c.lastObsTimestamp = uint64(block.timestamp);
        c.lastUpdatedAt = uint64(updatedAt);
        c.lastBlock = uint64(block.number);
        emit ConfirmationObserved(policyId, c.count, 0, 0);
    }

    function _finalizeTriggered(uint256 policyId, Policy storage p, uint256 dropBps)
        internal
        returns (bool, uint256, address, bytes32)
    {
        uint256 payout = (p.coverage * (10_000 - DEDUCTIBLE_BPS)) / 10_000;
        p.finalized = true;
        bytes32 reason = bytes32("TRIGGER_DROP");
        emit PolicyVerified(policyId, true, payout, dropBps, reason);
        return (true, payout, p.holder, reason);
    }

    /// @notice Live price read returning both price and updatedAt with the
    ///         LIVE staleness window enforced. Reverting here is treated as an
    ///         ORACLE_UNAVAILABLE condition by callers (F-03).
    function _currentPrice2() internal view returns (uint256 price, uint256 updatedAt) {
        (price, updatedAt) = _readFeed();
        require(block.timestamp - updatedAt <= MAX_PRICE_STALENESS, "ORACLE_STALE");
    }

    function getPolicyInfo(uint256 policyId) external view returns (address, uint256, uint256, uint64, uint64, bool) {
        Policy storage p = policies[policyId];
        return (p.holder, p.coverage, p.strikePrice, p.startTimestamp, p.expiresAt, p.finalized);
    }

    /// @notice View accessor for accrued confirmation progress (tests / off-chain).
    function getConfirmation(uint256 policyId) external view returns (uint8 count, uint64 lastObsTimestamp) {
        Confirmation storage c = confirmations[policyId];
        return (c.count, c.lastObsTimestamp);
    }

    /// @dev Storage gap for future upgrades (UUPS). Account for the 3 wiring
    ///      slots (router, priceFeed, sequencerFeed) + 2 mappings already declared.
    uint256[47] private __gap;
}
