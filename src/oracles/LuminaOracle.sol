// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/**
 * @title LuminaOracle
 * @author Lumina Protocol
 * @notice Concrete oracle for Lumina Protocol. Two responsibilities:
 *
 *   1. SPOT READS — getLatestPrice(asset)
 *      Reads the latest price from a registered Chainlink feed.
 *      Used by Shields at policy creation (e.g., BSS strikePrice, IL strikePrice).
 *      Validates: sequencer up, grace period elapsed, staleness, round completeness, price > 0.
 *
 *   2. PROOF VERIFICATION — verifySignature(digest, signature)
 *      Recovers ECDSA signer from a digest + signature.
 *      Used by CoverRouter (EIP-712 quote verification) and all Shields
 *      (oracle-signed TWAP proofs at claim time).
 *
 * ARCHITECTURE NOTES:
 *   - TWAP computation happens OFF-CHAIN in the Lumina backend.
 *     The backend reads multiple Chainlink rounds, computes the TWAP,
 *     signs the result with the oracleKey, and the agent submits it on-chain.
 *   - This contract does NOT compute TWAPs. It provides spot reads for
 *     policy creation and signature verification for claim proofs.
 *   - NOT upgradeable. If Oracle needs changes → deploy new, update Router
 *     via setOracle(). Shields have immutable oracle — redeploy if needed.
 *
 * L2 SEQUENCER PROTECTION (Base-specific):
 *   [FIX] When Base L2's sequencer goes down, Chainlink can't update prices.
 *   When it restarts, stale prices are served briefly. An attacker could buy
 *   BSS/IL with a pre-crash strikePrice. We check the Chainlink Sequencer
 *   Uptime Feed and enforce a grace period after restart.
 *
 * CHAINLINK FEEDS ON BASE L2 (chain 8453):
 *   ETH/USD:  0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
 *   BTC/USD:  0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F
 *   USDC/USD: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B
 *   USDT/USD: 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9
 *   DAI/USD:  0x591e79239a7d679378eC8c847e5038150364C78F
 *
 * @dev Ownable for admin operations (key rotation, feed management).
 */
