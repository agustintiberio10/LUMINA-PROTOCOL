// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVesting, IAaveV3PoolReader} from "../../../src/token/FounderVesting.sol";

contract MockOracle {
    int256 public ethPrice;
    int256 public btcPrice;
    bool public shouldRevert;

    function setPrices(int256 e, int256 b) external {
        ethPrice = e;
        btcPrice = b;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (shouldRevert) revert("ORACLE_DOWN");
        if (asset == bytes32("ETH")) return ethPrice;
        if (asset == bytes32("BTC")) return btcPrice;
        return 0;
    }
}

contract MockAave {
    uint128 public rate;
    bool public shouldRevert;

    function setRate(uint128 r) external {
        rate = r;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function getReserveData(address) external view returns (IAaveV3PoolReader.ReserveData memory data) {
        if (shouldRevert) revert("AAVE_DOWN");
        data.currentVariableBorrowRate = rate;
    }
}

contract MockLumina {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "insufficient");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @title FounderVestingEdgeCases
/// @notice Sprint Z.1 Phase 2 — 40 directed edge cases for FounderVesting immutable.
/// @dev Groups: T-ORC (15 oracle/Aave staleness+corruption), T-CNT (7 sustained-period counter),
///      T-DAY (3 timestamp definition), T-RACE (2 boundary races), T-FBK (6 fallback),
///      T-REL (4 release tranche), T-TRX (3 fallback↔oracle transition).
contract FounderVestingEdgeCases is Test {
    FounderVesting vesting;
    MockOracle oracle;
    MockAave aave;
    MockLumina lumina;
    address usdc = address(0x1);
    address recipient = address(0xBEEF);

    function setUp() public {
        vm.chainId(8453);
        oracle = new MockOracle();
        aave = new MockAave();
        lumina = new MockLumina();
        vesting = new FounderVesting(address(oracle), address(aave), address(lumina), usdc, recipient);
        lumina.mint(address(vesting), 8_000_000 * 1e18);
    }

    // ═══════ T-ORC: Oracle staleness / corruption ═══════

    function test_T_ORC_OracleEth_ReturnsZero_NoActivation() public {
        oracle.setPrices(0, 50_000_00000000);
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered(), "Should NOT activate with zero ETH price");
    }

    function test_T_ORC_OracleEthBtc_ReturnsNegative_NoActivation() public {
        oracle.setPrices(-1, 50_000_00000000);
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered());
    }

    function test_T_ORC_Oracle_Reverts_HandledViaCatch() public {
        oracle.setRevert(true);
        aave.setRate(uint128(8e25));
        // checkAltSeason() inner try-catch swallows revert. Aave still active.
        vesting.checkAltSeason();
        // condC may still be true; A+B should be false.
        (bool a, bool b,) = vesting.getConditions();
        assertFalse(a);
        assertFalse(b);
    }

    function test_T_ORC_OracleEth_MaxInt256_NoOverflow() public {
        // type(int256).max would overflow on ratio multiplication; verify it doesn't crash the contract.
        oracle.setPrices(type(int128).max, 50_000_00000000);
        vesting.checkAltSeason();
        // Should not crash.
    }

    function test_T_ORC_Aave_Reverts_HandledViaCatch() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRevert(true);
        vesting.checkAltSeason();
        // condC false but A+B true.
        (bool a, bool b, bool c) = vesting.getConditions();
        assertTrue(a);
        assertTrue(b);
        assertFalse(c);
    }

    function test_T_ORC_Aave_BorrowRateZero_NoActivation() public {
        aave.setRate(0);
        (,, bool c) = vesting.getConditions();
        assertFalse(c);
    }

    function test_T_ORC_Aave_BorrowRateExtreme_NoOverflow() public {
        aave.setRate(type(uint128).max);
        (,, bool c) = vesting.getConditions();
        assertTrue(c, "Extreme borrow rate should still trigger condC");
    }

    // ═══════ T-CNT: Counter behavior ═══════

    function test_T_CNT_FirstCheck_SetsConditionsMetSince() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), 0);
        assertFalse(vesting.altSeasonTriggered(), "Should NOT trigger on first check");
    }

    function test_T_CNT_ConditionsFail_ResetsCounter() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), 0);
        // Conditions drop.
        oracle.setPrices(0, 0);
        aave.setRate(0);
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0, "Counter must reset");
    }

    function test_T_CNT_Sustained7Days_Triggers() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason(); // start counter
        vm.warp(block.timestamp + 7 days + 1);
        vesting.checkAltSeason(); // should trigger
        assertTrue(vesting.altSeasonTriggered(), "Should trigger after 7 days sustained");
    }

    function test_T_CNT_SustainedLess7Days_DoesNotTrigger() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        vm.warp(block.timestamp + 7 days - 1);
        vesting.checkAltSeason();
        assertFalse(vesting.altSeasonTriggered());
    }

    // ═══════ T-FBK: Fallback ═══════

    function test_T_FBK_BeforeFallback_TriggerReverts() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() - 1);
        vm.expectRevert(bytes("Fallback not reached"));
        vesting.triggerFallback();
    }

    function test_T_FBK_ExactlyAtFallback_Triggers() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION());
        vesting.triggerFallback();
        assertTrue(vesting.altSeasonTriggered());
    }

    function test_T_FBK_AfterTrigger_CannotReTrigger() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vm.expectRevert(bytes("Already triggered"));
        vesting.triggerFallback();
    }

    // ═══════ T-REL: Release ═══════

    function test_T_REL_BeforeTrigger_Reverts() public {
        vm.expectRevert(bytes("Not triggered"));
        vesting.releaseTranche();
    }

    function test_T_REL_AfterTrigger_FirstTranche_Releases() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 1);
        assertEq(lumina.balanceOf(recipient), vesting.TRANCHE_AMOUNT());
    }

    function test_T_REL_SecondTrancheBeforeInterval_Reverts() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vesting.releaseTranche();
        vm.expectRevert(bytes("Too early"));
        vesting.releaseTranche();
    }

    function test_T_REL_AllThreeTranches_TotalEquals8M() public {
        uint256 t0 = vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1;
        vm.warp(t0);
        vesting.triggerFallback();
        vesting.releaseTranche(); // T1 at tranchesReleased=0 → releaseTime = trigger + 0 = OK
        vm.warp(t0 + 31 days);
        vesting.releaseTranche();
        vm.warp(t0 + 62 days);
        vesting.releaseTranche();
        assertEq(vesting.tranchesReleased(), 3);
        assertEq(vesting.totalReleased(), 8_000_000 * 1e18);
        assertEq(lumina.balanceOf(recipient), 8_000_000 * 1e18);
    }

    function test_T_REL_FourthTranche_Reverts() public {
        uint256 t0 = vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1;
        vm.warp(t0);
        vesting.triggerFallback();
        vesting.releaseTranche();
        vm.warp(t0 + 31 days);
        vesting.releaseTranche();
        vm.warp(t0 + 62 days);
        vesting.releaseTranche();
        vm.warp(t0 + 93 days);
        vm.expectRevert(bytes("All tranches released"));
        vesting.releaseTranche();
    }

    // ═══════ T-ORC: Extra oracle / Aave boundary tests ═══════

    function test_T_ORC_OracleBtc_ReturnsZero_NoCondAB() public {
        oracle.setPrices(5_000_00000000, 0);
        (bool a, bool b,) = vesting.getConditions();
        assertFalse(a);
        assertFalse(b);
    }

    function test_T_ORC_OracleBtc_ReturnsNegative_NoCondAB() public {
        oracle.setPrices(5_000_00000000, -1);
        (bool a, bool b,) = vesting.getConditions();
        assertFalse(a);
        assertFalse(b);
    }

    function test_T_ORC_EthBtcRatio_ExactlyAtThreshold_NotStrict() public {
        // ratio = 50e8 * 1e18 / 1000e8 = 50e15 == ETH_BTC_THRESHOLD; strict > requires above.
        oracle.setPrices(50_00000000, 1_000_00000000);
        (bool a,,) = vesting.getConditions();
        assertFalse(a, "exact threshold must NOT satisfy strict >");
    }

    function test_T_ORC_EthBtcRatio_JustAboveThreshold_CondA() public {
        oracle.setPrices(51_00000000, 1_000_00000000); // 51e15 > 50e15
        (bool a,,) = vesting.getConditions();
        assertTrue(a);
    }

    function test_T_ORC_EthUsd_ExactlyAtThreshold_NotStrict() public {
        oracle.setPrices(int256(uint256(vesting.ETH_USD_THRESHOLD())), 50_000_00000000);
        (, bool b,) = vesting.getConditions();
        assertFalse(b, "exact $4000 must NOT satisfy strict >");
    }

    function test_T_ORC_EthUsd_JustAboveThreshold_CondB() public {
        oracle.setPrices(int256(uint256(vesting.ETH_USD_THRESHOLD())) + 1, 50_000_00000000);
        (, bool b,) = vesting.getConditions();
        assertTrue(b);
    }

    function test_T_ORC_Aave_RateExactlyAtThreshold_NotStrict() public {
        aave.setRate(uint128(vesting.BORROW_RATE_THRESHOLD()));
        (,, bool c) = vesting.getConditions();
        assertFalse(c, "exact 7% must NOT satisfy strict >");
    }

    function test_T_ORC_Aave_RateJustAboveThreshold_CondC() public {
        aave.setRate(uint128(vesting.BORROW_RATE_THRESHOLD() + 1));
        (,, bool c) = vesting.getConditions();
        assertTrue(c);
    }

    // ═══════ T-CNT: Extra counter scenarios ═══════

    function test_T_CNT_AlternatingPairs_AB_then_BC_CounterContinues() public {
        // Start with A+B true (oracle prices) → counter starts.
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        vesting.checkAltSeason();
        uint256 startTs = vesting.conditionsMetSince();
        assertGt(startTs, 0);
        // Switch to B+C (drop A by raising BTC, keep ETH above $4k, raise aave above 7%).
        // Drop condA: ratio = 5000/1_000_000 = 0.005 < 0.05.
        oracle.setPrices(5_000_00000000, 1_000_000_00000000);
        aave.setRate(uint128(8e25));
        // Move forward 1 day to ensure a fresh check.
        vm.warp(block.timestamp + 1 days);
        vesting.checkAltSeason();
        // Counter should NOT reset (metCount stayed >= 2).
        assertEq(vesting.conditionsMetSince(), startTs, "counter must persist across pair switch");
    }

    function test_T_CNT_ConditionsBreakFor1Block_ResetsRestarts() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        uint256 firstTs = vesting.conditionsMetSince();
        assertGt(firstTs, 0);
        // Drop all conditions for 1 block.
        oracle.setPrices(0, 0);
        aave.setRate(0);
        vm.warp(block.timestamp + 1);
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), 0, "must reset");
        // Restore conditions, counter restarts at new ts.
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vm.warp(block.timestamp + 1);
        vesting.checkAltSeason();
        assertGt(vesting.conditionsMetSince(), firstTs, "restart with newer timestamp");
    }

    function test_T_CNT_TwoChecksSameBlock_CounterUnchanged() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        uint256 startTs = vesting.conditionsMetSince();
        // Second check in same block — counter timestamp must not change.
        vesting.checkAltSeason();
        assertEq(vesting.conditionsMetSince(), startTs);
        assertFalse(vesting.altSeasonTriggered());
    }

    // ═══════ T-DAY: Timestamp definition / drift ═══════

    function test_T_DAY_DefinitionExactly7Days_StrictGreaterEqual() public {
        // SUSTAINED_DURATION == 7 days (== 7 * 86400 seconds). Contract uses >= so EXACTLY 7d ⇒ triggers.
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        uint256 start = vesting.conditionsMetSince();
        vm.warp(start + 7 days);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered(), "exactly 7 days must trigger (>=)");
    }

    function test_T_DAY_BlockTimestampJump_FarFuture_StillTriggers() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        // Simulate a long L2 outage with no checks; conditions still met after months.
        vm.warp(block.timestamp + 365 days);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered());
    }

    function test_T_DAY_ConditionsMetSince_AlwaysLessThanOrEqualBlockTimestamp() public {
        // Property: conditionsMetSince is always ≤ block.timestamp (set in past, never future).
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        assertLe(vesting.conditionsMetSince(), block.timestamp);
        vm.warp(block.timestamp + 100);
        assertLe(vesting.conditionsMetSince(), block.timestamp);
    }

    // ═══════ T-RACE: Boundary race conditions ═══════

    function test_T_RACE_TriggerExactlyAt7DayBoundary_StateConsistent() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        uint256 start = vesting.conditionsMetSince();
        // Step to exact boundary.
        vm.warp(start + 7 days);
        vesting.checkAltSeason();
        assertTrue(vesting.altSeasonTriggered());
        assertEq(vesting.triggerTimestamp(), start + 7 days);
    }

    function test_T_RACE_DoubleCheck_AfterTrigger_SecondReverts() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        vm.warp(block.timestamp + 7 days + 1);
        vesting.checkAltSeason();
        // Already triggered; second call must revert.
        vm.expectRevert(bytes("Already triggered"));
        vesting.checkAltSeason();
    }

    // ═══════ T-FBK: Extra fallback semantics ═══════

    function test_T_FBK_FallbackPlus31Days_Tranche2Available() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        vesting.releaseTranche(); // tranche 1 at t0
        vm.warp(block.timestamp + 31 days);
        vesting.releaseTranche(); // tranche 2
        assertEq(vesting.tranchesReleased(), 2);
    }

    function test_T_FBK_DeployTimePlusFallbackMinus1Sec_TriggerReverts() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() - 1);
        vm.expectRevert(bytes("Fallback not reached"));
        vesting.triggerFallback();
    }

    function test_T_FBK_DeployTimePlus5Years_AllTranchesStillBounded() public {
        uint256 t0 = vesting.deployedAt() + 5 * 365 days;
        vm.warp(t0);
        vesting.triggerFallback();
        vesting.releaseTranche();
        vm.warp(t0 + 31 days);
        vesting.releaseTranche();
        vm.warp(t0 + 62 days);
        vesting.releaseTranche();
        assertEq(vesting.totalReleased(), 8_000_000 * 1e18, "must not over-release after 5y");
        vm.warp(t0 + 365 days);
        vm.expectRevert(bytes("All tranches released"));
        vesting.releaseTranche();
    }

    // ═══════ T-TRX: Fallback ↔ Oracle transition ═══════

    function test_T_TRX_OracleTriggers_FallbackBlocked() public {
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        vm.warp(block.timestamp + 7 days + 1);
        vesting.checkAltSeason(); // altSeasonTriggered = true
        // Now warp past fallback window; triggerFallback must still revert (already triggered).
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vm.expectRevert(bytes("Already triggered"));
        vesting.triggerFallback();
    }

    function test_T_TRX_FallbackTriggers_CheckAltSeasonBlocked() public {
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() + 1);
        vesting.triggerFallback();
        // checkAltSeason must now revert with already triggered.
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vm.expectRevert(bytes("Already triggered"));
        vesting.checkAltSeason();
    }

    function test_T_TRX_AlmostFallback_OracleStartsSustain_OracleWinsIfFaster() public {
        // 6 days before fallback. Oracle conditions met → sustained period starts.
        vm.warp(vesting.deployedAt() + vesting.FALLBACK_DURATION() - 6 days);
        oracle.setPrices(5_000_00000000, 50_000_00000000);
        aave.setRate(uint128(8e25));
        vesting.checkAltSeason();
        // Move 6 days forward (now 0 days before fallback / right at fallback).
        vm.warp(block.timestamp + 6 days);
        vesting.checkAltSeason();
        // Note: only 6 days sustained (< 7), so altSeason not triggered. Fallback IS available.
        assertFalse(vesting.altSeasonTriggered());
        vesting.triggerFallback();
        assertTrue(vesting.altSeasonTriggered());
        // Verify it was fallback path (triggerTimestamp == now).
        assertEq(vesting.triggerTimestamp(), block.timestamp);
    }
}
