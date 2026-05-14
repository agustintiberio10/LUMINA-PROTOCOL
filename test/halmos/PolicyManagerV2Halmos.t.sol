// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @notice Standalone arithmetic mirror of PolicyManagerV2 capacity-model math.
///         Halmos verifies the integer-dollar truncation + reservation calculation.
contract PolicyManagerV2Math {
    /// @dev coverageAmount (6-dec USDC) → payoutAmount (6-dec, 80%) → payoutUSD (integer dollars).
    function computePayoutUSD(uint256 coverageAmount) external pure returns (uint256) {
        uint256 payoutAmount = (coverageAmount * 8000) / 10_000;
        return payoutAmount / 1e6;
    }

    /// @dev reservedAmount in 18-dec USD-wei.
    function computeReserved(uint256 payoutUSD) external pure returns (uint256) {
        return payoutUSD * 1e18;
    }
}

/// @title PolicyManagerV2Halmos
/// @notice Sprint Z — formal verification of capacity-model precision tradeoff.
contract PolicyManagerV2Halmos is Test {
    PolicyManagerV2Math math;

    function setUp() public {
        math = new PolicyManagerV2Math();
    }

    /// @notice Property 1: payoutUSD <= coverageAmount / 1e6 (truncated 80%).
    ///         Truncation can never inflate the payout above 80% of coverage.
    function check_PayoutUSD_NeverExceedsCoverage80(uint256 coverageAmount) public view {
        vm.assume(coverageAmount <= type(uint128).max);
        uint256 payoutUSD = math.computePayoutUSD(coverageAmount);
        // payoutUSD (whole $) ≤ (coverage * 0.8) / 1e6 ⇒ payoutUSD * 1e6 ≤ coverage * 0.8.
        assert(payoutUSD * 1_000_000 <= (coverageAmount * 8000) / 10_000);
    }

    /// @notice Property 2: monotonic — higher coverage ⇒ payoutUSD non-decreasing.
    function check_PayoutUSD_Monotonic(uint256 coverageA, uint256 coverageB) public view {
        vm.assume(coverageA <= coverageB);
        vm.assume(coverageB <= type(uint128).max);
        uint256 payoutA = math.computePayoutUSD(coverageA);
        uint256 payoutB = math.computePayoutUSD(coverageB);
        assert(payoutA <= payoutB);
    }

    /// @notice Property 3: reserved (18-dec USD-wei) = payoutUSD * 1e18 — no overflow within budget.
    function check_Reserved_ScaledCorrectly(uint256 payoutUSD) public view {
        vm.assume(payoutUSD <= type(uint160).max); // bound to avoid uint256 overflow on *1e18
        uint256 reserved = math.computeReserved(payoutUSD);
        // reserved / 1e18 must round-trip to payoutUSD.
        assert(reserved / 1e18 == payoutUSD);
    }

    /// @notice Property 4: payoutUSD truncation error < $1 always.
    ///         Coverage * 0.8 / 1e6 (integer division) loses up to (1e6 - 1) wei = <$1.
    function check_PayoutUSD_TruncationBoundedByOneDollar(uint256 coverageAmount) public view {
        vm.assume(coverageAmount <= type(uint128).max);
        uint256 payoutAmount = (coverageAmount * 8000) / 10_000; // 6-dec USDC
        uint256 payoutUSD = math.computePayoutUSD(coverageAmount); // integer $
        uint256 lost = payoutAmount - (payoutUSD * 1e6);
        assert(lost < 1e6); // strict < $1
    }
}
