// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlexAggregator, FlexSequencer} from "./helpers/FlexAggregator.sol";

/// @title F-06 round-validation tests (red-team fix)
/// @notice BaseFlashShield._readFeed must reject incomplete rounds
///         (answeredInRound < roundId), zero/uninitialized rounds, and
///         future timestamps BEFORE the staleness subtraction.
contract F06_RoundValidation is Test {
    FlashBTCShield1h shield;
    FlexAggregator oracle;
    FlexSequencer seq;

    address router = makeAddr("router");
    address holder = makeAddr("holder");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6;
    uint32 constant WINDOW = 3600;

    function setUp() public {
        vm.warp(T0);
        oracle = new FlexAggregator(STRIKE, T0);
        seq = new FlexSequencer();
        shield = new FlashBTCShield1h(router, address(oracle), address(seq));
    }

    /// answeredInRound < roundId (stale carried-over answer) must revert.
    function test_StaleAnsweredInRoundRejected() public {
        // roundId=10 but answeredInRound=9 → incomplete/stale round.
        oracle.setRound(STRIKE, 10, T0, 9);
        vm.prank(router);
        vm.expectRevert(bytes("ORACLE_INCOMPLETE_ROUND"));
        shield.createPolicy(1, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    /// updatedAt == 0 (round not yet complete) must revert.
    function test_ZeroUpdatedAtRejected() public {
        oracle.setRound(STRIKE, 5, 0, 5);
        vm.prank(router);
        vm.expectRevert(bytes("ORACLE_ROUND_NOT_COMPLETE"));
        shield.createPolicy(1, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    /// updatedAt in the future must revert BEFORE the staleness subtraction
    /// (which would otherwise underflow / behave undefined).
    function test_FutureTimestampRejected() public {
        oracle.setRound(STRIKE, 5, T0 + 1000, 5);
        vm.prank(router);
        vm.expectRevert(bytes("ORACLE_FUTURE_TS"));
        shield.createPolicy(1, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    /// Healthy round (answeredInRound == roundId, valid updatedAt) passes.
    function test_HealthyRoundAccepted() public {
        oracle.setRound(STRIKE, 7, T0, 7);
        vm.prank(router);
        shield.createPolicy(1, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        (,, uint256 strike,,,) = shield.getPolicyInfo(1);
        assertEq(strike, uint256(STRIKE));
    }
}
