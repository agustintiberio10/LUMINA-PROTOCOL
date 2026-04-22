// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {PolicyManagerV2} from "../../../../src/core/PolicyManagerV2.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {CoverRouterV2} from "../../../../src/core/CoverRouterV2.sol";

contract MockPriceOracleAttacks {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

/// @notice A "malicious" implementation whose `reinitialize` attempts to reset ownership.
/// Our production contracts don't expose any such reinitialize — this contract is a
/// deliberately-evil upgrade target used to prove we cannot be upgraded to it by a
/// non-admin, and that even if an admin accidentally upgrades to it, state survives
/// (only a privileged admin can perform the upgrade in the first place).
contract MaliciousReinitImpl is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    function initialize(address) public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
    }

    /// @notice An imagined "reinitialize" trying to hijack ownership post-upgrade.
    /// It has no `initializer`/`reinitializer` modifier, so it can be called freely —
    /// but it will only apply to the proxy state if the malicious impl is actually
    /// installed.
    function hijackOwner(address newOwner) external {
        _transferOwnership(newOwner);
    }

    function _authorizeUpgrade(address) internal override {}
}

/**
 * @title InitializerAttacks
 * @notice Adversarial tests against the UUPS initializer + upgrade path.
 */
contract InitializerAttacks is Test {
    // ──────────────────────────────────────────────────
    // Attack 1: Non-admin upgrade attempts across all UUPS contracts (sample)
    // ──────────────────────────────────────────────────

    /// @notice Attacker tries to upgrade PolicyManagerV2 to a malicious implementation
    /// that would have a `hijackOwner()` function. Must revert — only owner can upgrade.
    function test_Attack_Reinitializer_UpgradeToMaliciousImpl_Reverts() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));

        // Deploy the malicious impl in advance (so the prank applies only to the
        // upgrade call and not the contract creation).
        address malicious = address(new MaliciousReinitImpl());

        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        pm.upgradeToAndCall(malicious, "");

        // Owner verifies nothing changed.
        assertEq(pm.owner(), address(this));
    }

    /// @notice Same test for BondVault (AccessControl-protected upgrade).
    function test_Attack_Reinitializer_BondVaultUpgrade_Reverts() public {
        MockPriceOracleAttacks oracle = new MockPriceOracleAttacks();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));

        address malicious = address(new MaliciousReinitImpl());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        v.upgradeToAndCall(malicious, "");

        assertTrue(v.hasRole(v.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    // ──────────────────────────────────────────────────
    // Attack 2: Storage collision via malicious upgrade
    // ──────────────────────────────────────────────────

    /// @notice Admin upgrades to a *different* impl (same layout). Verify that an
    /// adversarial attempt to re-run initialize() post-upgrade still reverts. The
    /// OZ `initializer` modifier is gated on `_initialized` slot in namespaced
    /// storage; once set, it blocks further initialize() regardless of the impl
    /// installed, as long as that impl uses the same `initializer`/`reinitializer`
    /// modifier pattern.
    function test_Attack_Initializer_CannotReinitializeAfterUpgrade() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        PolicyManagerV2 newImpl = new PolicyManagerV2();
        pm.upgradeToAndCall(address(newImpl), "");

        // After upgrade, the same `initialize(address)` signature still exists.
        // It must revert — OZ InvalidInitialization — because `_initialized` is set.
        vm.expectRevert();
        pm.initialize(makeAddr("otherVault"));
    }

    /// @notice Same check across BondVault.
    function test_Attack_Initializer_BondVaultNotReinitializable() public {
        MockPriceOracleAttacks oracle = new MockPriceOracleAttacks();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));

        BondVault newImpl = new BondVault();
        v.upgradeToAndCall(address(newImpl), "");

        vm.expectRevert();
        v.initialize(address(token), address(cb), address(oracle), address(this));
    }

    // ──────────────────────────────────────────────────
    // Attack 3: Direct implementation takeover (pre-proxy)
    // ──────────────────────────────────────────────────

    /// @notice Under an "implementation-only" deployment (without proxy), attacker
    /// tries to initialize the raw implementation. Must revert because of the
    /// `_disableInitializers()` invocation in every impl's constructor.
    function test_Attack_DirectImpl_CannotBeInitialized_PolicyManagerV2() public {
        PolicyManagerV2 impl = new PolicyManagerV2();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("vault"));
    }

    function test_Attack_DirectImpl_CannotBeInitialized_BondVault() public {
        BondVault impl = new BondVault();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("l"), makeAddr("cb"), makeAddr("o"), address(this));
    }

    function test_Attack_DirectImpl_CannotBeInitialized_LuminaTokenV2() public {
        LuminaTokenV2 impl = new LuminaTokenV2();
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        impl.initialize(makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("l"), makeAddr("t"));
    }

    // ──────────────────────────────────────────────────
    // Attack 4: Front-running via non-atomic deploy (negative control)
    // ──────────────────────────────────────────────────

    /// @notice Demonstrate that a freshly-deployed impl cannot be initialized by a
    /// front-runner (because of _disableInitializers in the constructor). If a
    /// future refactor removed that guard, this test would start failing loudly —
    /// it acts as a regression canary.
    function test_Attack_FrontRunImpl_AfterExplicitDeploy_Reverts() public {
        CoverRouterV2 impl = new CoverRouterV2();

        // Attacker tries to hijack the impl first.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        impl.initialize(makeAddr("u"), makeAddr("p"), makeAddr("b"));

        // Legitimate deployer now wraps it in a proxy via a separate path and owns
        // the proxy correctly.
        CoverRouterV2 router = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        assertEq(router.owner(), address(this));
    }
}
