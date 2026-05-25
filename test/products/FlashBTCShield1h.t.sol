// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "forge-std/Test.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";

/// @title FlashBTCShield1h unit tests (Sprint T-30a Phase F)
/// @notice Verifies the BaseFlashShield mechanic specialised for the
///         BTC 1h / 2.5% trigger variant. Tests are deterministic, use
///         absolute warps (via_ir gotcha), and ASCII-only literals.

contract MockChainlinkAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public constant decimals = 8;

    constructor(int256 _a, uint256 _u) {
        answer = _a;
        updatedAt = _u;
    }

    function setAnswer(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockSequencerFeed {
    int256 public answer; // 0 = up, 1 = down
    uint256 public startedAt;

    constructor() {
        // Past the grace period at deploy time so the shield is active.
        startedAt = block.timestamp > 2 hours ? block.timestamp - 2 hours : 0;
        answer = 0;
    }

    function setDown(bool down) external {
        answer = down ? int256(1) : int256(0);
        startedAt = block.timestamp;
    }

    function setUpPastGrace() external {
        answer = 0;
        startedAt = block.timestamp > 2 hours ? block.timestamp - 2 hours : 0;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

contract FlashBTCShield1hTest is Test {
    FlashBTCShield1h shield;
    MockChainlinkAggregator oracle;
    MockSequencerFeed sequencer;

    address router = makeAddr("router");
    address holder = makeAddr("holder");

    // Anchor absolute timestamp (avoid via_ir warp caching).
    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8; // BTC at $50k, 8 decimals
    uint256 constant COVERAGE = 10_000e6; // $10k USDC

    uint16 constant TRIGGER_DROP_BPS = 250; // 2.5%
    uint32 constant WINDOW = 3600; // 1h

    function setUp() public {
        vm.warp(T0);
        oracle = new MockChainlinkAggregator(STRIKE, T0);
        sequencer = new MockSequencerFeed();
        shield = FlashBTCShield1h(address(new ERC1967Proxy(address(new FlashBTCShield1h()), abi.encodeCall(FlashBTCShield1h.initialize, (router, address(oracle), address(sequencer))))));
    }

    // ── 1. strike-price snapshot ───────────────────────────────────────────────
    function testCreatePolicy_SnapshotsStrikePrice() public {
        vm.prank(router);
        shield.createPolicy(1, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        (,, uint256 strike,,,) = shield.getPolicyInfo(1);
        assertEq(strike, uint256(STRIKE), "strike must equal current oracle price");
    }

    // ── 2. sequencer-down blocks creation ──────────────────────────────────────
    function testCreatePolicy_RevertsWhenSequencerDown() public {
        sequencer.setDown(true);
        vm.prank(router);
        vm.expectRevert(bytes("SEQUENCER_DOWN"));
        shield.createPolicy(2, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    // ── 3. trigger at exact threshold ──────────────────────────────────────────
    function testVerify_TriggersAtExactThreshold() public {
        vm.prank(router);
        shield.createPolicy(3, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        // Move into the window and drop spot by exactly TRIGGER_DROP_BPS.
        vm.warp(T0 + 60);
        int256 dropped = (STRIKE * int256(uint256(10_000 - TRIGGER_DROP_BPS))) / 10_000;
        oracle.setAnswer(dropped, T0 + 60);
        vm.prank(router);
        (bool triggered, uint256 payout,,) = shield.verifyAndCalculate(3);
        assertTrue(triggered, "must trigger at threshold");
        assertGt(payout, 0, "payout > 0 when triggered");
    }

    // ── 4. no trigger 1 bp below threshold ─────────────────────────────────────
    function testVerify_NoTriggerBelowThreshold() public {
        vm.prank(router);
        shield.createPolicy(4, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        vm.warp(T0 + 60);
        // Drop by TRIGGER_DROP_BPS - 1 (insufficient).
        int256 dropped = (STRIKE * int256(uint256(10_000 - (TRIGGER_DROP_BPS - 1)))) / 10_000;
        oracle.setAnswer(dropped, T0 + 60);
        vm.prank(router);
        (bool triggered, uint256 payout,,) = shield.verifyAndCalculate(4);
        assertFalse(triggered, "must NOT trigger below threshold");
        assertEq(payout, 0, "payout zero when not triggered");
    }

    // ── 5. window expiry reverts verify ────────────────────────────────────────
    function testVerify_RevertsAfterWindowExpired() public {
        vm.prank(router);
        shield.createPolicy(5, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        vm.warp(T0 + WINDOW + 1);
        // Refresh oracle so it isn't stale (we want WINDOW_EXPIRED, not stale).
        oracle.setAnswer(STRIKE, T0 + WINDOW + 1);
        vm.prank(router);
        vm.expectRevert(bytes("WINDOW_EXPIRED"));
        shield.verifyAndCalculate(5);
    }

    // ── 6. 3 oracle confirmations enforced (loop reads spot 3x) ────────────────
    function testVerify_3ConfirmationsRequired() public {
        vm.prank(router);
        shield.createPolicy(6, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        vm.warp(T0 + 60);
        // Set price below trigger so that 3 reads of the same price still
        // produce a trigger. The loop's MIN semantics: if ANY of the 3 reads
        // is below threshold, trigger fires. We keep it static here to confirm
        // the loop runs (no revert) and uses _currentPrice each iteration.
        int256 dropped = (STRIKE * 9700) / 10_000; // 3% drop, above 2.5%
        oracle.setAnswer(dropped, T0 + 60);
        vm.prank(router);
        (bool triggered,,,) = shield.verifyAndCalculate(6);
        assertTrue(triggered, "3-confirmation loop completes and triggers");
        (,,,,, bool finalized) = shield.getPolicyInfo(6);
        assertTrue(finalized, "policy finalized after verify");
    }

    // ── 7. payout = 80% of coverage on trigger ─────────────────────────────────
    function testPayout_Is80PercentOfCoverage() public {
        vm.prank(router);
        shield.createPolicy(7, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        vm.warp(T0 + 60);
        // Force a deep drop so trigger is unambiguous.
        oracle.setAnswer(STRIKE / 2, T0 + 60);
        vm.prank(router);
        (bool triggered, uint256 payout, address h,) = shield.verifyAndCalculate(7);
        assertTrue(triggered);
        assertEq(payout, (COVERAGE * 8000) / 10_000, "payout must be 80% of coverage");
        assertEq(h, holder, "holder echoed back");
    }

    // ── 8. stale oracle reverts on createPolicy ────────────────────────────────
    function testStaleOracle_Reverts() public {
        // Move time forward so updatedAt is older than MAX_PRICE_STALENESS (3600s).
        vm.warp(T0 + 2 * 3600);
        // sequencer was deployed at T0 with startedAt = T0 - 2h, still past grace.
        // Oracle updatedAt is still T0 (stale by 2 hours).
        vm.prank(router);
        vm.expectRevert(bytes("ORACLE_STALE"));
        shield.createPolicy(8, holder, COVERAGE, uint64(T0 + 2 * 3600), uint64(T0 + 2 * 3600 + WINDOW));
    }
}
