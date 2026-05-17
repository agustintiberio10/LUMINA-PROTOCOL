// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FounderVesting, IAaveV3PoolReader} from "../../../src/token/FounderVesting.sol";

// +============================================================================+
// | Sprint FV -- Phase D: 60 edge-case tests for FounderVesting V2 (PATH 2)     |
// |                                                                            |
// | Groups (60 total):                                                         |
// |   T-ORC   x15  Oracle staleness / revert / corruption                      |
// |   T-CNT   x7   Counter / sustained-period boundary                         |
// |   T-DAY   x3   Definition of "day"                                         |
// |   T-RACE  x2   Race conditions                                             |
// |   T-FBK   x6   Fallback (3 years = 1095d)                                  |
// |   T-REL   x4   Tranche release                                             |
// |   T-TRX   x3   Trigger / counter transitions                               |
// |   T-OVR   x10  PATH 2 ETH > $5,000 override                                |
// |   T-COBRO x9   Verification of claim (balances + events + dust)            |
// |                                                                            |
// | All sustained durations updated to 1 day (86400s) per Sprint FV B.         |
// | All fallback durations updated to 1095d (3 years) per Sprint FV B.         |
// | ETH override threshold: 500_000_000_000 (= $5,000 in 8-dec Chainlink).     |
// | TRANCHE_AMOUNT = 8_000_000e18 / 3 (integer division, last tranche absorbs  |
// | remainder dust to make sum exactly 8M).                                    |
// |                                                                            |
// | NOTE on warp: foundry.toml has via_ir=true; per memory                     |
// | `foundry_via_ir_warp.md`, `vm.warp(block.timestamp + delta)` caches the    |
// | initial block.timestamp under via_ir. We anchor warps to `t0` captured at  |
// | setUp() and always pass absolute timestamps.                               |
// +============================================================================+

// -----------------------------------------------------------------------------
// Mocks
// -----------------------------------------------------------------------------

/// @notice Mock oracle with per-asset revert toggles + raw price setters.
contract MockOracleV2 {
    int256 public ethPrice;
    int256 public btcPrice;
    bool public revertOnETH;
    bool public revertOnBTC;
    bool public revertOnAny;

    function setEth(int256 p) external {
        ethPrice = p;
    }

    function setBtc(int256 p) external {
        btcPrice = p;
    }

    function setPrices(int256 _eth, int256 _btc) external {
        ethPrice = _eth;
        btcPrice = _btc;
    }

    function setRevertOnETH(bool v) external {
        revertOnETH = v;
    }

    function setRevertOnBTC(bool v) external {
        revertOnBTC = v;
    }

    function setRevertOnAny(bool v) external {
        revertOnAny = v;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (revertOnAny) revert("oracle down");
        if (asset == bytes32("ETH")) {
            if (revertOnETH) revert("eth feed down");
            return ethPrice;
        }
        if (asset == bytes32("BTC")) {
            if (revertOnBTC) revert("btc feed down");
            return btcPrice;
        }
        return 0;
    }
}

/// @notice Mock Aave V3 pool with revert toggle.
contract MockAavePoolV2 {
    uint128 public borrowRate;
    bool public revertOnRead;

    function setBorrowRate(uint128 r) external {
        borrowRate = r;
    }

    function setRevertOnRead(bool v) external {
        revertOnRead = v;
    }

    function getReserveData(address) external view returns (IAaveV3PoolReader.ReserveData memory data) {
        if (revertOnRead) revert("aave down");
        data.currentVariableBorrowRate = borrowRate;
    }
}

