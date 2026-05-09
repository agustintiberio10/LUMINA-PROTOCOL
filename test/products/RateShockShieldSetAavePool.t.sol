// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RateShockShield} from "src/products/RateShockShield.sol";

/// @title RateShockShieldSetAavePool
/// @notice Sprint H Phase 1.6 — focused tests for the new `setAavePool` setter.
contract RateShockShieldSetAavePoolTest is Test {
    // Re-declared event for vm.expectEmit (solc 0.8.20 doesn't support
    // `emit ContractName.EventName` cross-contract syntax — that's >=0.8.21).
    event AavePoolUpdated(address indexed oldPool, address indexed newPool);

    RateShockShield internal shield;

    address internal admin = address(this);
    address internal stranger = makeAddr("stranger");
    address internal initialPool = makeAddr("initialAavePool");
    address internal newPool = makeAddr("newAavePool");
    address internal usdc = makeAddr("usdc");
    address internal router = makeAddr("policyManager");
    address internal oracle = makeAddr("oracle");

    function setUp() public {
        RateShockShield impl = new RateShockShield();
        bytes memory initData =
            abi.encodeWithSelector(RateShockShield.initialize.selector, router, oracle, initialPool, usdc);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        shield = RateShockShield(address(proxy));
    }

    function test_setAavePool_updatesStorage() public {
        assertEq(address(shield.aavePool()), initialPool, "pre-state matches initial");
        shield.setAavePool(newPool);
        assertEq(address(shield.aavePool()), newPool, "aavePool rotated");
    }

    function test_setAavePool_emitsEvent() public {
        // Match indexed (oldPool, newPool) — no data field
        vm.expectEmit(true, true, false, false, address(shield));
        emit AavePoolUpdated(initialPool, newPool);
        shield.setAavePool(newPool);
    }

    function test_setAavePool_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(); // OwnableUnauthorizedAccount(stranger)
        shield.setAavePool(newPool);
    }

    function test_setAavePool_zeroAddressReverts() public {
        vm.expectRevert("Zero aavePool");
        shield.setAavePool(address(0));
    }
}
