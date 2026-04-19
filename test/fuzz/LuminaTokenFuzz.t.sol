// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";

/// @title LuminaTokenFuzz
/// @notice Fuzz tests for LuminaTokenV2 burn and transfer invariants.
contract LuminaTokenFuzz is Test {
    LuminaTokenV2 token;

    address holder = makeAddr("holder");
    address r1 = makeAddr("r1");
    address r2 = makeAddr("r2");
    address r3 = makeAddr("r3");
    address r4 = makeAddr("r4");
    address r5 = makeAddr("r5");

    function setUp() public {
        token = new LuminaTokenV2(r1, r2, r3, r4, r5);
        // Deal tokens to holder from r1 (bondVault has 70M)
        vm.prank(r1);
        token.transfer(holder, 1_000_000 * 1e18);
    }

    /// @notice Fuzz: burning always reduces total supply by the burned amount.
    function testFuzz_Burn_AlwaysReducesSupply(uint256 burnAmount) public {
        uint256 holderBal = token.balanceOf(holder);
        burnAmount = bound(burnAmount, 1, holderBal);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(holder);
        token.burn(burnAmount);

        uint256 supplyAfter = token.totalSupply();
        assertEq(supplyAfter, supplyBefore - burnAmount, "Supply should decrease by burned amount");
    }

    /// @notice Fuzz: transfers between accounts preserve total supply.
    function testFuzz_Transfer_PreservesTotalSupply(address to, uint256 amount) public {
        vm.assume(to != address(0));
        uint256 holderBal = token.balanceOf(holder);
        amount = bound(amount, 0, holderBal);

        uint256 supplyBefore = token.totalSupply();

        vm.prank(holder);
        token.transfer(to, amount);

        uint256 supplyAfter = token.totalSupply();
        assertEq(supplyAfter, supplyBefore, "Total supply should not change on transfer");
    }

    /// @notice Fuzz: burning more than balance reverts.
    function testFuzz_Burn_RevertsIfInsufficientBalance(uint256 burnAmount) public {
        uint256 holderBal = token.balanceOf(holder);
        burnAmount = bound(burnAmount, holderBal + 1, type(uint256).max);

        vm.prank(holder);
        vm.expectRevert();
        token.burn(burnAmount);
    }
}
