// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @notice Standalone math contract mirroring TWAPBurner's _swapAndBurn slippage math.
///         Halmos verifies the slippage floor invariant symbolically.
contract TWAPBurnerMath {
    uint256 public constant BPS = 10_000;

    /// @dev Computes minOut from quote with maxSlippageBps slippage protection.
    function applySlippage(uint256 quote, uint256 maxSlippageBps) external pure returns (uint256) {
        return (quote * (BPS - maxSlippageBps)) / BPS;
    }

    /// @dev 4-bucket fee distribution: total ≤ 10000 bps.
    function distribute(uint256 amount, uint256 burnBps, uint256 buybackBps, uint256 opsBps, uint256 maintBps)
        external
        pure
        returns (uint256 toBurn, uint256 toBuyback, uint256 toOps, uint256 toMaint)
    {
        toBurn = (amount * burnBps) / BPS;
        toBuyback = (amount * buybackBps) / BPS;
        toOps = (amount * opsBps) / BPS;
        toMaint = (amount * maintBps) / BPS;
    }
}

/// @title TWAPBurnerHalmos
/// @notice Sprint Z — formal verification of TWAPBurner slippage + distribution math.
///         Targets the gap Mythril couldn't analyze (z3 explosion on full contract).
contract TWAPBurnerHalmos is Test {
    TWAPBurnerMath math;

    function setUp() public {
        math = new TWAPBurnerMath();
    }

    /// @notice Property 1: slippage-adjusted minOut <= original quote (no inflation).
    function check_Slippage_NeverExceedsQuote(uint256 quote, uint256 maxSlippageBps) public view {
        vm.assume(maxSlippageBps <= 10_000);
        vm.assume(quote <= type(uint128).max);
        uint256 minOut = math.applySlippage(quote, maxSlippageBps);
        assert(minOut <= quote);
    }

    /// @notice Property 2: zero slippage ⇒ minOut == quote.
    function check_Slippage_ZeroBps_Identity(uint256 quote) public view {
        vm.assume(quote <= type(uint128).max);
        uint256 minOut = math.applySlippage(quote, 0);
        assert(minOut == quote);
    }

    /// @notice Property 3: 4-bucket distribution conservation — sum(toX) <= amount
    ///         for all (burnBps, buybackBps, opsBps, maintBps) with sum bps <= 10000.
    function check_Distribution_ConservesAmount(
        uint256 amount,
        uint256 burnBps,
        uint256 buybackBps,
        uint256 opsBps,
        uint256 maintBps
    ) public view {
        vm.assume(amount <= type(uint128).max);
        vm.assume(burnBps + buybackBps + opsBps + maintBps <= 10_000);
        (uint256 toBurn, uint256 toBuyback, uint256 toOps, uint256 toMaint) =
            math.distribute(amount, burnBps, buybackBps, opsBps, maintBps);
        assert(toBurn + toBuyback + toOps + toMaint <= amount);
    }

    /// @notice Property 4: distribution at full 10000 bps split ⇒ sum may equal amount
    ///         (or be off by rounding, never above).
    function check_Distribution_NeverInflates(uint256 amount, uint256 bps) public view {
        vm.assume(amount <= type(uint128).max);
        vm.assume(bps <= 10_000);
        (uint256 t1,,,) = math.distribute(amount, bps, 0, 0, 0);
        assert(t1 <= amount);
    }
}
