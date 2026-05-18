// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {RateShockShield, IAaveV3Pool} from "../../../src/products/RateShockShield.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {MockAavePool} from "../../../src/mocks/MockAavePool.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// +============================================================================+
// | Sprint EE -- Phase C: 60 edge-case tests for RateShockShield                |
// |                                                                            |
// | Groups (60 total):                                                         |
// |   T-AAVE  x12  Aave edge cases (revert, zero rate, >100 percent, etc.)     |
// |   T-WIN   x10  7-day window timing                                         |
// |   T-RATE  x10  Borrow-rate logic (exactly at threshold, spike+recover)     |
// |   T-SEQ   x6   Sequencer downtime on Base L2 affecting Aave reads          |
// |   T-PAY   x8   Payout semantics (80 percent of coverage, 20 percent ded.)  |
// |   T-PEM   x6   Premium semantics                                           |
// |   T-RAC   x8   Race conditions                                             |
// |                                                                            |
// | NOTE on warp: foundry.toml has via_ir=true; per memory                     |
// | `foundry_via_ir_warp.md`, `vm.warp(block.timestamp + delta)` caches the    |
// | initial block.timestamp under via_ir. We anchor warps to `t0` captured at  |
// | setUp() and always pass absolute timestamps.                               |
// |                                                                            |
// | RateShockShield specifics:                                                 |
// |   * Covered asset: USDC (bytes32 "USDC")                                   |
// |   * Trigger: Aave V3 USDC `currentVariableBorrowRate` > 10e25 (10 percent  |
// |              APY in RAY, 27 decimals)                                      |
// |   * Duration: fixed 7 days (604800 s), no waiting period                   |
// |   * Payout: 80 percent of coverage (20 percent deductible)                 |
// |   * NO oracle proof -- on-chain Aave read only                             |
// +============================================================================+

// -----------------------------------------------------------------------------
// Mocks
// -----------------------------------------------------------------------------

