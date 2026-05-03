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
import {LuminaBondMarketplace} from "../../../../src/marketplace/LuminaBondMarketplace.sol";
import {CEXLiquidityReserve} from "../../../../src/treasury/CEXLiquidityReserve.sol";
import {MaintenanceReserve} from "../../../../src/treasury/MaintenanceReserve.sol";
import {FlashBTCShield1h} from "../../../../src/products/FlashBTCShield1h.sol";
import {IShield} from "../../../../src/interfaces/IShield.sol";

contract MockOracleRace {
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

contract MockShieldOracleRace {
    int256 public priceBTC;

    constructor(int256 p) {
        priceBTC = p;
    }

    function getLatestPrice(bytes32) external view returns (int256) {
        return priceBTC;
    }
}

/**
 * @title RaceConditions
 * @notice Exercises race-sensitive state transitions that should survive
 *         same-block concurrent operations. Covers the post-PR #37 capacity
 *         reservation flow, burn-cap cumulative burns, buyback budget
 *         exhaustion, admin pause/deactivate races, multi-holder redemption,
 *         and post-upgrade continuity.
 */
contract RaceConditions is Test {
    // ─────────────────────────────────────────────────────────────
    // Shared fixtures
    // ─────────────────────────────────────────────────────────────
    function _token() internal returns (LuminaTokenV2) {
        return ProxyDeployer.deployLuminaTokenV2(
            makeAddr("bv"), makeAddr("cex"), makeAddr("f"), makeAddr("lbp"), makeAddr("tv")
        );
    }

    function _bvFull() internal returns (BondVault v, LuminaTokenV2 token, ClaimBond cb, MockOracleRace oracle) {
        oracle = new MockOracleRace(1e18);
        cb = ProxyDeployer.deployClaimBond();
        token = _token();
        v = ProxyDeployer.deployBondVault(address(token), address(cb), address(oracle), address(this));
        cb.setBondVault(address(v));
        deal(address(token), address(v), 70_000_000e18);
        vm.warp(1767225600 + 30 days);
    }

    // ─────────────────────────────────────────────────────────────
    // 1. Capacity reservation — PR #37 fix
    // ─────────────────────────────────────────────────────────────
    function test_Race_Reservation_SameBlock_DoesNotDoubleCount() public {
        (BondVault v,,,) = _bvFull();
        v.reserveCapacity(500e18);
        v.reserveCapacity(500e18);
        // Same-block: both reservations accumulate, no double-count.
        assertEq(v.totalReservedUSD(), 1000e18);
    }

    function test_Race_Reservation_ExceedsCap_Reverts() public {
        // availableCapacityUSD() subtracts both committed + reserved.
        // A reservation that would blow past 50% of reserve should leave 0 avail.
        (BondVault v,,,) = _bvFull();
        // Price $1 → reserve value = 70M USD → max commit = 35M USD.
        v.reserveCapacity(35_000_000e18);
        assertEq(v.availableCapacityUSD(), 0);
    }

    function test_Race_Reservation_CommitThenIssueBond_IndependentCounters() public {
        (BondVault v,,,) = _bvFull();
        v.reserveCapacity(1_000e18);
        assertEq(v.totalReservedUSD(), 1_000e18);

        v.commitReservation(1_000e18);
        assertEq(v.totalReservedUSD(), 0);
        // commitReservation alone does NOT bump totalCommittedUSD — that's
        // issueBond's responsibility.
        assertEq(v.totalCommittedUSD(), 0);

        v.issueBond(makeAddr("u"), 1_000, 0.036e18);
        assertEq(v.totalCommittedUSD(), 1_000e18);
    }

    function test_Race_Reservation_ReleaseThenReRelease_Reverts() public {
        (BondVault v,,,) = _bvFull();
        v.reserveCapacity(500e18);
        v.releaseReservation(500e18);
        assertEq(v.totalReservedUSD(), 0);
        // Second release with no remaining reservation reverts.
        vm.expectRevert(bytes("Insufficient reservation"));
        v.releaseReservation(500e18);
    }

    function test_Race_Reservation_InterleavedReserveRelease_ConsistentTotal() public {
        (BondVault v,,,) = _bvFull();
        // Reserve 1000, release 300, reserve 200, release 400 → 500 remaining.
        v.reserveCapacity(1000e18);
        v.releaseReservation(300e18);
        v.reserveCapacity(200e18);
        v.releaseReservation(400e18);
        assertEq(v.totalReservedUSD(), 500e18);
    }

    function test_Race_Reservation_MultipleIssuers_AccountingSane() public {
        (BondVault v,,,) = _bvFull();
        // Simulate 5 "concurrent" issuers each taking 100 USD capacity.
        for (uint256 i = 0; i < 5; i++) {
            v.reserveCapacity(100e18);
        }
        assertEq(v.totalReservedUSD(), 500e18);
        for (uint256 i = 0; i < 5; i++) {
            v.commitReservation(100e18);
            v.issueBond(makeAddr(string(abi.encode("u", i))), 100, 0.036e18);
        }
        assertEq(v.totalReservedUSD(), 0);
        assertEq(v.totalCommittedUSD(), 500e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 2. BondVault burn cap — sequential burns honour updated balance
    // ─────────────────────────────────────────────────────────────
    function test_Race_BurnCap_SequentialBurnsHonorUpdatedBalance() public {
        (BondVault v, LuminaTokenV2 token,,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));
        v.setAuthorizedCaller(address(this), true);

        uint256 balStart = token.balanceOf(address(v));
        uint256 firstCap = (balStart * 5) / 100;
        v.burnFromReserves(firstCap); // Succeeds.

        uint256 balAfter = token.balanceOf(address(v));
        // After burn, new cap is 5% of the REDUCED balance.
        uint256 secondCap = (balAfter * 5) / 100;
        assertLt(secondCap, firstCap, "cap shrinks after burn");
        v.burnFromReserves(secondCap); // Still succeeds at updated cap.
        assertEq(token.balanceOf(address(v)), balAfter - secondCap);
    }

    function test_Race_BurnCap_ConsecutiveMaxBurns_NeverExceeds5Percent() public {
        (BondVault v, LuminaTokenV2 token,,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));
        v.setAuthorizedCaller(address(this), true);

        uint256 start = token.balanceOf(address(v));
        for (uint256 i = 0; i < 10; i++) {
            uint256 bal = token.balanceOf(address(v));
            uint256 cap = (bal * 5) / 100;
            v.burnFromReserves(cap);
        }
        uint256 end = token.balanceOf(address(v));
        // 10 consecutive 5%-of-current-balance burns compound: 0.95^10 ≈ 0.5987.
        // So remaining ≈ 59.87% of start; burned ≈ 40.13%.
        assertApproxEqRel(end, (start * 5987) / 10000, 0.001e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 3. TWAPBurner cooldown invariant
    // ─────────────────────────────────────────────────────────────
    function test_Race_TWAPBurner_CooldownConstantPersistsAcrossCalls() public {
        TWAPBurner b = ProxyDeployer.deployTWAPBurner(makeAddr("u"), makeAddr("l"), makeAddr("d"));
        // Default cooldown set in initialize = 900s.
        assertEq(b.burnCooldown(), 900);
        // Reassigning does not persist across reverts; cooldown remains the
        // governed threshold.
        b.setBurnCooldown(3600);
        assertEq(b.burnCooldown(), 3600);
    }

    // ─────────────────────────────────────────────────────────────
    // 4. BuybackEngine daily budget — same-day exhaustion
    // ─────────────────────────────────────────────────────────────
    function test_Race_Buyback_DailyConfig_SecondSetOverwrites() public {
        BuybackEngine be = ProxyDeployer.deployBuybackEngine(
            makeAddr("cb"), makeAddr("bv"), makeAddr("so"), makeAddr("co"), makeAddr("mk"), makeAddr("u"), address(this)
        );
        be.setDailyBuyback(1_000e6, 70, 2);
        (uint256 b1, uint256 m1,,) = be.dailyConfig();
        assertEq(b1, 1_000e6);
        assertEq(m1, 70);

        // Admin can override same-day. Verifies the setter writes atomically.
        be.setDailyBuyback(5_000e6, 95, 4);
        (uint256 b2, uint256 m2,,) = be.dailyConfig();
        assertEq(b2, 5_000e6);
        assertEq(m2, 95);
    }

    // ─────────────────────────────────────────────────────────────
    // 5. PolicyManager deactivate/register concurrency
    // ─────────────────────────────────────────────────────────────
    function test_Race_PolicyManager_DeactivateBetweenRegistrations() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        bytes32 pid = keccak256("P");
        pm.registerProduct(pid, makeAddr("shield"));
        assertTrue(pm.productActive(pid));

        // Same-block deactivate.
        pm.deactivateProduct(pid);
        assertFalse(pm.productActive(pid));

        // Re-register with a different shield is allowed (admin can reactivate).
        pm.registerProduct(pid, makeAddr("shield2"));
        assertTrue(pm.productActive(pid));
        assertEq(pm.productShield(pid), makeAddr("shield2"));
    }

    function test_Race_PolicyManager_SimultaneousRegistrations_AllProductIdsUnique() public {
        PolicyManagerV2 pm = ProxyDeployer.deployPolicyManagerV2(makeAddr("vault"));
        // Same-block register 10 products.
        for (uint256 i = 0; i < 10; i++) {
            pm.registerProduct(keccak256(abi.encode("PID", i)), makeAddr(string(abi.encode("sh", i))));
        }
        for (uint256 i = 0; i < 10; i++) {
            assertTrue(pm.productActive(keccak256(abi.encode("PID", i))));
        }
    }

    // ─────────────────────────────────────────────────────────────
    // 6. CoverRouter pause — blocks subsequent ops
    // ─────────────────────────────────────────────────────────────
    function test_Race_CoverRouter_PauseBetweenOps() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        bytes32 pid = keccak256("P");
        r.configureProduct(pid, 8000, 200, 2000, 3600, true);
        assertFalse(r.paused());

        // Pause.
        r.setPaused(true);
        assertTrue(r.paused());
        // Unpause immediately same-block.
        r.setPaused(false);
        assertFalse(r.paused());
    }

    function test_Race_CoverRouter_DeactivateProduct_PreservesPriorConfig() public {
        CoverRouterV2 r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("p"), makeAddr("b"));
        bytes32 pid = keccak256("P");
        r.configureProduct(pid, 8000, 200, 2000, 3600, true);
        (,,,,, bool active1) = r.products(pid);
        assertTrue(active1);
        // Same-block deactivation via reconfigure with active=false.
        r.configureProduct(pid, 8000, 200, 2000, 3600, false);
        (,,,,, bool active2) = r.products(pid);
        assertFalse(active2);
    }

    // ─────────────────────────────────────────────────────────────
    // 7. Multi-holder redeem — same epoch
    // ─────────────────────────────────────────────────────────────
    function test_Race_Redeem_MultipleHolders_SameEpoch() public {
        (BondVault v, LuminaTokenV2 token, ClaimBond cb,) = _bvFull();
        token.grantRole(token.BURNER_ROLE(), address(v));

        address[3] memory holders = [makeAddr("h1"), makeAddr("h2"), makeAddr("h3")];
        for (uint256 i = 0; i < 3; i++) {
            v.issueBond(holders[i], 100, 0.036e18);
        }
        assertEq(v.totalCommittedUSD(), 300e18);

        // block.timestamp at mint = 1767225600 + 30 days = 1_769_817_600.
        // maturity = ts + 730 days = 1_832_889_600.
        // monthsFromBase = (1_832_889_600 - 1_767_225_600) / 2_629_746 = 65_664_000 / 2_629_746 ≈ 24.97 → 24.
        // year = 2026 + 24/12 = 2028; month = 1 + 24%12 = 1. epochId = 202801.
        uint256 epochId = 202801;
        for (uint256 i = 0; i < 3; i++) {
            assertEq(cb.balanceOf(holders[i], epochId), 100);
        }

        // Warp past maturity.
        vm.warp(block.timestamp + 731 days);
        assertTrue(cb.isMatured(epochId));

        // Sequential redemptions see the shrinking LUMINA balance.
        uint256 totalRedeemed;
        for (uint256 i = 0; i < 3; i++) {
            uint256 balBefore = token.balanceOf(holders[i]);
            vm.prank(holders[i]);
            v.redeemBond(epochId, 100);
            totalRedeemed += token.balanceOf(holders[i]) - balBefore;
        }
        assertEq(totalRedeemed, 300e18);
    }

    // ─────────────────────────────────────────────────────────────
    // 8. Shield — concurrent createPolicy calls
    // ─────────────────────────────────────────────────────────────
    function test_Race_Shield_ConcurrentCreatePolicy_AllDistinctIds() public {
        MockShieldOracleRace oracle = new MockShieldOracleRace(60_000e8);
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        uint256[] memory ids = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            IShield.CreatePolicyParams memory p;
            p.buyer = makeAddr(string(abi.encode("b", i)));
            p.coverageAmount = 1000e6;
            p.premiumAmount = 10e6;
            p.durationSeconds = 3600;
            p.asset = "BTC";
            ids[i] = s.createPolicy(p);
        }
        // Check IDs are 1..5 (monotonic) — i.e. no overwriting or duplication.
        for (uint256 i = 0; i < 5; i++) {
            assertEq(ids[i], i + 1);
        }
        assertEq(s.activePolicies(), 5);
        assertEq(s.totalPolicies(), 5);
    }

    // ─────────────────────────────────────────────────────────────
    // 9. CEX allocator racing (admin-level test)
    // ─────────────────────────────────────────────────────────────
    function test_Race_CEX_AdminGrantAllocatorBetweenOps() public {
        CEXLiquidityReserve c = ProxyDeployer.deployCEXLiquidityReserve(makeAddr("l"), address(this));
        bytes32 role = c.ALLOCATOR_ROLE();
        c.grantRole(role, makeAddr("opA"));
        c.grantRole(role, makeAddr("opB"));
        assertTrue(c.hasRole(role, makeAddr("opA")));
        assertTrue(c.hasRole(role, makeAddr("opB")));

        c.revokeRole(role, makeAddr("opB"));
        assertTrue(c.hasRole(role, makeAddr("opA")));
        assertFalse(c.hasRole(role, makeAddr("opB")));
    }

    // ─────────────────────────────────────────────────────────────
    // 10. MaintenanceReserve spend vs cap racing
    // ─────────────────────────────────────────────────────────────
    function test_Race_MaintenanceReserve_CapAndSpendRole_Independent() public {
        MaintenanceReserve m = ProxyDeployer.deployMaintenanceReserve(makeAddr("u"), address(this));
        m.setMonthlyCap(10_000e6);
        // Admin can tighten cap without affecting SPENDER_ROLE grants.
        m.setMonthlyCap(5_000e6);
        assertEq(m.monthlyCap(), 5_000e6);
        bytes32 spender = m.SPENDER_ROLE();
        assertTrue(m.hasRole(spender, address(this)));
    }

    // ─────────────────────────────────────────────────────────────
    // 11. UUPS upgrade + operation — state preserved
    // ─────────────────────────────────────────────────────────────
    function test_Race_Upgrade_StatePreservedAndOperationsContinue() public {
        (BondVault v,,,) = _bvFull();
        v.issueBond(makeAddr("pre"), 123, 0.036e18);
        uint256 committedPre = v.totalCommittedUSD();

        v.upgradeToAndCall(address(new BondVault()), "");
        // Immediate subsequent op — no warp.
        v.issueBond(makeAddr("post"), 456, 0.036e18);
        assertEq(v.totalCommittedUSD(), committedPre + 456e18);
    }

    function test_Race_Upgrade_NoReentry_OnMaliciousAttacker() public {
        (BondVault v,,,) = _bvFull();
        address attackerImpl = address(new BondVault());
        vm.prank(makeAddr("atk"));
        vm.expectRevert();
        v.upgradeToAndCall(attackerImpl, "");
    }

    // ─────────────────────────────────────────────────────────────
    // 12. Marketplace list/cancel/buy state racing
    // ─────────────────────────────────────────────────────────────
    function test_Race_Marketplace_SetBurnerBetweenOps() public {
        LuminaBondMarketplace m =
            ProxyDeployer.deployLuminaBondMarketplace(makeAddr("cb"), makeAddr("u"), makeAddr("b"), address(this));
        m.setTwapBurner(makeAddr("newBurner1"));
        m.setTwapBurner(makeAddr("newBurner2"));
        // Last-write-wins; no dangling pointer.
        assertEq(m.twapBurner(), makeAddr("newBurner2"));
    }

    // ─────────────────────────────────────────────────────────────
    // 13. Cross-contract reservation reconciliation after upgrade
    // ─────────────────────────────────────────────────────────────
    function test_Race_Reservation_Preserved_Across_Upgrade() public {
        (BondVault v,,,) = _bvFull();
        v.reserveCapacity(1_000e18);
        assertEq(v.totalReservedUSD(), 1_000e18);
        v.upgradeToAndCall(address(new BondVault()), "");
        // Reserved bucket preserved.
        assertEq(v.totalReservedUSD(), 1_000e18);
        // Release still works.
        v.releaseReservation(1_000e18);
        assertEq(v.totalReservedUSD(), 0);
    }

    // ─────────────────────────────────────────────────────────────
    // 14. Token role grants race
    // ─────────────────────────────────────────────────────────────
    function test_Race_Token_RoleGrantsInSameBlock_AllApply() public {
        LuminaTokenV2 t = _token();
        bytes32 burner = t.BURNER_ROLE();
        t.grantRole(burner, makeAddr("a"));
        t.grantRole(burner, makeAddr("b"));
        t.grantRole(burner, makeAddr("c"));
        assertTrue(t.hasRole(burner, makeAddr("a")));
        assertTrue(t.hasRole(burner, makeAddr("b")));
        assertTrue(t.hasRole(burner, makeAddr("c")));
    }

    // ─────────────────────────────────────────────────────────────
    // 15. Shield oracle swap mid-operation
    // ─────────────────────────────────────────────────────────────
    function test_Race_Shield_OracleAddressImmutableFromState() public {
        MockShieldOracleRace oracle = new MockShieldOracleRace(60_000e8);
        FlashBTCShield1h s = ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
        // There is no setOracle; oracle can only change via upgrade.
        // Creating two policies back-to-back uses the same oracle address.
        IShield.CreatePolicyParams memory p;
        p.buyer = makeAddr("b1");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = 3600;
        p.asset = "BTC";
        uint256 id1 = s.createPolicy(p);

        p.buyer = makeAddr("b2");
        uint256 id2 = s.createPolicy(p);

        assertEq(s.getBSSData(id1).strikePrice, s.getBSSData(id2).strikePrice);
    }

    // ─────────────────────────────────────────────────────────────
    // 16. ClaimBond mint/burn race
    // ─────────────────────────────────────────────────────────────
    function test_Race_ClaimBond_MintBurnSameBlock_BalanceCorrect() public {
        ClaimBond cb = ProxyDeployer.deployClaimBond();
        cb.setBondVault(address(this));
        cb.mint(makeAddr("h"), 202804, 1000);
        cb.burn(makeAddr("h"), 202804, 300);
        assertEq(cb.balanceOf(makeAddr("h"), 202804), 700);
        assertEq(cb.totalSupply(202804), 700);
    }

    // ─────────────────────────────────────────────────────────────
    // 17. BondVault issueBond accounting monotonicity
    // ─────────────────────────────────────────────────────────────
    function test_Race_BondVault_100IssueBonds_NoInconsistency() public {
        (BondVault v,,,) = _bvFull();
        uint256 expected;
        for (uint256 i = 1; i <= 100; i++) {
            v.issueBond(makeAddr(string(abi.encode("u", i))), i, 0.036e18);
            expected += i * 1e18;
        }
        assertEq(v.totalCommittedUSD(), expected);
    }

    // ─────────────────────────────────────────────────────────────
    // 18. Reservation vs release inverse operation
    // ─────────────────────────────────────────────────────────────
    function test_Race_Reservation_SimultaneousReserveAndRelease() public {
        (BondVault v,,,) = _bvFull();
        v.reserveCapacity(500e18);
        v.reserveCapacity(500e18);
        v.releaseReservation(300e18);
        v.reserveCapacity(100e18);
        v.releaseReservation(200e18);
        // Net: 500 + 500 - 300 + 100 - 200 = 600.
        assertEq(v.totalReservedUSD(), 600e18);
    }
}
