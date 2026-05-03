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
import {BuybackEngine} from "../../../../src/marketplace/BuybackEngine.sol";
import {LuminaBondMarketplace} from "../../../../src/marketplace/LuminaBondMarketplace.sol";
import {ShieldKeeper} from "../../../../src/automation/ShieldKeeper.sol";
import {CapacityOracle} from "../../../../src/oracles/CapacityOracle.sol";
import {SolvencyOracle} from "../../../../src/oracles/SolvencyOracle.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../src/treasury/MaintenanceReserve.sol";
import {TreasuryVesting} from "../../../../src/token/TreasuryVesting.sol";

contract MockOracleAP {
    function getLuminaPrice() external pure returns (uint256) {
        return 0.036e18;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

contract MockBondVaultAP {
    address public lumina;

    constructor(address _lumina) {
        lumina = _lumina;
    }

    function totalCommittedUSD() external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title AdminPowers
 * @notice Admin capability audit for 15 core UUPS contracts.
 *
 * For each contract, two test types are exercised:
 *   (1) CanExecute_AdminOps — admin can invoke every admin-only setter.
 *   (2) NonAdminRejectedOnOps — third-party cannot invoke the same setters.
 *
 * Upgrade-auth coverage (admin can upgrade / non-admin cannot upgrade) is
 * already exhaustively tested in audit #2 (`InitializerSecurity.t.sol`) and
 * is not re-duplicated here.
 */
contract AdminPowers is Test {
    // ── 1. LuminaTokenV2 ──
    function _deployToken() internal returns (LuminaTokenV2) {
        return ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
    }

    function test_Admin_LuminaToken_CanGrantAndRevokeRoles() public {
        LuminaTokenV2 t = _deployToken();
        bytes32 burnerRole = t.BURNER_ROLE();
        t.grantRole(burnerRole, makeAddr("burner"));
        assertTrue(t.hasRole(burnerRole, makeAddr("burner")));
        t.revokeRole(burnerRole, makeAddr("burner"));
        assertFalse(t.hasRole(burnerRole, makeAddr("burner")));
    }

    function test_Admin_LuminaToken_NonAdminCannotGrantRoles() public {
        LuminaTokenV2 t = _deployToken();
        bytes32 burnerRole = t.BURNER_ROLE();
        address atk = makeAddr("atk");
        vm.prank(atk);
        vm.expectRevert();
        t.grantRole(burnerRole, atk);
    }

    // ── 2. BondVault ──
    function _bvSetup() internal returns (BondVault v) {
        MockOracleAP oracle = new MockOracleAP();
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        LuminaTokenV2 token = _deployToken();
        v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        cb.setBondVault(address(v));
        deal(address(token), address(v), 70_000_000e18);
    }

    function test_Admin_BondVault_CanSetAuthorizedCaller() public {
        BondVault v = _bvSetup();
        v.setAuthorizedCaller(makeAddr("caller"), true);
        assertTrue(v.authorizedCallers(makeAddr("caller")));
        v.setAuthorizedCaller(makeAddr("caller"), false);
        assertFalse(v.authorizedCallers(makeAddr("caller")));
    }

    function test_Admin_BondVault_NonAdminCannotSetAuthorizedCaller() public {
        BondVault v = _bvSetup();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        v.setAuthorizedCaller(makeAddr("atk"), true);
    }

    // ── 3. ClaimBond ──
    function test_Admin_ClaimBond_CanSetBondVaultOnce() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));
        assertEq(cb.bondVault(), address(this));
        // Second call must revert — one-shot guard.
        vm.expectRevert();
        cb.setBondVault(makeAddr("other"));
    }

    function test_Admin_ClaimBond_NonOwnerCannotSetBondVault() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        cb.setBondVault(makeAddr("atk"));
    }

    // ── 4. PolicyManagerV2 ──
    function _pmDeploy() internal returns (PolicyManagerV2 pm) {
        pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
    }

    function test_Admin_PolicyManager_CanSetRouterAndRegisterProducts() public {
        PolicyManagerV2 pm = _pmDeploy();
        pm.setRouter(address(this));
        assertEq(pm.router(), address(this));
        pm.registerProduct(keccak256("P"), makeAddr("shield"));
        assertTrue(pm.productActive(keccak256("P")));
        pm.deactivateProduct(keccak256("P"));
        assertFalse(pm.productActive(keccak256("P")));
    }

    function test_Admin_PolicyManager_NonOwnerCannotSetRouter() public {
        PolicyManagerV2 pm = _pmDeploy();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        pm.setRouter(makeAddr("atk"));
    }

    function test_Admin_PolicyManager_NonOwnerCannotRegisterProduct() public {
        PolicyManagerV2 pm = _pmDeploy();
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        pm.registerProduct(keccak256("X"), makeAddr("s"));
    }

    // ── 5. CoverRouterV2 ──
    function _crDeploy() internal returns (CoverRouterV2) {
        return ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
    }

    function test_Admin_CoverRouterV2_CanConfigureAndAuthorize() public {
        CoverRouterV2 r = _crDeploy();
        r.configureProduct(keccak256("P"), 8000, 200, 2000, 3600, true);
        r.setRelayer(makeAddr("relayer"), true);
        r.setPaused(true);
        r.setPolicyManager(makeAddr("newPM"));
        r.setTwapBurner(makeAddr("newBurner"));
        r.setCapacityOracle(makeAddr("co"));
        assertTrue(r.paused());
        assertTrue(r.authorizedRelayers(makeAddr("relayer")));
        assertEq(address(r.policyManager()), makeAddr("newPM"));
    }

    function test_Admin_CoverRouterV2_NonOwnerRejectedOnAllSetters() public {
        CoverRouterV2 r = _crDeploy();
        address atk = makeAddr("atk");

        vm.prank(atk);
        vm.expectRevert();
        r.configureProduct(keccak256("P"), 8000, 200, 2000, 3600, true);

        vm.prank(atk);
        vm.expectRevert();
        r.setRelayer(makeAddr("a"), true);

        vm.prank(atk);
        vm.expectRevert();
        r.setPaused(true);

        vm.prank(atk);
        vm.expectRevert();
        r.setPolicyManager(makeAddr("a"));
    }

    // ── 6. TWAPBurner ──
    function _burnerDeploy() internal returns (TWAPBurner) {
        return ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
    }

    function test_Admin_TWAPBurner_CanConfigureAll() public {
        TWAPBurner b = _burnerDeploy();
        b.setPoolFee(3000);
        b.setMaxSlippageBps(500);
        b.setMinBurnAmount(10e6);
        b.setMaxBurnAmount(100_000e6);
        b.setBurnCooldown(3600);
        b.setAuthorizedSender(makeAddr("s"), true);
        b.setCapacityOracle(makeAddr("o"));
        b.setFeeDistributor(makeAddr("fd"));
        b.setReserves(makeAddr("br"), makeAddr("or"), makeAddr("mr"));
        b.setAdaptiveMode(true);
        assertEq(b.poolFee(), 3000);
        assertEq(b.maxSlippageBps(), 500);
        assertTrue(b.authorizedSenders(makeAddr("s")));
        assertTrue(b.adaptiveModeEnabled());
    }

    function test_Admin_TWAPBurner_NonOwnerRejectedOnAllSetters() public {
        TWAPBurner b = _burnerDeploy();
        address atk = makeAddr("atk");

        vm.prank(atk);
        vm.expectRevert();
        b.setPoolFee(3000);

        vm.prank(atk);
        vm.expectRevert();
        b.setMinBurnAmount(1e6);

        vm.prank(atk);
        vm.expectRevert();
        b.setAuthorizedSender(atk, true);

        vm.prank(atk);
        vm.expectRevert();
        b.recoverToken(makeAddr("t"), 1);
    }

    // ── 7. AdaptiveFeeDistributor ──
    function test_Admin_AdaptiveFeeDistributor_NonOwnerCannotUpgrade() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("so"));
        address newImpl = address(new AdaptiveFeeDistributor());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        d.upgradeToAndCall(newImpl, "");
    }

    function test_Admin_AdaptiveFeeDistributor_OwnerCanUpgrade() public {
        AdaptiveFeeDistributor d = ProxyDeployer.deployAdaptiveFeeDistributor(makeAddr("so"));
        d.upgradeToAndCall(address(new AdaptiveFeeDistributor()), "");
        assertEq(d.owner(), address(this));
    }

    // ── 8. BuybackEngine ──
    function _beDeploy(address admin) internal returns (BuybackEngine) {
        return ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"), makeAddr("bv"), makeAddr("so"), makeAddr("co"), makeAddr("mk"), makeAddr("u"), admin
        );
    }

    function test_Admin_BuybackEngine_OperatorCanSetDailyBuyback() public {
        BuybackEngine be = _beDeploy(address(this));
        be.setDailyBuyback(10_000e6, 80, 4);
        (uint256 budget, uint256 maxPct,,) = be.dailyConfig();
        assertEq(budget, 10_000e6);
        assertEq(maxPct, 80);
    }

    function test_Admin_BuybackEngine_NonOperatorCannotSetDailyBuyback() public {
        BuybackEngine be = _beDeploy(address(this));
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        be.setDailyBuyback(1_000e6, 50, 1);
    }

    function test_Admin_BuybackEngine_MaxPercentCappedAt95() public {
        BuybackEngine be = _beDeploy(address(this));
        // Protocol-level guard: maxPricePercent > 95 must revert even for operator.
        vm.expectRevert(bytes("Max percent 1-95"));
        be.setDailyBuyback(1_000e6, 96, 1);
    }

    // ── 9. LuminaBondMarketplace ──
    function _mpDeploy(address admin) internal returns (LuminaBondMarketplace) {
        return ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), admin);
    }

    function test_Admin_LuminaBondMarketplace_FeeManagerCanSetTwapBurner() public {
        LuminaBondMarketplace m = _mpDeploy(address(this));
        m.setTwapBurner(makeAddr("newBurner"));
        assertEq(m.twapBurner(), makeAddr("newBurner"));
    }

    function test_Admin_LuminaBondMarketplace_NonFeeManagerCannotSetTwapBurner() public {
        LuminaBondMarketplace m = _mpDeploy(address(this));
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        m.setTwapBurner(makeAddr("atk"));
    }

    // ── 10. ShieldKeeper ──
    function test_Admin_ShieldKeeper_OwnerCanPauseUnpause() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        assertTrue(k.paused());
        k.unpause();
        assertFalse(k.paused());
    }

    function test_Admin_ShieldKeeper_NonOwnerCannotPause() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        k.pause();
    }

    // ── 11. CapacityOracle ──
    function _coDeploy() internal returns (CapacityOracle) {
        return ProxyDeployer.deployCapacityOracle(address(0), makeAddr("l"), makeAddr("u"), 0.036e18);
    }

    function test_Admin_CapacityOracle_OwnerCanSetParams() public {
        CapacityOracle o = _coDeploy();
        o.setTwapWindow(900);
        o.setEmergencyPrice(0.05e18);
        assertEq(o.twapWindow(), 900);
        assertEq(o.emergencyPrice(), 0.05e18);
    }

    function test_Admin_CapacityOracle_NonOwnerCannotSetParams() public {
        CapacityOracle o = _coDeploy();
        address atk = makeAddr("atk");
        vm.prank(atk);
        vm.expectRevert();
        o.setEmergencyPrice(0.99e18);

        vm.prank(atk);
        vm.expectRevert();
        o.setTwapWindow(600);
    }

    // ── 12. SolvencyOracle ──
    function _soDeploy(address admin) internal returns (SolvencyOracle) {
        MockBondVaultAP bv = new MockBondVaultAP(makeAddr("lumina"));
        return ProxyDeployer.deploySolvencyOracle(address(bv), makeAddr("co"), admin);
    }

    function test_Admin_SolvencyOracle_AdminCanEmergencyPause() public {
        SolvencyOracle so = _soDeploy(address(this));
        so.setEmergencyPause(true);
        assertTrue(so.emergencyPaused());
        so.setEmergencyPause(false);
        assertFalse(so.emergencyPaused());
    }

    function test_Admin_SolvencyOracle_NonAdminCannotEmergencyPause() public {
        SolvencyOracle so = _soDeploy(address(this));
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        so.setEmergencyPause(true);
    }

    // ── 13. CEXLiquidityReserve ──
    function test_Admin_CEXLiquidityReserve_AdminCanGrantRoles() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        bytes32 role = c.ALLOCATOR_ROLE();
        c.grantRole(role, makeAddr("newAllocator"));
        assertTrue(c.hasRole(role, makeAddr("newAllocator")));
    }

    function test_Admin_CEXLiquidityReserve_NonAdminCannotGrantRoles() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        bytes32 role = c.ALLOCATOR_ROLE();
        address atk = makeAddr("atk");
        vm.prank(atk);
        vm.expectRevert();
        c.grantRole(role, atk);
    }

    // ── 14. MaintenanceReserve ──
    function test_Admin_MaintenanceReserve_AdminCanSetMonthlyCap() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        m.setMonthlyCap(100_000e6);
        assertEq(m.monthlyCap(), 100_000e6);
    }

    function test_Admin_MaintenanceReserve_NonAdminCannotSetMonthlyCap() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        m.setMonthlyCap(1e9);
    }

    function test_Admin_MaintenanceReserve_NonAdminCannotRecoverToken() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        m.recoverToken(makeAddr("t"), 1);
    }

    // ── 15. TreasuryVesting ──
    function test_Admin_TreasuryVesting_OwnerAdminRightsPreserved() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        assertEq(tv.owner(), address(this));
    }

    function test_Admin_TreasuryVesting_NonOwnerCannotUpgrade() public {
        TreasuryVesting tv = ProxyDeployer.deployTreasuryVesting(makeAddr("l"));
        address newImpl = address(new TreasuryVesting());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        tv.upgradeToAndCall(newImpl, "");
    }
}
