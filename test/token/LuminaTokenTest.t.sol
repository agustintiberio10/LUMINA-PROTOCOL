// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {LuminaToken} from "../../src/token/LuminaToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract LuminaTokenTest is Test {
    LuminaToken public token;

    address treasury = makeAddr("treasury");
    address exitEngine = makeAddr("exitEngine");
    address exchange = makeAddr("exchange");
    address vesting = makeAddr("vesting");
    address deployer;

    function setUp() public {
        deployer = address(this);
        token = new LuminaToken(treasury, exitEngine, exchange, vesting);
    }

    function test_constructor_mints_max_supply() public {
        assertEq(token.totalSupply(), 100_000_000 * 1e18);
    }

    function test_distribution_correct() public {
        assertEq(token.balanceOf(treasury), 10_000_000 * 1e18);
        assertEq(token.balanceOf(exitEngine), 15_000_000 * 1e18);
        assertEq(token.balanceOf(exchange), 10_000_000 * 1e18);
        assertEq(token.balanceOf(vesting), 65_000_000 * 1e18);
    }

    function test_no_mint_function_exists() public {
        // Verify no mint(address,uint256) selector exists
        bytes4 mintSelector = bytes4(keccak256("mint(address,uint256)"));
        // Attempt a low-level staticcall with the mint selector — should return false (no such function)
        (bool success,) = address(token).staticcall(abi.encodeWithSelector(mintSelector, address(this), 1e18));
        assertFalse(success);
    }

    function test_max_supply_constant() public {
        assertEq(token.MAX_SUPPLY(), 100_000_000 * 1e18);
    }

    function test_burn_by_holder() public {
        uint256 burnAmount = 1000 * 1e18;
        vm.prank(treasury);
        token.burn(burnAmount);
        assertEq(token.balanceOf(treasury), 10_000_000 * 1e18 - burnAmount);
        assertEq(token.totalSupply(), 100_000_000 * 1e18 - burnAmount);
        assertEq(token.totalBurned(), burnAmount);
    }

    function test_burnByRole_with_role() public {
        address burner = makeAddr("burner");
        token.grantRole(token.BURNER_ROLE(), burner);

        uint256 burnAmount = 500 * 1e18;
        vm.prank(burner);
        token.burnByRole(treasury, burnAmount);

        assertEq(token.balanceOf(treasury), 10_000_000 * 1e18 - burnAmount);
        assertEq(token.totalBurned(), burnAmount);
    }

    function test_burnByRole_without_role_reverts() public {
        address nobody = makeAddr("nobody");
        vm.prank(nobody);
        vm.expectRevert();
        token.burnByRole(treasury, 100 * 1e18);
    }

    function test_totalBurned_tracks_correctly() public {
        uint256 burnAmount = 1000 * 1e18;
        vm.prank(treasury);
        token.burn(burnAmount);
        assertEq(token.totalBurned(), burnAmount);
    }

    function test_transfer_works() public {
        address recipient = makeAddr("recipient");
        vm.prank(treasury);
        token.transfer(recipient, 100 * 1e18);
        assertEq(token.balanceOf(recipient), 100 * 1e18);
    }

    function test_approve_and_transferFrom_works() public {
        address spender = makeAddr("spender");
        address recipient = makeAddr("recipient");

        vm.prank(treasury);
        token.approve(spender, 200 * 1e18);

        vm.prank(spender);
        token.transferFrom(treasury, recipient, 200 * 1e18);

        assertEq(token.balanceOf(recipient), 200 * 1e18);
    }

    function test_admin_role_management() public {
        address burner = makeAddr("burner");
        bytes32 burnerRole = token.BURNER_ROLE();

        token.grantRole(burnerRole, burner);
        assertTrue(token.hasRole(burnerRole, burner));

        token.revokeRole(burnerRole, burner);
        assertFalse(token.hasRole(burnerRole, burner));
    }

    function test_zero_address_constructor_reverts() public {
        vm.expectRevert("Zero treasury");
        new LuminaToken(address(0), exitEngine, exchange, vesting);

        vm.expectRevert("Zero exitEngine");
        new LuminaToken(treasury, address(0), exchange, vesting);

        vm.expectRevert("Zero exchange");
        new LuminaToken(treasury, exitEngine, address(0), vesting);

        vm.expectRevert("Zero vesting");
        new LuminaToken(treasury, exitEngine, exchange, address(0));
    }
}
