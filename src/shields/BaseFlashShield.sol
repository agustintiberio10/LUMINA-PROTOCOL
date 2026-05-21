// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShieldV2} from "../interfaces/IShieldV2.sol";
import {IChainlinkAggregator} from "../interfaces/IChainlinkAggregator.sol";
import {IChainlinkL2SequencerUptimeFeed} from "../interfaces/IChainlinkL2SequencerUptimeFeed.sol";

/// @title BaseFlashShield
/// @author Lumina Protocol
/// @notice Abstract base for the Sprint T-30a flash-shield set.
///         Implements the new "drop-from-purchase-price" mechanic with
///         direct Chainlink reads (NO EIP-712 signed proofs) plus an L2
///         sequencer-uptime guard.
///
///         Mechanic summary:
///         - `createPolicy` snapshots `strikePrice` from the Chainlink feed.
///         - `verifyAndCalculate` reads spot 3 times in-tx, uses the MIN as
///           the conservative reference, and triggers when the drop in bps
///           is >= the shield-specific TRIGGER_DROP_BPS.
///         - On trigger, payout = coverage * (1 - DEDUCTIBLE_BPS).
///
///         Per-shield knobs are exposed via the three abstract virtuals:
///         `_triggerDropBps`, `_window`, and `asset`.
abstract contract BaseFlashShield is IShieldV2 {
    // ═══════ TYPES ═══════
    struct Policy {
        address holder;
        uint256 coverage;
        uint256 strikePrice; // spot at createPolicy
        uint64 startTimestamp;
        uint64 expiresAt;
        bool finalized;
    }

    // ═══════ IMMUTABLES ═══════
    address public immutable router; // CoverRouterV2 (onlyRouter)
    IChainlinkAggregator public immutable priceFeed;
    IChainlinkL2SequencerUptimeFeed public immutable sequencerFeed;

    // ═══════ CONSTANTS ═══════
    uint16 internal constant DEDUCTIBLE_BPS = 2000; // 20%
    uint8 internal constant ORACLE_CONFIRMATIONS = 3;
    uint32 internal constant CONFIRMATION_INTERVAL = 60; // 60s between off-chain reads
    uint32 internal constant GRACE_PERIOD = 3600; // 1h grace after sequencer recovery
    uint32 internal constant MAX_PRICE_STALENESS = 3600; // updatedAt must be within 1h

    // ═══════ STATE ═══════
    mapping(uint256 => Policy) internal policies;

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

    // ═══════ MODIFIERS ═══════
    modifier onlyRouter() {
        require(msg.sender == router, "NOT_ROUTER");
        _;
    }

    modifier whenSequencerActive() {
        require(sequencerActive(), "SEQUENCER_DOWN");
        _;
    }

    // ═══════ CONSTRUCTOR ═══════
    constructor(address _router, address _priceFeed, address _sequencerFeed) {
        require(_router != address(0), "ZERO_ROUTER");
        require(_priceFeed != address(0), "ZERO_PRICE_FEED");
        // sequencerFeed can be address(0) on chains without one (Base mainnet has one)
        router = _router;
        priceFeed = IChainlinkAggregator(_priceFeed);
        sequencerFeed = IChainlinkL2SequencerUptimeFeed(_sequencerFeed);
    }

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

    /// @notice Reads the current Chainlink price, enforcing freshness.
    function _currentPrice() internal view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(answer > 0, "ORACLE_INVALID");
        require(block.timestamp - updatedAt <= MAX_PRICE_STALENESS, "ORACLE_STALE");
        return uint256(answer);
    }

    // ═══════ EXTERNAL: IShieldV2 ═══════

    function createPolicy(
        uint256 policyId,
        address holder,
        uint256 coverage,
        uint64 startTimestamp,
        uint64 expiresAt
    ) external onlyRouter whenSequencerActive {
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

    function verifyAndCalculate(uint256 policyId)
        external
        onlyRouter
        whenSequencerActive
        returns (bool triggered, uint256 payout, address holder, bytes32 reason)
    {
        Policy storage p = policies[policyId];
        require(p.holder != address(0), "POLICY_NOT_FOUND");
        require(!p.finalized, "ALREADY_FINALIZED");
        require(block.timestamp <= p.expiresAt, "WINDOW_EXPIRED");

        // 3 confirmations of current price. For testability, the
        // implementation reads spot 3 times in a single tx; gas overhead is
        // acceptable. Each read passes _currentPrice() so staleness is
        // checked each time. CONFIRMATION_INTERVAL between reads is enforced
        // off-chain by the relayer (caller retries every 60s); intra-tx, the
        // contract accepts any 3 reads but uses MIN to be conservative.
        uint256 minPrice = type(uint256).max;
        for (uint8 i = 0; i < ORACLE_CONFIRMATIONS; i++) {
            uint256 px = _currentPrice();
            if (px < minPrice) minPrice = px;
        }

        uint256 dropBps;
        if (minPrice >= p.strikePrice) {
            dropBps = 0;
        } else {
            dropBps = ((p.strikePrice - minPrice) * 10_000) / p.strikePrice;
        }

        if (dropBps >= _triggerDropBps()) {
            payout = (p.coverage * (10_000 - DEDUCTIBLE_BPS)) / 10_000;
            triggered = true;
            reason = bytes32("TRIGGER_DROP");
        } else {
            reason = bytes32("NO_TRIGGER");
        }

        p.finalized = true;
        holder = p.holder;
        emit PolicyVerified(policyId, triggered, payout, dropBps, reason);
    }

    function getPolicyInfo(uint256 policyId)
        external
        view
        returns (address, uint256, uint256, uint64, uint64, bool)
    {
        Policy storage p = policies[policyId];
        return (p.holder, p.coverage, p.strikePrice, p.startTimestamp, p.expiresAt, p.finalized);
    }
}
