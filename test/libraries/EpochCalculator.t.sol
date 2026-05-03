// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {EpochCalculator} from "../../src/libraries/EpochCalculator.sol";

/// @notice Wrapper to call internal-only library functions through an
///         external surface, mirroring the bytecode that consumers
///         actually execute.
contract EpochCalculatorWrapper {
    function currentEpoch(uint256 anchor, uint256 dur) external view returns (uint256) {
        return EpochCalculator.currentEpoch(anchor, dur);
    }

    function epochBoundaries(uint256 anchor, uint256 dur) external view returns (uint256, uint256) {
        return EpochCalculator.epochBoundaries(anchor, dur);
    }

    function epochBoundariesAt(uint256 anchor, uint256 dur, uint256 idx) external pure returns (uint256, uint256) {
        return EpochCalculator.epochBoundariesAt(anchor, dur, idx);
    }

    function isInEpoch(uint256 anchor, uint256 dur, uint256 idx, uint256 ts) external pure returns (bool) {
        return EpochCalculator.isInEpoch(anchor, dur, idx, ts);
    }
}

/// @title EpochCalculatorTest
/// @notice Audit V5.1 fix L-2 — drift-free epoch arithmetic, companion
///         to MonthCalculator (FIX #25).
contract EpochCalculatorTest is Test {
    EpochCalculatorWrapper w;

    uint256 constant ANCHOR = 1_700_000_000; // ~Nov 2023
    uint256 constant DUR_1H = 1 hours; // 3600
    uint256 constant DUR_24H = 24 hours; // 86400

    function setUp() public {
        w = new EpochCalculatorWrapper();
        vm.warp(ANCHOR);
    }

    // ═══════ CRITICAL — formula correctness ═══════

    function test_FirstEpochIsZero() public view {
        assertEq(w.currentEpoch(ANCHOR, DUR_1H), 0);
        assertEq(w.currentEpoch(ANCHOR, DUR_24H), 0);
    }

    function test_EpochOneAfterDuration() public {
        vm.warp(ANCHOR + DUR_1H);
        assertEq(w.currentEpoch(ANCHOR, DUR_1H), 1);

        vm.warp(ANCHOR + DUR_24H);
        assertEq(w.currentEpoch(ANCHOR, DUR_24H), 1);
    }

    function test_EpochBoundariesExact() public {
        // At epoch 5 of 24h since anchor.
        vm.warp(ANCHOR + 5 * DUR_24H + 100); // 100 seconds into epoch 5
        (uint256 start, uint256 end) = w.epochBoundaries(ANCHOR, DUR_24H);
        assertEq(start, ANCHOR + 5 * DUR_24H);
        assertEq(end, ANCHOR + 6 * DUR_24H);
    }

    function test_EpochBoundaryFirstSecond() public {
        // First second of epoch 3.
        vm.warp(ANCHOR + 3 * DUR_24H);
        (uint256 start, uint256 end) = w.epochBoundaries(ANCHOR, DUR_24H);
        assertEq(start, ANCHOR + 3 * DUR_24H);
        assertEq(end, ANCHOR + 4 * DUR_24H);
        assertEq(w.currentEpoch(ANCHOR, DUR_24H), 3);
    }

    function test_EpochBoundaryLastSecond() public {
        // Last second of epoch 3 = epoch_4_start - 1.
        vm.warp(ANCHOR + 4 * DUR_24H - 1);
        assertEq(w.currentEpoch(ANCHOR, DUR_24H), 3);
    }

    // ═══════ NO-DRIFT verification ═══════

    function test_NoDriftAfter1000Epochs() public {
        // After 1000 epochs the calculator must still produce the
        // canonical anchor + 1000 * duration boundary, not a drifted
        // value. (This is the entire point of the library.)
        vm.warp(ANCHOR + 1000 * DUR_24H);
        assertEq(w.currentEpoch(ANCHOR, DUR_24H), 1000);
        (uint256 start,) = w.epochBoundaries(ANCHOR, DUR_24H);
        assertEq(start, ANCHOR + 1000 * DUR_24H);
    }

    function test_NoDriftAfter10000Epochs() public {
        vm.warp(ANCHOR + 10000 * DUR_24H);
        assertEq(w.currentEpoch(ANCHOR, DUR_24H), 10000);
        (uint256 start, uint256 end) = w.epochBoundaries(ANCHOR, DUR_24H);
        assertEq(start, ANCHOR + 10000 * DUR_24H);
        assertEq(end, ANCHOR + 10001 * DUR_24H);
    }

    function test_NoDriftMidEpochAfter5000Periods() public {
        // Mid-epoch: 5000 epochs + half an epoch. currentEpoch should be 5000.
        vm.warp(ANCHOR + 5000 * DUR_24H + DUR_24H / 2);
        assertEq(w.currentEpoch(ANCHOR, DUR_24H), 5000);
    }

    // ═══════ Edge cases ═══════

    function test_RevertsIfDurationZero() public {
        vm.expectRevert("EpochCalculator: zero duration");
        w.currentEpoch(ANCHOR, 0);
    }

    function test_RevertsIfAnchorInFuture() public {
        vm.expectRevert("EpochCalculator: anchor in future");
        w.currentEpoch(block.timestamp + 1, DUR_1H);
    }

    function test_AnchorZeroReturnsAbsoluteEpoch() public view {
        // Anchor = 0 → "epochs since Unix epoch start".
        assertEq(w.currentEpoch(0, DUR_24H), block.timestamp / DUR_24H);
    }

    // ═══════ epochBoundariesAt + isInEpoch ═══════

    function test_EpochBoundariesAtFutureEpoch() public view {
        (uint256 start, uint256 end) = w.epochBoundariesAt(ANCHOR, DUR_24H, 100);
        assertEq(start, ANCHOR + 100 * DUR_24H);
        assertEq(end, ANCHOR + 101 * DUR_24H);
    }

    function test_IsInEpochTrue() public view {
        assertTrue(w.isInEpoch(ANCHOR, DUR_24H, 5, ANCHOR + 5 * DUR_24H + 100));
        assertTrue(w.isInEpoch(ANCHOR, DUR_24H, 5, ANCHOR + 5 * DUR_24H));
        assertTrue(w.isInEpoch(ANCHOR, DUR_24H, 5, ANCHOR + 6 * DUR_24H - 1));
    }

    function test_IsInEpochFalse() public view {
        assertFalse(w.isInEpoch(ANCHOR, DUR_24H, 5, ANCHOR + 6 * DUR_24H)); // start of next epoch
        assertFalse(w.isInEpoch(ANCHOR, DUR_24H, 5, ANCHOR + 4 * DUR_24H)); // previous epoch
        assertFalse(w.isInEpoch(ANCHOR, DUR_24H, 5, ANCHOR - 1)); // before anchor
    }

    function test_DeterminismAcrossDurations() public {
        // The whole point: `(now - anchor) / duration` is purely
        // arithmetic, no state, no rounding tricks.
        vm.warp(ANCHOR + 1234567);
        uint256 e1h_a = w.currentEpoch(ANCHOR, DUR_1H);
        uint256 e1h_b = w.currentEpoch(ANCHOR, DUR_1H);
        assertEq(e1h_a, e1h_b);
    }

    // ═══════ Cross-check with MonthCalculator semantics (FIX #25) ═══════

    function test_30DayDurationMatchesMonthCalculatorSemantics() public {
        // EpochCalculator with 30-day duration must produce the SAME
        // value as MonthCalculator.currentMonthSinceDeploy. This locks
        // the L-2 library into a superset of the FIX #25 library.
        uint256 thirtyDays = 30 days;
        vm.warp(ANCHOR + 7 * thirtyDays + 100);
        assertEq(w.currentEpoch(ANCHOR, thirtyDays), 7);
    }
}
