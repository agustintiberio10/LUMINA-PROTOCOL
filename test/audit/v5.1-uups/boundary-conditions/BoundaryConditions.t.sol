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
import {CapacityOracle} from "../../../../src/oracles/CapacityOracle.sol";
import {BuybackEngine} from "../../../../src/marketplace/BuybackEngine.sol";
import {LuminaBondMarketplace} from "../../../../src/marketplace/LuminaBondMarketplace.sol";
import {MaintenanceReserve} from "../../../../src/treasury/MaintenanceReserve.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";

import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../../src/products/FlashETHShield48h.sol";
import {MicroDepegShield} from "../../../../src/products/MicroDepegShield.sol";
import {RateShockShield} from "../../../../src/products/RateShockShield.sol";

contract MockOracleBoundary {
    uint256 public price;

    constructor(uint256 _p) {
        price = _p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }


    function setPrice(uint256 _p) external {
        price = _p;
    }
}

contract MockBondVaultBoundary {
    address public lumina;
    uint256 public committed;

    constructor(address _l, uint256 _c) {
        lumina = _l;
        committed = _c;
    }

    function totalCommittedUSD() external view returns (uint256) {
        return committed;
    }

    function setCommitted(uint256 v) external {
        committed = v;
    }
}

contract MockCapacityOracleBoundary {
    uint256 public priceVal;

    constructor(uint256 _p) {
        priceVal = _p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return priceVal;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }


    function setPrice(uint256 _p) external {
        priceVal = _p;
    }
}

/**
 * @title BoundaryConditions
 * @notice Tests every business threshold at its exact boundary, 1 wei below,
 *         and 1 wei above (where applicable). Targets V5.1 UUPS.
 */
