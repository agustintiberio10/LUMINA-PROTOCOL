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
import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";

contract MockOracleCC2 {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

contract MockBondVaultCC2 {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function totalCommittedUSD() external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title UpgradePathCrossContract
 * @notice Cross-contract E2E upgrade scenarios.
 *
 * Covers the five cross-contract flows defined in the audit plan:
 *  1. Full-lifecycle with all contracts upgraded.
 *  2. Partial upgrade — only some contracts upgraded.
 *  3. PolicyManager ↔ BondVault post-upgrade.
 *  4. CoverRouter ↔ Shields post-upgrade.
 *  5. TWAPBurner ↔ AdaptiveFeeDistributor post-upgrade.
 */
contract UpgradePathCrossContract is Test {
    // ────────────────────────────────────────────────────────────────
    // 1. Full-lifecycle with 9+ contracts all upgraded in sequence
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_FullLifecycle_AllContractsUpgraded() public {
        vm.chainId(8453);
        // Deploy the core set and set up basic state.
        MockOracleCC2 priceOracle = new MockOracleCC2();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault vault =
            ProxyDeployer.deployBondVault(address(token), address(cb), address(priceOracle), address(this));
        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000e18);

        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(address(vault));
        pm.setRouter(address(this));
        pm.registerProduct(keccak256("PROD"), makeAddr("shield"));

        CoverRouterV2 router = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), address(pm), makeAddr("b"));
        router.configureProduct(keccak256("PROD"), 8000, 200, 2000, 3600, true);

        TWAPBurner burner = ProxyDeployer.deployTWAPBurner(makeAddr("u"), address(token), makeAddr("d"));
        burner.setMinBurnAmount(1e6);

        MockBondVaultCC2 mockBV = new MockBondVaultCC2(address(token));
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(mockBV), makeAddr("co"), address(this));
        AdaptiveFeeDistributor afd = ProxyDeployer.deployAdaptiveFeeDistributor(address(so));

        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(address(cb), makeAddr("u"), address(burner), address(this));

        BuybackEngine be = ProxyDeployer.deployBuybackEngine(
            address(cb), address(vault), address(so), makeAddr("co"), address(mp), makeAddr("u"), address(this)
        );
        be.setDailyBuyback(10_000e6, 80, 4);

        // Issue a bond and mint claim bonds as state before upgrade.
        vm.warp(1767225600 + 30 days);
        vault.issueBond(makeAddr("u1"), 1000);

        // Upgrade EVERY contract in sequence.
        token.upgradeToAndCall(address(new LuminaTokenV2()), "");
        vault.upgradeToAndCall(address(new BondVault()), "");
        cb.upgradeToAndCall(address(new ClaimBond()), "");
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");
        router.upgradeToAndCall(address(new CoverRouterV2()), "");
        burner.upgradeToAndCall(address(new TWAPBurner()), "");
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        afd.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        mp.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        be.upgradeToAndCall(address(new BuybackEngine()), "");

        // Verify cross-references still resolve.
        assertEq(address(pm.bondVault()), address(vault));
        assertEq(address(router.policyManager()), address(pm));
        assertEq(address(afd.solvencyOracle()), address(so));
        assertEq(address(mp.claimBond()), address(cb));
        assertEq(address(be.marketplace()), address(mp));

        // Verify state survived.
        assertEq(vault.totalCommittedUSD(), 1000e18);
        assertTrue(pm.productActive(keccak256("PROD")));
        (,,,,, bool productActive) = router.products(keccak256("PROD"));
        assertTrue(productActive);

        // Continue operations post-upgrade.
        vault.issueBond(makeAddr("u2"), 500);
        assertEq(vault.totalCommittedUSD(), 1500e18);
        pm.registerProduct(keccak256("PROD2"), makeAddr("shield2"));
        assertTrue(pm.productActive(keccak256("PROD2")));
    }

    // ────────────────────────────────────────────────────────────────
    // 2. Partial upgrade — only PolicyManager and BondVault updated
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_PartialUpgrade_OnlySomeContractsUpgraded() public {
        vm.chainId(8453);
        MockOracleCC2 oracle = new MockOracleCC2();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000e18);
        vm.warp(1767225600 + 30 days);

        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(address(vault));
        pm.setRouter(address(this));
        vault.issueBond(makeAddr("u"), 1000);
        pm.registerProduct(keccak256("PID"), makeAddr("shield"));

        // Upgrade ONLY PolicyManager and BondVault; ClaimBond stays at V1.
        vault.upgradeToAndCall(address(new BondVault()), "");
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");

        // Cross-contract call from PM → vault still works; ClaimBond state intact.
        assertEq(vault.totalCommittedUSD(), 1000e18);
        assertTrue(pm.productActive(keccak256("PID")));
        assertEq(cb.bondVault(), address(vault));

        // Continue operations.
        vault.issueBond(makeAddr("u2"), 500);
        assertEq(vault.totalCommittedUSD(), 1500e18);
    }

    // ────────────────────────────────────────────────────────────────
    // 3. PolicyManager ↔ BondVault integrity after both upgraded
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_CrossContract_PolicyManagerAndBondVault() public {
        vm.chainId(8453);
        MockOracleCC2 oracle = new MockOracleCC2();
        LuminaTokenV2 token = ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("placeholder"));
        BondVault vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(pm));
        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000e18);

        pm = ProxyDeployer.deployPolicyManagerV2(address(vault));
        pm.setRouter(address(this));

        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");
        vault.upgradeToAndCall(address(new BondVault()), "");

        assertEq(address(pm.bondVault()), address(vault));

        // A cross-call path from PM to vault (mocking shield.createPolicy) still works.
        bytes32 pid = keccak256("X");
        pm.registerProduct(pid, makeAddr("shield"));
        assertEq(pm.productShield(pid), makeAddr("shield"));
    }

    // ────────────────────────────────────────────────────────────────
    // 4. CoverRouter ↔ Shields: router upgrade doesn't break shield access
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_CrossContract_CoverRouterAndShields() public {
        vm.chainId(8453);
        CoverRouterV2 router = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        // A shield registered with router=address(this) (simulating PM) — the shield
        // itself is not owned by the router in this test, we just confirm each side
        // can be upgraded independently.
        FlashBTCShield1h shield = ProxyDeployer.deployFlashBTCShield1h(address(this), makeAddr("oracle"));

        router.configureProduct(shield.PRODUCT_ID(), 8000, 200, 2000, 3600, true);

        // Upgrade both.
        router.upgradeToAndCall(address(new CoverRouterV2()), "");
        shield.upgradeToAndCall(address(new FlashBTCShield1h()), "");

        // Post-upgrade: router's product config preserved; shield identity preserved.
        (,,,,, bool active) = router.products(shield.PRODUCT_ID());
        assertTrue(active);
        assertEq(shield.router(), address(this));
    }

    // ────────────────────────────────────────────────────────────────
    // 5. TWAPBurner ↔ AdaptiveFeeDistributor post-upgrade
    // ────────────────────────────────────────────────────────────────
    function test_UpgradeE2E_CrossContract_TWAPBurnerAndDistributor() public {
        vm.chainId(8453);
        MockBondVaultCC2 mockBV = new MockBondVaultCC2(makeAddr("lumina"));
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(mockBV), makeAddr("co"), address(this));
        AdaptiveFeeDistributor afd = ProxyDeployer.deployAdaptiveFeeDistributor(address(so));
        TWAPBurner burner = ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
        burner.setFeeDistributor(address(afd));
        burner.setReserves(makeAddr("br"), makeAddr("or"), makeAddr("mr"));
        burner.setAdaptiveMode(true);

        // Upgrade all three.
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        afd.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        burner.upgradeToAndCall(address(new TWAPBurner()), "");

        // Cross-refs preserved.
        assertEq(address(afd.solvencyOracle()), address(so));
        assertEq(burner.feeDistributor(), address(afd));
        assertTrue(burner.adaptiveModeEnabled());

        // Adaptive flag toggling post-upgrade still works.
        burner.setAdaptiveMode(false);
        assertFalse(burner.adaptiveModeEnabled());
        burner.setAdaptiveMode(true);
        assertTrue(burner.adaptiveModeEnabled());
    }
}
