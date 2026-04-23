// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../src/bonds/ClaimBond.sol";

contract ClaimBondTest is Test {
    ClaimBond bond;
    address vault;

    function setUp() public {
        vault = address(this);

        ClaimBond impl = new ClaimBond();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        bond = ClaimBond(address(proxy));
        bond.setBondVault(vault);
    }

    function test_setBondVault_once() public {
        ClaimBond impl = new ClaimBond();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        ClaimBond b = ClaimBond(address(proxy));
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

        // [FIX-#18] Direct user-to-user transfers are now blocked.
        vm.prank(user1);
        vm.expectRevert(bytes("ClaimBond: transfers only via authorized operators"));
        bond.safeTransferFrom(user1, user2, 202804, 400, "");

        // Whitelisting an operator restores the transfer path.
        bond.setAuthorizedOperator(address(this), true);
        vm.prank(user1);
        bond.setApprovalForAll(address(this), true);
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

    // ═══════ setBondVault frontrun prevention (Gap 2) ═══════

    function test_SetBondVault_OneShot_CannotBeCalledTwice() public {
        vm.expectRevert("Already set");
        bond.setBondVault(address(0xdeadbeef));
    }

    function test_SetBondVault_OnlyOwner_PreventsFrontrun() public {
        ClaimBond impl = new ClaimBond();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        ClaimBond freshBond = ClaimBond(address(proxy));
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert(); // Ownable revert
        freshBond.setBondVault(address(0xdeadbeef));

        freshBond.setBondVault(makeAddr("legit"));
        assertEq(freshBond.bondVault(), makeAddr("legit"));
    }

    function test_SetBondVault_MaliciousVault_RejectedAfterInit() public {
        assertEq(bond.bondVault(), vault);

        vm.expectRevert("Already set");
        bond.setBondVault(makeAddr("malicious"));

        assertEq(bond.bondVault(), vault);
    }

    function test_cannot_initialize_twice() public {
        vm.expectRevert();
        bond.initialize();
    }

    function test_implementation_cannot_be_initialized() public {
        ClaimBond impl = new ClaimBond();
        vm.expectRevert();
        impl.initialize();
    }
}