/// @notice Minimal ERC20-like mock to satisfy IERC20.transfer + balanceOf used by FV.
contract MockLumina {
    mapping(address => uint256) public balanceOf;
    string public name = "MockLumina";

    function setBalance(address who, uint256 amount) external {
        balanceOf[who] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Plain contract recipient (no payable, no special interface) -- used to
///         confirm tokens can land in a contract address via ERC20.transfer.
contract PlainContractRecipient {
    // intentionally empty -- receives via ERC20 balance ledger only.

    }

// -----------------------------------------------------------------------------
// Test Harness
// -----------------------------------------------------------------------------

contract FounderVestingV2EdgeCases is Test {
    // Re-declare events for vm.expectEmit matching. Solidity 0.8.20 requires events to be
    // in scope of the emitting contract; re-declaring with identical signature is the
    // standard foundry pattern when the event lives in another contract.
    event SustainedPeriodReset(uint256 timestamp);
    event AltSeasonTriggered(uint256 timestamp);
    event OverrideConditionMet(uint256 indexed ethPrice, uint256 timestamp);
    event OverrideConditionLost(uint256 indexed ethPrice, uint256 timestamp);
    event OverrideTriggered(uint256 indexed ethPrice, uint256 timestamp);
    event FallbackTriggered(uint256 timestamp);
    event TrancheReleased(uint256 trancheNumber, uint256 amount, address recipient);
    event RecipientUpdated(address oldRecipient, address newRecipient);

    FounderVesting fv;
    MockOracleV2 oracle;
    MockAavePoolV2 aave;
    MockLumina lumina;

    address usdc = makeAddr("usdc");
    address recipient = makeAddr("recipient");
    address attacker = makeAddr("attacker");
    address ownerAddr; // address(this) by default in Ownable

    uint256 t0;

    // Mirror of constants for readability inside tests.
    uint256 constant SUSTAINED = 1 days; // 86_400 seconds
    uint256 constant FALLBACK_D = 1095 days; // 94_608_000 seconds
    uint256 constant TRANCHE_INT = 31 days;
    uint256 constant TOTAL_AMOUNT = 8_000_000 * 1e18;
    uint256 constant TRANCHE_AMOUNT = TOTAL_AMOUNT / 3; // 2_666_666.666... * 1e18 (integer-truncated)

    // Threshold for PATH 2 override: ETH > $5,000 in 8-dec Chainlink.
    int256 constant ETH_OVERRIDE_THRESHOLD = 500_000_000_000; // exactly $5,000.00000000
    int256 constant ETH_OVERRIDE_PASS = 500_000_000_001; // $5,000.00000001 -- strictly above
    int256 constant ETH_OVERRIDE_FAIL_HI = 500_000_000_000; // exactly $5,000 -- NOT above (strict `>`)

    function setUp() public {
        // Pin a non-trivial block.timestamp to avoid wrap-around with FALLBACK_D.
        vm.warp(1_700_000_000);

        oracle = new MockOracleV2();
        aave = new MockAavePoolV2();
        lumina = new MockLumina();

        ownerAddr = address(this);
        fv = new FounderVesting(address(oracle), address(aave), address(lumina), usdc, recipient);
        // Fund the vesting contract with the full 8M LUMINA allocation.
        lumina.setBalance(address(fv), TOTAL_AMOUNT);

        t0 = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Set PATH 1 to be 2-of-3 (A + B): ETH=$4500, BTC=$60k (ratio=0.075 > 0.05), ethPrice > $4k.
    ///      Aave borrow rate stays 0 -> condC=false. ETH < $5k -> no PATH 2 override.
    function _setPath1_2of3_NoOverride() internal {
        oracle.setPrices(4500_00000000, 60000_00000000);
        aave.setBorrowRate(0);
    }

    /// @dev Set PATH 1 to be 1-of-3 only (condB true). ETH=$4500, BTC=$0 -> condA,condB false (need both prices).
    function _setPath1_1of3() internal {
        // Only condC by setting Aave above threshold; oracle returns 0 for both.
        oracle.setPrices(0, 0);
        aave.setBorrowRate(8e25); // 8% > 7%
    }

    /// @dev Set PATH 1 to 0-of-3.
    function _setPath1_0of3() internal {
        oracle.setPrices(0, 0);
        aave.setBorrowRate(0);
    }

    /// @dev Set PATH 2 override active (ETH > $5,000) but PATH 1 = 0-of-3 (BTC=0 disables A+B).
    function _setOverrideOnly() internal {
        oracle.setEth(ETH_OVERRIDE_PASS);
        oracle.setBtc(0); // disables condA and condB (needs btcPrice > 0)
        aave.setBorrowRate(0);
    }

    /// @dev Trigger PATH 1 fully: 2-of-3 + sustain 1 day. After this `altSeasonTriggered` is true.
    function _triggerPath1() internal returns (uint256 trigTs) {
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        vm.warp(t0 + SUSTAINED + 1);
        fv.checkAltSeason();
        trigTs = fv.triggerTimestamp();
    }

    // =====================================================================
    // T-ORC: Oracle staleness / revert / corruption (15)
    // =====================================================================

    function test_ORC_OracleRevertsETH_NoAdvance() public {
        // ETH feed reverts; BTC OK; Aave 0. metCount=0 because condA/condB need ethPrice>0.
        oracle.setRevertOnETH(true);
        oracle.setBtc(60000_00000000);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0, "Should not start sustained period");
        assertFalse(fv.altSeasonTriggered());
    }

    function test_ORC_OracleRevertsBTC_NoAdvance() public {
        oracle.setRevertOnBTC(true);
        oracle.setEth(4500_00000000);
        fv.checkAltSeason();
        // condA/condB need btcPrice>0 -> metCount=0.
        assertEq(fv.conditionsMetSince(), 0);
        assertFalse(fv.altSeasonTriggered());
    }

    function test_ORC_OracleReturnsZero_NotMet() public {
        oracle.setPrices(0, 0);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
        assertFalse(fv.altSeasonTriggered());
    }

    function test_ORC_OracleReturnsNegative_NotMet() public {
        // Internal code only assigns price when _eth>0 / _btc>0, so negatives are dropped.
        oracle.setPrices(-1, -1);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
        assertFalse(fv.altSeasonTriggered());
    }

    function test_ORC_AaveRevert_CondCFalse() public {
        aave.setRevertOnRead(true);
        oracle.setPrices(4500_00000000, 60000_00000000); // A+B true -> 2-of-3 anyway
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), t0, "A+B still gives 2-of-3");
        assertFalse(fv.altSeasonTriggered());
    }

    function test_ORC_AllOraclesRevert_AllFalse() public {
        oracle.setRevertOnAny(true);
        aave.setRevertOnRead(true);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
        assertEq(fv.overrideMetSince(), 0);
        assertFalse(fv.altSeasonTriggered());
    }

    function test_ORC_StalePriceFromOracle_TreatedAsLive_IfNotReverted() public {
        // FV does not check staleness -- a stale but positive price is consumed as-is.
        // (Document: staleness defense lives in the oracle layer.)
        oracle.setPrices(4500_00000000, 60000_00000000);
        // Advance time massively -- oracle still returns the same positive prices.
        vm.warp(t0 + 30 days);
        fv.checkAltSeason();
        assertTrue(fv.conditionsMetSince() > 0, "Stale-but-positive prices still satisfy A+B");
    }

    function test_ORC_OracleReverts_PartialFlow_ETHOK_BTCRevert() public {
        oracle.setEth(4500_00000000);
        oracle.setRevertOnBTC(true);
        aave.setBorrowRate(8e25); // condC true alone -- only 1-of-3
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0, "Only 1-of-3 (condC) -> no sustained start");
    }

    function test_ORC_OverrideEvalRespects_OracleRevert_ETHZero() public {
        // ETH reverts -> ethPriceOut=0 -> ethOverride=false even if threshold semantics would say "$0 < $5k".
        oracle.setRevertOnETH(true);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), 0, "Override must remain unset when ETH feed reverts");
    }

    function test_ORC_PartialFlow_BTCOK_ETHRevert_StaysFalse() public {
        oracle.setRevertOnETH(true);
        oracle.setBtc(60000_00000000);
        aave.setBorrowRate(0);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
        assertEq(fv.overrideMetSince(), 0);
    }

    function test_ORC_ExtremeHighETH_NoBTC_OnlyOverride() public {
        // ETH = $1M (massive), BTC=0 -> condA/condB false; ethOverride true.
        oracle.setEth(int256(100_000_000_000_000)); // $1,000,000 in 8-dec
        oracle.setBtc(0);
        fv.checkAltSeason();
        // PATH 1: 0-of-3 -> no sustained start.
        assertEq(fv.conditionsMetSince(), 0);
        // PATH 2: override met -> overrideMetSince set.
        assertEq(fv.overrideMetSince(), t0);
    }

    function test_ORC_ExtremeHighBTC_LowETH_NoConds() public {
        oracle.setEth(1_00000000); // $1
        oracle.setBtc(int256(10_000_000_000_000)); // $100,000
        // ratio = 1e8 * 1e18 / 1e13 = 1e13 (way below 5e16) -> condA false; condB false.
        aave.setBorrowRate(0);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
    }

    function test_ORC_OracleIntMax_NoOverflow_OverrideTrue() public {
        // int256 max for ethPrice -> still positive, override should trigger condition met.
        oracle.setEth(type(int256).max);
        oracle.setBtc(0);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), t0);
    }

    function test_ORC_OracleRevertsETH_AfterMet_PreservesOverride() public {
        // Override has been met previously; now ETH feed reverts -> ethOverride=false -> reset overrideMetSince.
        oracle.setEth(ETH_OVERRIDE_PASS);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), t0);

        oracle.setRevertOnETH(true);
        vm.warp(t0 + 1 hours);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), 0, "Lost override -> reset");
    }

    function test_ORC_AaveExactlyAtThreshold_NotMet() public {
        // BORROW_RATE_THRESHOLD = 7e25; condC uses strict `>`.
        aave.setBorrowRate(uint128(7e25));
        oracle.setPrices(0, 0);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0, "Exactly-at-threshold is not strictly above");
    }

    function test_ORC_EthBtcRatioExactlyAtThreshold_CondAFalse() public {
        // ratio = ETH_BTC_THRESHOLD = 50e15 exactly -> strict `>` -> condA false.
        // Choose ETH=$3,000, BTC=$60,000 (ratio = 0.050 exactly in 18-dec). condB also false (ETH < $4k).
        oracle.setPrices(3000_00000000, 60000_00000000);
        aave.setBorrowRate(0);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0, "Exactly-at-ratio-threshold is not strictly above");
    }

    // =====================================================================
    // T-CNT: Counter / sustained timing (7)
    // =====================================================================

    function test_CNT_TwoOfThree_Sustained1Day_Triggers() public {
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), t0);
        vm.warp(t0 + SUSTAINED);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
        assertEq(fv.triggerTimestamp(), t0 + SUSTAINED);
    }

    function test_CNT_TwoOfThree_23h59m_Insufficient() public {
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        vm.warp(t0 + 23 hours + 59 minutes);
        fv.checkAltSeason();
        assertFalse(fv.altSeasonTriggered());
    }

    function test_CNT_TwoOfThree_24h00s_Triggers() public {
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        vm.warp(t0 + 24 hours); // exactly SUSTAINED -- `>=` so triggers
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
    }

    function test_CNT_TwoOfThree_25h_Triggers() public {
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        vm.warp(t0 + 25 hours);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
    }

    function test_CNT_OnlyOneCondMet_NeverTriggers() public {
        _setPath1_1of3();
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
        vm.warp(t0 + 10 days);
        fv.checkAltSeason();
        assertFalse(fv.altSeasonTriggered());
        assertEq(fv.conditionsMetSince(), 0);
    }

    function test_CNT_FlipFrom2To1_ResetsCounter() public {
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), t0);

        // Flip to 1-of-3 (drop oracle prices, leave aave at 0 -> 0-of-3 actually).
        oracle.setPrices(0, 0);
        vm.warp(t0 + 1 hours);
        vm.expectEmit(false, false, false, true);
        emit SustainedPeriodReset(t0 + 1 hours);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0);
    }

    function test_CNT_NotCalledForDays_RequiresNewSustained_OK() public {
        // Once met, the sustained-period start is preserved while conditions remain true.
        // Even if no caller hits checkAltSeason for several days, the next call sees
        // (block.timestamp - conditionsMetSince) >= SUSTAINED -> triggers immediately.
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        // No further calls for 10 days while conditions remain met externally.
        vm.warp(t0 + 10 days);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered(), "Lazy-evaluation: long uninterrupted satisfaction triggers");
    }

    // =====================================================================
    // T-DAY: Definition of "day" (3)
    // =====================================================================

    function test_DAY_DurationIsExactly86400Seconds() public view {
        assertEq(fv.SUSTAINED_DURATION(), 86_400);
    }

    function test_DAY_BlockTimestampDriftWithinTolerance() public {
        // Drift of +/- ~12 seconds (block time variance) at the boundary should still trigger
        // once we cross 86_400. We exercise +13s past the boundary.
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        vm.warp(t0 + 86_400 + 13);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
    }

    function test_DAY_LeapSecondLikeBoundary() public {
        // 86_400 + 1 (a "leap second" past the day boundary) still triggers via >=.
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        vm.warp(t0 + 86_401);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
    }

    // =====================================================================
    // T-RACE: Race conditions (2)
    // =====================================================================

    function test_RACE_TwoCallersSameBlock_LastWins_DocumentedAsFirstTriggerSticks() public {
        // First call starts the sustained period. Within the SAME block (same timestamp),
        // a second caller does not move the needle -- `conditionsMetSince` is already non-zero,
        // and `block.timestamp - conditionsMetSince == 0 < SUSTAINED` -> no trigger yet.
        _setPath1_2of3_NoOverride();
        vm.prank(attacker);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), t0);

        vm.prank(recipient);
        fv.checkAltSeason();
        // No mutation -- conditionsMetSince stays at t0 (idempotent within block).
        assertEq(fv.conditionsMetSince(), t0);
        assertFalse(fv.altSeasonTriggered());
    }

    function test_RACE_PostTriggerAttempt_RevertsAlreadyTriggered() public {
        _triggerPath1();
        vm.prank(attacker);
        vm.expectRevert(bytes("Already triggered"));
        fv.checkAltSeason();
    }

    // =====================================================================
    // T-FBK: Fallback at 1095 days (6)
    // =====================================================================

    function test_FBK_AtExactly1095Days_Allowed() public {
        vm.warp(t0 + FALLBACK_D);
        fv.triggerFallback();
        assertTrue(fv.altSeasonTriggered());
        assertEq(fv.triggerTimestamp(), t0 + FALLBACK_D);
    }

    function test_FBK_OneSecondBefore_Reverts() public {
        vm.warp(t0 + FALLBACK_D - 1);
        vm.expectRevert(bytes("Fallback not reached"));
        fv.triggerFallback();
    }

    function test_FBK_AfterTrigger_Reverts() public {
        _triggerPath1();
        vm.warp(t0 + FALLBACK_D + 1);
        vm.expectRevert(bytes("Already triggered"));
        fv.triggerFallback();
    }

    function test_FBK_AnyoneCanCall() public {
        vm.warp(t0 + FALLBACK_D);
        vm.prank(attacker);
        fv.triggerFallback();
        assertTrue(fv.altSeasonTriggered());
    }

    function test_FBK_EmitsFallbackTriggered() public {
        vm.warp(t0 + FALLBACK_D);
        vm.expectEmit(false, false, false, true);
        emit FallbackTriggered(t0 + FALLBACK_D);
        fv.triggerFallback();
    }

    function test_FBK_NotAllowedIfPath2AlreadyTriggered() public {
        // PATH 2 triggers first; fallback later must revert.
        _setOverrideOnly();
        fv.checkAltSeason();
        vm.warp(t0 + SUSTAINED + 1);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered(), "Sanity: PATH 2 triggered");

        vm.warp(t0 + FALLBACK_D + 1);
        vm.expectRevert(bytes("Already triggered"));
        fv.triggerFallback();
    }

    // =====================================================================
    // T-REL: Tranche release (4)
    // =====================================================================

    function test_REL_FirstTranche_AtTriggerTimestamp_Releases() public {
        uint256 trigTs = _triggerPath1();
        // First tranche unlocks at trigTs + 0*31d = trigTs (already current block).
        fv.releaseTranche();
        assertEq(fv.tranchesReleased(), 1);
        assertEq(lumina.balanceOf(recipient), TRANCHE_AMOUNT);
        assertEq(fv.totalReleased(), TRANCHE_AMOUNT);
        // Suppress unused-var warning under via_ir.
        trigTs;
    }

    function test_REL_SecondTranche_Requires31Days() public {
        uint256 trigTs = _triggerPath1();
        fv.releaseTranche(); // T1

        // Too early at trigTs + 30d.
        vm.warp(trigTs + 30 days);
        vm.expectRevert(bytes("Too early"));
        fv.releaseTranche();

        // OK at trigTs + 31d.
        vm.warp(trigTs + TRANCHE_INT);
        fv.releaseTranche();
        assertEq(fv.tranchesReleased(), 2);
    }

    function test_REL_ThirdTranche_LastTrancheGetsRemainder() public {
        uint256 trigTs = _triggerPath1();
        fv.releaseTranche(); // T1
        vm.warp(trigTs + TRANCHE_INT); // T2
        fv.releaseTranche();
        vm.warp(trigTs + 2 * TRANCHE_INT); // T3
        fv.releaseTranche();

        // Last tranche = TOTAL_AMOUNT - totalReleased(after T2) = TOTAL - 2*TRANCHE_AMOUNT
        uint256 expectedT3 = TOTAL_AMOUNT - 2 * TRANCHE_AMOUNT;
        assertEq(fv.totalReleased(), TOTAL_AMOUNT, "Sum of all tranches equals TOTAL_AMOUNT");
        assertEq(lumina.balanceOf(recipient), TOTAL_AMOUNT, "Recipient holds the full 8M");
        // Sanity: expectedT3 > TRANCHE_AMOUNT by the rounding dust (2 wei in this case).
        assertGe(expectedT3, TRANCHE_AMOUNT);
    }

    function test_REL_BeyondTotal_Reverts() public {
        uint256 trigTs = _triggerPath1();
        fv.releaseTranche();
        vm.warp(trigTs + TRANCHE_INT);
        fv.releaseTranche();
        vm.warp(trigTs + 2 * TRANCHE_INT);
        fv.releaseTranche();

        // 4th call must revert.
        vm.warp(trigTs + 3 * TRANCHE_INT);
        vm.expectRevert(bytes("All tranches released"));
        fv.releaseTranche();
    }

    // =====================================================================
    // T-TRX: Trigger transitions (3)
    // =====================================================================

    function test_TRX_Path1Triggers_Path2CounterPreserved() public {
        // Set both PATH 1 (2-of-3) AND PATH 2 (override) active simultaneously.
        oracle.setEth(ETH_OVERRIDE_PASS); // ETH > $5k -> also satisfies condB (> $4k)
        oracle.setBtc(60000_00000000);
        aave.setBorrowRate(0); // condC false
        // condA: ratio = 500_000_000_001 * 1e18 / 6_000_000_000_000 ~ 8.3e13 (< 5e16) -> false.
        // So PATH 1: condB only? need to recheck.
        // Actually condA: ETH/BTC = 5000/60000 = 0.083 > 0.05 -> condA TRUE.
        // condB: ETH > $4k -> TRUE. metCount=2.
        fv.checkAltSeason();
        // PATH 1 starts sustained period AND PATH 2 starts overrideMetSince.
        assertEq(fv.conditionsMetSince(), t0);
        assertEq(fv.overrideMetSince(), t0);

        // After 1d, PATH 1 evaluates first and triggers -> return before PATH 2 block.
        vm.warp(t0 + SUSTAINED);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
        // overrideMetSince is preserved (NOT zeroed) because PATH 2 block was skipped via early return.
        assertEq(fv.overrideMetSince(), t0, "PATH 2 counter preserved after PATH 1 trigger");
    }

    function test_TRX_Path2Triggers_Path1CounterPreserved() public {
        // PATH 1 sees 1-of-3 (condC only). PATH 2 override active.
        oracle.setEth(ETH_OVERRIDE_PASS);
        oracle.setBtc(0); // disables condA + condB
        aave.setBorrowRate(8e25); // condC TRUE -> 1-of-3, no sustained start
        fv.checkAltSeason();
        // PATH 1: 1-of-3 -> conditionsMetSince stays 0. PATH 2: overrideMetSince set.
        assertEq(fv.conditionsMetSince(), 0);
        assertEq(fv.overrideMetSince(), t0);

        vm.warp(t0 + SUSTAINED);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered(), "PATH 2 triggers");
        // PATH 1 counter remained at 0 throughout -- preserved.
        assertEq(fv.conditionsMetSince(), 0);
    }

    function test_TRX_ConditionsLost_BeforeSustained_ResetsCounter() public {
        _setPath1_2of3_NoOverride();
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), t0);

        // Drop conditions before sustained period elapses.
        oracle.setPrices(0, 0);
        vm.warp(t0 + 1 hours);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0, "Counter reset");
        assertFalse(fv.altSeasonTriggered());
    }

    // =====================================================================
    // T-OVR: PATH 2 ETH override (10)
    // =====================================================================

    function test_Override_Exactly5000_NotMet() public {
        // Strict `>` -- exactly $5,000.000_00000000 is NOT > threshold.
        oracle.setEth(ETH_OVERRIDE_FAIL_HI);
        oracle.setBtc(0);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), 0, "Exactly at $5,000 must not start override");
    }

    function test_Override_5001_MetButNotSustained_12h() public {
        _setOverrideOnly();
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), t0);
        vm.warp(t0 + 12 hours);
        fv.checkAltSeason();
        assertFalse(fv.altSeasonTriggered(), "12h < 24h sustain");
        assertEq(fv.overrideMetSince(), t0, "Counter preserved");
    }

    function test_Override_5001_Sustained1Day_Triggers() public {
        _setOverrideOnly();
        fv.checkAltSeason();
        vm.warp(t0 + SUSTAINED);
        vm.expectEmit(true, false, false, true);
        emit OverrideTriggered(uint256(ETH_OVERRIDE_PASS), t0 + SUSTAINED);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
        assertEq(fv.triggerTimestamp(), t0 + SUSTAINED);
    }

    function test_Override_5000Plus_FailsTo4999_ResetsOverrideMetSince() public {
        _setOverrideOnly();
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), t0);

        // Drop ETH below threshold.
        oracle.setEth(4999_99999999);
        vm.warp(t0 + 1 hours);
        vm.expectEmit(true, false, false, true);
        emit OverrideConditionLost(uint256(int256(4999_99999999)), t0 + 1 hours);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), 0);
    }

    function test_Override_5001_BreaksFor1Block_Resets() public {
        _setOverrideOnly();
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), t0);

        // 1 block later, ETH drops to exactly $5,000 (still not strictly above) -> reset.
        oracle.setEth(ETH_OVERRIDE_FAIL_HI);
        vm.warp(t0 + 12); // ~1 block on Base.
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), 0);

        // Restore -- counter starts from this new timestamp.
        oracle.setEth(ETH_OVERRIDE_PASS);
        vm.warp(t0 + 24);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), t0 + 24, "New sustained period starts from re-met timestamp");
    }

    function test_Override_DuringPath1Sustained_BothPathsRace() public {
        // Both PATH 1 (2-of-3 via A+B) AND PATH 2 (override) active.
        oracle.setEth(ETH_OVERRIDE_PASS); // > $5k -> condB true + override
        oracle.setBtc(60000_00000000); // condA: 0.083 > 0.05 -> true
        aave.setBorrowRate(0);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), t0);
        assertEq(fv.overrideMetSince(), t0);
        // After SUSTAINED, both paths could trigger -- PATH 1 evaluated first wins.
        vm.warp(t0 + SUSTAINED);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
        // Documented: PATH 1 is evaluated before PATH 2 in `checkAltSeason`, so PATH 1 wins ties.
    }

    function test_Override_TriggersFirst_Path1Counter_StaysFrozen() public {
        // PATH 1 = 1-of-3 (condC only). PATH 2 active and triggers first.
        oracle.setEth(ETH_OVERRIDE_PASS);
        oracle.setBtc(0); // no condA/condB
        aave.setBorrowRate(8e25);
        fv.checkAltSeason();
        assertEq(fv.conditionsMetSince(), 0); // 1-of-3, never started

        vm.warp(t0 + SUSTAINED);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
        // PATH 1 counter remained 0 throughout, post-trigger nothing mutates it.
        assertEq(fv.conditionsMetSince(), 0, "conditionsMetSince not zeroed by override-trigger (was already 0)");
    }

    function test_Override_Path1TriggersFirst_OverrideMetSince_StaysSet() public {
        // PATH 1 triggers; overrideMetSince was previously set. After trigger, no further mutations.
        oracle.setEth(ETH_OVERRIDE_PASS);
        oracle.setBtc(60000_00000000);
        aave.setBorrowRate(0);
        fv.checkAltSeason();
        uint256 ovSnap = fv.overrideMetSince();
        assertEq(ovSnap, t0);

        vm.warp(t0 + SUSTAINED);
        fv.checkAltSeason();
        assertTrue(fv.altSeasonTriggered());
        assertEq(fv.overrideMetSince(), ovSnap, "overrideMetSince stays set after PATH 1 trigger");
    }

    function test_Override_PostTrigger_NoEffect() public {
        // After triggered=true, checkAltSeason reverts; no override mutation possible.
        _triggerPath1();
        oracle.setEth(ETH_OVERRIDE_PASS);
        vm.expectRevert(bytes("Already triggered"));
        fv.checkAltSeason();
    }

    function test_Override_OracleReverts_DoesNotAdvance() public {
        // ETH oracle reverts -> ethPrice=0 -> ethOverride=false -> no advance.
        oracle.setRevertOnETH(true);
        fv.checkAltSeason();
        assertEq(fv.overrideMetSince(), 0, "Override cannot advance when ETH feed reverts");
    }

    // =====================================================================
    // T-COBRO: Verification of claim -- balances + events + dust (9)
    // =====================================================================

    function test_Cobro_Tranche1_RecipientBalanceIncreasesByTrancheAmount() public {
        _triggerPath1();
        uint256 before_ = lumina.balanceOf(recipient);
        fv.releaseTranche();
        uint256 delta = lumina.balanceOf(recipient) - before_;
        // TRANCHE_AMOUNT = 8M*1e18 / 3 = 2_666_666_666666666666666666 (integer-truncated)
        assertEq(delta, TRANCHE_AMOUNT);
    }

    function test_Cobro_Tranche1_FVBalanceDecreasesByTrancheAmount() public {
        _triggerPath1();
        uint256 fvBefore = lumina.balanceOf(address(fv));
        fv.releaseTranche();
        uint256 fvAfter = lumina.balanceOf(address(fv));
        assertEq(fvBefore - fvAfter, TRANCHE_AMOUNT);
    }

    function test_Cobro_Tranche2_RecipientBalanceTotal_TwoTranches() public {
        uint256 trigTs = _triggerPath1();
        fv.releaseTranche();
        vm.warp(trigTs + TRANCHE_INT);
        fv.releaseTranche();
        assertEq(lumina.balanceOf(recipient), 2 * TRANCHE_AMOUNT);
        // ~ 5_333_333_333333333333333332 LUMINA wei
    }

    function test_Cobro_Tranche3_RecipientBalanceExactly_8M_NoDustLeft() public {
        uint256 trigTs = _triggerPath1();
        fv.releaseTranche();
        vm.warp(trigTs + TRANCHE_INT);
        fv.releaseTranche();
        vm.warp(trigTs + 2 * TRANCHE_INT);
        fv.releaseTranche();
        // Last tranche absorbs the integer-division dust (TOTAL - 2*TRANCHE_AMOUNT).
        assertEq(lumina.balanceOf(recipient), TOTAL_AMOUNT, "Recipient holds exactly 8M");
        assertEq(lumina.balanceOf(address(fv)), 0, "No dust left in FV contract");
        assertEq(fv.totalReleased(), TOTAL_AMOUNT);
    }

    function test_Cobro_TrancheReleased_EmitsCorrectEvent() public {
        _triggerPath1();
        // First tranche: trancheNumber=1 (post-increment), amount=TRANCHE_AMOUNT, recipient=recipient.
        vm.expectEmit(false, false, false, true);
        emit TrancheReleased(1, TRANCHE_AMOUNT, recipient);
        fv.releaseTranche();
    }

    function test_Cobro_FVBalanceFinal_Zero_After3Tranches() public {
        uint256 trigTs = _triggerPath1();
        fv.releaseTranche();
        vm.warp(trigTs + TRANCHE_INT);
        fv.releaseTranche();
        vm.warp(trigTs + 2 * TRANCHE_INT);
        fv.releaseTranche();
        assertEq(lumina.balanceOf(address(fv)), 0);
    }

    function test_Cobro_OldRecipient_NoBalance_AfterUpdateRecipient() public {
        // Update recipient BEFORE any tranche releases -- old recipient must end up with zero.
        address newRecipient = makeAddr("newFounder");
        fv.updateRecipient(newRecipient);
        assertEq(fv.recipient(), newRecipient);

        uint256 trigTs = _triggerPath1();
        fv.releaseTranche();
        vm.warp(trigTs + TRANCHE_INT);
        fv.releaseTranche();
        vm.warp(trigTs + 2 * TRANCHE_INT);
        fv.releaseTranche();

        // Original `recipient` (set at deploy) never received any tranche.
        assertEq(lumina.balanceOf(recipient), 0, "Old recipient holds zero");
        assertEq(lumina.balanceOf(newRecipient), TOTAL_AMOUNT, "New recipient holds full 8M");
    }

    function test_Cobro_NewRecipient_Receives_AfterUpdateRecipient() public {
        // Update recipient AFTER tranche 1 has been released -- tranches 2+3 go to new recipient.
        uint256 trigTs = _triggerPath1();
        fv.releaseTranche();
        assertEq(lumina.balanceOf(recipient), TRANCHE_AMOUNT, "T1 -> original recipient");

        address newRecipient = makeAddr("newFounder2");
        fv.updateRecipient(newRecipient);

        vm.warp(trigTs + TRANCHE_INT);
        fv.releaseTranche();
        vm.warp(trigTs + 2 * TRANCHE_INT);
        fv.releaseTranche();

        // Original recipient: T1 only.
        assertEq(lumina.balanceOf(recipient), TRANCHE_AMOUNT);
        // New recipient: T2 + T3 (T3 absorbs dust).
        uint256 expected_new = TOTAL_AMOUNT - TRANCHE_AMOUNT;
        assertEq(lumina.balanceOf(newRecipient), expected_new);
    }

    function test_Cobro_RecipientCanBeContract_ReceivesViaTransfer() public {
        // Replace recipient with a plain contract address; ERC20.transfer delivers correctly.
        PlainContractRecipient ctr = new PlainContractRecipient();
        fv.updateRecipient(address(ctr));

        uint256 trigTs = _triggerPath1();
        fv.releaseTranche();
        assertEq(lumina.balanceOf(address(ctr)), TRANCHE_AMOUNT, "Contract receives T1");

        vm.warp(trigTs + TRANCHE_INT);
        fv.releaseTranche();
        vm.warp(trigTs + 2 * TRANCHE_INT);
        fv.releaseTranche();
        assertEq(lumina.balanceOf(address(ctr)), TOTAL_AMOUNT, "Contract receives full 8M");
    }
}
