// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield1h} from "../../src/products/FlashETHShield1h.sol";

/// @title FlashETHShield1h unit tests (Sprint T-30a Phase F)
/// @notice ETH 1h / 4% trigger variant.

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
    int256 public answer;
    uint256 public startedAt;

    constructor() {
        startedAt = block.timestamp > 2 hours ? block.timestamp - 2 hours : 0;
        answer = 0;
    }

    function setDown(bool down) external {
        answer = down ? int256(1) : int256(0);
        startedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

contract FlashETHShield1hTest is Test {
    FlashETHShield1h shield;
    MockChainlinkAggregator oracle;
    MockSequencerFeed sequencer;

    address router = makeAddr("router");
    address holder = makeAddr("holder");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 3_000e8; // ETH at $3k, 8 decimals
    uint256 constant COVERAGE = 10_000e6;

    uint16 constant TRIGGER_DROP_BPS = 400; // 4%
    uint32 constant WINDOW = 3600; // 1h

    function setUp() public {
        vm.warp(T0);
        oracle = new MockChainlinkAggregator(STRIKE, T0);
        sequencer = new MockSequencerFeed();
        shield = new FlashETHShield1h(router, address(oracle), address(sequencer));
    }

    function testCreatePolicy_SnapshotsStrikePrice() public {
        vm.prank(router);
        shield.createPolicy(1, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        (,, uint256 strike,,,) = shield.getPolicyInfo(1);
        assertEq(strike, uint256(STRIKE));
    }

    function testCreatePolicy_RevertsWhenSequencerDown() public {
        sequencer.setDown(true);
        vm.prank(router);
        vm.expectRevert(bytes("SEQUENCER_DOWN"));
        shield.createPolicy(2, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    /// [F-01 migration] Drives `id` through the multi-block confirmation model:
    /// 3 spaced sub-barrier observations across distinct blocks, >=60s apart,
    /// with strictly-increasing oracle `updatedAt`, after the 5-min dwell.
    function _confirm3(uint256 id, int256 droppedAnswer)
        internal
        returns (bool triggered, uint256 payout, address h)
    {
        if (block.timestamp < T0 + 5 minutes) vm.warp(T0 + 5 minutes + 1);
        for (uint256 i = 0; i < 3; i++) {
            uint256 ts = block.timestamp;
            oracle.setAnswer(droppedAnswer, ts);
            vm.prank(router);
            (triggered, payout, h,) = shield.verifyAndCalculate(id);
            if (i < 2) {
                vm.roll(block.number + 1);
                vm.warp(ts + 61);
            }
        }
    }

    function testVerify_TriggersAtExactThreshold() public {
        vm.prank(router);
        shield.createPolicy(3, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        int256 dropped = (STRIKE * int256(uint256(10_000 - TRIGGER_DROP_BPS))) / 10_000;
        (bool triggered, uint256 payout,) = _confirm3(3, dropped);
        assertTrue(triggered);
        assertGt(payout, 0);
    }

    function testVerify_NoTriggerBelowThreshold() public {
        vm.prank(router);
        shield.createPolicy(4, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        vm.warp(T0 + 5 minutes + 1);
        int256 dropped = (STRIKE * int256(uint256(10_000 - (TRIGGER_DROP_BPS - 1)))) / 10_000;
        oracle.setAnswer(dropped, block.timestamp);
        vm.prank(router);
        (bool triggered, uint256 payout,,) = shield.verifyAndCalculate(4);
        assertFalse(triggered);
        assertEq(payout, 0);
    }

    /// [F-01] Window expiry now SETTLES false (reason WINDOW_EXPIRED) rather
    /// than reverting, provided the oracle is evaluable within the longer
    /// settlement-staleness tolerance.
    function testVerify_SettlesFalseAfterWindowExpired() public {
        vm.prank(router);
        shield.createPolicy(5, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        vm.warp(T0 + WINDOW + 1);
        oracle.setAnswer(STRIKE, T0 + WINDOW + 1);
        vm.prank(router);
        (bool triggered,,, bytes32 reason) = shield.verifyAndCalculate(5);
        assertFalse(triggered);
        assertEq(reason, bytes32("WINDOW_EXPIRED"));
    }

    /// [F-01] Two confirmations are NOT enough; the 3rd spaced sub-barrier
    /// observation is what triggers. Single-block triggering is impossible.
    function testVerify_3ConfirmationsRequired() public {
        vm.prank(router);
        shield.createPolicy(6, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        // Drop 0.5% beyond this shield's threshold (generic across variants).
        int256 dropped = (STRIKE * int256(uint256(10_000 - (TRIGGER_DROP_BPS + 50)))) / 10_000;

        vm.warp(T0 + 5 minutes + 1);
        uint256 ts1 = block.timestamp;
        oracle.setAnswer(dropped, ts1);
        vm.prank(router);
        (bool t1,,,) = shield.verifyAndCalculate(6);
        assertFalse(t1, "1st observation accrues, no trigger");

        vm.roll(block.number + 1);
        vm.warp(ts1 + 61);
        uint256 ts2 = block.timestamp;
        oracle.setAnswer(dropped, ts2);
        vm.prank(router);
        (bool t2,,,) = shield.verifyAndCalculate(6);
        assertFalse(t2, "2nd observation accrues, no trigger");

        vm.roll(block.number + 1);
        vm.warp(ts2 + 61);
        oracle.setAnswer(dropped, block.timestamp);
        vm.prank(router);
        (bool t3,,,) = shield.verifyAndCalculate(6);
        assertTrue(t3, "3rd confirmation triggers");
        (,,,,, bool finalized) = shield.getPolicyInfo(6);
        assertTrue(finalized);
    }

    function testPayout_Is80PercentOfCoverage() public {
        vm.prank(router);
        shield.createPolicy(7, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        (bool triggered, uint256 payout, address h) = _confirm3(7, STRIKE / 2);
        assertTrue(triggered);
        assertEq(payout, (COVERAGE * 8000) / 10_000);
        assertEq(h, holder);
    }

    function testStaleOracle_Reverts() public {
        vm.warp(T0 + 2 * 3600);
        vm.prank(router);
        vm.expectRevert(bytes("ORACLE_STALE"));
        shield.createPolicy(8, holder, COVERAGE, uint64(T0 + 2 * 3600), uint64(T0 + 2 * 3600 + WINDOW));
    }
}
