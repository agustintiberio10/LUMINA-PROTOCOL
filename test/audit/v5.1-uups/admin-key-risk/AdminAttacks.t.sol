// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../src/core/PolicyManagerV2.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";

contract MockOracleAttack {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

/// @notice Malicious drop-in impl for PolicyManagerV2. Same Ownable+UUPS parentage
/// and same slot-0 `bondVault` pointer to demonstrate that a compromised admin
/// could install arbitrary code. The `drain(address)` function shows the attacker
/// would have unrestricted access to the proxy storage.
contract MaliciousPolicyManagerImpl is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    address public bondVault; // matches V1 layout slot 0

    function setBondVaultDirect(address newBv) external {
        bondVault = newBv;
    }

    function _authorizeUpgrade(address) internal override {}
}

/// @notice Malicious drop-in impl for LuminaTokenV2 demonstrating that a
/// compromised admin could install an impl that mints new tokens — proving
/// why the admin key must be highly restricted.
contract MaliciousTokenImpl is Initializable, UUPSUpgradeable {
    function exploitMint(
        address,
        /* to */
        uint256 /* amt */
    )
        external
        pure
        returns (bool)
    {
        // A real attacker would write to the ERC20 balances namespace here.
        // We don't actually mint in this test — the point is the CALL path is
        // open. Having the ability to install this impl is itself the risk.
        return true;
    }

    function _authorizeUpgrade(address) internal override {}
}

/**
 * @title AdminAttacks
 * @notice Simulates the WORST CASE of a compromised admin. These tests are
 *         documentation of inherent UUPS admin risk — they PASS by demonstrating
 *         the attack would succeed with the admin key, underscoring the need
 *         for multisig + timelock pre-mainnet.
 */
contract AdminAttacks is Test {
    // ────────────────────────────────────────────────────────────────
    // Malicious upgrade attack — admin installs attacker impl
    // ────────────────────────────────────────────────────────────────
    function test_AdminAttack_PolicyManager_MaliciousUpgrade_InstallsArbitraryLogic() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));

        // Admin (address(this)) upgrades to malicious impl.
        MaliciousPolicyManagerImpl evil = new MaliciousPolicyManagerImpl();
        pm.upgradeToAndCall(address(evil), "");

        // Attacker can now call arbitrary mutator that writes slot 0 directly.
        MaliciousPolicyManagerImpl(address(pm)).setBondVaultDirect(makeAddr("attackerVault"));
        // Slot-0 check via V1 ABI: pm.bondVault() now points at attacker address.
        assertEq(address(pm.bondVault()), makeAddr("attackerVault"));
    }

    function test_AdminAttack_LuminaToken_MaliciousUpgrade_CanInstallMaliciousImpl() public {
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        // Any holder of DEFAULT_ADMIN_ROLE can swap the impl — demonstrated here.
        MaliciousTokenImpl evil = new MaliciousTokenImpl();
        token.upgradeToAndCall(address(evil), "");

        // The malicious impl is now active. This cast succeeds.
        assertTrue(MaliciousTokenImpl(address(token)).exploitMint(address(this), 1));
    }

    function test_AdminAttack_NonAdmin_CANNOT_InstallMaliciousImpl() public {
        // Defence: non-admin upgrades are rejected, so the attack is only
        // possible if the admin key itself is compromised.
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        address evil = address(new MaliciousTokenImpl());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        token.upgradeToAndCall(evil, "");
    }

    // ────────────────────────────────────────────────────────────────
    // Admin-authorizes-attacker-as-caller (BondVault)
    // ────────────────────────────────────────────────────────────────
    function test_AdminAttack_BondVault_AuthorizeAttackerAsCaller() public {
        MockOracleAttack oracle = new MockOracleAttack();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        BondVault v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));

        // Admin authorizes attacker EOA as a caller — attacker can now invoke
        // burnFromReserves / decreaseObligations under their own control.
        v.setAuthorizedCaller(makeAddr("attacker"), true);
        assertTrue(v.authorizedCallers(makeAddr("attacker")));
    }

    // ────────────────────────────────────────────────────────────────
    // Renounce role leaves contract adminless
    // ────────────────────────────────────────────────────────────────
    function test_AdminAttack_LuminaToken_RenounceLeavesAdminless() public {
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        token.renounceRole(adminRole, address(this));
        assertFalse(token.hasRole(adminRole, address(this)));

        // No one can grant BURNER_ROLE anymore → protocol frozen for role mgmt.
        bytes32 burnerRole = token.BURNER_ROLE();
        vm.expectRevert();
        token.grantRole(burnerRole, makeAddr("newBurner"));
    }

    function test_AdminAttack_BondVault_RenounceLeavesNoAdmin() public {
        MockOracleAttack oracle = new MockOracleAttack();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        BondVault v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));

        bytes32 callerRole = v.AUTHORIZED_CALLER_ADMIN_ROLE();
        bytes32 defaultRole = v.DEFAULT_ADMIN_ROLE();
        v.renounceRole(callerRole, address(this));
        v.renounceRole(defaultRole, address(this));

        // Neither upgrade nor setAuthorizedCaller is possible.
        address newImpl = address(new BondVault());
        vm.expectRevert();
        v.upgradeToAndCall(newImpl, "");

        vm.expectRevert();
        v.setAuthorizedCaller(makeAddr("x"), true);
    }

    function test_AdminAttack_PolicyManager_OwnerRenounceLocksOwner() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        pm.renounceOwnership();
        assertEq(pm.owner(), address(0));

        // No further admin-only ops possible.
        vm.expectRevert();
        pm.setRouter(address(this));
    }

    function test_AdminAttack_CEXReserve_AdminCanRevokeOwnAllocator() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        bytes32 allocator = c.ALLOCATOR_ROLE();
        c.revokeRole(allocator, address(this));
        assertFalse(c.hasRole(allocator, address(this)));
    }

    // ────────────────────────────────────────────────────────────────
    // Admin key separation defence — the same attack by an attacker fails.
    // (Acts as a positive control for every "admin can" result above.)
    // ────────────────────────────────────────────────────────────────
    function test_AdminAttack_ControlCase_AttackerWithoutAdminCannotUpgrade() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        address evil = address(new MaliciousPolicyManagerImpl());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        pm.upgradeToAndCall(evil, "");
    }
}
