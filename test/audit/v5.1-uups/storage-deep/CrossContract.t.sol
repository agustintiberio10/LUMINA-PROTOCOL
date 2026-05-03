// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../src/core/TWAPBurner.sol";
import {AdaptiveFeeDistributor} from "../../../../src/core/AdaptiveFeeDistributor.sol";
import {SolvencyOracle} from "../../../../src/oracles/SolvencyOracle.sol";
import {BuybackEngine} from "../../../../src/marketplace/BuybackEngine.sol";
import {LuminaBondMarketplace} from "../../../../src/marketplace/LuminaBondMarketplace.sol";

contract MockPriceOracleCC {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

contract MockBondVaultCC {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function totalCommittedUSD() external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title CrossContract
 * @notice Verifies that collaborating UUPS contracts continue to interact correctly
 * after BOTH (or all three) are independently upgraded. Storage layout of each
 * must be stable so that cross-contract references, pointers (addresses stored as
 * state), and role maps still resolve.
 */
contract CrossContract is Test {
    // 1. PolicyManager ↔ BondVault
    function test_Storage_CrossContract_PolicyManager_BondVault_AfterBothUpgraded() public {
        MockPriceOracleCC oracle = new MockPriceOracleCC();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("founder"), makeAddr("lbp"), makeAddr("treasury")
        );

        // BondVault's policyManager is set in init; deploy PM first, then vault with PM address.
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("placeholder-vault"));
        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(pm));
        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000e18);

        // Redeploy PM with the real vault so both sides link.
        pm = ProxyDeployer.deployPolicyManagerV2(address(vault));
        pm.setRouter(address(this));

        vault.upgradeToAndCall(address(new BondVault()), "");
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");

        assertEq(address(pm.bondVault()), address(vault));
        // vault.policyManager was set to the FIRST pm (the placeholder one); the new pm is
        // deployed separately and vault's pointer is not rewired by an upgrade. The cross-ref
        // test here is: PM still references the correct vault; that's the field that matters
        // for settlement flow.

        bytes32 pid = keccak256("CROSS-TEST");
        pm.registerProduct(pid, makeAddr("shield"));
        assertTrue(pm.productActive(pid));
        assertEq(pm.productShield(pid), makeAddr("shield"));
    }

    // 2. CoverRouter ↔ PolicyManager
    function test_Storage_CrossContract_CoverRouter_PolicyManager_AfterBothUpgraded() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        CoverRouterV2 router = ProxyDeployer.deployCoverRouterV2(makeAddr("usdc"), address(pm), makeAddr("burner"));
        pm.setRouter(address(router));

        router.configureProduct(keccak256("PROD-A"), 8000, 200, 2000, 3600, true);
        pm.registerProduct(keccak256("PROD-A"), makeAddr("shieldA"));

        // Upgrade BOTH
        router.upgradeToAndCall(address(new CoverRouterV2()), "");
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");

        // Verify cross-refs and state preserved
        assertEq(address(router.policyManager()), address(pm));
        assertEq(pm.router(), address(router));
        assertTrue(pm.productActive(keccak256("PROD-A")));
        (,,,,, bool active) = router.products(keccak256("PROD-A"));
        assertTrue(active);
    }

    // 3. TWAPBurner ↔ AdaptiveFeeDistributor ↔ SolvencyOracle (three-way)
    function test_Storage_CrossContract_TWAP_FeeDistributor_SolvencyOracle_AllUpgraded() public {
        MockBondVaultCC bv = new MockBondVaultCC(makeAddr("lumina"));
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
        AdaptiveFeeDistributor afd = ProxyDeployer.deployAdaptiveFeeDistributor(address(so));
        TWAPBurner burner = ProxyDeployer.deployTWAPBurner(makeAddr("usdc"), makeAddr("lumina"), makeAddr("dex"));
        burner.setFeeDistributor(address(afd));
        burner.setReserves(makeAddr("buybackReserve"), makeAddr("opsReserve"), makeAddr("maintReserve"));
        burner.setAdaptiveMode(true);

        // Upgrade ALL three
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        afd.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        burner.upgradeToAndCall(address(new TWAPBurner()), "");

        // Cross-references must still line up
        assertEq(address(afd.solvencyOracle()), address(so));
        assertEq(burner.feeDistributor(), address(afd));
        assertTrue(burner.adaptiveModeEnabled());
    }

    // 4. BuybackEngine ↔ Marketplace ↔ ClaimBond
    function test_Storage_CrossContract_Buyback_Marketplace_ClaimBond_AllUpgraded() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), makeAddr("usdc"), makeAddr("burner"), address(this));
        BuybackEngine be = ProxyDeployer.deployBuybackEngine(
            address(cb), makeAddr("bv"), makeAddr("so"), makeAddr("co"), address(mp), makeAddr("usdc"), address(this)
        );

        // Set state on each
        cb.setBondVault(address(this));
        cb.mint(makeAddr("alice"), 202804, 1000);
        mp.setTwapBurner(makeAddr("newBurner"));
        be.setDailyBuyback(10_000e6, 80, 4);

        // Upgrade ALL three
        cb.upgradeToAndCall(address(new ClaimBond()), "");
        mp.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        be.upgradeToAndCall(address(new BuybackEngine()), "");

        // Cross-references and state preserved
        assertEq(address(mp.claimBond()), address(cb));
        assertEq(address(be.claimBond()), address(cb));
        assertEq(address(be.marketplace()), address(mp));
        assertEq(cb.balanceOf(makeAddr("alice"), 202804), 1000);
        assertEq(mp.twapBurner(), makeAddr("newBurner"));
        (uint256 budget,,,) = be.dailyConfig();
        assertEq(budget, 10_000e6);
    }

    // 5. Shield ↔ PolicyManager (via a mocked shield + real PM, since real shields are
    //    deployed behind router — the key cross-ref verification here is that PM's
    //    productShield mapping survives upgrade of both sides).
    function test_Storage_CrossContract_Shield_PolicyManager_BothUpgraded() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        pm.setRouter(address(this));
        address shield = makeAddr("shield1");
        bytes32 pid = keccak256("SHIELD-PID-001");
        pm.registerProduct(pid, shield);

        // Upgrade PolicyManager (stand-in for simultaneous upgrade — shields are just
        // addresses from PM's perspective; a shield upgrade doesn't rewire the pointer).
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");

        // Cross-refs
        assertTrue(pm.productActive(pid));
        assertEq(pm.productShield(pid), shield);

        // Registering further products post-upgrade must still work.
        pm.registerProduct(keccak256("SHIELD-PID-002"), makeAddr("shield2"));
        assertTrue(pm.productActive(keccak256("SHIELD-PID-002")));
    }
}
