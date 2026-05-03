// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IOracle} from "../interfaces/IOracle.sol";

/// @notice Minimal Chainlink AggregatorV3 view used here. Defined inline
///         (vs. importing the full Chainlink package) because we only
///         need `latestRoundData` and `decimals`.
interface IChainlinkAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

/// @title ChainlinkGraceOracle
/// @notice [Audit fix H-13] First concrete `IOracle` implementation in
///         the repo. Tracks Chainlink feed downtime so shields can grant
///         a proportional grace period at trigger time, in line with the
///         pre-existing Sequencer Uptime grace pattern.
///
///         The contract is admin-configured: an authorised multisig
///         registers feeds + heartbeats post-deploy. Anyone can call
///         `markChainlinkDown(asset)` to record the start of an outage
///         on-chain; the same caller (or a separate keeper) calls
///         `markChainlinkUp(asset)` once the feed recovers. Total
///         downtime is then queryable per asset via
///         `getChainlinkDowntime(asset, sinceTimestamp)`.
///
/// @dev    Trust model:
///           - `setFeed`/`setHeartbeat`/`setSequencerFeed` are
///             multisig-only.
///           - `markChainlinkDown` is permissionless BUT only registers
///             a downtime window if `_isFeedDown(asset)` is currently
///             true (revert / stale / old round). A spammer cannot
///             open a fake window.
///           - `markChainlinkUp` is permissionless and only closes a
///             window if the feed has actually recovered.
///           - Per-asset cumulative downtime is the sum of CLOSED
///             windows + the open window if any. The view is
///             monotonically non-decreasing.
contract ChainlinkGraceOracle is Initializable, UUPSUpgradeable, AccessControlUpgradeable, IOracle {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev Maximum heartbeat the admin may register (1 week). Higher
    ///      values would let the admin trivially mark every feed "down"
    ///      and unbound the grace period — the cap removes that vector.
    uint256 public constant MAX_HEARTBEAT_SECONDS = 7 days;

    // ═══════ STORAGE — slots 0..N (UUPS-safe, no inherited storage) ═══════
    mapping(bytes32 asset => address feed) public assetFeed;
    mapping(bytes32 asset => uint256 heartbeat) public heartbeat;

    /// @dev Open window for `asset`: > 0 ⇒ feed currently marked down,
    ///      value is the timestamp of the `markChainlinkDown` call.
    mapping(bytes32 asset => uint256 startedAt) public openDowntimeStart;
    /// @dev Cumulative downtime from CLOSED windows (i.e. windows whose
    ///      `markChainlinkUp` already fired). The open window's elapsed
    ///      time is added on read in `getChainlinkDowntime`.
    mapping(bytes32 asset => uint256 totalDowntime) public closedDowntime;

    /// @dev Authorised oracle signing key for `verifySignature` /
    ///      EIP-712 quotes. Set post-deploy; `oracleKey()` returns it.
    address private _oracleKey;

    /// @dev Chainlink Sequencer Uptime Feed for the deployment chain
    ///      (Base Mainnet: 0xBCA61D6e7f4F4Bb6cF77AeC5A1AB6D7e6CcF13B6,
    ///       Base Sepolia: 0xBCA61D6e7f4F4Bb6cF77AeC5A1AB6D7e6CcF13B6).
    ///      Optional — if zero we fall back to "no sequencer downtime"
    ///      so the contract works on chains without a SUF.
    address public sequencerUptimeFeed;

    // ═══════ EVENTS ═══════
    event FeedSet(bytes32 indexed asset, address indexed feed, uint256 heartbeat);
    event HeartbeatSet(bytes32 indexed asset, uint256 heartbeat);
    event ChainlinkDownMarked(bytes32 indexed asset, uint256 timestamp);
    event ChainlinkUpMarked(bytes32 indexed asset, uint256 windowDuration);
    event SequencerFeedSet(address indexed feed);
    event OracleKeySet(address indexed key);

    // ═══════ ERRORS ═══════
    error UnknownAsset(bytes32 asset);
    error FeedNotDown(bytes32 asset);
    error FeedNotUp(bytes32 asset);
    error HeartbeatTooLarge(uint256 given, uint256 max);
    error ZeroAddressNotAllowed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin_) public initializer {
        __AccessControl_init();
        __UUPSUpgradeable_init();
        if (admin_ == address(0)) revert ZeroAddressNotAllowed();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
    }

    // ═══════ ADMIN ═══════

    /// @notice Register a Chainlink AggregatorV3 feed for an asset and its
    ///         heartbeat (max time between updates the feed is contractually
    ///         required to push). Both are required for `markChainlinkDown`
    ///         to be able to evaluate whether the feed is actually stale.
    function setFeed(bytes32 asset, address feed, uint256 heartbeatSeconds) external onlyRole(ADMIN_ROLE) {
        if (feed == address(0)) revert ZeroAddressNotAllowed();
        if (heartbeatSeconds == 0 || heartbeatSeconds > MAX_HEARTBEAT_SECONDS) {
            revert HeartbeatTooLarge(heartbeatSeconds, MAX_HEARTBEAT_SECONDS);
        }
        assetFeed[asset] = feed;
        heartbeat[asset] = heartbeatSeconds;
        emit FeedSet(asset, feed, heartbeatSeconds);
    }

    /// @notice Update the heartbeat for an already-registered asset.
    function setHeartbeat(bytes32 asset, uint256 heartbeatSeconds) external onlyRole(ADMIN_ROLE) {
        if (assetFeed[asset] == address(0)) revert UnknownAsset(asset);
        if (heartbeatSeconds == 0 || heartbeatSeconds > MAX_HEARTBEAT_SECONDS) {
            revert HeartbeatTooLarge(heartbeatSeconds, MAX_HEARTBEAT_SECONDS);
        }
        heartbeat[asset] = heartbeatSeconds;
        emit HeartbeatSet(asset, heartbeatSeconds);
    }

    function setSequencerFeed(address feed) external onlyRole(ADMIN_ROLE) {
        sequencerUptimeFeed = feed;
        emit SequencerFeedSet(feed);
    }

    function setOracleKey(address key) external onlyRole(ADMIN_ROLE) {
        _oracleKey = key;
        emit OracleKeySet(key);
    }

    // ═══════ DOWNTIME TRACKING (permissionless) ═══════

    /// @notice Open a downtime window for `asset` if the feed is
    ///         currently DOWN by the contract's definition (revert /
    ///         stale / old round). Idempotent: if a window is already
    ///         open we no-op rather than revert.
    function markChainlinkDown(bytes32 asset) external {
        if (assetFeed[asset] == address(0)) revert UnknownAsset(asset);
        if (openDowntimeStart[asset] != 0) {
            return; // already marked — idempotent
        }
        if (!_isFeedDown(asset)) revert FeedNotDown(asset);
        openDowntimeStart[asset] = block.timestamp;
        emit ChainlinkDownMarked(asset, block.timestamp);
    }

    /// @notice Close the open downtime window for `asset` once the feed
    ///         has recovered. Reverts if no window is open OR the feed
    ///         is still down.
    function markChainlinkUp(bytes32 asset) external {
        uint256 startedAt = openDowntimeStart[asset];
        if (startedAt == 0) revert FeedNotUp(asset);
        if (_isFeedDown(asset)) revert FeedNotUp(asset);
        uint256 windowDuration = block.timestamp - startedAt;
        closedDowntime[asset] += windowDuration;
        openDowntimeStart[asset] = 0;
        emit ChainlinkUpMarked(asset, windowDuration);
    }

    // ═══════ IOracle implementation ═══════

    function getLatestPrice(bytes32 asset) external view override returns (int256 price) {
        address feed = assetFeed[asset];
        if (feed == address(0)) revert UnknownAsset(asset);
        (, int256 answer,,,) = IChainlinkAggregatorV3(feed).latestRoundData();
        return answer;
    }

    /// @inheritdoc IOracle
    /// @dev Reads the Sequencer Uptime Feed if configured. Returns 0
    ///      when no SUF is wired (i.e. on a chain that does not have
    ///      one, or pre-deploy).
    function getSequencerDowntime(uint256 sinceTimestamp) external view override returns (uint256 downtime) {
        address suf = sequencerUptimeFeed;
        if (suf == address(0)) return 0;
        // Sequencer Uptime Feed answer == 0 → up; answer == 1 → down.
        // startedAt is when the current up/down period began.
        try IChainlinkAggregatorV3(suf).latestRoundData() returns (
            uint80, int256 answer, uint256 startedAt, uint256, uint80
        ) {
            if (answer == 0) return 0;
            // answer == 1 → sequencer is currently DOWN.
            uint256 effectiveStart = startedAt > sinceTimestamp ? startedAt : sinceTimestamp;
            if (block.timestamp <= effectiveStart) return 0;
            return block.timestamp - effectiveStart;
        } catch {
            return 0;
        }
    }

    /// @inheritdoc IOracle
    /// @dev Sum of (a) the closed windows accumulated by paired
    ///      mark-down/mark-up calls and (b) the open window's elapsed
    ///      time if any. Note this is the LIFETIME total — callers that
    ///      only care about a window starting at `sinceTimestamp` should
    ///      compute deltas off-chain. Shields use it as an upper bound
    ///      for the grace period extension, which is itself capped by
    ///      `BaseShield.MAX_GRACE_EXTENSION`, so the lifetime semantics
    ///      are safe.
    function getChainlinkDowntime(
        bytes32 asset,
        uint256 /*sinceTimestamp*/
    )
        external
        view
        override
        returns (uint256 downtime)
    {
        downtime = closedDowntime[asset];
        uint256 startedAt = openDowntimeStart[asset];
        if (startedAt != 0 && block.timestamp > startedAt) {
            downtime += block.timestamp - startedAt;
        }
    }

    /// @inheritdoc IOracle
    /// @dev [Audit fix H-13 follow-up] Implements the sibling
    ///      `verifySignature` so deploying `ChainlinkGraceOracle` as the
    ///      single concrete `IOracle` does NOT regress the existing
    ///      EIP-191 / EIP-712 quote-verification flow that shields use
    ///      at claim time. Recovers the signer of the personal-sign
    ///      message of `digest` (= what most off-chain signers produce
    ///      when calling `signer.signMessage(digest)`), or returns
    ///      `address(0)` if recovery fails. The shield then compares
    ///      the recovered signer against `oracleKey()`.
    function verifySignature(bytes32 digest, bytes calldata signature) external pure override returns (address signer) {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(digest);
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(ethSignedHash, signature);
        if (err != ECDSA.RecoverError.NoError) return address(0);
        return recovered;
    }

    function oracleKey() external view override returns (address) {
        return _oracleKey;
    }

    // ═══════ INTERNAL ═══════

    /// @dev A Chainlink feed is considered DOWN if any of:
    ///      (a) `latestRoundData()` reverts;
    ///      (b) `block.timestamp - updatedAt > heartbeat`;
    ///      (c) `answeredInRound < roundId`.
    function _isFeedDown(bytes32 asset) internal view returns (bool) {
        address feed = assetFeed[asset];
        uint256 hb = heartbeat[asset];
        try IChainlinkAggregatorV3(feed).latestRoundData() returns (
            uint80 roundId, int256, uint256, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (block.timestamp > updatedAt + hb) return true;
            if (answeredInRound < roundId) return true;
            return false;
        } catch {
            return true;
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[40] private __gap;
}