/// @notice Mock IOracle. RateShock does NOT use price reads, but BaseShield's
///         _validateStatusForTrigger calls oracle.getSequencerDowntime, and
///         __BaseShield_init rejects zero oracle.
contract MockOracleForShield is IOracle {
    address public authorizedKey;
    uint256 public sequencerDowntime;

    constructor() {
        authorizedKey = address(this);
    }

    function setSequencerDowntime(uint256 d) external {
        sequencerDowntime = d;
    }

    function getLatestPrice(bytes32) external pure returns (int256) {
        return 0;
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return sequencerDowntime;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function oracleKey() external view returns (address) {
        return authorizedKey;
    }
}

/// @notice Adversarial Aave mock that lets a test arbitrarily replace the full
///         ReserveData struct (sentinel rates, garbage timestamps, etc.).
contract MockAaveAdversarial {
    bool public shouldRevert;
    IAaveV3Pool.ReserveData internal _data;

    error AaveDown();

    function setReserveData(IAaveV3Pool.ReserveData calldata d) external {
        _data = d;
    }

    function setVariableBorrowRate(uint128 r) external {
        _data.currentVariableBorrowRate = r;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function getReserveData(address) external view returns (IAaveV3Pool.ReserveData memory) {
        if (shouldRevert) revert AaveDown();
        return _data;
    }
}

// -----------------------------------------------------------------------------
// Test Harness
// -----------------------------------------------------------------------------

contract RateShockShieldEdgeCases is Test {
    // Re-declared events for vm.expectEmit (solc 0.8.20 cross-contract emit
    // requires re-declaration in the test contract's scope).
    event PolicyCreated(
        uint256 indexed policyId,
        address indexed buyer,
        uint256 coverageAmount,
        uint256 premiumPaid,
        uint32 durationSeconds,
        uint256 waitingEndsAt,
        uint256 expiresAt
    );
    event PolicyPaidOut(uint256 indexed policyId, address indexed recipient, uint256 payoutAmount, bytes32 reason);
    event PolicyExpired(uint256 indexed policyId);
    event PolicySettledTriggered(uint256 indexed policyId, address indexed buyer, uint256 maxPayout);
    event PolicySettledExpired(uint256 indexed policyId);
    event AavePoolUpdated(address indexed oldPool, address indexed newPool);

    RateShockShield shield;
    MockAavePool aave; // friendly mock
    MockOracleForShield oracle;

    address router; // routerEOA -- BaseShield.onlyRouter
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");
    address usdc = makeAddr("usdc");

    uint256 t0;

    // Mirror constants for readability
    uint256 constant DURATION = 604800; // 7 days
    uint256 constant WAITING = 0;
    uint256 constant DEDUCTIBLE_BPS = 2000;
    uint256 constant BPS_DENOM = 10_000;
    uint256 constant TRIGGER_RATE = 10e25; // 10 percent APY in RAY
    uint256 constant MIN_COVERAGE = 100e6; // 100 USDC (6-dec) from BaseShield._minCoverage

    function setUp() public {
        vm.warp(1_700_000_000);
        t0 = block.timestamp;

        router = makeAddr("router");
        oracle = new MockOracleForShield();
        aave = new MockAavePool();

        shield = ProxyDeployer.deployRateShockShield(router, address(oracle), address(aave), usdc);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _defaultParams(uint256 coverage) internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = coverage;
        p.premiumAmount = coverage / 10; // 10 percent arbitrary
        p.durationSeconds = uint32(DURATION);
        p.asset = "USDC";
        p.stablecoin = "USDC";
        p.protocol = address(0);
        p.extraData = "";
    }

    function _createDefault() internal returns (uint256 policyId) {
        vm.prank(router);
        policyId = shield.createPolicy(_defaultParams(MIN_COVERAGE));
    }

    function _setRateBps(uint256 bps) internal {
        aave.setBorrowRate(usdc, bps);
    }

    /// @dev Adversarial helper: swap in a controllable Aave mock and return it.
    function _swapInAdversarial() internal returns (MockAaveAdversarial adv) {
        adv = new MockAaveAdversarial();
        shield.setAavePool(address(adv));
    }

    // =====================================================================
    // T-AAVE: Aave edge cases (12)
    // =====================================================================

    function test_AAVE_PoolReverts_TriggerCheckBubbles() public {
        uint256 pid = _createDefault();
        aave.setRevert(true);
        // checkAndSettlePolicy reads aave inside _checkTriggerCondition.
        vm.warp(t0 + DURATION + 24 hours + 1);
        vm.expectRevert(MockAavePool.RevertSimulated.selector);
        shield.checkAndSettlePolicy(pid);
    }

    function test_AAVE_PoolReverts_VerifyAndCalculateBubbles() public {
        uint256 pid = _createDefault();
        aave.setRevert(true);
        // Inside coverage window, verifyAndCalculate reads aave and aave reverts.
        vm.warp(t0 + 1 hours);
        vm.prank(router);
        vm.expectRevert(MockAavePool.RevertSimulated.selector);
        shield.verifyAndCalculate(pid, "");
    }

    function test_AAVE_ReturnsZero_NoTrigger() public {
        uint256 pid = _createDefault();
        // Default rate is zero -- ensure no trigger.
        assertEq(aave.variableBorrowRateOf(usdc), 0);
        vm.warp(t0 + 1 hours);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(RateShockShield.RateBelowTrigger.selector, uint256(0)));
        shield.verifyAndCalculate(pid, "");
    }

    function test_AAVE_ReturnsHugeRate_StillTriggers() public {
        // Aave reports an absurdly high rate (e.g. 500 percent APY). Still triggers.
        uint256 pid = _createDefault();
        _setRateBps(50_000); // 500 percent
        vm.warp(t0 + 1 hours);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
        assertEq(r.reason, bytes32("RATESHOCK_AAVE_USDC_ABOVE_10"));
    }

    function test_AAVE_ReturnsMaxUint128_StillTriggers() public {
        // Push raw struct so we bypass the BPS overflow check.
        MockAaveAdversarial adv = _swapInAdversarial();
        IAaveV3Pool.ReserveData memory d;
        d.currentVariableBorrowRate = type(uint128).max;
        adv.setReserveData(d);

        uint256 pid = _createDefault();
        vm.warp(t0 + 1 hours);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_AAVE_ReserveDisabled_ReturnsZeroData_NoTrigger() public {
        // Disabled reserve == zero-initialized ReserveData.
        MockAaveAdversarial adv = _swapInAdversarial();
        IAaveV3Pool.ReserveData memory d;
        adv.setReserveData(d);

        uint256 pid = _createDefault();
        vm.warp(t0 + 1 hours);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(RateShockShield.RateBelowTrigger.selector, uint256(0)));
        shield.verifyAndCalculate(pid, "");
    }

    function test_AAVE_StaleTimestamp_StillReadsRate() public {
        // RateShockShield does NOT check lastUpdateTimestamp. Stale data still triggers.
        _setRateBps(1500); // 15 percent
        aave.setStale(true);
        uint256 pid = _createDefault();
        vm.warp(t0 + 1 hours);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_AAVE_setAavePool_ZeroReverts() public {
        vm.expectRevert(bytes("Zero aavePool"));
        shield.setAavePool(address(0));
    }

    function test_AAVE_setAavePool_OnlyOwner() public {
        MockAavePool other = new MockAavePool();
        vm.prank(attacker);
        // OZ Ownable revert (custom error in 5.x)
        vm.expectRevert();
        shield.setAavePool(address(other));
    }

    function test_AAVE_setAavePool_EmitsAndUpdates() public {
        MockAavePool other = new MockAavePool();
        vm.expectEmit(true, true, false, false, address(shield));
        emit AavePoolUpdated(address(aave), address(other));
        shield.setAavePool(address(other));
        assertEq(address(shield.aavePool()), address(other));
    }

    function test_AAVE_setAavePool_RoutesNewReads() public {
        // After rotation, currentBorrowRate must consult the new pool.
        MockAavePool other = new MockAavePool();
        other.setBorrowRate(usdc, 1500); // 15 percent
        shield.setAavePool(address(other));
        assertEq(shield.currentBorrowRate(), uint256(1500) * 1e23);
    }

    function test_AAVE_currentBorrowRate_ViewMatches() public {
        _setRateBps(700);
        assertEq(shield.currentBorrowRate(), uint256(700) * 1e23);
    }

    // =====================================================================
    // T-WIN: 7-day window timing (10)
    // =====================================================================

    function test_WIN_TriggerAtT0_NotWaiting_BecauseWaitingZero() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        // Block.timestamp == t0 == waitingEndsAt. _doVerifyAndCalculate guards
        // `block.timestamp < waitingEndsAt` -- equal is OK.
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_WIN_TriggerAt1SecondBeforeExpiry_OK() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.warp(t0 + DURATION - 1);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_WIN_TriggerAtExactExpiry_OK() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        // block.timestamp == expiresAt. Guard is `> expiresAt`, so equal passes.
        vm.warp(t0 + DURATION);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_WIN_TriggerAfterExpiry_RevertsEventAfterExpiry() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.warp(t0 + DURATION + 1);
        vm.prank(router);
        // BaseShield.verifyAndCalculate runs _computeStatus first; at +1s past
        // expiresAt + cleanupAt=expiresAt+24h, status is still ACTIVE/EXPIRED OK,
        // but the *cleanup* hasn't passed, so _validateStatusForTrigger is OK and
        // we reach _doVerifyAndCalculate, which reverts with EventAfterExpiry.
        vm.expectRevert(
            abi.encodeWithSelector(BaseShield.EventAfterExpiry.selector, pid, t0 + DURATION + 1, t0 + DURATION)
        );
        shield.verifyAndCalculate(pid, "");
    }

    function test_WIN_TriggerLongAfterCleanup_RevertsInvalidStatus() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        // expiresAt + 24h (CLAIM_GRACE_PERIOD) -- _validateStatusForTrigger reverts.
        vm.warp(t0 + DURATION + 24 hours + 1);
        vm.prank(router);
        vm.expectRevert(); // InvalidPolicyStatus(EXPIRED, ACTIVE)
        shield.verifyAndCalculate(pid, "");
    }

    function test_WIN_PolicyDurationIsExactly7Days() public {
        uint256 pid = _createDefault();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.expiresAt - info.startTimestamp, DURATION);
    }

    function test_WIN_MultiplePolicies_IndependentTimings() public {
        uint256 pid1 = _createDefault();
        // Advance + create another -- expiresAt offsets differ by the warp delta.
        vm.warp(t0 + 1 days);
        uint256 pid2 = _createDefault();

        IShield.PolicyInfo memory i1 = shield.getPolicyInfo(pid1);
        IShield.PolicyInfo memory i2 = shield.getPolicyInfo(pid2);

        assertEq(i1.startTimestamp, t0);
        assertEq(i2.startTimestamp, t0 + 1 days);
        assertEq(i2.expiresAt - i1.expiresAt, 1 days);
    }

    function test_WIN_DurationOutsideRange_Reverts() public {
        IShield.CreatePolicyParams memory p = _defaultParams(MIN_COVERAGE);
        p.durationSeconds = uint32(DURATION - 1);
        uint32 minD = uint32(DURATION);
        uint32 maxD = uint32(DURATION);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IShield.DurationOutOfRange.selector, p.durationSeconds, minD, maxD));
        shield.createPolicy(p);
    }

    function test_WIN_DurationOver_Reverts() public {
        IShield.CreatePolicyParams memory p = _defaultParams(MIN_COVERAGE);
        p.durationSeconds = uint32(DURATION + 1);
        uint32 minD = uint32(DURATION);
        uint32 maxD = uint32(DURATION);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IShield.DurationOutOfRange.selector, p.durationSeconds, minD, maxD));
        shield.createPolicy(p);
    }

    function test_WIN_WaitingPeriodIsZero() public view {
        assertEq(shield.waitingPeriod(), 0);
    }

    // =====================================================================
    // T-RATE: Borrow-rate logic (10)
    // =====================================================================

    function test_RATE_ExactlyAtThreshold_NoTrigger() public {
        // 1000 BPS -> 10e25 == TRIGGER_RATE. Guard is strict `>`.
        uint256 pid = _createDefault();
        _setRateBps(1000);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(RateShockShield.RateBelowTrigger.selector, TRIGGER_RATE));
        shield.verifyAndCalculate(pid, "");
    }

    function test_RATE_JustBelow_NoTrigger() public {
        // 999 BPS = 9.99 percent -> 9.99e25 (< TRIGGER_RATE)
        uint256 pid = _createDefault();
        _setRateBps(999);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(RateShockShield.RateBelowTrigger.selector, uint256(999) * 1e23));
        shield.verifyAndCalculate(pid, "");
    }

    function test_RATE_JustAbove_Triggers() public {
        // 1001 BPS = 10.01 percent
        uint256 pid = _createDefault();
        _setRateBps(1001);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_RATE_AtOneOverThresholdWei_Triggers() public {
        // TRIGGER_RATE + 1 wei -- minimum delta to trigger.
        MockAaveAdversarial adv = _swapInAdversarial();
        IAaveV3Pool.ReserveData memory d;
        d.currentVariableBorrowRate = uint128(TRIGGER_RATE + 1);
        adv.setReserveData(d);

        uint256 pid = _createDefault();
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_RATE_SpikeThenRecover_NoTriggerOnLowSnapshot() public {
        uint256 pid = _createDefault();
        _setRateBps(1500); // 15 percent first
        // ... but recover BEFORE the call
        _setRateBps(500); // 5 percent now
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(RateShockShield.RateBelowTrigger.selector, uint256(500) * 1e23));
        shield.verifyAndCalculate(pid, "");
    }

    function test_RATE_LowThenSpike_TriggersOnHighSnapshot() public {
        uint256 pid = _createDefault();
        _setRateBps(500); // 5 percent
        // Spike right before check
        _setRateBps(1500); // 15 percent
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_RATE_CheckTriggerCondition_ReturnsTrueWhenAbove() public {
        _setRateBps(1500);
        // _checkTriggerCondition is internal; expose via settlement after expiry.
        uint256 pid = _createDefault();
        vm.warp(t0 + DURATION + 24 hours + 1);
        // Settlement is permissionless.
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    function test_RATE_CheckTriggerCondition_ReturnsFalseWhenBelow() public {
        _setRateBps(500);
        uint256 pid = _createDefault();
        vm.warp(t0 + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    function test_RATE_TriggerRateConstantValue() public view {
        assertEq(shield.TRIGGER_RATE(), 10e25);
    }

    function test_RATE_RateCanBeReadBeforeAndAfterPolicy() public {
        // currentBorrowRate is policy-agnostic.
        assertEq(shield.currentBorrowRate(), 0);
        _setRateBps(700);
        assertEq(shield.currentBorrowRate(), uint256(700) * 1e23);
        _createDefault();
        assertEq(shield.currentBorrowRate(), uint256(700) * 1e23);
    }

    // =====================================================================
    // T-SEQ: Sequencer downtime on Base L2 (6)
    // =====================================================================

    function test_SEQ_DowntimeZero_VerifyOK() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        oracle.setSequencerDowntime(0);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_SEQ_DowntimeExtendsCleanup() public {
        // At expiresAt + 25h, status is normally EXPIRED past cleanup. With
        // 2h downtime, cleanupAt = expiresAt+24h+2h = expiresAt+26h, so 25h still ACTIVE/EXPIRED ok.
        uint256 pid = _createDefault();
        _setRateBps(1500);
        oracle.setSequencerDowntime(2 hours);
        vm.warp(t0 + DURATION + 25 hours);
        vm.prank(router);
        // Reaches _doVerifyAndCalculate, which checks `block.timestamp > expiresAt`
        // -> reverts EventAfterExpiry (NOT InvalidPolicyStatus -- proving downtime extension).
        vm.expectRevert(
            abi.encodeWithSelector(BaseShield.EventAfterExpiry.selector, pid, t0 + DURATION + 25 hours, t0 + DURATION)
        );
        shield.verifyAndCalculate(pid, "");
    }

    function test_SEQ_DowntimeDoesNotCoverGap_RevertsInvalidStatus() public {
        // 1h downtime, 25h past expiry -> cleanupAt+downtime = 25h, exactly tripwire.
        uint256 pid = _createDefault();
        _setRateBps(1500);
        oracle.setSequencerDowntime(1 hours);
        vm.warp(t0 + DURATION + 25 hours + 1);
        vm.prank(router);
        // _validateStatusForTrigger reverts InvalidPolicyStatus(EXPIRED, ACTIVE).
        vm.expectRevert();
        shield.verifyAndCalculate(pid, "");
    }

    function test_SEQ_DowntimeLargerThanGap_VerifyReachesAaveRevert() public {
        // 48h downtime, 30h past expiry, set aave to revert -- proves we got past
        // the status check (which would have happened first if downtime=0).
        uint256 pid = _createDefault();
        oracle.setSequencerDowntime(48 hours);
        aave.setRevert(true);
        vm.warp(t0 + DURATION + 30 hours);
        vm.prank(router);
        // Status guard passes (cleanupAt extended). Then _doVerifyAndCalculate
        // checks `block.timestamp > expiresAt` -> EventAfterExpiry before reading aave.
        // Outcome: EventAfterExpiry, not RevertSimulated.
        vm.expectRevert(
            abi.encodeWithSelector(BaseShield.EventAfterExpiry.selector, pid, t0 + DURATION + 30 hours, t0 + DURATION)
        );
        shield.verifyAndCalculate(pid, "");
    }

    function test_SEQ_DowntimeIgnoredForCheckAndSettle() public {
        // checkAndSettlePolicy uses only SAFETY_WINDOW=24h, not downtime.
        uint256 pid = _createDefault();
        _setRateBps(1500);
        oracle.setSequencerDowntime(99 days); // huge downtime irrelevant for settle
        vm.warp(t0 + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    function test_SEQ_DowntimeBeforeSafetyWindow_CheckAndSettleStillReverts() public {
        // Within SAFETY_WINDOW (24h) post-expiry, checkAndSettle rejects regardless
        // of downtime.
        uint256 pid = _createDefault();
        _setRateBps(1500);
        oracle.setSequencerDowntime(48 hours);
        vm.warp(t0 + DURATION + 23 hours);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseShield.SafetyWindowNotPassed.selector, pid, t0 + DURATION + 24 hours, t0 + DURATION + 23 hours
            )
        );
        shield.checkAndSettlePolicy(pid);
    }

    // =====================================================================
    // T-PAY: Payout semantics (8)
    // =====================================================================

    function test_PAY_MaxPayoutIs80PercentOfCoverage() public {
        uint256 coverage = 1_000e6; // 1k USDC
        IShield.CreatePolicyParams memory p = _defaultParams(coverage);
        vm.prank(router);
        uint256 pid = shield.createPolicy(p);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, (coverage * 8000) / 10000);
    }

    function test_PAY_PayoutCappedAtMaxPayout() public {
        // Even if BaseShield's result.payoutAmount somehow exceeded maxPayout,
        // BaseShield clamps it. RateShockShield returns exactly cp.maxPayout.
        uint256 coverage = 5_000e6;
        IShield.CreatePolicyParams memory p = _defaultParams(coverage);
        vm.prank(router);
        uint256 pid = shield.createPolicy(p);
        _setRateBps(1500);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(r.payoutAmount, info.maxPayout);
    }

    function test_PAY_RecipientIsBuyer() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertEq(r.recipient, buyer);
    }

    function test_PAY_PaidOutStatus_TransitionsCorrectly() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.startPrank(router);
        shield.verifyAndCalculate(pid, "");
        // BaseShield.markPaidOut finalizes status.
        vm.expectEmit(true, true, false, true, address(shield));
        emit PolicyPaidOut(pid, buyer, shield.getPolicyInfo(pid).maxPayout, bytes32("PAID_OUT"));
        shield.markPaidOut(pid);
        vm.stopPrank();
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    function test_PAY_ExpiredStatus_TransitionsCorrectly() public {
        uint256 pid = _createDefault();
        // Don't trigger; mark expired after warp past expiry+cleanup.
        vm.warp(t0 + DURATION + 24 hours + 1);
        vm.prank(router);
        vm.expectEmit(true, false, false, false, address(shield));
        emit PolicyExpired(pid);
        shield.markExpired(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    function test_PAY_DoubleSettle_Reverts() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.warp(t0 + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        vm.expectRevert();
        shield.checkAndSettlePolicy(pid);
    }

    function test_PAY_ZeroCoverage_BelowMin_Reverts() public {
        IShield.CreatePolicyParams memory p = _defaultParams(0);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(IShield.CoverageOutOfRange.selector, 0, MIN_COVERAGE, type(uint256).max));
        shield.createPolicy(p);
    }

    function test_PAY_ActiveCoverageAccountedAndReleased() public {
        uint256 coverage = 1_000e6;
        IShield.CreatePolicyParams memory p = _defaultParams(coverage);
        vm.prank(router);
        uint256 pid = shield.createPolicy(p);
        assertEq(shield.totalActiveCoverage(), coverage);
        assertEq(shield.activePolicies(), 1);
        _setRateBps(1500);
        vm.warp(t0 + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        assertEq(shield.totalActiveCoverage(), 0);
        assertEq(shield.activePolicies(), 0);
    }

    // =====================================================================
    // T-PEM: Premium semantics (6)
    // =====================================================================

    function test_PEM_PremiumStoredAsProvided() public {
        IShield.CreatePolicyParams memory p = _defaultParams(MIN_COVERAGE);
        p.premiumAmount = 12_345_678; // arbitrary
        vm.prank(router);
        uint256 pid = shield.createPolicy(p);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.premiumPaid, 12_345_678);
    }

    function test_PEM_PremiumZero_IsAllowed_AtShieldLevel() public {
        // BaseShield does not validate premium > 0; that's a router-side concern.
        IShield.CreatePolicyParams memory p = _defaultParams(MIN_COVERAGE);
        p.premiumAmount = 0;
        vm.prank(router);
        uint256 pid = shield.createPolicy(p);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.premiumPaid, 0);
    }

    function test_PEM_PremiumDoesNotAffectMaxPayout() public {
        // Two policies, same coverage, different premium -> same maxPayout.
        IShield.CreatePolicyParams memory p1 = _defaultParams(MIN_COVERAGE);
        IShield.CreatePolicyParams memory p2 = _defaultParams(MIN_COVERAGE);
        p1.premiumAmount = 10;
        p2.premiumAmount = 1_000_000;
        vm.prank(router);
        uint256 pid1 = shield.createPolicy(p1);
        vm.prank(router);
        uint256 pid2 = shield.createPolicy(p2);
        IShield.PolicyInfo memory i1 = shield.getPolicyInfo(pid1);
        IShield.PolicyInfo memory i2 = shield.getPolicyInfo(pid2);
        assertEq(i1.maxPayout, i2.maxPayout);
    }

    function test_PEM_PremiumIndependentOfCoverage() public {
        IShield.CreatePolicyParams memory p = _defaultParams(2_500e6);
        p.premiumAmount = 1; // tiny
        vm.prank(router);
        uint256 pid = shield.createPolicy(p);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.premiumPaid, 1);
        assertEq(info.coverageAmount, 2_500e6);
    }

    function test_PEM_PremiumIsNotPartOfPayout() public {
        IShield.CreatePolicyParams memory p = _defaultParams(1_000e6);
        p.premiumAmount = 999_999; // big premium -- ignored in payout calc
        vm.prank(router);
        uint256 pid = shield.createPolicy(p);
        _setRateBps(1500);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        // Payout is 80 percent of coverage, premium-agnostic.
        assertEq(r.payoutAmount, (uint256(1_000e6) * 8000) / 10000);
    }

    function test_PEM_PremiumPaidPreservedAfterSettle() public {
        IShield.CreatePolicyParams memory p = _defaultParams(MIN_COVERAGE);
        p.premiumAmount = 777;
        vm.prank(router);
        uint256 pid = shield.createPolicy(p);
        _setRateBps(1500);
        vm.warp(t0 + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.premiumPaid, 777, "premium preserved post-settle");
    }

    // =====================================================================
    // T-RAC: Race conditions (8)
    // =====================================================================

    function test_RAC_OnlyRouter_CanCreate() public {
        IShield.CreatePolicyParams memory p = _defaultParams(MIN_COVERAGE);
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.createPolicy(p);
    }

    function test_RAC_OnlyRouter_CanVerify() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.verifyAndCalculate(pid, "");
    }

    function test_RAC_OnlyRouter_CanMarkPaidOut() public {
        uint256 pid = _createDefault();
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markPaidOut(pid);
    }

    function test_RAC_CheckAndSettleIsPermissionless() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.warp(t0 + DURATION + 24 hours + 1);
        // Anyone can call.
        vm.prank(attacker);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    function test_RAC_RotateAavePoolMidPolicy_NewRatesApply() public {
        uint256 pid = _createDefault();
        // Original aave reports 5 percent.
        _setRateBps(500);
        // Rotate to a new pool that reports 15 percent.
        MockAavePool other = new MockAavePool();
        other.setBorrowRate(usdc, 1500);
        shield.setAavePool(address(other));
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    function test_RAC_VerifyAfterMarkPaidOut_Reverts() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.startPrank(router);
        shield.verifyAndCalculate(pid, "");
        shield.markPaidOut(pid);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, "");
        vm.stopPrank();
    }

    function test_RAC_VerifyAfterMarkExpired_Reverts() public {
        uint256 pid = _createDefault();
        vm.warp(t0 + DURATION + 24 hours + 1);
        vm.startPrank(router);
        shield.markExpired(pid);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, "");
        vm.stopPrank();
    }

    function test_RAC_CheckAndSettle_WhenAlreadyFinalized_Reverts() public {
        uint256 pid = _createDefault();
        _setRateBps(1500);
        vm.warp(t0 + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        // Second call -> revert (finalized).
        vm.expectRevert();
        shield.checkAndSettlePolicy(pid);
    }
}
