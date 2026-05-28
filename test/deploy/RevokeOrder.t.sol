// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";

/// @title RevokeOrderTest
/// @notice ADR-027 — regression for the AccessControl revoke-order bug surfaced
///         by the 2026-05-28 fork dry-run.
///
///         The bug: `revokeRole` is itself gated by `getRoleAdmin(role)`, which
///         on `BondVault` defaults to `DEFAULT_ADMIN_ROLE` for every role
///         (including `AUTHORIZED_CALLER_ADMIN_ROLE`). If the deployer
///         self-revokes `DEFAULT_ADMIN_ROLE` FIRST, the subsequent revoke of
///         `AUTHORIZED_CALLER_ADMIN_ROLE` reverts with
///         `AccessControlUnauthorizedAccount(deployer, 0x00)` and the deployer
///         is left as a permanent "phantom" admin on the secondary role.
///
///         These tests pin the canonical order documented in the runbook +
///         `DEPLOY-MAINNET-RUNBOOK.md` ADR-027 sub-section:
///           grants (any order) → revoke AUTHORIZED first → DEFAULT last.
///
///         Hermetic: no fork, no script — directly deploys BondVault as a
///         UUPS proxy and exercises the AccessControl flow.
contract MockOracle_RevokeOrder {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

contract RevokeOrderTest is Test {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant AUTHORIZED_CALLER_ADMIN_ROLE = keccak256("AUTHORIZED_CALLER_ADMIN_ROLE");

    BondVault internal bondVault;
    address internal deployer;
    address internal multisig;

    address internal constant LUMINA_DUMMY = address(uint160(uint256(keccak256("lumina"))));
    address internal constant CLAIM_BOND_DUMMY = address(uint160(uint256(keccak256("claimBond"))));

    function setUp() public {
        deployer = makeAddr("deployer");
        multisig  = makeAddr("multisig");

        MockOracle_RevokeOrder oracle = new MockOracle_RevokeOrder();

        vm.startPrank(deployer);
        BondVault impl = new BondVault();
        bytes memory init = abi.encodeWithSelector(
            BondVault.initialize.selector,
            LUMINA_DUMMY,
            CLAIM_BOND_DUMMY,
            address(oracle),
            address(0) // 2-step init: PM set later
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
        bondVault = BondVault(address(proxy));
        vm.stopPrank();

        // Sanity: deployer holds both roles, multisig holds none.
        assertTrue(bondVault.hasRole(DEFAULT_ADMIN_ROLE, deployer), "setUp: deployer missing DEFAULT");
        assertTrue(bondVault.hasRole(AUTHORIZED_CALLER_ADMIN_ROLE, deployer), "setUp: deployer missing AUTH");
        assertFalse(bondVault.hasRole(DEFAULT_ADMIN_ROLE, multisig), "setUp: multisig has DEFAULT");
        assertFalse(bondVault.hasRole(AUTHORIZED_CALLER_ADMIN_ROLE, multisig), "setUp: multisig has AUTH");
    }

    /// Happy path — canonical ADR-027 order: grant both → revoke AUTH → revoke DEFAULT.
    function test_correctOrder_succeeds() public {
        vm.startPrank(deployer);

        // Grants (order does not matter)
        bondVault.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        bondVault.grantRole(AUTHORIZED_CALLER_ADMIN_ROLE, multisig);

        // Revokes — AUTH first, DEFAULT last
        bondVault.revokeRole(AUTHORIZED_CALLER_ADMIN_ROLE, deployer);
        bondVault.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

        vm.stopPrank();

        // End state: multisig holds both, deployer holds neither.
        assertTrue(bondVault.hasRole(DEFAULT_ADMIN_ROLE, multisig), "multisig should hold DEFAULT");
        assertTrue(bondVault.hasRole(AUTHORIZED_CALLER_ADMIN_ROLE, multisig), "multisig should hold AUTH");
        assertFalse(bondVault.hasRole(DEFAULT_ADMIN_ROLE, deployer), "deployer must NOT hold DEFAULT");
        assertFalse(bondVault.hasRole(AUTHORIZED_CALLER_ADMIN_ROLE, deployer), "deployer must NOT hold AUTH");
    }

    /// Wrong order — revoke DEFAULT first then AUTH. The second revoke MUST
    /// revert because the deployer no longer holds DEFAULT_ADMIN_ROLE (which
    /// is the admin of AUTHORIZED_CALLER_ADMIN_ROLE per OZ's default).
    function test_wrongOrder_reverts() public {
        vm.startPrank(deployer);

        bondVault.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        bondVault.grantRole(AUTHORIZED_CALLER_ADMIN_ROLE, multisig);

        // First revoke succeeds — deployer still has DEFAULT_ADMIN_ROLE.
        bondVault.revokeRole(DEFAULT_ADMIN_ROLE, deployer);

        // Now deployer is gone from DEFAULT. The next revoke must revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                deployer,
                DEFAULT_ADMIN_ROLE
            )
        );
        bondVault.revokeRole(AUTHORIZED_CALLER_ADMIN_ROLE, deployer);

        vm.stopPrank();

        // Phantom-admin scenario: deployer STILL holds AUTH (wedged on-chain).
        assertTrue(
            bondVault.hasRole(AUTHORIZED_CALLER_ADMIN_ROLE, deployer),
            "wrong-order leaves deployer as phantom AUTH admin"
        );
    }

    /// Multisig can do the revoke at any time (it holds DEFAULT_ADMIN_ROLE
    /// after the grant). This is the operationally safer fallback: have the
    /// multisig itself revoke the deployer instead of the deployer
    /// self-revoking, which sidesteps the ordering trap entirely.
    function test_multisigCanRevokeDeployer_anyOrder() public {
        vm.startPrank(deployer);
        bondVault.grantRole(DEFAULT_ADMIN_ROLE, multisig);
        bondVault.grantRole(AUTHORIZED_CALLER_ADMIN_ROLE, multisig);
        vm.stopPrank();

        vm.startPrank(multisig);
        // Multisig can revoke in either order — its DEFAULT_ADMIN_ROLE is not
        // touched. Pick the "wrong-order" intentionally to prove the point.
        bondVault.revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        bondVault.revokeRole(AUTHORIZED_CALLER_ADMIN_ROLE, deployer);
        vm.stopPrank();

        assertFalse(bondVault.hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(bondVault.hasRole(AUTHORIZED_CALLER_ADMIN_ROLE, deployer));
    }
}
