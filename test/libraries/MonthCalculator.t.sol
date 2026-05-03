// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MonthCalculator} from "../../src/libraries/MonthCalculator.sol";

/// @notice Thin wrapper so we can call the library through an external
///         contract (libraries with internal-only functions are inlined,
///         so testing via a thin wrapper exercises the real bytecode the
///         consumers see).
contract MonthCalculatorWrapper {
    function currentMonthSinceDeploy(uint256 anchor) external view returns (uint256) {
        return MonthCalculator.currentMonthSinceDeploy(anchor);
    }

    function monthConst() external pure returns (uint256) {
        return MonthCalculator.MONTH;
    }
}

/// @title MonthCalculatorTest
/// @notice Audit V5.1 fix M-9 - library tests for the canonical
///         "(now - anchor) / 30 days" month-since-anchor formula.
contract MonthCalculatorTest is Test {
    MonthCalculatorWrapper w;

    uint256 constant MONTH = 30 days;

    function setUp() public {
        w = new MonthCalculatorWrapper();
        // Fix block.timestamp to a deterministic value so calculations
        // are stable across environments.
        vm.warp(1_700_000_000); // ~Nov 2023, well past 0
    }

    // ═══════ CRITICAL — formula correctness ═══════

    function test_FirstMonthIsZero() public view {
        // Anchor == now → month 0.
        uint256 month = w.currentMonthSinceDeploy(block.timestamp);
        assertEq(month, 0, "month at exact anchor != 0");
    }

    function test_MonthOneAfter30Days() public {
        uint256 anchor = 1_700_000_000;
        vm.warp(anchor + MONTH);
        assertEq(w.currentMonthSinceDeploy(anchor), 1);
    }

    function test_MonthBoundaryExact() public {
        uint256 anchor = 1_700_000_000;
        // 30 days exactly → month 1 (the boundary belongs to the new month).
        vm.warp(anchor + MONTH);
        assertEq(w.currentMonthSinceDeploy(anchor), 1);
    }

    function test_MonthBoundaryOneSecondBefore() public {
        uint256 anchor = 1_700_000_000;
        // 30 days - 1s → still month 0 (last second of month 0).
        vm.warp(anchor + MONTH - 1);
        assertEq(w.currentMonthSinceDeploy(anchor), 0);
    }

    function test_LargeMonthCount() public {
        uint256 anchor = 1_700_000_000;
        vm.warp(anchor + 100 * MONTH);
        assertEq(w.currentMonthSinceDeploy(anchor), 100);
    }

    function test_RevertsIfAnchorInFuture() public {
        // Library's contract is "anchor must not be in the future".
        vm.expectRevert("MonthCalculator: anchor in future");
        w.currentMonthSinceDeploy(block.timestamp + 1);
    }

    function test_AnchorZeroReturnsAbsoluteMonth() public view {
        // MaintenanceReserve uses anchor=0 → "month since Unix epoch".
        // At block.timestamp = 1.7e9, that is 1.7e9 / (30 * 86400) ≈ 656.
        uint256 month = w.currentMonthSinceDeploy(0);
        assertEq(month, block.timestamp / (30 days));
    }

    function test_MonthConstantIs30Days() public view {
        assertEq(w.monthConst(), 30 days);
        assertEq(w.monthConst(), 2_592_000); // 30 * 86400 seconds
    }

    // ═══════ Determinism: same now + same anchor → same month ═══════

    function test_SameNowSameAnchorSameMonth() public view {
        // The whole point of the M-9 fix: the formula is purely
        // (now - anchor) / 30 days. No state, no rounding tricks.
        // Two calls at the same block must return identical values.
        uint256 a = w.currentMonthSinceDeploy(block.timestamp - 7 days);
        uint256 b = w.currentMonthSinceDeploy(block.timestamp - 7 days);
        assertEq(a, b);
    }

    function test_FormulaIdenticalAcrossAnchors() public {
        // Two consumers with anchors A and B, where B = A + delta and
        // (now - A) >= (now - B). The month difference equals
        // delta / MONTH (when delta is a multiple of MONTH).
        uint256 anchorA = block.timestamp - 5 * MONTH;
        uint256 anchorB = block.timestamp - 2 * MONTH;
        uint256 monthA = w.currentMonthSinceDeploy(anchorA);
        uint256 monthB = w.currentMonthSinceDeploy(anchorB);
        assertEq(monthA, 5);
        assertEq(monthB, 2);
        assertEq(monthA - monthB, 3); // = (5*MONTH - 2*MONTH) / MONTH
    }
}
