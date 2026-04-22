// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ProxyDeployer} from "../../../helpers/ProxyDeployer.sol";

import {LuminaTokenV2} from "../../../../src/token/LuminaTokenV2.sol";
import {BondVault} from "../../../../src/bonds/BondVault.sol";
import {ClaimBond} from "../../../../src/bonds/ClaimBond.sol";
import {PolicyManagerV2} from "../../../../src/core/PolicyManagerV2.sol";
import {CoverRouterV2} from "../../../../src/core/CoverRouterV2.sol";
import {TWAPBurner} from "../../../../src/core/TWAPBurner.sol";
import {AdaptiveFeeDistributor} from "../../../../src/core/AdaptiveFeeDistributor.sol";
import {BuybackEngine} from "../../../../src/marketplace/BuybackEngine.sol";
import {LuminaBondMarketplace} from "../../../../src/marketplace/LuminaBondMarketplace.sol";
import {ShieldKeeper} from "../../../../src/automation/ShieldKeeper.sol";
import {CapacityOracle} from "../../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../../src/oracles/SolvencyOracle.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../src/treasury/MaintenanceReserve.sol";
import {TreasuryVesting} from "../../../../src/token/TreasuryVesting.sol";

contract MockOracleE2E {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
}

contract MockBondVaultE2E {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function totalCommittedUSD() external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title UpgradePathE2E
 * @notice End-to-end upgrade tests for 15 core UUPS contracts.
 *
 * Each contract is tested through three scenarios that emphasise FUNCTIONAL
 * behaviour after an upgrade (complementing audits #1 and #2 which focus on
 * storage-slot layout and initializer safety).
 *
 *   (A) WithActiveState          — deploy V1, exercise real operations to
 *                                  populate state, upgrade, verify state
 *                                  AND continue to operate successfully.
 *   (B) SequentialUpgrades       — V1 → V2 → V3 with operations interleaved
 *                                  between upgrades, confirming accumulated
 *                                  state survives every step.
 *   (C) PostUpgradeOperationsWork — after one upgrade, all primary methods
 *                                   still function identically.
 */
contract UpgradePathE2E is Test {
    // ─────────────────────────────────────────────────────────────
    // 1. LuminaTokenV2
    // ─────────────────────────────────────────────────────────────
    function _deployToken() internal returns (LuminaTokenV2) {
        return ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
    }

    function test_UpgradeE2E_LuminaToken_WithActiveState() public {
        LuminaTokenV2 t = _deployToken();
        t.grantRole(t.BURNER_ROLE(), address(this));
        vm.prank(makeAddr("lbp"));
        t.approve(address(this), 3_000e18);
        t.burnFrom(makeAddr("lbp"), 3_000e18);

        uint256 burnedBefore = t.totalBurned();
        uint256 supplyBefore = t.totalSupply();

        t.upgradeToAndCall(address(new LuminaTokenV2()), "");

        assertEq(t.totalBurned(), burnedBefore);
        assertEq(t.totalSupply(), supplyBefore);

        // Continue operations post-upgrade.
        vm.prank(makeAddr("lbp"));
        t.approve(address(this), 1_000e18);
        t.burnFrom(makeAddr("lbp"), 1_000e18);
        assertEq(t.totalBurned(), burnedBefore + 1_000e18);
    }

    function test_UpgradeE2E_LuminaToken_SequentialUpgrades() public {
        LuminaTokenV2 t = _deployToken();
        t.grantRole(t.BURNER_ROLE(), address(this));
        vm.prank(makeAddr("lbp"));
        t.approve(address(this), 5_000e18);

        t.burnFrom(makeAddr("lbp"), 1_000e18);
        t.upgradeToAndCall(address(new LuminaTokenV2()), "");

        t.burnFrom(makeAddr("lbp"), 1_500e18);
        t.upgradeToAndCall(address(new LuminaTokenV2()), "");

        t.burnFrom(makeAddr("lbp"), 2_500e18);
        t.upgradeToAndCall(address(new LuminaTokenV2()), "");

        assertEq(t.totalBurned(), 5_000e18);
        assertTrue(t.hasRole(t.BURNER_ROLE(), address(this)));
    }

    function test_UpgradeE2E_LuminaToken_PostUpgradeOperationsWork() public {
        LuminaTokenV2 t = _deployToken();
        t.upgradeToAndCall(address(new LuminaTokenV2()), "");

        // Grant role, burn, transfer — every operation should succeed.
        t.grantRole(t.BURNER_ROLE(), address(this));
        assertTrue(t.hasRole(t.BURNER_ROLE(), address(this)));

        vm.prank(makeAddr("lbp"));
        t.transfer(makeAddr("alice"), 1_000e18);
        assertEq(t.balanceOf(makeAddr("alice")), 1_000e18);

        vm.prank(makeAddr("alice"));
        t.approve(address(this), 500e18);
        t.burnFrom(makeAddr("alice"), 500e18);
        assertEq(t.balanceOf(makeAddr("alice")), 500e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 2. BondVault
    // ─────────────────────────────────────────────────────────────
    function _deployBondVaultFull() internal returns (BondVault vault, LuminaTokenV2 token, ClaimBond cb) {
        MockOracleE2E oracle = new MockOracleE2E();
        cb = ProxyDeployer.deployClaimBond();
        token = _deployToken();
        vault = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        cb.setBondVault(address(vault));
        deal(address(token), address(vault), 70_000_000e18);
        vm.warp(1767225600 + 30 days);
    }

    function test_UpgradeE2E_BondVault_WithActiveState() public {
        (BondVault vault,,) = _deployBondVaultFull();
        vault.issueBond(makeAddr("u1"), 1000);
        vault.issueBond(makeAddr("u2"), 2000);
        uint256 committedBefore = vault.totalCommittedUSD();

        vault.upgradeToAndCall(address(new BondVault()), "");

        assertEq(vault.totalCommittedUSD(), committedBefore);
        vault.issueBond(makeAddr("u3"), 500);
        assertEq(vault.totalCommittedUSD(), committedBefore + 500e18);
    }

    function test_UpgradeE2E_BondVault_SequentialUpgrades() public {
        (BondVault vault,,) = _deployBondVaultFull();
        vault.issueBond(makeAddr("u1"), 1000);
        vault.upgradeToAndCall(address(new BondVault()), "");
        vault.issueBond(makeAddr("u2"), 2000);
        vault.upgradeToAndCall(address(new BondVault()), "");
        vault.issueBond(makeAddr("u3"), 3000);
        vault.upgradeToAndCall(address(new BondVault()), "");
        assertEq(vault.totalCommittedUSD(), 6000e18);
    }

    function test_UpgradeE2E_BondVault_PostUpgradeOperationsWork() public {
        (BondVault vault,,) = _deployBondVaultFull();
        vault.upgradeToAndCall(address(new BondVault()), "");

        vault.setAuthorizedCaller(makeAddr("buyback"), true);
        assertTrue(vault.authorizedCallers(makeAddr("buyback")));
        vault.issueBond(makeAddr("u"), 100);
        assertEq(vault.totalCommittedUSD(), 100e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. ClaimBond
    // ─────────────────────────────────────────────────────────────
    function test_UpgradeE2E_ClaimBond_WithActiveState() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));
        cb.mint(makeAddr("alice"), 202804, 1000);

        cb.upgradeToAndCall(address(new ClaimBond()), "");

        assertEq(cb.balanceOf(makeAddr("alice"), 202804), 1000);
        cb.mint(makeAddr("alice"), 202804, 500);
        assertEq(cb.balanceOf(makeAddr("alice"), 202804), 1500);
    }

    function test_UpgradeE2E_ClaimBond_SequentialUpgrades() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));

        cb.mint(makeAddr("a"), 202804, 100);
        cb.upgradeToAndCall(address(new ClaimBond()), "");
        cb.mint(makeAddr("a"), 202805, 200);
        cb.upgradeToAndCall(address(new ClaimBond()), "");
        cb.mint(makeAddr("a"), 202806, 400);
        cb.upgradeToAndCall(address(new ClaimBond()), "");

        assertEq(cb.balanceOf(makeAddr("a"), 202804), 100);
        assertEq(cb.balanceOf(makeAddr("a"), 202805), 200);
        assertEq(cb.balanceOf(makeAddr("a"), 202806), 400);
    }

    function test_UpgradeE2E_ClaimBond_PostUpgradeOperationsWork() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));
        cb.upgradeToAndCall(address(new ClaimBond()), "");

        cb.mint(makeAddr("alice"), 202804, 1000);
        cb.mint(makeAddr("bob"), 202805, 2000);
        assertEq(cb.totalSupply(202804), 1000);
        assertEq(cb.totalSupply(202805), 2000);
    }

    // ─────────────────────────────────────────────────────────────
    // 4. PolicyManagerV2
    // ─────────────────────────────────────────────────────────────
    function _deployPM() internal returns (PolicyManagerV2 pm) {
        pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        pm.setRouter(address(this));
    }

    function test_UpgradeE2E_PolicyManager_WithActiveState() public {
        PolicyManagerV2 pm = _deployPM();
        pm.registerProduct(keccak256("PID1"), makeAddr("shield1"));
        pm.registerProduct(keccak256("PID2"), makeAddr("shield2"));

        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");

        assertTrue(pm.productActive(keccak256("PID1")));
        assertTrue(pm.productActive(keccak256("PID2")));
        pm.registerProduct(keccak256("PID3"), makeAddr("shield3"));
        assertTrue(pm.productActive(keccak256("PID3")));
    }

    function test_UpgradeE2E_PolicyManager_SequentialUpgrades() public {
        PolicyManagerV2 pm = _deployPM();
        pm.registerProduct(keccak256("A"), makeAddr("sA"));
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");
        pm.registerProduct(keccak256("B"), makeAddr("sB"));
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");
        pm.registerProduct(keccak256("C"), makeAddr("sC"));
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");
        assertTrue(pm.productActive(keccak256("A")));
        assertTrue(pm.productActive(keccak256("B")));
        assertTrue(pm.productActive(keccak256("C")));
    }

    function test_UpgradeE2E_PolicyManager_PostUpgradeOperationsWork() public {
        PolicyManagerV2 pm = _deployPM();
        pm.upgradeToAndCall(address(new PolicyManagerV2()), "");

        pm.registerProduct(keccak256("XYZ"), makeAddr("shield"));
        assertTrue(pm.productActive(keccak256("XYZ")));
        pm.deactivateProduct(keccak256("XYZ"));
        assertFalse(pm.productActive(keccak256("XYZ")));
    }

    // ─────────────────────────────────────────────────────────────
    // 5. CoverRouterV2
    // ─────────────────────────────────────────────────────────────
    function test_UpgradeE2E_CoverRouterV2_WithActiveState() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        r.configureProduct(keccak256("A"), 8000, 200, 2000, 3600, true);
        r.setRelayer(makeAddr("relayer"), true);

        r.upgradeToAndCall(address(new CoverRouterV2()), "");

        assertTrue(r.authorizedRelayers(makeAddr("relayer")));
        r.configureProduct(keccak256("B"), 7000, 300, 1500, 7200, true);
        (,,,,, bool active) = r.products(keccak256("B"));
        assertTrue(active);
    }

    function test_UpgradeE2E_CoverRouterV2_SequentialUpgrades() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        r.configureProduct(keccak256("A"), 8000, 100, 1000, 3600, true);
        r.upgradeToAndCall(address(new CoverRouterV2()), "");
        r.configureProduct(keccak256("B"), 7000, 200, 1500, 7200, true);
        r.upgradeToAndCall(address(new CoverRouterV2()), "");
        r.configureProduct(keccak256("C"), 6000, 300, 2000, 86400, true);
        r.upgradeToAndCall(address(new CoverRouterV2()), "");
        (,,,,, bool a) = r.products(keccak256("A"));
        (,,,,, bool b) = r.products(keccak256("B"));
        (,,,,, bool c) = r.products(keccak256("C"));
        assertTrue(a && b && c);
    }

    function test_UpgradeE2E_CoverRouterV2_PostUpgradeOperationsWork() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        r.upgradeToAndCall(address(new CoverRouterV2()), "");

        r.configureProduct(keccak256("P"), 8000, 100, 500, 3600, true);
        r.setRelayer(makeAddr("r"), true);
        // Reconfigure as inactive (no dedicated deactivate — configureProduct sets active bool).
        r.configureProduct(keccak256("P"), 8000, 100, 500, 3600, false);
        (,,,,, bool active) = r.products(keccak256("P"));
        assertFalse(active);
        r.setPaused(true);
        assertTrue(r.paused());
    }

    // ─────────────────────────────────────────────────────────────
    // 6. TWAPBurner
    // ─────────────────────────────────────────────────────────────
    function _deployBurner() internal returns (TWAPBurner) {
        return ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
    }

    function test_UpgradeE2E_TWAPBurner_WithActiveState() public {
        TWAPBurner b = _deployBurner();
        b.setMinBurnAmount(1e6);
        b.setBurnCooldown(3600);
        b.setAuthorizedSender(makeAddr("relayer"), true);

        b.upgradeToAndCall(address(new TWAPBurner()), "");

        assertEq(b.minBurnAmount(), 1e6);
        assertEq(b.burnCooldown(), 3600);
        assertTrue(b.authorizedSenders(makeAddr("relayer")));

        b.setBurnCooldown(7200);
        assertEq(b.burnCooldown(), 7200);
    }

    function test_UpgradeE2E_TWAPBurner_SequentialUpgrades() public {
        TWAPBurner b = _deployBurner();
        b.setMinBurnAmount(1e6);
        b.upgradeToAndCall(address(new TWAPBurner()), "");
        b.setMinBurnAmount(2e6);
        b.upgradeToAndCall(address(new TWAPBurner()), "");
        b.setMinBurnAmount(5e6);
        b.upgradeToAndCall(address(new TWAPBurner()), "");
        assertEq(b.minBurnAmount(), 5e6);
    }

    function test_UpgradeE2E_TWAPBurner_PostUpgradeOperationsWork() public {
        TWAPBurner b = _deployBurner();
        b.upgradeToAndCall(address(new TWAPBurner()), "");

        b.setMinBurnAmount(1e6);
        b.setMaxBurnAmount(100_000e6);
        b.setMaxSlippageBps(200);
        b.setFeeDistributor(makeAddr("fd"));
        b.setReserves(makeAddr("br"), makeAddr("or"), makeAddr("mr"));
        b.setAdaptiveMode(true);
        assertTrue(b.adaptiveModeEnabled());
    }

    // ─────────────────────────────────────────────────────────────
    // 7. AdaptiveFeeDistributor
    // ─────────────────────────────────────────────────────────────
    function test_UpgradeE2E_AdaptiveFeeDistributor_WithActiveState() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("so"));
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        assertEq(address(d.solvencyOracle()), makeAddr("so"));
    }

    function test_UpgradeE2E_AdaptiveFeeDistributor_SequentialUpgrades() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("so"));
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        assertEq(address(d.solvencyOracle()), makeAddr("so"));
    }

    function test_UpgradeE2E_AdaptiveFeeDistributor_PostUpgradeOperationsWork() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("so"));
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        assertEq(d.owner(), address(this));
    }

    // ─────────────────────────────────────────────────────────────
    // 8. BuybackEngine
    // ─────────────────────────────────────────────────────────────
    function _deployBE() internal returns (BuybackEngine) {
        return ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"), makeAddr("bv"), makeAddr("so"), makeAddr("co"), makeAddr("mk"), makeAddr("u"), address(this)
        );
    }

    function test_UpgradeE2E_BuybackEngine_WithActiveState() public {
        BuybackEngine be = _deployBE();
        be.setDailyBuyback(10_000e6, 80, 4);

        be.upgradeToAndCall(address(new BuybackEngine()), "");

        (uint256 budget, uint256 maxPct,,) = be.dailyConfig();
        assertEq(budget, 10_000e6);
        assertEq(maxPct, 80);

        be.setDailyBuyback(20_000e6, 90, 5);
        (uint256 newBudget,,,) = be.dailyConfig();
        assertEq(newBudget, 20_000e6);
    }

    function test_UpgradeE2E_BuybackEngine_SequentialUpgrades() public {
        BuybackEngine be = _deployBE();
        be.setDailyBuyback(1_000e6, 70, 2);
        be.upgradeToAndCall(address(new BuybackEngine()), "");
        be.setDailyBuyback(2_000e6, 80, 3);
        be.upgradeToAndCall(address(new BuybackEngine()), "");
        be.setDailyBuyback(3_000e6, 90, 4);
        be.upgradeToAndCall(address(new BuybackEngine()), "");
        (uint256 budget,,,) = be.dailyConfig();
        assertEq(budget, 3_000e6);
    }

    function test_UpgradeE2E_BuybackEngine_PostUpgradeOperationsWork() public {
        BuybackEngine be = _deployBE();
        be.upgradeToAndCall(address(new BuybackEngine()), "");

        be.setDailyBuyback(5_000e6, 85, 6);
        assertTrue(be.hasRole(be.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    // ─────────────────────────────────────────────────────────────
    // 9. LuminaBondMarketplace
    // ─────────────────────────────────────────────────────────────
    function _deployMP() internal returns (LuminaBondMarketplace) {
        return ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
    }

    function test_UpgradeE2E_LuminaBondMarketplace_WithActiveState() public {
        LuminaBondMarketplace m = _deployMP();
        m.setTwapBurner(makeAddr("b1"));

        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");

        assertEq(m.twapBurner(), makeAddr("b1"));
        m.setTwapBurner(makeAddr("b2"));
        assertEq(m.twapBurner(), makeAddr("b2"));
    }

    function test_UpgradeE2E_LuminaBondMarketplace_SequentialUpgrades() public {
        LuminaBondMarketplace m = _deployMP();
        m.setTwapBurner(makeAddr("b1"));
        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        m.setTwapBurner(makeAddr("b2"));
        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        m.setTwapBurner(makeAddr("b3"));
        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        assertEq(m.twapBurner(), makeAddr("b3"));
    }

    function test_UpgradeE2E_LuminaBondMarketplace_PostUpgradeOperationsWork() public {
        LuminaBondMarketplace m = _deployMP();
        m.upgradeToAndCall(address(new LuminaBondMarketplace()), "");
        m.setTwapBurner(makeAddr("nb"));
        assertEq(m.twapBurner(), makeAddr("nb"));
        assertTrue(m.hasRole(m.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    // ─────────────────────────────────────────────────────────────
    // 10. ShieldKeeper
    // ─────────────────────────────────────────────────────────────
    function test_UpgradeE2E_ShieldKeeper_WithActiveState() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();

        k.upgradeToAndCall(address(new ShieldKeeper()), "");

        assertTrue(k.paused());
        k.unpause();
        assertFalse(k.paused());
    }

    function test_UpgradeE2E_ShieldKeeper_SequentialUpgrades() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        k.upgradeToAndCall(address(new ShieldKeeper()), "");
        k.unpause();
        k.upgradeToAndCall(address(new ShieldKeeper()), "");
        k.pause();
        k.upgradeToAndCall(address(new ShieldKeeper()), "");
        assertTrue(k.paused());
    }

    function test_UpgradeE2E_ShieldKeeper_PostUpgradeOperationsWork() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.upgradeToAndCall(address(new ShieldKeeper()), "");
        k.pause();
        k.unpause();
        assertFalse(k.paused());
    }

    // ─────────────────────────────────────────────────────────────
    // 11. CapacityOracle
    // ─────────────────────────────────────────────────────────────
    function _deployCO() internal returns (CapacityOracle) {
        return ProxyDeployer.deployCapacityOracle(address(0), makeAddr("l"), makeAddr("u"), 0.036e18);
    }

    function test_UpgradeE2E_CapacityOracle_WithActiveState() public {
        CapacityOracle o = _deployCO();
        o.setEmergencyPrice(0.05e18);
        o.setTwapWindow(600);

        o.upgradeToAndCall(address(new CapacityOracle()), "");

        assertEq(o.emergencyPrice(), 0.05e18);
        assertEq(o.twapWindow(), 600);
        o.setEmergencyPrice(0.07e18);
        assertEq(o.emergencyPrice(), 0.07e18);
    }

    function test_UpgradeE2E_CapacityOracle_SequentialUpgrades() public {
        CapacityOracle o = _deployCO();
        o.setEmergencyPrice(0.01e18);
        o.upgradeToAndCall(address(new CapacityOracle()), "");
        o.setEmergencyPrice(0.02e18);
        o.upgradeToAndCall(address(new CapacityOracle()), "");
        o.setEmergencyPrice(0.03e18);
        o.upgradeToAndCall(address(new CapacityOracle()), "");
        assertEq(o.emergencyPrice(), 0.03e18);
    }

    function test_UpgradeE2E_CapacityOracle_PostUpgradeOperationsWork() public {
        CapacityOracle o = _deployCO();
        o.upgradeToAndCall(address(new CapacityOracle()), "");

        o.setEmergencyPrice(0.99e18);
        o.setTwapWindow(1200);
        assertEq(o.emergencyPrice(), 0.99e18);
        assertEq(o.twapWindow(), 1200);
        // getLuminaPrice falls back to emergencyPrice when pool == address(0).
        assertEq(o.getLuminaPrice(), 0.99e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 12. SolvencyOracle
    // ─────────────────────────────────────────────────────────────
    function _deploySO() internal returns (SolvencyOracle) {
        MockBondVaultE2E bv = new MockBondVaultE2E(makeAddr("lumina"));
        return ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
    }

    function test_UpgradeE2E_SolvencyOracle_WithActiveState() public {
        SolvencyOracle so = _deploySO();
        so.setEmergencyPause(true);

        so.upgradeToAndCall(address(new SolvencyOracle()), "");

        assertTrue(so.emergencyPaused());
        so.setEmergencyPause(false);
        assertFalse(so.emergencyPaused());
    }

    function test_UpgradeE2E_SolvencyOracle_SequentialUpgrades() public {
        SolvencyOracle so = _deploySO();
        so.setEmergencyPause(true);
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        so.setEmergencyPause(false);
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        so.setEmergencyPause(true);
        so.upgradeToAndCall(address(new SolvencyOracle()), "");
        assertTrue(so.emergencyPaused());
    }

    function test_UpgradeE2E_SolvencyOracle_PostUpgradeOperationsWork() public {
        SolvencyOracle so = _deploySO();
        so.upgradeToAndCall(address(new SolvencyOracle()), "");

        (uint8 s, uint8 m) = so.getCurrentQuadrant();
        assertEq(s, 1);
        assertEq(m, 1);
        so.setEmergencyPause(true);
        assertTrue(so.emergencyPaused());
    }

    // ─────────────────────────────────────────────────────────────
    // 13. CEXLiquidityReserve
    // ─────────────────────────────────────────────────────────────
    function test_UpgradeE2E_CEXLiquidityReserve_WithActiveState() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        uint256 deployedBefore = c.deploymentTimestamp();

        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");

        assertEq(c.deploymentTimestamp(), deployedBefore);
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_UpgradeE2E_CEXLiquidityReserve_SequentialUpgrades() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        uint256 deployedBefore = c.deploymentTimestamp();
        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");
        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");
        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");
        assertEq(c.deploymentTimestamp(), deployedBefore);
    }

    function test_UpgradeE2E_CEXLiquidityReserve_PostUpgradeOperationsWork() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        c.upgradeToAndCall(address(new CEXLiquidityReserve()), "");
        assertTrue(c.hasRole(c.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(c.hasRole(c.ALLOCATOR_ROLE(), address(this)));
        c.grantRole(c.ALLOCATOR_ROLE(), makeAddr("new"));
        assertTrue(c.hasRole(c.ALLOCATOR_ROLE(), makeAddr("new")));
    }

    // ─────────────────────────────────────────────────────────────
    // 14. MaintenanceReserve
    // ─────────────────────────────────────────────────────────────
    function test_UpgradeE2E_MaintenanceReserve_WithActiveState() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        m.setMonthlyCap(50_000e6);

        m.upgradeToAndCall(address(new MaintenanceReserve()), "");

        assertEq(m.monthlyCap(), 50_000e6);
        m.setMonthlyCap(75_000e6);
        assertEq(m.monthlyCap(), 75_000e6);
    }

    function test_UpgradeE2E_MaintenanceReserve_SequentialUpgrades() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        m.setMonthlyCap(10_000e6);
        m.upgradeToAndCall(address(new MaintenanceReserve()), "");
        m.setMonthlyCap(20_000e6);
        m.upgradeToAndCall(address(new MaintenanceReserve()), "");
        m.setMonthlyCap(30_000e6);
        m.upgradeToAndCall(address(new MaintenanceReserve()), "");
        assertEq(m.monthlyCap(), 30_000e6);
    }

    function test_UpgradeE2E_MaintenanceReserve_PostUpgradeOperationsWork() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        m.upgradeToAndCall(address(new MaintenanceReserve()), "");
        m.setMonthlyCap(1_000e6);
        assertEq(m.monthlyCap(), 1_000e6);
        m.grantRole(m.SPENDER_ROLE(), makeAddr("x"));
        assertTrue(m.hasRole(m.SPENDER_ROLE(), makeAddr("x")));
    }

    // ─────────────────────────────────────────────────────────────
    // 15. TreasuryVesting
    // ─────────────────────────────────────────────────────────────
    function test_UpgradeE2E_TreasuryVesting_WithActiveState() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        uint256 deployedBefore = tv.deployedAt();

        tv.upgradeToAndCall(address(new TreasuryVesting()), "");

        assertEq(tv.deployedAt(), deployedBefore);
        assertEq(address(tv.luminaToken()), makeAddr("l"));
    }

    function test_UpgradeE2E_TreasuryVesting_SequentialUpgrades() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        uint256 depBefore = tv.deployedAt();
        tv.upgradeToAndCall(address(new TreasuryVesting()), "");
        tv.upgradeToAndCall(address(new TreasuryVesting()), "");
        tv.upgradeToAndCall(address(new TreasuryVesting()), "");
        assertEq(tv.deployedAt(), depBefore);
    }

    function test_UpgradeE2E_TreasuryVesting_PostUpgradeOperationsWork() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        tv.upgradeToAndCall(address(new TreasuryVesting()), "");
        assertEq(tv.owner(), address(this));
        assertEq(address(tv.luminaToken()), makeAddr("l"));
    }
}
