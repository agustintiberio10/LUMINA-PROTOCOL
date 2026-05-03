// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ChainlinkGraceOracle} from "../../src/oracles/ChainlinkGraceOracle.sol";

/// @dev Mock Chainlink AggregatorV3 with per-call toggles for the three
///      "down" modes the contract under test detects:
///        (a) `latestRoundData()` reverts
///        (b) `block.timestamp - updatedAt > heartbeat` (stale)
///        (c) `answeredInRound < roundId` (round not completed)
contract MockChainlinkFeed {
    int256 public price = int256(60_000_00000000); // $60K, 8-dec
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    uint256 public updatedAt;
    bool public revertOnRead;

    constructor() {
        updatedAt = block.timestamp;
    }

    function setPrice(int256 p) external {
        price = p;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setRoundIds(uint80 r, uint80 a) external {
        roundId = r;
        answeredInRound = a;
    }

    function setRevertOnRead(bool r) external {
        revertOnRead = r;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!revertOnRead, "Mock feed down");
        return (roundId, price, updatedAt, updatedAt, answeredInRound);
    }
}

/// @title ChainlinkGracePeriodTest
/// @notice Audit V5.1 fix H-13 — verifies the on-chain grace-period
///         tracker for Chainlink price-feed outages. Tests the oracle
///         itself; the BaseShield integration is covered indirectly by
///         shields' regression suite (chunk `test/shields/*`).
contract ChainlinkGracePeriodTest is Test {
    ChainlinkGraceOracle internal oracle;
    MockChainlinkFeed internal btcFeed;
    MockChainlinkFeed internal ethFeed;

    address internal admin = makeAddr("admin");
    address internal stranger = makeAddr("stranger");

    bytes32 internal constant BTC = bytes32("BTC");
    bytes32 internal constant ETH = bytes32("ETH");
    uint256 internal constant BTC_HEARTBEAT = 1200; // 20 min
    uint256 internal constant ETH_HEARTBEAT = 1200;

    function setUp() public {
        btcFeed = new MockChainlinkFeed();
        ethFeed = new MockChainlinkFeed();

        ChainlinkGraceOracle impl = new ChainlinkGraceOracle();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(impl), abi.encodeWithSelector(ChainlinkGraceOracle.initialize.selector, admin));
        oracle = ChainlinkGraceOracle(address(proxy));

        vm.startPrank(admin);
        oracle.setFeed(BTC, address(btcFeed), BTC_HEARTBEAT);
        oracle.setFeed(ETH, address(ethFeed), ETH_HEARTBEAT);
        vm.stopPrank();

        // Default: feeds were just updated → fresh.
        btcFeed.setPrice(60_000_00000000);
        ethFeed.setPrice(3_000_00000000);
    }

    // ─────────────────────────────────────────────────────────────────────
    // CRITICAL — three "down" detection modes
    // ─────────────────────────────────────────────────────────────────────

    function test_RevertOracleDetectedCorrectly() public {
        btcFeed.setRevertOnRead(true);
        // markChainlinkDown should accept since the feed is currently down.
        oracle.markChainlinkDown(BTC);
        assertGt(oracle.openDowntimeStart(BTC), 0, "down window must be open");
    }

    function test_StaleOracleDetectedCorrectly() public {
        // updatedAt = now → fresh; warp past heartbeat → stale.
        vm.warp(block.timestamp + BTC_HEARTBEAT + 1);
        oracle.markChainlinkDown(BTC);
        assertGt(oracle.openDowntimeStart(BTC), 0);
    }

    function test_AnsweredInRoundOldDetectedCorrectly() public {
        btcFeed.setRoundIds(5, 3); // answered 2 rounds ago
        oracle.markChainlinkDown(BTC);
        assertGt(oracle.openDowntimeStart(BTC), 0);
    }

    // ─────────────────────────────────────────────────────────────────────
    // CRITICAL — downtime accumulation
    // ─────────────────────────────────────────────────────────────────────

    function test_ChainlinkDownExtendsExpiry() public {
        btcFeed.setRevertOnRead(true);
        uint256 startedAt = block.timestamp;
        oracle.markChainlinkDown(BTC);
        assertEq(oracle.openDowntimeStart(BTC), startedAt);

        // Advance 6h relative to the down-mark.
        vm.warp(startedAt + 6 hours);
        assertEq(oracle.getChainlinkDowntime(BTC, 0), 6 hours, "open window contributes 6h elapsed");

        // Advance another 18h (relative) → total 24h since markDown.
        vm.warp(block.timestamp + 18 hours);
        assertEq(oracle.getChainlinkDowntime(BTC, 0), 24 hours, "open window contributes 24h elapsed");
    }

    function test_ChainlinkRecoveryStopsExtension() public {
        btcFeed.setRevertOnRead(true);
        uint256 t0 = block.timestamp;
        oracle.markChainlinkDown(BTC);

        vm.warp(t0 + 6 hours);
        // Recover the feed
        btcFeed.setRevertOnRead(false);
        btcFeed.setPrice(60_000_00000000); // refreshes updatedAt
        oracle.markChainlinkUp(BTC);

        uint256 frozen = oracle.getChainlinkDowntime(BTC, 0);
        assertEq(frozen, 6 hours);

        // No further accumulation
        vm.warp(t0 + 30 hours);
        assertEq(oracle.getChainlinkDowntime(BTC, 0), 6 hours, "post-recovery downtime is frozen");
    }

    function test_MultipleDowntimesAccumulate() public {
        // Window 1: 1h
        btcFeed.setRevertOnRead(true);
        oracle.markChainlinkDown(BTC);
        vm.warp(block.timestamp + 1 hours);
        btcFeed.setRevertOnRead(false);
        btcFeed.setPrice(60_000_00000000);
        oracle.markChainlinkUp(BTC);

        // Gap: 6h
        vm.warp(block.timestamp + 6 hours);
        // Refresh feed so it doesn't go stale and we can mark down again
        btcFeed.setPrice(60_000_00000000);

        // Window 2: 2h
        btcFeed.setRevertOnRead(true);
        oracle.markChainlinkDown(BTC);
        vm.warp(block.timestamp + 2 hours);
        btcFeed.setRevertOnRead(false);
        btcFeed.setPrice(60_000_00000000);
        oracle.markChainlinkUp(BTC);

        // Gap: 1h
        vm.warp(block.timestamp + 1 hours);
        btcFeed.setPrice(60_000_00000000);

        // Window 3: 3h (still open)
        btcFeed.setRevertOnRead(true);
        oracle.markChainlinkDown(BTC);
        vm.warp(block.timestamp + 3 hours);

        // Total = 1 + 2 + 3 = 6 hours
        assertEq(oracle.getChainlinkDowntime(BTC, 0), 6 hours);
    }

    // ─────────────────────────────────────────────────────────────────────
    // PROTECCIONES — admin / abuse
    // ─────────────────────────────────────────────────────────────────────

    function test_OnlyOwnerCanSetHeartbeat() public {
        vm.prank(stranger);
        vm.expectRevert(); // AccessControl revert
        oracle.setHeartbeat(BTC, 600);

        // Admin succeeds
        vm.prank(admin);
        oracle.setHeartbeat(BTC, 600);
        assertEq(oracle.heartbeat(BTC), 600);
    }

    function test_AbusiveMarkChainlinkDownReverts() public {
        // Feed is fresh → markChainlinkDown must revert
        vm.expectRevert(abi.encodeWithSelector(ChainlinkGraceOracle.FeedNotDown.selector, BTC));
        oracle.markChainlinkDown(BTC);
    }

    function test_MarkUpRevertsIfStillDown() public {
        btcFeed.setRevertOnRead(true);
        oracle.markChainlinkDown(BTC);
        // Feed still down → mark up reverts
        vm.expectRevert(abi.encodeWithSelector(ChainlinkGraceOracle.FeedNotUp.selector, BTC));
        oracle.markChainlinkUp(BTC);
    }

    function test_MarkUpRevertsIfNotMarkedDown() public {
        // No open window → mark up reverts
        vm.expectRevert(abi.encodeWithSelector(ChainlinkGraceOracle.FeedNotUp.selector, BTC));
        oracle.markChainlinkUp(BTC);
    }

    function test_MarkDownIdempotent() public {
        btcFeed.setRevertOnRead(true);
        oracle.markChainlinkDown(BTC);
        uint256 firstStart = oracle.openDowntimeStart(BTC);

        // Warp + call again — idempotent (no-op, doesn't reset start)
        vm.warp(block.timestamp + 1 hours);
        oracle.markChainlinkDown(BTC);
        assertEq(oracle.openDowntimeStart(BTC), firstStart, "idempotent call must not reset start");
    }

    function test_HeartbeatTooLargeReverts() public {
        vm.prank(admin);
        vm.expectRevert();
        oracle.setHeartbeat(BTC, 8 days); // exceeds MAX_HEARTBEAT_SECONDS (7 days)
    }

    function test_UnknownAssetMarkDownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ChainlinkGraceOracle.UnknownAsset.selector, bytes32("UNKNOWN")));
        oracle.markChainlinkDown(bytes32("UNKNOWN"));
    }

    // ─────────────────────────────────────────────────────────────────────
    // REGRESSION — feed lookups
    // ─────────────────────────────────────────────────────────────────────

    function test_GetLatestPriceWorksForRegisteredFeed() public view {
        int256 price = oracle.getLatestPrice(BTC);
        assertEq(price, 60_000_00000000);
    }

    function test_GetLatestPriceRevertsForUnknownAsset() public {
        vm.expectRevert();
        oracle.getLatestPrice(bytes32("UNKNOWN"));
    }

    function test_NormalGetChainlinkDowntimeIsZeroByDefault() public view {
        assertEq(oracle.getChainlinkDowntime(BTC, 0), 0);
        assertEq(oracle.getChainlinkDowntime(ETH, 0), 0);
    }

    function test_PerAssetIsolation() public {
        // BTC down, ETH up — only BTC accumulates.
        btcFeed.setRevertOnRead(true);
        oracle.markChainlinkDown(BTC);
        vm.warp(block.timestamp + 5 hours);

        assertEq(oracle.getChainlinkDowntime(BTC, 0), 5 hours);
        assertEq(oracle.getChainlinkDowntime(ETH, 0), 0, "ETH must not accumulate from BTC outage");
    }
}
