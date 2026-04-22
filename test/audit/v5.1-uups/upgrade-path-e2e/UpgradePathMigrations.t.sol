// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {ShieldKeeper} from "../../../../src/automation/ShieldKeeper.sol";
import {PolicyManagerV2} from "../../../../src/core/PolicyManagerV2.sol";

/// @notice ShieldKeeperV2 extends V1 with an additional state variable and a new
/// function, plus a reinitialize() gated by `reinitializer(2)`. Because V1 has
/// `uint256[50] private __gap` at its end, V2's new state lands AFTER the gap
/// and therefore never collides with V1 slots. This mirrors the standard
/// OpenZeppelin UUPS migration pattern.
contract ShieldKeeperV2 is ShieldKeeper {
    uint256 public newFeatureValue;

    function setNewFeatureValue(uint256 v) external {
        newFeatureValue = v;
    }

    function reinitializeV2(uint256 initial) public reinitializer(2) {
        newFeatureValue = initial;
    }
}

/// @notice PolicyManagerV2Reinit — same pattern, with a reinitializer for
/// the init-data upgrade path test.
contract PolicyManagerV2Reinit is PolicyManagerV2 {
    uint256 public featureFlag;

    function reinitializeV2(uint256 flag) public reinitializer(2) {
        featureFlag = flag;
    }
}

/**
 * @title UpgradePathMigrations
 * @notice State migration, rollback, event emission, and upgrade-with-init-data
 *         scenarios. Representative contracts are used (ShieldKeeper and
 *         PolicyManagerV2) rather than repeating patterns across all 24.
 */
contract UpgradePathMigrations is Test {
    // ERC-1967 event redeclared locally for vm.expectEmit comparison.
    event Upgraded(address indexed implementation);

    // ────────────────────────────────────────────────────────────────
    // New storage variable via V2
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_Migration_NewStorageVariableWorks() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();

        // Upgrade to V2 which adds `newFeatureValue`.
        k.upgradeToAndCall(address(new ShieldKeeperV2()), "");

        // V1 state survived: paused flag + policyManager pointer.
        assertTrue(k.paused());
        assertEq(address(k.policyManager()), makeAddr("pm"));

        // Call the new function on V2. Cast through the V2 interface.
        ShieldKeeperV2(address(k)).setNewFeatureValue(42);
        assertEq(ShieldKeeperV2(address(k)).newFeatureValue(), 42);
    }

    // ────────────────────────────────────────────────────────────────
    // New function via V2
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_Migration_NewFunctionWorks() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.upgradeToAndCall(address(new ShieldKeeperV2()), "");

        ShieldKeeperV2 v2 = ShieldKeeperV2(address(k));
        v2.setNewFeatureValue(7);
        assertEq(v2.newFeatureValue(), 7);

        // V1 functions still callable.
        v2.pause();
        assertTrue(v2.paused());
        v2.unpause();
        assertFalse(v2.paused());
    }

    // ────────────────────────────────────────────────────────────────
    // Upgrade with init data (reinitialize during upgrade)
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_Migration_WithInitData() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PID"), makeAddr("shield"));

        bytes memory initData = abi.encodeWithSelector(PolicyManagerV2Reinit.reinitializeV2.selector, uint256(99));
        pm.upgradeToAndCall(address(new PolicyManagerV2Reinit()), initData);

        // V1 state preserved.
        assertTrue(pm.productActive(keccak256("PID")));
        assertEq(pm.router(), address(this));

        // V2 reinitializer ran.
        assertEq(PolicyManagerV2Reinit(address(pm)).featureFlag(), 99);
    }

    // ────────────────────────────────────────────────────────────────
    // Reinitialize cannot be called twice
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_Migration_ReinitializeCanOnlyRunOnce() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        bytes memory data = abi.encodeWithSelector(PolicyManagerV2Reinit.reinitializeV2.selector, uint256(1));
        pm.upgradeToAndCall(address(new PolicyManagerV2Reinit()), data);
        assertEq(PolicyManagerV2Reinit(address(pm)).featureFlag(), 1);

        // Calling reinitializer again with the same version must revert.
        vm.expectRevert();
        PolicyManagerV2Reinit(address(pm)).reinitializeV2(2);
    }

    // ────────────────────────────────────────────────────────────────
    // Rollback: V1 → V2 → V1 (compatible interfaces; V2-only state slot
    // is no longer accessible via V1's ABI, but V1 operations still work).
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_Rollback_V1toV2toV1() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();

        // Deploy a snapshot of the V1 impl so we can come back to it.
        address v1Impl = address(new ShieldKeeper());

        // Upgrade to V2, set V2 state.
        k.upgradeToAndCall(address(new ShieldKeeperV2()), "");
        ShieldKeeperV2(address(k)).setNewFeatureValue(555);

        // Rollback: upgrade back to V1 impl.
        k.upgradeToAndCall(v1Impl, "");

        // V1 operations still work; pre-V2 state preserved.
        assertTrue(k.paused());
        k.unpause();
        assertFalse(k.paused());
        assertEq(address(k.policyManager()), makeAddr("pm"));
        // The V2 slot still holds 555 — dormant but present; it'll return
        // if we upgrade forward to V2 again.
        k.upgradeToAndCall(address(new ShieldKeeperV2()), "");
        assertEq(ShieldKeeperV2(address(k)).newFeatureValue(), 555);
    }

    // ────────────────────────────────────────────────────────────────
    // Event emission on upgrade
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_EmitsUpgradedEvent() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        address newImpl = address(new ShieldKeeper());
        vm.expectEmit(true, false, false, false);
        emit Upgraded(newImpl);
        k.upgradeToAndCall(newImpl, "");
    }

    function test_UpgradeE2E_EmitsUpgradedEvent_PolicyManager() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        address newImpl = address(new PolicyManagerV2());
        vm.expectEmit(true, false, false, false);
        emit Upgraded(newImpl);
        pm.upgradeToAndCall(newImpl, "");
    }
}
