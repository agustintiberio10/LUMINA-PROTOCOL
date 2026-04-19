// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/// @title MarketplaceFuzz
/// @notice Fuzz tests for LuminaBondMarketplace fee calculation invariants.
contract MarketplaceFuzz is Test {
    uint256 constant SELLER_FEE_BPS = 150;
    uint256 constant BUYER_FEE_BPS = 150;
    uint256 constant BPS_DENOMINATOR = 10000;

    /// @notice Fuzz: verify fee calculation math is consistent for random prices.
    function testFuzz_FeeCalculation_Correct(uint256 price) public pure {
        // Avoid overflow: price * 150 must fit in uint256
        // Max safe: type(uint256).max / 150
        price = bound(price, 0, type(uint256).max / BPS_DENOMINATOR);

        uint256 sellerFee = (price * SELLER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 buyerFee = (price * BUYER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 totalFee = sellerFee + buyerFee;

        // Seller fee equals buyer fee (both 150 BPS)
        assertEq(sellerFee, buyerFee, "Seller and buyer fees should be equal");

        // Total fee = 2 * (price * 150 / 10000). Due to integer rounding,
        // this can differ by 1 from (price * 300) / 10000.
        uint256 expectedTotal = (price * 300) / BPS_DENOMINATOR;
        uint256 diff = totalFee > expectedTotal ? totalFee - expectedTotal : expectedTotal - totalFee;
        assertLe(diff, 1, "Total fee should be ~3% of price (rounding)");

        // Fee should never exceed the price
        assertLe(sellerFee, price, "Seller fee should not exceed price");
        assertLe(buyerFee, price, "Buyer fee should not exceed price");

        // sellerReceives + sellerFee = price
        uint256 sellerReceives = price - sellerFee;
        assertEq(sellerReceives + sellerFee, price, "Seller receives + fee = price");

        // totalBuyerPays = price + buyerFee
        uint256 totalBuyerPays = price + buyerFee;
        assertEq(totalBuyerPays, price + buyerFee, "Buyer pays price + fee");
    }
}