contract BoundaryConditions is Test {
    // ─────────────────────────────────────────────────────────────
    // Shared helpers
    // ─────────────────────────────────────────────────────────────
    function _token() internal returns (LuminaTokenV2) {
        return ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
    }

    function _bvFull() internal returns (BondVault v, LuminaTokenV2 token, ClaimBond cb, MockOracleBoundary oracle) {
        oracle = new MockOracleBoundary(1e18); // $1/LUMINA for clean math
        cb = ProxyDeployer.deployClaimBond();
        token = _token();
        v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        cb.setBondVault(address(v));
        deal(address(token), address(v), 70_000_000e18);
        vm.warp(1767225600 + 30 days);
    }

    // ─────────────────────────────────────────────────────────────
    // Token distribution sums to 100M
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_TokenDistribution_SumsTo100M() public {
        assertEq(uint256(70_000_000 + 14_000_000 + 8_000_000 + 5_000_000 + 3_000_000), uint256(100_000_000));
        LuminaTokenV2 t = _token();
        assertEq(t.totalSupply(), 100_000_000e18);
    }

    // ─────────────────────────────────────────────────────────────
    // BondVault burn cap 5% exact / +1 wei reverts / -1 wei succeeds
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_BurnCap_ExactlyFivePercent_Succeeds() public {
        (BondVault v, LuminaTokenV2 token,,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));
        v.setAuthorizedCaller(address(this), true);
        uint256 bal = token.balanceOf(address(v));
        uint256 exactly5 = (bal * 5) / 100;
        v.burnFromReserves(exactly5);
        assertEq(token.balanceOf(address(v)), bal - exactly5);
    }

    function test_Boundary_BurnCap_OneWeiBelowFivePercent_Succeeds() public {
        (BondVault v, LuminaTokenV2 token,,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));
        v.setAuthorizedCaller(address(this), true);
        uint256 bal = token.balanceOf(address(v));
        uint256 below = (bal * 5) / 100 - 1;
        v.burnFromReserves(below);
    }

    function test_Boundary_BurnCap_OneWeiAboveFivePercent_Reverts() public {
        (BondVault v, LuminaTokenV2 token,,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));
        v.setAuthorizedCaller(address(this), true);
        uint256 bal = token.balanceOf(address(v));
        uint256 over = (bal * 5) / 100 + 1;
        vm.expectRevert(bytes("Exceeds 5% per-tx cap"));
        v.burnFromReserves(over);
    }

    // ─────────────────────────────────────────────────────────────
    // SAFETY_FACTOR_BPS — max commitment = 50% of reserve value
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_SafetyFactor_Commit_AtExactly50Percent_ReturnsZeroAvailable() public {
        (BondVault v,,, MockOracleBoundary oracle) = _bvFull();
        oracle.setPrice(1e18); // $1/LUMINA → 70M LUMINA = 70M USD
        v.issueBond(makeAddr("u"), 35_000_000, 0.036e18); // exactly 50% = $35M
        assertEq(v.availableCapacityUSD(), 0);
    }

    function test_Boundary_SafetyFactor_Commit_OneUSDBelow50Percent_OneAvailable() public {
        (BondVault v,,, MockOracleBoundary oracle) = _bvFull();
        oracle.setPrice(1e18);
        v.issueBond(makeAddr("u"), 34_999_999, 0.036e18); // $1 under max
        assertEq(v.availableCapacityUSD(), 1);
    }

    // ─────────────────────────────────────────────────────────────
    // Solvency ratio: classifier thresholds via getSolvencyRatio()
    // (Classifier is internal; we verify the ratio lands at the
    //  expected boundary numerical value.)
    // ─────────────────────────────────────────────────────────────
    function _solvencySetup(uint256 committedUSD, uint256 luminaBalance, uint256 price)
        internal
        returns (SolvencyOracle so)
    {
        LuminaTokenV2 token = _token();
        MockBondVaultBoundary bv = new MockBondVaultBoundary(address(token), committedUSD);
        MockCapacityOracleBoundary co = new MockCapacityOracleBoundary(price);
        // Move tokens to the mock vault address so balanceOf(bv) matches.
        deal(address(token), address(bv), luminaBalance);
        so = ProxyDeployer.deploySolvencyOracle(address(bv), address(co), address(this));
    }

    function test_Boundary_Solvency_ExactlyUltra_20000Bps() public {
        // valueUSD / obligations = 2.0 → 20000 bps.
        // value = 100e18, obligations = 50e18 → ratio 200%.
        SolvencyOracle so = _solvencySetup(50e18, 100e18, 1e18);
        assertEq(so.getSolvencyRatio(), 20000);
    }

    function test_Boundary_Solvency_ExactlyHealthy_10000Bps() public {
        SolvencyOracle so = _solvencySetup(100e18, 100e18, 1e18);
        assertEq(so.getSolvencyRatio(), 10000);
    }

    function test_Boundary_Solvency_ExactlyStressed_7000Bps() public {
        SolvencyOracle so = _solvencySetup(100e18, 70e18, 1e18);
        assertEq(so.getSolvencyRatio(), 7000);
    }

    function test_Boundary_Solvency_Crisis_6999Bps_Below7000() public {
        // Pick balance to land at 6999 bps: (bal × 1e18 / 1e18 × 10000) / obligations = 6999
        // obligations = 10_000, balance = 6_999 (both in wei).
        SolvencyOracle so = _solvencySetup(10_000, 6_999, 1e18);
        assertEq(so.getSolvencyRatio(), 6999);
    }

    function test_Boundary_Solvency_Ultra_20001Bps_Above20000() public {
        // balance = 20_001 wei, obligations = 10_000 wei → 20001 bps.
        SolvencyOracle so = _solvencySetup(10_000, 20_001, 1e18);
        assertEq(so.getSolvencyRatio(), 20001);
    }

    // ─────────────────────────────────────────────────────────────
    // Buyback price cap: exact 95% allowed, 96% rejected
    // ─────────────────────────────────────────────────────────────
    function _buybackDeploy() internal returns (BuybackEngine be) {
        be = ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"), makeAddr("bv"), makeAddr("so"), makeAddr("co"), makeAddr("mk"), makeAddr("u"), address(this)
        );
    }

    function test_Boundary_Buyback_MaxPrice_Exactly95_Allows() public {
        BuybackEngine be = _buybackDeploy();
        be.setDailyBuyback(10_000e6, 95, 4);
        (, uint256 maxPct,,) = be.dailyConfig();
        assertEq(maxPct, 95);
    }

    function test_Boundary_Buyback_MaxPrice_94_Allows() public {
        BuybackEngine be = _buybackDeploy();
        be.setDailyBuyback(10_000e6, 94, 4);
        (, uint256 maxPct,,) = be.dailyConfig();
        assertEq(maxPct, 94);
    }

    function test_Boundary_Buyback_MaxPrice_96_Reverts() public {
        BuybackEngine be = _buybackDeploy();
        vm.expectRevert(bytes("Max percent 1-95"));
        be.setDailyBuyback(10_000e6, 96, 4);
    }

    function test_Boundary_Buyback_MaxPrice_Zero_Reverts() public {
        BuybackEngine be = _buybackDeploy();
        vm.expectRevert(bytes("Max percent 1-95"));
        be.setDailyBuyback(10_000e6, 0, 4);
    }

    function test_Boundary_Buyback_Duration_Exactly72h_Allows() public {
        BuybackEngine be = _buybackDeploy();
        be.setDailyBuyback(10_000e6, 80, 72);
    }

    function test_Boundary_Buyback_Duration_73h_Reverts() public {
        BuybackEngine be = _buybackDeploy();
        vm.expectRevert(bytes("Duration 1-72 hours"));
        be.setDailyBuyback(10_000e6, 80, 73);
    }

    function test_Boundary_Buyback_Duration_0h_Reverts() public {
        BuybackEngine be = _buybackDeploy();
        vm.expectRevert(bytes("Duration 1-72 hours"));
        be.setDailyBuyback(10_000e6, 80, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // TWAPBurner parameter boundaries (ranges from the setters)
    // ─────────────────────────────────────────────────────────────
    function _burnerDeploy() internal returns (TWAPBurner b) {
        b = ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
    }

    function test_Boundary_TWAP_Slippage_Exactly50Bps_Allows() public {
        TWAPBurner b = _burnerDeploy();
        b.setMaxSlippageBps(50);
        assertEq(b.maxSlippageBps(), 50);
    }

    function test_Boundary_TWAP_Slippage_49Bps_Reverts() public {
        TWAPBurner b = _burnerDeploy();
        vm.expectRevert(bytes("Slippage: 0.5%-10%"));
        b.setMaxSlippageBps(49);
    }

    function test_Boundary_TWAP_Slippage_Exactly1000Bps_Allows() public {
        TWAPBurner b = _burnerDeploy();
        b.setMaxSlippageBps(1000);
        assertEq(b.maxSlippageBps(), 1000);
    }

    function test_Boundary_TWAP_Slippage_1001Bps_Reverts() public {
        TWAPBurner b = _burnerDeploy();
        vm.expectRevert(bytes("Slippage: 0.5%-10%"));
        b.setMaxSlippageBps(1001);
    }

    function test_Boundary_TWAP_Cooldown_Exactly60s_Allows() public {
        TWAPBurner b = _burnerDeploy();
        b.setBurnCooldown(60);
    }

    function test_Boundary_TWAP_Cooldown_59s_Reverts() public {
        TWAPBurner b = _burnerDeploy();
        vm.expectRevert(bytes("Cooldown: 1min-24hr"));
        b.setBurnCooldown(59);
    }

    function test_Boundary_TWAP_Cooldown_Exactly86400s_Allows() public {
        TWAPBurner b = _burnerDeploy();
        b.setBurnCooldown(86400);
    }

    function test_Boundary_TWAP_Cooldown_86401s_Reverts() public {
        TWAPBurner b = _burnerDeploy();
        vm.expectRevert(bytes("Cooldown: 1min-24hr"));
        b.setBurnCooldown(86401);
    }

    function test_Boundary_TWAP_MinBurn_Exactly_0_1e6_Allows() public {
        TWAPBurner b = _burnerDeploy();
        b.setMinBurnAmount(1e5); // 0.1 USDC
    }

    function test_Boundary_TWAP_MinBurn_Below_0_1e6_Reverts() public {
        TWAPBurner b = _burnerDeploy();
        vm.expectRevert(bytes("Min too low"));
        b.setMinBurnAmount(1e5 - 1);
    }

    function test_Boundary_TWAP_PoolFee_ValidValues() public {
        TWAPBurner b = _burnerDeploy();
        b.setPoolFee(500);
        b.setPoolFee(3000);
        b.setPoolFee(10000);
        assertEq(b.poolFee(), 10000);
    }

    function test_Boundary_TWAP_PoolFee_InvalidValue_Reverts() public {
        TWAPBurner b = _burnerDeploy();
        vm.expectRevert(bytes("Invalid fee tier"));
        b.setPoolFee(400);
    }

    // ─────────────────────────────────────────────────────────────
    // CapacityOracle TWAP window: 5min..2h
    // ─────────────────────────────────────────────────────────────
    function _coDeploy() internal returns (CapacityOracle o) {
        o = ProxyDeployer.deployCapacityOracle(address(0), makeAddr("l"), makeAddr("u"), 0.036e18);
    }

    function test_Boundary_CapacityOracle_Window_Exactly300s_Allows() public {
        CapacityOracle o = _coDeploy();
        o.setTwapWindow(300);
    }

    function test_Boundary_CapacityOracle_Window_299s_Reverts() public {
        CapacityOracle o = _coDeploy();
        vm.expectRevert(bytes("Window: 5min-2hr"));
        o.setTwapWindow(299);
    }

    function test_Boundary_CapacityOracle_Window_Exactly7200s_Allows() public {
        CapacityOracle o = _coDeploy();
        o.setTwapWindow(7200);
    }

    function test_Boundary_CapacityOracle_Window_7201s_Reverts() public {
        CapacityOracle o = _coDeploy();
        vm.expectRevert(bytes("Window: 5min-2hr"));
        o.setTwapWindow(7201);
    }

    function test_Boundary_CapacityOracle_EmergencyPrice_Zero_Reverts() public {
        CapacityOracle o = _coDeploy();
        vm.expectRevert();
        o.setEmergencyPrice(0);
    }

    function test_Boundary_CapacityOracle_EmergencyPrice_One_Allows() public {
        CapacityOracle o = _coDeploy();
        o.setEmergencyPrice(1);
        assertEq(o.emergencyPrice(), 1);
    }

    // ─────────────────────────────────────────────────────────────
    // Distribution: 16 quadrants + maintenance floor
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Distribution_AllQuadrants_SumExactly10000() public {
        MockBondVaultBoundary bv = new MockBondVaultBoundary(address(_token()), 0);
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(address(so));
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (uint256 bb, uint256 bybk, uint256 ops, uint256 mt) = d.lookupDistribution(s, m);
                assertEq(bb + bybk + ops + mt, 10000);
            }
        }
    }

    function test_Boundary_Distribution_MaintenanceFloor_At200() public {
        MockBondVaultBoundary bv = new MockBondVaultBoundary(address(_token()), 0);
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(address(so));
        for (uint8 s = 0; s < 4; s++) {
            for (uint8 m = 0; m < 4; m++) {
                (,,, uint256 mt) = d.lookupDistribution(s, m);
                assertGe(mt, 200, "Maintenance must be >= 200 bps");
            }
        }
    }

    // ─────────────────────────────────────────────────────────────
    // Distribution classifier rejects out-of-range levels
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Distribution_Level4_Reverts() public {
        MockBondVaultBoundary bv = new MockBondVaultBoundary(address(_token()), 0);
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(address(so));
        vm.expectRevert(bytes("Invalid solvency level"));
        d.lookupDistribution(4, 0);
    }

    function test_Boundary_Distribution_MomentumLevel4_Reverts() public {
        MockBondVaultBoundary bv = new MockBondVaultBoundary(address(_token()), 0);
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(address(so));
        vm.expectRevert(bytes("Invalid momentum level"));
        d.lookupDistribution(0, 4);
    }

    // ─────────────────────────────────────────────────────────────
    // Marketplace fees: 1.5% exact
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_MarketplaceFees_BuyerFee_ExactCalc() public {
        LuminaBondMarketplace mp =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        uint256 price = 100e6; // $100
        uint256 expected = (price * mp.BUYER_FEE_BPS()) / mp.BPS_DENOMINATOR(); // = 1.5e6 ($1.50)
        assertEq(expected, 15e5);
        assertEq(mp.BUYER_FEE_BPS(), 150);
        assertEq(mp.SELLER_FEE_BPS(), 150);
        assertEq(mp.BPS_DENOMINATOR(), 10000);
    }

    // ─────────────────────────────────────────────────────────────
    // Shield trigger drop BPS constants — exact values per product
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Shield_TriggerDropBps_FlashBTC_1h_500() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), makeAddr("o"));
        assertEq(s.TRIGGER_DROP_BPS(), 500); // 5%
    }

    function test_Boundary_Shield_TriggerDropBps_FlashBTC_4h_800() public {
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), makeAddr("o"));
        assertEq(s.TRIGGER_DROP_BPS(), 800); // 8%
    }

    function test_Boundary_Shield_TriggerDropBps_FlashBTC_24h_1000() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), makeAddr("o"));
        assertEq(s.TRIGGER_DROP_BPS(), 1000); // 10%
    }

    function test_Boundary_Shield_TriggerDropBps_FlashBTC_48h_1500() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), makeAddr("o"));
        assertEq(s.TRIGGER_DROP_BPS(), 1500); // 15%
    }

    function test_Boundary_Shield_TriggerDropBps_FlashETH_1h_700() public {
        FlashETHShield1h s = ProxyDeployer.deployFlashETHShield1h(address(this), makeAddr("o"));
        assertEq(s.TRIGGER_DROP_BPS(), 700); // 7%
    }

    function test_Boundary_Shield_TriggerDropBps_FlashETH_24h_1200() public {
        FlashETHShield24h s = ProxyDeployer.deployFlashETHShield24h(address(this), makeAddr("o"));
        assertEq(s.TRIGGER_DROP_BPS(), 1200); // 12%
    }

    function test_Boundary_Shield_TriggerDropBps_FlashETH_48h_1800() public {
        FlashETHShield48h s = ProxyDeployer.deployFlashETHShield48h(address(this), makeAddr("o"));
        assertEq(s.TRIGGER_DROP_BPS(), 1800); // 18%
    }

    function test_Boundary_Shield_MicroDepeg_TriggerPrice_99_500_000() public {
        MicroDepegShield s = ProxyDeployer.deployMicroDepegShield(address(this), makeAddr("o"));
        assertEq(s.TRIGGER_PRICE(), 99_500_000); // $0.995 in 8-dec
    }

    function test_Boundary_Shield_RateShock_TriggerRate_10e25_RAY() public {
        RateShockShield s =
            ProxyDeployer.deployRateShockShield(address(this), makeAddr("o"), makeAddr("a"), makeAddr("u"));
        assertEq(s.TRIGGER_RATE(), 10e25); // 10% APY in RAY (27-dec)
    }

    function test_Boundary_Shield_DeductibleBps_All9_Equal2000() public {
        FlashBTCShield1h s1 = ProxyDeployer.deployFlashBTCShield1h(address(this), makeAddr("o"));
        FlashBTCShield4h s2 = ProxyDeployer.deployFlashBTCShield4h(address(this), makeAddr("o"));
        FlashBTCShield24h s3 = ProxyDeployer.deployFlashBTCShield24h(address(this), makeAddr("o"));
        FlashBTCShield48h s4 = ProxyDeployer.deployFlashBTCShield48h(address(this), makeAddr("o"));
        FlashETHShield1h s5 = ProxyDeployer.deployFlashETHShield1h(address(this), makeAddr("o"));
        FlashETHShield24h s6 = ProxyDeployer.deployFlashETHShield24h(address(this), makeAddr("o"));
        FlashETHShield48h s7 = ProxyDeployer.deployFlashETHShield48h(address(this), makeAddr("o"));
        assertEq(s1.DEDUCTIBLE_BPS(), 2000);
        assertEq(s2.DEDUCTIBLE_BPS(), 2000);
        assertEq(s3.DEDUCTIBLE_BPS(), 2000);
        assertEq(s4.DEDUCTIBLE_BPS(), 2000);
        assertEq(s5.DEDUCTIBLE_BPS(), 2000);
        assertEq(s6.DEDUCTIBLE_BPS(), 2000);
        assertEq(s7.DEDUCTIBLE_BPS(), 2000);
    }

    // ─────────────────────────────────────────────────────────────
    // Shield durations: exact seconds per product
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Shield_Duration_FlashBTC_1h_3600() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), makeAddr("o"));
        (uint32 minD, uint32 maxD) = s.durationRange();
        assertEq(minD, 3600);
        assertEq(maxD, 3600);
    }

    function test_Boundary_Shield_Duration_FlashBTC_4h_14400() public {
        FlashBTCShield4h s = ProxyDeployer.deployFlashBTCShield4h(address(this), makeAddr("o"));
        (uint32 minD, uint32 maxD) = s.durationRange();
        assertEq(minD, 14400);
        assertEq(maxD, 14400);
    }

    function test_Boundary_Shield_Duration_FlashBTC_24h_86400() public {
        FlashBTCShield24h s = ProxyDeployer.deployFlashBTCShield24h(address(this), makeAddr("o"));
        (uint32 minD, uint32 maxD) = s.durationRange();
        assertEq(minD, 86400);
        assertEq(maxD, 86400);
    }

    function test_Boundary_Shield_Duration_FlashBTC_48h_172800() public {
        FlashBTCShield48h s = ProxyDeployer.deployFlashBTCShield48h(address(this), makeAddr("o"));
        (uint32 minD, uint32 maxD) = s.durationRange();
        assertEq(minD, 172800);
        assertEq(maxD, 172800);
    }

    function test_Boundary_Shield_Duration_MicroDepeg_604800() public {
        MicroDepegShield s = ProxyDeployer.deployMicroDepegShield(address(this), makeAddr("o"));
        (uint32 minD, uint32 maxD) = s.durationRange();
        assertEq(minD, 604800);
        assertEq(maxD, 604800);
    }

    function test_Boundary_Shield_Duration_RateShock_604800() public {
        RateShockShield s =
            ProxyDeployer.deployRateShockShield(address(this), makeAddr("o"), makeAddr("a"), makeAddr("u"));
        (uint32 minD, uint32 maxD) = s.durationRange();
        assertEq(minD, 604800);
        assertEq(maxD, 604800);
    }

    // ─────────────────────────────────────────────────────────────
    // Shield max allocation BPS & max proof age
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Shield_MaxAllocationBps_FlashBTC_3000() public {
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), makeAddr("o"));
        assertEq(s.maxAllocationBps(), 3000);
    }

    // ─────────────────────────────────────────────────────────────
    // Epoch ID domain boundaries
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Epoch_ExactlyAtBase_January2026() public {
        (BondVault v,,,) = _bvFull();
        vm.warp(1767225600); // Exactly Jan 1 2026
        v.issueBond(makeAddr("u"), 100, 0.036e18); // Should succeed at base.
    }

    function test_Boundary_Epoch_MaturityBeforeBase_Reverts() public {
        // issueBond computes maturity = block.timestamp + 730 days. If block.timestamp
        // is in year 1970 (genesis), maturity is in year 1972, still before BASE_TS
        // (Jan 1 2026). _timestampToEpoch enforces `ts >= BASE_TS`, so the call reverts.
        (BondVault v,,,) = _bvFull();
        vm.warp(1);
        vm.expectRevert(bytes("Before base"));
        v.issueBond(makeAddr("u"), 100, 0.036e18);
    }

    function test_Boundary_Epoch_AtOrAfterBase_Works() public {
        // block.timestamp just 1 second before BASE_TS still produces maturity
        // well after BASE_TS (base + 730 days − 1s), so no revert.
        (BondVault v,,,) = _bvFull();
        vm.warp(1767225600 - 1);
        v.issueBond(makeAddr("u"), 100, 0.036e18);
        assertEq(v.totalCommittedUSD(), 100e18);
    }

    // ─────────────────────────────────────────────────────────────
    // Coverage limits on buyPolicy (via CoverRouterV2) — min $100
    // buyPolicy itself requires actual USDC transfer + PM integration;
    // we verify the constant boundary via quote function.
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Coverage_Quote_At100USD_NoRevert() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        bytes32 pid = keccak256("P");
        r.configureProduct(pid, 8000, 200, 2000, 3600, true);
        (uint256 premium,) = r.quotePremium(pid, 100e6);
        assertGt(premium, 0);
    }

    function test_Boundary_Coverage_Quote_At99USD_StillWorks() public {
        // quotePremium does not enforce the $100 floor; that happens in
        // buyPolicy / buyPolicyFor. This test documents that distinction.
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        bytes32 pid = keccak256("P");
        r.configureProduct(pid, 8000, 200, 2000, 3600, true);
        (uint256 premium,) = r.quotePremium(pid, 99e6);
        assertGt(premium, 0);
    }

    // ─────────────────────────────────────────────────────────────
    // Safety factor constant (BondVault) — value assertion
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_BondVault_SafetyFactor_Is5000Bps() public {
        (BondVault v,,,) = _bvFull();
        assertEq(v.SAFETY_FACTOR_BPS(), 5000);
    }

    function test_Boundary_BondVault_MinRedeemPrice_Is5e15() public {
        // [Fix C-3] MIN_REDEEM_PRICE raised from 1e15 to 5e15 to align with
        // CoverRouterV2.MIN_PRICE_FOR_NEW_POLICIES.
        (BondVault v,,,) = _bvFull();
        assertEq(v.MIN_REDEEM_PRICE(), 5e15);
    }

    function test_Boundary_BondVault_MaturityPeriod_730Days() public {
        (BondVault v,,,) = _bvFull();
        assertEq(v.BOND_MATURITY_SECONDS(), 730 days);
    }

    // ─────────────────────────────────────────────────────────────
    // Solvency evaluation interval boundaries
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Solvency_EvaluationInterval_1Day() public {
        MockBondVaultBoundary bv = new MockBondVaultBoundary(address(_token()), 0);
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
        assertEq(so.EVALUATION_INTERVAL(), 1 days);
    }

    function test_Boundary_Solvency_QuadrantChangeCooldown_7Days() public {
        MockBondVaultBoundary bv = new MockBondVaultBoundary(address(_token()), 0);
        SolvencyOracle so = ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), address(this));
        assertEq(so.COOLDOWN_BETWEEN_QUADRANT_CHANGES(), 7 days);
    }

    // ─────────────────────────────────────────────────────────────
    // CoverRouterV2 circuit breaker price constants
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_Router_MinPriceForNewPolicies_5e15() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        assertEq(r.MIN_PRICE_FOR_NEW_POLICIES(), 5e15); // $0.005
    }

    function test_Boundary_Router_ResetPriceForNewPolicies_8e15() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        assertEq(r.RESET_PRICE_FOR_NEW_POLICIES(), 8e15); // $0.008
    }

    // ─────────────────────────────────────────────────────────────
    // MaintenanceReserve monthly cap — admin-driven boundary
    // ─────────────────────────────────────────────────────────────
    function test_Boundary_MaintenanceReserve_SetCap_AnyValue() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        m.setMonthlyCap(0); // zero is allowed — governance decision
        m.setMonthlyCap(type(uint256).max); // no upper bound enforced
        assertEq(m.monthlyCap(), type(uint256).max);
    }
}
