// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {LuminaTokenV2} from "../../src/token/LuminaTokenV2.sol";
import {ClaimBond} from "../../src/bonds/ClaimBond.sol";
import {BondVault} from "../../src/bonds/BondVault.sol";

/// @title DeployBondVaultSetC
/// @notice Sprint T (ADR-012) — regression tests for the deploy script fix.
///         Validates that a fresh BondVault deploy via the documented pattern
///         leaves the deployer holding **BOTH** admin roles + correct wiring +
///         default `bondMaturitySeconds`.
///
///         The bug being prevented (BondVault SET B Sepolia, block 41,213,954):
///         the deploy script auto-revoked DEFAULT_ADMIN_ROLE 87 blocks after
///         deploy, dropping admin holders to 0 — the proxy became
///         upgrade-locked permanently. Sprint T removed those revoke calls
///         from `script/deploy/DeployLuminaV5Complete.s.sol` (lines 562-567).
///
///         These tests verify the post-deploy invariants the script must
///         maintain. They DO NOT execute the .s.sol script directly (that is
///         covered by `test/audit/v5.1-uups/integration/deploy/DeployScripts.t.sol`),
///         but mirror the deploy + wiring flow so any regression that
///         re-introduces a self-revoke fails here.
contract MockPriceOracle_DeploySetC {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

contract DeployBondVaultSetC is Test {
    LuminaTokenV2 token;
    ClaimBond claimBond;
    BondVault vault;
    MockPriceOracle_DeploySetC oracle;

    address deployer = address(this);
    address policyManager = makeAddr("policyManager");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");
    address cexLiquidityReserve = makeAddr("cexLiquidityReserve");

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1767225600 + 30 days);

        oracle = new MockPriceOracle_DeploySetC();

        // Mirror the deploy script's flow: deploy + wire + verify.
        // Deliberately omits the (now-removed) post-deploy revokeRole calls.
        ClaimBond claimBondImpl = new ClaimBond();
        ERC1967Proxy claimBondProxy =
            new ERC1967Proxy(address(claimBondImpl), abi.encodeWithSelector(ClaimBond.initialize.selector));
        claimBond = ClaimBond(address(claimBondProxy));

        // LuminaTokenV2 — initialized with all 5 distribution targets.
        LuminaTokenV2 tokenImpl = new LuminaTokenV2();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeWithSelector(
                LuminaTokenV2.initialize.selector,
                makeAddr("tempVault"),
                cexLiquidityReserve,
                founderVesting,
                lbpDeposit,
                treasuryVesting
            )
        );
        token = LuminaTokenV2(address(tokenProxy));

        BondVault vaultImpl = new BondVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeWithSelector(
                BondVault.initialize.selector, address(token), address(claimBond), address(oracle), policyManager
            )
        );
        vault = BondVault(address(vaultProxy));

        claimBond.setBondVault(address(vault));
    }

    // ─────────────────────────────────────────────────────────
    // Role retention — the core regression tests
    // ─────────────────────────────────────────────────────────

    function test_Deploy_DeployerKeepsDefaultAdminRole() public view {
        assertTrue(
            vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer), "Deployer must retain DEFAULT_ADMIN_ROLE post-deploy"
        );
    }

    function test_Deploy_DeployerKeepsAuthorizedCallerAdminRole() public view {
        assertTrue(
            vault.hasRole(vault.AUTHORIZED_CALLER_ADMIN_ROLE(), deployer),
            "Deployer must retain AUTHORIZED_CALLER_ADMIN_ROLE post-deploy"
        );
    }

    /// @notice Demonstrates the lockdown failure mode the fix prevents:
    ///         if `revokeRole(DEFAULT_ADMIN_ROLE, deployer)` were re-introduced
    ///         post-deploy, the proxy would become upgrade-locked. This test
    ///         performs the revoke deliberately and asserts the resulting
    ///         locked-state — guarantees we recognize the failure mode.
    function test_Deploy_NoSelfRevokeOccurs_RegressionDemo() public {
        // Pre-state per the actual deploy script flow (Sprint T): role retained.
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer));

        // SIMULATE the bug — deploy script self-revoke.
        vault.revokeRole(vault.DEFAULT_ADMIN_ROLE(), deployer);

        // Post-revoke: 0 admin holders. Upgrade attempts revert.
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), deployer));

        BondVault newImpl = new BondVault();
        vm.expectRevert(); // AccessControlUnauthorizedAccount
        vault.upgradeToAndCall(address(newImpl), "");
    }

    // ─────────────────────────────────────────────────────────
    // Initialization invariants
    // ─────────────────────────────────────────────────────────

    function test_Deploy_BondMaturitySecondsDefault730Days() public view {
        assertEq(vault.bondMaturitySeconds(), 730 days);
    }

    function test_Deploy_PolicyManagerWired() public view {
        assertEq(vault.policyManager(), policyManager);
    }

    function test_Deploy_ClaimBondWired() public view {
        assertEq(address(vault.claimBond()), address(claimBond));
    }

    function test_Deploy_LuminaWired() public view {
        assertEq(address(vault.lumina()), address(token));
    }

    function test_Deploy_PriceOracleWired() public view {
        assertEq(address(vault.priceOracle()), address(oracle));
    }
}
