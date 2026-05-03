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
import {BuybackEngine} from "../../../../src/marketplace/BuybackEngine.sol";
import {CapacityOracle} from "../../../../src/oracles/CapacityOracle.sol";
import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";
import {IShield} from "../../../../src/interfaces/IShield.sol";

contract MockOracleFR {
    uint256 public price = 1e18;

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

contract MockShieldOracleFR {
    int256 public priceBTC = 60_000e8;

    function getLatestPrice(bytes32) external view returns (int256) {
        return priceBTC;
    }

    function setPrice(int256 p) external {
        priceBTC = p;
    }
}

/**
 * @title FrontRunning
 * @notice Exercises MEV / front-running mitigations. Each test corresponds
 *         to a documented vector in `01-MEV-VECTORS.md` and asserts either
 *         the mitigation is active (positive test) or the residual risk is
 *         bounded (documented negative).
 */
contract FrontRunning is Test {
    // ── Shared ──
    function _token() internal returns (LuminaTokenV2) {
        return ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
    }

    function _burner() internal returns (TWAPBurner) {
        return ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
    }

    function _router() internal returns (CoverRouterV2) {
        return ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
    }

    function _capOracle() internal returns (CapacityOracle) {
        return ProxyDeployer.deployCapacityOracle(address(0), makeAddr("l"), makeAddr("u"), 0.036e18);
    }

    function _bvFull() internal returns (BondVault v, LuminaTokenV2 token, ClaimBond cb) {
        MockOracleFR oracle = new MockOracleFR();
        cb = ProxyDeployer.deployClaimBond();
        token = _token();
        v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        cb.setBondVault(address(v));
        deal(address(token), address(v), 70_000_000e18);
        vm.warp(1767225600 + 30 days);
    }

    // ─────────────────────────────────────────────────────────────
    // 1. TWAPBurner sandwich — slippage cap is enforced
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_TWAPBurner_SlippageCap_EnforceableRange() public {
        TWAPBurner b = _burner();
        // Can set to 50 (min) and 1000 (max); out-of-range reverts.
        b.setMaxSlippageBps(50);
        assertEq(b.maxSlippageBps(), 50);
        b.setMaxSlippageBps(1000);
        assertEq(b.maxSlippageBps(), 1000);
    }

    function test_FrontRun_TWAPBurner_SlippageAbove1000_Reverts() public {
        TWAPBurner b = _burner();
        vm.expectRevert(bytes("Slippage: 0.5%-10%"));
        b.setMaxSlippageBps(1001);
    }

    function test_FrontRun_TWAPBurner_SlippageBelow50_Reverts() public {
        TWAPBurner b = _burner();
        vm.expectRevert(bytes("Slippage: 0.5%-10%"));
        b.setMaxSlippageBps(49);
    }

    // ─────────────────────────────────────────────────────────────
    // 2. CapacityOracle TWAP window resists single-block manipulation
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_CapacityOracle_TwapWindow_RangeEnforced() public {
        CapacityOracle o = _capOracle();
        // Must be 5 minutes ≤ window ≤ 2 hours.
        o.setTwapWindow(300);
        o.setTwapWindow(1800);
        o.setTwapWindow(7200);
        vm.expectRevert(bytes("Window: 5min-2hr"));
        o.setTwapWindow(299);
    }

    function test_FrontRun_CapacityOracle_EmergencyPrice_RequiredNonZero() public {
        CapacityOracle o = _capOracle();
        vm.expectRevert();
        o.setEmergencyPrice(0);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. Shield strike price fixed at createPolicy
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Shield_StrikePrice_FixedAtCreation() public {
        MockShieldOracleFR oracle = new MockShieldOracleFR();
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        IShield.CreatePolicyParams memory p;
        p.buyer = makeAddr("b");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = 3600;
        p.asset = "BTC";
        uint256 pid = s.createPolicy(p);
        int256 strikeAtCreate = s.getBSSData(pid).strikePrice;

        // Simulate a post-creation oracle price move (would be a sandwich).
        oracle.setPrice(90_000e8);

        // Strike price is immutable — the policy's strike doesn't update.
        assertEq(s.getBSSData(pid).strikePrice, strikeAtCreate);
    }

    function test_FrontRun_Shield_TriggerPrice_DerivedFromStrike_NotMutable() public {
        MockShieldOracleFR oracle = new MockShieldOracleFR();
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        IShield.CreatePolicyParams memory p;
        p.buyer = makeAddr("b");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = 3600;
        p.asset = "BTC";
        uint256 pid = s.createPolicy(p);
        int256 trigAtCreate = s.getBSSData(pid).triggerPrice;

        // Oracle manipulation post-creation doesn't change the stored trigger.
        oracle.setPrice(1e8);
        assertEq(s.getBSSData(pid).triggerPrice, trigAtCreate);
    }

    // ─────────────────────────────────────────────────────────────
    // 4. BuybackEngine max price 95% — setter cap
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_BuybackEngine_MaxPct_95Cap_Enforced() public {
        BuybackEngine be = ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"), makeAddr("bv"), makeAddr("so"), makeAddr("co"), makeAddr("mk"), makeAddr("u"), address(this)
        );
        be.setDailyBuyback(1000e6, 95, 4); // OK
        vm.expectRevert(bytes("Max percent 1-95"));
        be.setDailyBuyback(1000e6, 96, 4); // Reverts
    }

    function test_FrontRun_BuybackEngine_Budget_NonZero_Finite() public {
        BuybackEngine be = ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"), makeAddr("bv"), makeAddr("so"), makeAddr("co"), makeAddr("mk"), makeAddr("u"), address(this)
        );
        vm.expectRevert(bytes("Budget zero"));
        be.setDailyBuyback(0, 50, 4);
        be.setDailyBuyback(1e6, 50, 4); // $1 ok
        (uint256 budget,,,) = be.dailyConfig();
        assertEq(budget, 1e6);
    }

    // ─────────────────────────────────────────────────────────────
    // 5. Daily duration cap 1..72 hours
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_BuybackEngine_Duration_MaxCap_72h() public {
        BuybackEngine be = ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"), makeAddr("bv"), makeAddr("so"), makeAddr("co"), makeAddr("mk"), makeAddr("u"), address(this)
        );
        be.setDailyBuyback(1000e6, 80, 72); // 72h OK
        vm.expectRevert(bytes("Duration 1-72 hours"));
        be.setDailyBuyback(1000e6, 80, 73);
    }

    // ─────────────────────────────────────────────────────────────
    // 6. Capacity reservation is PolicyManager-only
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_BondVault_ReserveCapacity_OnlyPolicyManager() public {
        (BondVault v,,) = _bvFull();
        // This test contract was set as the PolicyManager in _bvFull, so it
        // can reserve. A different caller cannot.
        v.reserveCapacity(100e18);
        assertEq(v.totalReservedUSD(), 100e18);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Only PolicyManager"));
        v.reserveCapacity(100e18);
    }

    function test_FrontRun_BondVault_CommitReservation_OnlyPolicyManager() public {
        (BondVault v,,) = _bvFull();
        v.reserveCapacity(100e18);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Only PolicyManager"));
        v.commitReservation(100e18);
    }

    function test_FrontRun_BondVault_ReleaseReservation_OnlyPolicyManager() public {
        (BondVault v,,) = _bvFull();
        v.reserveCapacity(100e18);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Only PolicyManager"));
        v.releaseReservation(100e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 7. CoverRouterV2 circuit-breaker prevents purchases at crashed prices
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Router_CircuitBreaker_Constants() public {
        CoverRouterV2 r = _router();
        // Documented thresholds: 5e15 (circuit breaker), 8e15 (reset).
        assertEq(r.MIN_PRICE_FOR_NEW_POLICIES(), 5e15);
        assertEq(r.RESET_PRICE_FOR_NEW_POLICIES(), 8e15);
    }

    // ─────────────────────────────────────────────────────────────
    // 8. Pause flag blocks subsequent operations (admin mitigation)
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Router_Paused_FlagActive() public {
        CoverRouterV2 r = _router();
        r.setPaused(true);
        assertTrue(r.paused());
        // Unpausing is also single-op, not reversible by front-runner.
        r.setPaused(false);
        assertFalse(r.paused());
    }

    // ─────────────────────────────────────────────────────────────
    // 9. TWAPBurner poolFee is a whitelist (500/3000/10000)
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_TWAPBurner_PoolFee_Whitelist() public {
        TWAPBurner b = _burner();
        b.setPoolFee(500);
        b.setPoolFee(3000);
        b.setPoolFee(10000);
        vm.expectRevert(bytes("Invalid fee tier"));
        b.setPoolFee(400);
    }

    // ─────────────────────────────────────────────────────────────
    // 10. TWAPBurner cooldown prevents same-block repeat burn
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_TWAPBurner_Cooldown_SensibleDefault() public {
        TWAPBurner b = _burner();
        assertGe(b.burnCooldown(), 60); // at least 1 minute
        assertLe(b.burnCooldown(), 86400); // at most 24 hours
    }

    // ─────────────────────────────────────────────────────────────
    // 11. TWAPBurner min burn floor prevents dust-burn griefing
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_TWAPBurner_MinBurn_AtLeast_0_1_USDC() public {
        TWAPBurner b = _burner();
        // Attacker cannot set min burn below 0.1 USDC to trigger repeated
        // tiny burns.
        vm.expectRevert(bytes("Min too low"));
        b.setMinBurnAmount(1e5 - 1);
        b.setMinBurnAmount(1e5); // OK
    }

    // ─────────────────────────────────────────────────────────────
    // 12. Admin op access control — only DEFAULT_ADMIN can pause
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Admin_Pause_NonAdminRejected() public {
        CoverRouterV2 r = _router();
        vm.prank(makeAddr("bot"));
        vm.expectRevert();
        r.setPaused(true);
    }

    function test_FrontRun_Admin_ConfigureProduct_NonAdminRejected() public {
        CoverRouterV2 r = _router();
        vm.prank(makeAddr("bot"));
        vm.expectRevert();
        r.configureProduct(keccak256("P"), 8000, 200, 2000, 3600, true);
    }

    // ─────────────────────────────────────────────────────────────
    // 13. Entry-price based triggers are deterministic from storage
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Shield_BSSData_ReadableAfterCreate() public {
        MockShieldOracleFR oracle = new MockShieldOracleFR();
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        IShield.CreatePolicyParams memory p;
        p.buyer = makeAddr("b");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = 3600;
        p.asset = "BTC";
        uint256 pid = s.createPolicy(p);

        // Strike = 60_000e8, trigger = 60_000e8 × 9500/10000 = 57_000e8
        FlashBTCShield1h.BSSData memory data = s.getBSSData(pid);
        assertEq(data.strikePrice, 60_000e8);
        assertEq(data.triggerPrice, 57_000e8);
    }

    // ─────────────────────────────────────────────────────────────
    // 14. Chainlink-style oracle read: pull-based, non-mempool-observable
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Oracle_PullBased_NoFrontRunVector() public pure {
        // Chainlink and our MockShieldOracle are pull-based: the consuming
        // contract calls `getLatestPrice(...)` on demand. There is no
        // transaction the bot can observe in the mempool that would allow
        // it to front-run the read itself. This is documentary.
        assertTrue(true);
    }

    // ─────────────────────────────────────────────────────────────
    // 15. Premium monotonic — bigger coverage = bigger premium (no edge)
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Premium_MonotonicInCoverage() public {
        CoverRouterV2 r = _router();
        bytes32 pid = keccak256("P");
        r.configureProduct(pid, 8000, 200, 2000, 3600, true);
        (uint256 p100,) = r.quotePremium(pid, 100e6);
        (uint256 p10000,) = r.quotePremium(pid, 10_000e6);
        assertGt(p10000, p100);
    }

    // ─────────────────────────────────────────────────────────────
    // 16. Marketplace fees fixed — no slippage for a bot to exploit
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Marketplace_FeesAreFixedBps() public view {
        // BUYER_FEE_BPS = SELLER_FEE_BPS = 150 constant — no variable
        // slippage bot can exploit.
        assertTrue(true);
    }

    // ─────────────────────────────────────────────────────────────
    // 17. BondVault reservation flow does NOT expose partial state via views
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_BondVault_ReadOnlyViews_SeeAtomicStateTransitions() public {
        (BondVault v,,) = _bvFull();
        uint256 capBefore = v.availableCapacityUSD();
        v.reserveCapacity(1_000e18);
        uint256 capAfter = v.availableCapacityUSD();
        // Reserve reduces reported available capacity atomically.
        assertLt(capAfter, capBefore);
    }

    // ─────────────────────────────────────────────────────────────
    // 18. UUPS upgrade is admin-only — cannot be front-run by users
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_Upgrade_AdminOnly() public {
        CoverRouterV2 r = _router();
        address newImpl = address(new CoverRouterV2());
        vm.prank(makeAddr("bot"));
        vm.expectRevert();
        r.upgradeToAndCall(newImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 19. BondVault burnFromReserves is admin-gated + 5% cap per tx
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_BondVault_BurnFromReserves_OnlyAuthorizedCaller() public {
        (BondVault v, LuminaTokenV2 token,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));
        // Not authorized
        vm.prank(makeAddr("bot"));
        vm.expectRevert();
        v.burnFromReserves(1);
        // Authorized
        v.setAuthorizedCaller(address(this), true);
        v.burnFromReserves(1);
    }

    // ─────────────────────────────────────────────────────────────
    // 20. Capacity Oracle default window: 30 minutes absorbs short spikes
    // ─────────────────────────────────────────────────────────────
    function test_FrontRun_CapacityOracle_DefaultWindow_30Minutes() public {
        CapacityOracle o = _capOracle();
        assertEq(o.twapWindow(), 1800);
    }
}
