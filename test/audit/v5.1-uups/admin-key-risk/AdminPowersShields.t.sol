// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield24h} from "../../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../../src/products/FlashETHShield48h.sol";
import {RateShockShield} from "../../../../src/products/RateShockShield.sol";

/**
 * @title AdminPowersShields
 * @notice Shield-level admin authorization audit. Every shield inherits
 *         OwnableUpgradeable via BaseShield, so the entire admin surface is:
 *
 *           _authorizeUpgrade(newImpl) — onlyOwner
 *           transferOwnership / renounceOwnership (OZ Ownable)
 *
 *         For each shield we verify the owner is the deployer and that a
 *         non-owner attacker cannot trigger an upgrade.
 */
contract AdminPowersShields is Test {
    address constant ORACLE = address(0xE1);
    address constant AAVE = address(0xE2);
    address constant USDC = address(0xE3);

    function test_Admin_FlashBTCShield1h_OwnerCanUpgrade_NonOwnerCannot() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), ORACLE);
        assertEq(s.owner(), address(this));
        address newImpl = address(new FlashBTCShield1h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, ""); // owner path succeeds
    }

    function test_Admin_FlashBTCShield24h_OwnerCanUpgrade_NonOwnerCannot() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), ORACLE);
        assertEq(s.owner(), address(this));
        address newImpl = address(new FlashBTCShield24h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Admin_FlashBTCShield48h_OwnerCanUpgrade_NonOwnerCannot() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), ORACLE);
        assertEq(s.owner(), address(this));
        address newImpl = address(new FlashBTCShield48h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Admin_FlashETHShield1h_OwnerCanUpgrade_NonOwnerCannot() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), ORACLE);
        assertEq(s.owner(), address(this));
        address newImpl = address(new FlashETHShield1h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Admin_FlashETHShield24h_OwnerCanUpgrade_NonOwnerCannot() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), ORACLE);
        assertEq(s.owner(), address(this));
        address newImpl = address(new FlashETHShield24h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Admin_FlashETHShield48h_OwnerCanUpgrade_NonOwnerCannot() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), ORACLE);
        assertEq(s.owner(), address(this));
        address newImpl = address(new FlashETHShield48h());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    function test_Admin_RateShockShield_OwnerCanUpgrade_NonOwnerCannot() public {
        RateShockShield s = ProxyDeployer.deployRateShockShield(address(this), ORACLE, AAVE, USDC);
        assertEq(s.owner(), address(this));
        address newImpl = address(new RateShockShield());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
        s.upgradeToAndCall(newImpl, "");
    }

    // Renounce-ownership across one representative shield — pattern is shared.
    function test_AdminAttack_Shield_RenounceOwnership_FreezesAdmin() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), ORACLE);
        s.renounceOwnership();
        assertEq(s.owner(), address(0));
        address newImpl = address(new FlashBTCShield1h());
        vm.expectRevert();
        s.upgradeToAndCall(newImpl, "");
    }
}
