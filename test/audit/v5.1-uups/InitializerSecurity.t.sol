// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";
import {LuminaTokenV2} from "../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../src/core/CoverRouterV2.sol";

contract MockPriceOracleInit {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

/// @title InitializerSecurity
/// @notice Verifies UUPS initializer security for Phase A contracts.
contract InitializerSecurity is Test {
    address bondVault = makeAddr("bondVault");
    address cexReserve = makeAddr("cexReserve");
    address founderVesting = makeAddr("founderVesting");
    address lbpDeposit = makeAddr("lbpDeposit");
    address treasuryVesting = makeAddr("treasuryVesting");

    // ═══════ LuminaTokenV2 ═══════

    function test_LuminaToken_cannotInitializeTwice() public {
        LuminaTokenV2 token =
            ProxyDeployer.deployLuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);
        vm.expectRevert();
        token.initialize(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);
    }

    function test_LuminaToken_implementationCannotBeInitialized() public {
        LuminaTokenV2 impl = new LuminaTokenV2();
        vm.expectRevert();
        impl.initialize(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);
    }

    function test_LuminaToken_onlyAdminCanUpgrade() public {
        LuminaTokenV2 token =
            ProxyDeployer.deployLuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting);
        LuminaTokenV2 newImpl = new LuminaTokenV2();

        // Non-admin cannot upgrade
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        token.upgradeToAndCall(address(newImpl), "");

        // Admin (this contract, deployer) CAN upgrade
        token.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════ BondVault ═══════

    function test_BondVault_cannotInitializeTwice() public {
        MockPriceOracleInit oracle = new MockPriceOracleInit();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault vault = ProxyDeployer.deployBondVault(makeAddr("lumina"), address(cb), address(oracle), address(0));

        vm.expectRevert();
        vault.initialize(makeAddr("lumina"), address(cb), address(oracle), address(0));
    }

    function test_BondVault_implementationCannotBeInitialized() public {
        BondVault impl = new BondVault();
        vm.expectRevert();
        impl.initialize(makeAddr("lumina"), makeAddr("cb"), makeAddr("oracle"), address(0));
    }

    function test_BondVault_onlyAdminCanUpgrade() public {
        MockPriceOracleInit oracle = new MockPriceOracleInit();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault vault = ProxyDeployer.deployBondVault(makeAddr("lumina"), address(cb), address(oracle), address(0));
        BondVault newImpl = new BondVault();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        vault.upgradeToAndCall(address(newImpl), "");

        // Admin can upgrade
        vault.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════ ClaimBond ═══════

    function test_ClaimBond_cannotInitializeTwice() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        vm.expectRevert();
        cb.initialize();
    }

    function test_ClaimBond_implementationCannotBeInitialized() public {
        ClaimBond impl = new ClaimBond();
        vm.expectRevert();
        impl.initialize();
    }

    function test_ClaimBond_onlyOwnerCanUpgrade() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        ClaimBond newImpl = new ClaimBond();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        cb.upgradeToAndCall(address(newImpl), "");

        // Owner can upgrade
        cb.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════ PolicyManagerV2 ═══════

    function test_PolicyManager_cannotInitializeTwice() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        vm.expectRevert();
        pm.initialize(makeAddr("vault"));
    }

    function test_PolicyManager_implementationCannotBeInitialized() public {
        PolicyManagerV2 impl = new PolicyManagerV2();
        vm.expectRevert();
        impl.initialize(makeAddr("vault"));
    }

    function test_PolicyManager_onlyOwnerCanUpgrade() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        PolicyManagerV2 newImpl = new PolicyManagerV2();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        pm.upgradeToAndCall(address(newImpl), "");

        pm.upgradeToAndCall(address(newImpl), "");
    }

    // ═══════ CoverRouterV2 ═══════

    function test_CoverRouter_cannotInitializeTwice() public {
        CoverRouterV2 cr = ProxyDeployer.deployCoverRouterV2(makeAddr("usdc"), makeAddr("pm"), makeAddr("burner"));
        vm.expectRevert();
        cr.initialize(makeAddr("usdc"), makeAddr("pm"), makeAddr("burner"));
    }

    function test_CoverRouter_implementationCannotBeInitialized() public {
        CoverRouterV2 impl = new CoverRouterV2();
        vm.expectRevert();
        impl.initialize(makeAddr("usdc"), makeAddr("pm"), makeAddr("burner"));
    }

    function test_CoverRouter_onlyOwnerCanUpgrade() public {
        CoverRouterV2 cr = ProxyDeployer.deployCoverRouterV2(makeAddr("usdc"), makeAddr("pm"), makeAddr("burner"));
        CoverRouterV2 newImpl = new CoverRouterV2();

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        cr.upgradeToAndCall(address(newImpl), "");

        cr.upgradeToAndCall(address(newImpl), "");
    }
}
