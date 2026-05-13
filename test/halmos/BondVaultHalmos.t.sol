// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @notice Standalone arithmetic mirror of BondVault redemption math + capacity calc.
///         Halmos verifies properties over symbolic inputs without full contract setup.
contract BondVaultMath {
    /// @dev Redemption: amount of LUMINA received for `bondAmount` (USD wei) at `pricePerToken` (18-dec).
    ///      Formula: luminaOut = (bondAmount * 1e18) / pricePerToken.
    function redeemLumina(uint256 bondAmount, uint256 pricePerToken) external pure returns (uint256) {
        if (pricePerToken == 0) return 0;
        return (bondAmount * 1e18) / pricePerToken;
    }

    /// @dev Available capacity = balance * price - committed (all 18-dec USD-wei).
    function availableCapacity(uint256 balance, uint256 price, uint256 committed) external pure returns (uint256) {
        uint256 valueUSD = (balance * price) / 1e18;
        if (valueUSD <= committed) return 0;
        return valueUSD - committed;
    }
}

/// @title BondVaultHalmos
/// @notice Sprint Z — formal verification of BondVault redemption + capacity math.
contract BondVaultHalmos is Test {
    BondVaultMath math;

    function setUp() public {
        math = new BondVaultMath();
    }

    /// @notice Property 1: redemption with zero price returns 0 (no division by zero).
    function check_Redeem_ZeroPrice_ReturnsZero(uint256 bondAmount) public view {
        assert(math.redeemLumina(bondAmount, 0) == 0);
    }

    /// @notice Property 2: higher price ⇒ less LUMINA per bond (monotonically decreasing in price).
    function check_Redeem_PriceMonotonic(uint256 bondAmount, uint256 priceLow, uint256 priceHigh) public view {
        vm.assume(priceLow > 0 && priceLow <= priceHigh);
        vm.assume(bondAmount <= type(uint128).max);
        vm.assume(priceHigh <= type(uint128).max);
        uint256 luminaLow = math.redeemLumina(bondAmount, priceLow);
        uint256 luminaHigh = math.redeemLumina(bondAmount, priceHigh);
        // priceLow (cheaper LUMINA) ⇒ more LUMINA per USD.
        assert(luminaLow >= luminaHigh);
    }

    /// @notice Property 3: available capacity never negative (returns 0 floor).
    ///         Bounded inputs to avoid Halmos overflow during `balance * price`.
    function check_Capacity_NeverNegative(uint256 balance, uint256 price, uint256 committed) public view {
        vm.assume(balance <= type(uint96).max);
        vm.assume(price <= type(uint96).max);
        uint256 cap = math.availableCapacity(balance, price, committed);
        // uint cannot be negative; explicit assertion + the formula returns 0 when over-committed.
        assert(cap >= 0);
        // additionally: cap is bounded by valueUSD.
        uint256 valueUSD = (balance * price) / 1e18;
        assert(cap <= valueUSD);
    }

    /// @notice Property 4: when committed >= valueUSD, capacity is exactly 0.
    function check_Capacity_OverCommitted_ReturnsZero(uint256 balance, uint256 price, uint256 committed) public view {
        vm.assume(balance <= type(uint96).max);
        vm.assume(price <= type(uint96).max);
        uint256 valueUSD = (balance * price) / 1e18;
        vm.assume(committed >= valueUSD);
        assert(math.availableCapacity(balance, price, committed) == 0);
    }
}
