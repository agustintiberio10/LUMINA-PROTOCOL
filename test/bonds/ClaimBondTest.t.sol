// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/bonds/ClaimBond.sol";

contract ClaimBondTest is Test {
    ClaimBond bond;
    address vault;

    function setUp() public {
        vault = address(this);
        bond = new ClaimBond();
        bond.setBondVault(vault);
    }

    function test_setBondVault_once() public {
        ClaimBond b = new ClaimBond();
        b.setBondVault(makeAddr("v"));
        vm.expectRevert("Already set");
        b.setBondVault(makeAddr("other"));
    }

    function test_mint() public {
        bond.mint(makeAddr("user"), 202804, 800);
        assertEq(bond.balanceOf(makeAddr("user"), 202804), 800);
        assertEq(bond.totalSupply(202804), 800);
    }

    function test_epoch_created_on_first_mint() public {
        assertFalse(bond.epochExists(202804));
        bond.mint(makeAddr("user"), 202804, 100);
        assertTrue(bond.epochExists(202804));
        assertTrue(bond.maturityDate(202804) > 0);
    }

    function test_multiple_mints_same_epoch() public {
        bond.mint(makeAddr("user1"), 202804, 800);
        bond.mint(makeAddr("user2"), 202804, 4000);
        assertEq(bond.totalSupply(202804), 4800);
    }

    function test_burn() public {
        bond.mint(makeAddr("user"), 202804, 800);
        bond.burn(makeAddr("user"), 202804, 300);
        assertEq(bond.balanceOf(makeAddr("user"), 202804), 500);
    }

    function test_only_vault_can_mint() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert("Only BondVault");
        bond.mint(makeAddr("user"), 202804, 100);
    }

    function test_transfer() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        bond.mint(user1, 202804, 1000);
        vm.prank(user1);
        bond.safeTransferFrom(user1, user2, 202804, 400, "");
        assertEq(bond.balanceOf(user1, 202804), 600);
        assertEq(bond.balanceOf(user2, 202804), 400);
    }

    function test_isMatured() public {
        bond.mint(makeAddr("user"), 202804, 100);
        assertFalse(bond.isMatured(202804));
        vm.warp(bond.maturityDate(202804) + 1);
        assertTrue(bond.isMatured(202804));
    }

    function test_invalid_month_reverts() public {
        vm.expectRevert("Invalid month");
        bond.mint(makeAddr("user"), 202813, 100);
    }
}