contract LuminaOracle is IOracle, Ownable {
    using ECDSA for bytes32;

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    /// @notice [FIX] Grace period after sequencer restarts before accepting prices.
    ///         Prevents stale-price attacks during L2 sequencer recovery.
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    // ═══════════════════════════════════════════════════════════
    //  STRUCTS
    // ═══════════════════════════════════════════════════════════

    struct FeedConfig {
        IAggregatorV3 feed;         // Chainlink aggregator
        uint256 maxStaleness;       // Max seconds since last update (heartbeat)
        bool active;                // Feed is registered and active
    }

    // ═══════════════════════════════════════════════════════════
    //  STORAGE
    // ═══════════════════════════════════════════════════════════

    /// @notice Authorized signing key for quotes and proofs
    address private _oracleKey;

    /// @notice Feed registry: asset identifier → Chainlink config
    mapping(bytes32 => FeedConfig) private _feeds;

    /// @notice All registered asset identifiers (for enumeration)
    /// @dev Soft-delete: removeFeed sets active=false but does NOT remove from this array.
    ///      Callers of getAllAssets() must check isFeedActive() for each entry.
    bytes32[] private _assetIds;

    /// @notice [FIX] Chainlink L2 Sequencer Uptime Feed
    IAggregatorV3 private immutable _sequencerUptimeFeed;

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event OracleKeyRotated(address indexed oldKey, address indexed newKey);
    event FeedRegistered(bytes32 indexed asset, address indexed feed, uint256 maxStaleness);
    event FeedUpdated(bytes32 indexed asset, address indexed feed, uint256 maxStaleness);
    event FeedRemoved(bytes32 indexed asset);

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error ZeroAddress(string param);
    error ZeroValue(string param);              // [FIX] Dedicated error for non-address zero values
    error FeedNotRegistered(bytes32 asset);
    error FeedAlreadyRegistered(bytes32 asset);
    error StalePriceAsset(bytes32 asset, uint256 updatedAt, uint256 maxStaleness);
    error InvalidPriceAsset(bytes32 asset, int256 price);
    error IncompleteRound(bytes32 asset, uint80 roundId, uint80 answeredInRound);
    error InvalidSignatureLength();
    error SequencerDown();                      // [FIX] L2 sequencer is currently offline
    error SequencerGracePeriodNotOver();         // [FIX] Sequencer restarted too recently

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    /**
     * @param owner_ Admin address (multisig recommended)
     * @param oracleKey_ Initial signing key (backend EOA)
     * @param sequencerUptimeFeed_ Chainlink L2 Sequencer Uptime Feed on Base.
     *        Set to address(0) for testnet deployment (skips sequencer check).
     */
    constructor(
        address owner_,
        address oracleKey_,
        address sequencerUptimeFeed_
    ) Ownable(owner_) {
        if (oracleKey_ == address(0)) revert ZeroAddress("oracleKey");
        _oracleKey = oracleKey_;
        _sequencerUptimeFeed = IAggregatorV3(sequencerUptimeFeed_);
        emit OracleKeyRotated(address(0), oracleKey_);
    }

    // ═══════════════════════════════════════════════════════════
    //  IOracle — SPOT READS
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IOracle
    function getLatestPrice(bytes32 asset) external view returns (int256 price) {
        // [FIX] Check L2 sequencer health before reading any price feed.
        // If sequencer is down or just restarted, prices may be stale/exploitable.
        _checkSequencer();

        FeedConfig storage config = _feeds[asset];
        if (!config.active) revert FeedNotRegistered(asset);

        (
            uint80 roundId,
            int256 answer,
            /* startedAt */,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = config.feed.latestRoundData();

        // Validate price is positive
        if (answer <= 0) revert InvalidPriceAsset(asset, answer);

        // Validate round completeness (prevents reading partial/pending rounds)
        if (answeredInRound < roundId) {
            revert IncompleteRound(asset, roundId, answeredInRound);
        }

        // [FIX] Validate staleness with underflow protection.
        // On L2, timestamp sync issues can cause updatedAt > block.timestamp briefly.
        // Instead of Solidity 0.8 panic (opaque revert), we emit a clear error.
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > config.maxStaleness) {
            revert StalePriceAsset(asset, updatedAt, config.maxStaleness);
        }

        price = answer;
    }

    // ═══════════════════════════════════════════════════════════
    //  IOracle — SIGNATURE VERIFICATION
    // ═══════════════════════════════════════════════════════════

    /// @inheritdoc IOracle
    function verifySignature(
        bytes32 digest,
        bytes calldata signature
    ) external view returns (address signer) {
        // Signature must be 65 bytes (r, s, v)
        if (signature.length != 65) revert InvalidSignatureLength();

        // Recover signer using OpenZeppelin ECDSA
        // Uses tryRecover to avoid revert on malformed signatures
        (address recovered, ECDSA.RecoverError err, ) = ECDSA.tryRecover(digest, signature);

        if (err != ECDSA.RecoverError.NoError) {
            return address(0); // Invalid signature → return zero (caller checks against oracleKey)
        }

        signer = recovered;
    }

    /// @inheritdoc IOracle
    function oracleKey() external view returns (address) {
        return _oracleKey;
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN — ORACLE KEY MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Rotate the oracle signing key
     * @dev Call this when:
     *   - Key compromise suspected
     *   - Planned key rotation
     *   - Backend infrastructure change
     *
     *   Old signatures remain valid (stateless verification).
     *   New quotes/proofs must be signed with the new key.
     *
     * @param newKey New signing key address (backend EOA)
     */
    function setOracleKey(address newKey) external onlyOwner {
        if (newKey == address(0)) revert ZeroAddress("oracleKey");
        address oldKey = _oracleKey;
        _oracleKey = newKey;
        emit OracleKeyRotated(oldKey, newKey);
    }

    // ═══════════════════════════════════════════════════════════
    //  ADMIN — FEED MANAGEMENT
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Register a new Chainlink price feed
     * @param asset Asset identifier (e.g., "ETH", "BTC", "USDC")
     * @param feed Chainlink AggregatorV3 address on Base L2
     * @param maxStaleness Max seconds since last update before price is stale.
     *        Typical values:
     *          ETH/USD, BTC/USD: 1200 (20 min, Chainlink heartbeat on Base)
     *          USDC/USD, USDT/USD, DAI/USD: 86400 (24h, stablecoin feeds update less frequently)
     */
    function registerFeed(
        bytes32 asset,
        address feed,
        uint256 maxStaleness
    ) external onlyOwner {
        if (feed == address(0)) revert ZeroAddress("feed");
        if (_feeds[asset].active) revert FeedAlreadyRegistered(asset);
        if (maxStaleness == 0) revert ZeroValue("maxStaleness");

        // Verify feed is alive by doing a test read
        IAggregatorV3 aggregator = IAggregatorV3(feed);
        (, int256 testPrice, , , ) = aggregator.latestRoundData();
        if (testPrice <= 0) revert InvalidPriceAsset(asset, testPrice);

        _feeds[asset] = FeedConfig({
            feed: aggregator,
            maxStaleness: maxStaleness,
            active: true
        });
        _assetIds.push(asset);

        emit FeedRegistered(asset, feed, maxStaleness);
    }

    /**
     * @notice Update an existing feed's config (address and/or staleness)
     * @dev Use when Chainlink deploys new aggregator or heartbeat changes
     */
    function updateFeed(
        bytes32 asset,
        address feed,
        uint256 maxStaleness
    ) external onlyOwner {
        if (!_feeds[asset].active) revert FeedNotRegistered(asset);
        if (feed == address(0)) revert ZeroAddress("feed");
        if (maxStaleness == 0) revert ZeroValue("maxStaleness");

        // Test read on new feed
        IAggregatorV3 aggregator = IAggregatorV3(feed);
        (, int256 testPrice, , , ) = aggregator.latestRoundData();
        if (testPrice <= 0) revert InvalidPriceAsset(asset, testPrice);

        _feeds[asset].feed = aggregator;
        _feeds[asset].maxStaleness = maxStaleness;

        emit FeedUpdated(asset, feed, maxStaleness);
    }

    /**
     * @notice Deactivate a feed (soft delete — keeps in _assetIds for history)
     * @dev getLatestPrice will revert for this asset after removal.
     *      The asset remains in _assetIds. Use isFeedActive() to filter.
     */
    function removeFeed(bytes32 asset) external onlyOwner {
        if (!_feeds[asset].active) revert FeedNotRegistered(asset);
        _feeds[asset].active = false;
        emit FeedRemoved(asset);
    }

    // ═══════════════════════════════════════════════════════════
    //  VIEWS
    // ═══════════════════════════════════════════════════════════

    /// @notice Get feed config for an asset
    function getFeedConfig(bytes32 asset) external view returns (
        address feed,
        uint256 maxStaleness,
        bool active
    ) {
        FeedConfig storage config = _feeds[asset];
        return (address(config.feed), config.maxStaleness, config.active);
    }

    /// @notice Get all registered asset identifiers (includes inactive feeds).
    /// @dev Soft-delete: removed feeds stay in this array. Filter with isFeedActive().
    function getAllAssets() external view returns (bytes32[] memory) {
        return _assetIds;
    }

    /// @notice Check if a feed is registered and active
    function isFeedActive(bytes32 asset) external view returns (bool) {
        return _feeds[asset].active;
    }

    /**
     * @notice Get latest price WITH full Chainlink metadata (for off-chain consumers)
     * @dev Unlike getLatestPrice, this returns all round data for debugging/monitoring
     */
    function getLatestRoundData(bytes32 asset) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        FeedConfig storage config = _feeds[asset];
        if (!config.active) revert FeedNotRegistered(asset);
        return config.feed.latestRoundData();
    }

    /// @notice Get sequencer uptime feed address
    function sequencerUptimeFeed() external view returns (address) {
        return address(_sequencerUptimeFeed);
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL — L2 SEQUENCER CHECK
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice [FIX] Verify L2 sequencer is up and grace period has elapsed.
     * @dev If sequencerUptimeFeed is address(0) (testnet), skip the check.
     *
     *      Attack scenario without this check:
     *        1. Sequencer goes down for 2h. ETH crashes 40% during downtime.
     *        2. Sequencer restarts. Mempool TXs execute with STALE prices.
     *        3. Attacker buys BSS with pre-crash strikePrice → instant profit.
     *
     *      With this check:
     *        1. Sequencer restarts → getLatestPrice reverts for SEQUENCER_GRACE_PERIOD.
     *        2. After grace, Chainlink has updated → fresh prices → safe.
     */
    function _checkSequencer() internal view {
        // Skip check on testnet (sequencer feed not deployed)
        if (address(_sequencerUptimeFeed) == address(0)) return;

        (
            /* uint80 roundId */,
            int256 status,
            uint256 startedAt,              // [FIX R2] Use startedAt per Chainlink docs
            /* uint256 updatedAt */,
            /* uint80 answeredInRound */
        ) = _sequencerUptimeFeed.latestRoundData();

        // status == 0: Sequencer is up. status == 1: Sequencer is down.
        if (status != 0) revert SequencerDown();

        // [FIX R2] Ensure grace period has elapsed since sequencer state CHANGED.
        // Chainlink recommends startedAt (when status changed to current value),
        // NOT updatedAt (when the round was last written). If the oracle re-confirms
        // the same status, updatedAt resets but startedAt stays fixed — using
        // updatedAt could extend the grace block indefinitely (DoS).
        // Underflow-safe: if startedAt > block.timestamp (L2 drift), reverts fail-closed.
        if (block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD) {
            revert SequencerGracePeriodNotOver();
        }
    }
}
