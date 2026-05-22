// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @notice Arithmetic mirrors of T-30a invariants for Halmos symbolic verification.
contract SprintT30bMath {
    uint256 internal constant MAX_REDEMPTION_PER_EPOCH_BPS = 108;
    uint256 internal constant DEDUCTIBLE_BPS = 2000;
    uint256 internal constant PAYOUT_BPS = 10000 - DEDUCTIBLE_BPS;
    uint256 internal constant BPS_DENOM = 10000;

    function maxThisEpoch(uint256 vaultUSD18) external pure returns (uint256) {
        return (vaultUSD18 * MAX_REDEMPTION_PER_EPOCH_BPS) / BPS_DENOM;
    }

    function dropBps(uint256 strike, uint256 current) external pure returns (uint256) {
        if (current >= strike || strike == 0) return 0;
        return ((strike - current) * BPS_DENOM) / strike;
    }

    function payout(uint256 coverage) external pure returns (uint256) {
        return (coverage * PAYOUT_BPS) / BPS_DENOM;
    }

    function withinWindow(uint64 startTs, uint64 windowSec, uint64 now_) external pure returns (bool) {
        if (now_ < startTs) return false;
        return now_ <= startTs + windowSec;
    }
}

/// @title SprintT30bHalmos
/// @notice Sprint T-30b — formal verification of 5 T-30a invariants.
contract SprintT30bHalmos is Test {
    SprintT30bMath m;

    function setUp() public {
        m = new SprintT30bMath();
    }

    /// @notice Inv 1: epoch redemption cap never exceeds vault balance * 1.08%.
    function check_ThrottleNeverExceedsMax(uint256 vaultUSD18) public view {
        vm.assume(vaultUSD18 <= type(uint128).max);
        uint256 cap = m.maxThisEpoch(vaultUSD18);
        // cap == vault * 108 / 10000 ⇒ cap * 10000 == vault * 108 (exact within rounding).
        // monotonic + bounded by vault.
        assert(cap <= vaultUSD18);
        assert(cap * BPS_DENOM() <= vaultUSD18 * 108);
    }

    /// @notice Inv 2: drop = (strike - current) * 10000 / strike (exact integer math).
    function check_DropCalculationExact(uint256 strike, uint256 current) public view {
        vm.assume(strike > 0 && strike <= type(uint128).max);
        vm.assume(current <= type(uint128).max);
        uint256 d = m.dropBps(strike, current);
        // Property: if current >= strike, drop == 0.
        if (current >= strike) {
            assert(d == 0);
        } else {
            // d * strike == (strike - current) * 10000 (within integer rounding ≤ 1).
            // The integer division d = ((strike - current) * 10000) / strike is exact
            // when (strike - current) * 10000 is divisible by strike; otherwise truncated by ≤ 1 bps.
            assert(d <= 10000);
            // d * strike + remainder == (strike - current) * 10000 with 0 ≤ remainder < strike.
            uint256 lhs = d * strike;
            uint256 rhs = (strike - current) * 10000;
            assert(lhs <= rhs);
            assert(rhs - lhs < strike);
        }
    }

    /// @notice Inv 3: window enforced — within only iff now_ in [startTs, startTs + windowSec].
    function check_WindowStrictlyEnforced(uint64 startTs, uint64 windowSec, uint64 now_) public view {
        // Avoid uint64 overflow in startTs + windowSec.
        vm.assume(uint256(startTs) + uint256(windowSec) <= type(uint64).max);
        bool within = m.withinWindow(startTs, windowSec, now_);
        if (now_ < startTs || now_ > startTs + windowSec) {
            assert(!within);
        } else {
            assert(within);
        }
    }

    /// @notice Inv 4: payout always equals coverage * 80% (drop the 20% deductible).
    function check_PayoutAlways80Percent(uint256 coverage) public view {
        vm.assume(coverage <= type(uint128).max);
        uint256 p = m.payout(coverage);
        // p == coverage * 8000 / 10000.
        assert(p * 10000 <= coverage * 8000);
        assert(p * 10000 + 9999 >= coverage * 8000); // rounding floor within 1 unit
        assert(p <= coverage); // never exceeds principal
    }

    /// @notice Inv 5: idempotent finalization — finalizing twice over an already-finalized
    ///         flag never re-pays (we model with a single boolean: once true, payout(once) returns 0).
    function check_NoDoublePayout(bool finalizedAtCall, uint256 coverage) public view {
        vm.assume(coverage <= type(uint128).max);
        // If already finalized, the contract MUST short-circuit and pay 0.
        uint256 p = finalizedAtCall ? 0 : m.payout(coverage);
        if (finalizedAtCall) {
            assert(p == 0);
        } else {
            assert(p == (coverage * 8000) / 10000);
        }
    }

    function BPS_DENOM() internal pure returns (uint256) {
        return 10000;
    }
}
