// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield1h} from "../../../src/products/FlashETHShield1h.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashETHShield1hEdgeCases
/// @notice Sprint EE Phase C -- 60 unit edge cases for FlashETHShield1h (ETH, 1h, 7% drop).
///         Categories:
///           T-ORC (12) Oracle plumbing / sanity bounds at create + at verify
///           T-WIN (10) Window: waitingEndsAt / expiresAt / safety / boundary
///           T-PRC (10) Trigger pricing: strict-less-than / equality / rounding
///           T-SEQ  (6) Sequencer downtime adjustments
///           T-PAY  (8) Payout / deductible / max coverage
///           T-PEM  (6) Permissions: onlyRouter / onlyOwner / initializer
///           T-RAC  (8) Races / re-entry / status-machine guards
///
///         Uses an in-test MockOracleEE that satisfies both IOracle and the
///         IOracleV2 EIP-712 surface used by BaseShield._verifyPriceProofEIP712.
///         Signatures are accepted/rejected via a single boolean flag.
contract FlashETHShield1hEdgeCases is Test {
    // ===== Constants mirroring FlashETHShield1h =====
    uint256 internal constant ETH_OK = 4_000e8; // mid-range price in 8-dec
    uint256 internal constant ETH_MIN = 500e8;
    uint256 internal constant ETH_MAX = 50_000e8;
    uint32 internal constant DURATION = 3600;
    uint256 internal constant MAX_PROOF_AGE = 900;
    uint256 internal constant DEDUCTIBLE_BPS = 2000;
    uint256 internal constant TRIGGER_DROP_BPS = 700;
    uint256 internal constant BPS = 10_000;

    FlashETHShield1h internal shield;
    MockOracleEE internal oracle;
    address internal router; // address(this) acts as router
    address internal buyer = makeAddr("buyer");

    // ===== Mirrored events =====
    event PolicyCreated(
        uint256 indexed policyId,
        address indexed buyer,
        uint256 coverageAmount,
        uint256 premiumPaid,
        uint32 durationSeconds,
        uint256 waitingEndsAt,
        uint256 expiresAt
    );
    event OracleRotated(address indexed oldOracle, address indexed newOracle);

    function setUp() public {
        vm.chainId(8453);
        router = address(this);
        oracle = new MockOracleEE();
        oracle.setPrice("ETH", int256(ETH_OK));
        shield = ProxyDeployer.deployFlashETHShield1h(router, address(oracle));
    }

    // ===== Helpers =====
    function _params(bytes32 asset, uint32 d, uint256 cov) internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = cov;
        p.premiumAmount = 10e6;
        p.durationSeconds = d;
        p.asset = asset;
    }

    function _defaultParams() internal view returns (IShield.CreatePolicyParams memory) {
        return _params("ETH", DURATION, 1_000e6);
    }

    function _create() internal returns (uint256) {
        return shield.createPolicy(_defaultParams());
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes("sig"));
    }

    // ============================================================
    // T-ORC -- Oracle plumbing / sanity bounds (12)
    // ============================================================

    function test_ORC_01_CreateRevertsOnZeroPrice() public {
        oracle.setPrice("ETH", 0);
        vm.expectRevert(FlashETHShield1h.InvalidOracleProof.selector);
        shield.createPolicy(_defaultParams());
    }

    function test_ORC_02_CreateRevertsOnNegativePrice() public {
        oracle.setPrice("ETH", -1);
        vm.expectRevert(FlashETHShield1h.InvalidOracleProof.selector);
        shield.createPolicy(_defaultParams());
    }

    function test_ORC_03_CreateRevertsOnPriceBelowMin() public {
        oracle.setPrice("ETH", int256(ETH_MIN) - 1);
        vm.expectRevert();
        shield.createPolicy(_defaultParams());
    }

    function test_ORC_04_CreateAcceptsPriceAtMinBoundary() public {
        oracle.setPrice("ETH", int256(ETH_MIN));
        uint256 pid = shield.createPolicy(_defaultParams());
        assertEq(shield.getBSSData(pid).strikePrice, int256(ETH_MIN));
    }

    function test_ORC_05_CreateAcceptsPriceAtMaxBoundary() public {
        oracle.setPrice("ETH", int256(ETH_MAX));
        uint256 pid = shield.createPolicy(_defaultParams());
        assertEq(shield.getBSSData(pid).strikePrice, int256(ETH_MAX));
    }

    function test_ORC_06_CreateRevertsOnePriceAboveMax() public {
        oracle.setPrice("ETH", int256(ETH_MAX) + 1);
        vm.expectRevert();
        shield.createPolicy(_defaultParams());
    }

    function test_ORC_07_CreateRevertsOnExtremePrice100x() public {
        oracle.setPrice("ETH", int256(ETH_OK) * 100);
        vm.expectRevert();
        shield.createPolicy(_defaultParams());
    }

    function test_ORC_08_CreateRevertsOnInvalidAssetBTC() public {
        IShield.CreatePolicyParams memory p = _defaultParams();
        p.asset = "BTC";
        vm.expectRevert(abi.encodeWithSelector(FlashETHShield1h.InvalidAsset.selector, bytes32("BTC")));
        shield.createPolicy(p);
    }

    function test_ORC_09_CreateRevertsOnInvalidAssetUSDC() public {
        IShield.CreatePolicyParams memory p = _defaultParams();
        p.asset = "USDC";
        vm.expectRevert(abi.encodeWithSelector(FlashETHShield1h.InvalidAsset.selector, bytes32("USDC")));
        shield.createPolicy(p);
    }

    function test_ORC_10_VerifyRevertsOnPriceBelowMin() public {
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_MIN) - 1, "ETH", t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_ORC_11_VerifyRevertsOnPriceAboveMax() public {
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_MAX) + 1, "ETH", t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_ORC_12_VerifyRevertsOnZeroVerifiedPrice() public {
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 300);
        bytes memory proof = _proof(0, "ETH", t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    // ============================================================
    // T-WIN -- Window guards (10)
    // ============================================================

    function test_WIN_01_RevertsWhenProofTooOld() public {
        uint256 pid = _create();
        oracle.setSignerOk(true);
        // verifiedAt = waitingEndsAt (block.timestamp at create); jump 901s later -> stale.
        // Read from policy storage so via_ir cannot inline t0 = block.timestamp
        // and re-read it after the warp.
        uint256 verifiedAt = shield.getPolicyInfo(pid).waitingEndsAt;
        vm.warp(verifiedAt + MAX_PROOF_AGE + 1);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", verifiedAt);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_WIN_02_AcceptsProofAtMaxAgeBoundary() public {
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 t0 = block.timestamp;
        // verifiedAt = t0, jump exactly MAX_PROOF_AGE seconds -> still OK
        vm.warp(t0 + MAX_PROOF_AGE);
        int256 droppedPrice = int256(ETH_OK) * 92 / 100;
        bytes memory proof = _proof(droppedPrice, "ETH", t0);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_WIN_03_VerifiedAtBeforeWaitingEnds_Reverts() public {
        // WAITING_PERIOD = 0 so waitingEndsAt = startTimestamp.
        // verifiedAt strictly less than waitingEndsAt triggers EventAfterExpiry.
        // NOTE: read waitingEndsAt from policy storage; under via_ir, local
        // captures of block.timestamp may be re-evaluated after a warp.
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 waitingEndsAt = shield.getPolicyInfo(pid).waitingEndsAt;
        // verifiedAt = waitingEndsAt - 1 (strictly before window opens).
        // Stay close to waitingEndsAt so proof-freshness (MAX_PROOF_AGE=900s)
        // doesn't pre-empt the window check.
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", waitingEndsAt > 0 ? waitingEndsAt - 1 : 0);
        vm.warp(waitingEndsAt + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_WIN_04_VerifiedAtExactlyAtWaitingEnds_OK() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create(); // waitingEndsAt = t0 (wp=0)
        oracle.setSignerOk(true);
        vm.warp(t0 + 100);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0); // == waitingEndsAt
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_WIN_05_VerifiedAtExactlyAtExpiresAt_OK() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 expiresAt = t0 + DURATION;
        vm.warp(expiresAt - 1);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", expiresAt);
        // verifiedAt > expiresAt would revert; verifiedAt == expiresAt is allowed.
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_WIN_06_VerifiedAtAfterExpires_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 expiresAt = t0 + DURATION;
        // Stay BEFORE expiry so PolicyStatus is still ACTIVE (not EXPIRED),
        // and only the verifiedAt-vs-expiresAt check fires.
        vm.warp(expiresAt - 1);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", expiresAt + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_WIN_07_RevertsWhenDurationTooShort() public {
        IShield.CreatePolicyParams memory p = _defaultParams();
        p.durationSeconds = DURATION - 1;
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_WIN_08_RevertsWhenDurationTooLong() public {
        IShield.CreatePolicyParams memory p = _defaultParams();
        p.durationSeconds = DURATION + 1;
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_WIN_09_CheckAndSettleBeforeSafetyWindow_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        uint256 expiresAt = t0 + DURATION;
        // Less than 24h safety window after expiry.
        vm.warp(expiresAt + 1 hours);
        vm.expectRevert();
        shield.checkAndSettlePolicy(pid);
    }

    function test_WIN_10_CheckAndSettleAfterSafetyWindow_NoTrigger() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        uint256 expiresAt = t0 + DURATION;
        // After safety window with price ABOVE trigger -> not triggered.
        vm.warp(expiresAt + 24 hours + 1);
        oracle.setPrice("ETH", int256(ETH_OK)); // unchanged
        shield.checkAndSettlePolicy(pid);
        // Policy is now finalized as EXPIRED.
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ============================================================
    // T-PRC -- Trigger pricing (10)
    // ============================================================

    function test_PRC_01_TriggerPriceIsStrike_x_93pct() public {
        uint256 pid = _create();
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);
        int256 expected = (int256(ETH_OK) * int256(BPS - TRIGGER_DROP_BPS)) / int256(BPS);
        assertEq(data.triggerPrice, expected);
    }

    function test_PRC_02_PriceExactlyAtTrigger_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(data.triggerPrice, "ETH", t0 + 100);
        // verifiedPrice >= trigger -> TriggerNotMet
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_03_PriceOneBelowTrigger_Triggers() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(data.triggerPrice - 1, "ETH", t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
        assertEq(r.reason, bytes32("FLASHETH1H_DROP7"));
    }

    function test_PRC_04_PriceOneAboveTrigger_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(data.triggerPrice + 1, "ETH", t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_05_AssetMismatchProofBTC_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 80 / 100, "BTC", t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_06_AssetMismatchProofEmpty_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 80 / 100, bytes32(0), t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_07_InvalidSignature_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(false);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 80 / 100, "ETH", t0 + 100);
        vm.expectRevert(FlashETHShield1h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_08_TriggerPriceRoundingDown() public {
        // Pick a strike that does NOT divide cleanly by BPS to exercise floor()
        oracle.setPrice("ETH", 4_001e8 + 7);
        uint256 pid = shield.createPolicy(_defaultParams());
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);
        int256 expected = (data.strikePrice * int256(BPS - TRIGGER_DROP_BPS)) / int256(BPS);
        assertEq(data.triggerPrice, expected);
    }

    function test_PRC_09_TriggerAtMinPriceFloor() public {
        oracle.setPrice("ETH", int256(ETH_MIN));
        uint256 pid = shield.createPolicy(_defaultParams());
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);
        // trigger = 500e8 * 9300 / 10000 = 465e8
        assertEq(data.triggerPrice, 465e8);
    }

    function test_PRC_10_TriggerAtMaxPriceCeiling() public {
        oracle.setPrice("ETH", int256(ETH_MAX));
        uint256 pid = shield.createPolicy(_defaultParams());
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);
        // trigger = 50000e8 * 9300 / 10000 = 46500e8
        assertEq(data.triggerPrice, 46_500e8);
    }

    // ============================================================
    // T-SEQ -- Sequencer downtime (6)
    // ============================================================

    function test_SEQ_01_ZeroDowntime_NormalSettlement() public {
        oracle.setDowntime(0);
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_02_NonZeroDowntime_ExtendsClaimWindow() public {
        // Downtime is configured to exercise _validateStatusForTrigger downtime
        // branch. Effective claim window is bounded by MAX_PROOF_AGE=900s AND
        // verifiedAt <= expiresAt; we warp just past expiresAt with
        // verifiedAt=expiresAt so the proof remains fresh.
        oracle.setDowntime(1 hours);
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 expiresAt = t0 + DURATION;
        vm.warp(expiresAt + 600);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", expiresAt);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_03_DowntimeBeyondCleanup_StillReverts() public {
        oracle.setDowntime(1 hours);
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 expiresAt = t0 + DURATION;
        // 25h+1s -> beyond adjusted cleanupAt (expiresAt + 25h)
        vm.warp(expiresAt + 25 hours + 1);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_SEQ_04_DowntimeQueriedWithExpiresAt() public {
        // _validateStatusForTrigger reads getSequencerDowntime(cp.expiresAt).
        // Verify the call path is exercised. Real claim window is bounded by
        // MAX_PROOF_AGE=900s AND verifiedAt <= expiresAt; we warp just past
        // expiresAt with verifiedAt=expiresAt so the proof is fresh.
        // NOTE: under via_ir local `t0` captures of block.timestamp get
        // inlined and re-evaluated post-warp; read expiresAt from policy
        // storage so the value is stable.
        oracle.setDowntime(2 hours);
        uint256 pid = _create();
        oracle.setSignerOk(true);
        uint256 expiresAt = shield.getPolicyInfo(pid).expiresAt;
        vm.warp(expiresAt + 600);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", expiresAt);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_05_CheckAndSettle_OracleRevertOnPrice_NoTrigger() public {
        // checkAndSettlePolicy reads getLatestPrice + returns false on revert/0.
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        vm.warp(t0 + DURATION + 24 hours + 1);
        oracle.setPrice("ETH", 0); // returns 0 -> _checkTriggerCondition=false
        shield.checkAndSettlePolicy(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_SEQ_06_CheckAndSettle_PriceBelowTrigger_PaidOut() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);
        vm.warp(t0 + DURATION + 24 hours + 1);
        oracle.setPrice("ETH", data.triggerPrice - 1);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    // ============================================================
    // T-PAY -- Payout calculation (8)
    // ============================================================

    function test_PAY_01_MaxPayoutIs80pctOfCoverage() public {
        uint256 pid = _create();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, (1_000e6 * (BPS - DEDUCTIBLE_BPS)) / BPS);
    }

    function test_PAY_02_MinCoverageEnforced() public {
        IShield.CreatePolicyParams memory p = _defaultParams();
        p.coverageAmount = 100e6 - 1; // _minCoverage() = 100e6
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_PAY_03_AtMinCoverageBoundary_OK() public {
        IShield.CreatePolicyParams memory p = _defaultParams();
        p.coverageAmount = 100e6;
        uint256 pid = shield.createPolicy(p);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, 80e6);
    }

    function test_PAY_04_LargeCoverageScales() public {
        IShield.CreatePolicyParams memory p = _defaultParams();
        p.coverageAmount = 10_000_000e6;
        uint256 pid = shield.createPolicy(p);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, 8_000_000e6);
    }

    function test_PAY_05_PayoutResultRecipientIsBuyer() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertEq(r.recipient, buyer);
    }

    function test_PAY_06_PayoutAmountClampedToMaxPayout() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(r.payoutAmount, info.maxPayout);
    }

    function test_PAY_07_ReasonIsFlashETH1HDrop7() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertEq(r.reason, bytes32("FLASHETH1H_DROP7"));
    }

    function test_PAY_08_MarkPaidOutFlipsStatus() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        shield.verifyAndCalculate(pid, proof);
        shield.markPaidOut(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
    }

    // ============================================================
    // T-PEM -- Permissions (6)
    // ============================================================

    function test_PEM_01_OnlyRouter_CreateRevertsForRandom() public {
        address rand = makeAddr("rand");
        vm.prank(rand);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.createPolicy(_defaultParams());
    }

    function test_PEM_02_OnlyRouter_VerifyRevertsForRandom() public {
        uint256 pid = _create();
        oracle.setSignerOk(true);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", block.timestamp);
        address rand = makeAddr("rand");
        vm.prank(rand);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PEM_03_OnlyRouter_MarkPaidOutRevertsForRandom() public {
        uint256 pid = _create();
        address rand = makeAddr("rand");
        vm.prank(rand);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markPaidOut(pid);
    }

    function test_PEM_04_InitializerCanOnlyRunOnce() public {
        vm.expectRevert();
        shield.initialize(router, address(oracle));
    }

    function test_PEM_05_OwnerCanRotateOracle() public {
        MockOracleEE newOracle = new MockOracleEE();
        vm.expectEmit(true, true, false, false);
        emit OracleRotated(address(oracle), address(newOracle));
        shield.setOracle(address(newOracle));
        assertEq(shield.oracle(), address(newOracle));
    }

    function test_PEM_06_NonOwnerCannotRotateOracle() public {
        MockOracleEE newOracle = new MockOracleEE();
        address rand = makeAddr("rand");
        vm.prank(rand);
        vm.expectRevert();
        shield.setOracle(address(newOracle));
    }

    // ============================================================
    // T-RAC -- Races / status machine (8)
    // ============================================================

    function test_RAC_01_CannotVerifyAfterPaidOut() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        shield.verifyAndCalculate(pid, proof);
        shield.markPaidOut(pid);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_RAC_02_CannotMarkPaidOutTwice() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        shield.verifyAndCalculate(pid, proof);
        shield.markPaidOut(pid);
        vm.expectRevert();
        shield.markPaidOut(pid);
    }

    function test_RAC_03_CannotMarkExpiredAfterPaidOut() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        oracle.setSignerOk(true);
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        shield.verifyAndCalculate(pid, proof);
        shield.markPaidOut(pid);
        vm.expectRevert();
        shield.markExpired(pid);
    }

    function test_RAC_04_VerifyOnNonexistentPolicyReverts() public {
        oracle.setSignerOk(true);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IShield.PolicyNotFound.selector, uint256(999)));
        shield.verifyAndCalculate(999, proof);
    }

    function test_RAC_05_CheckAndSettleTwice_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _create();
        vm.warp(t0 + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        vm.expectRevert();
        shield.checkAndSettlePolicy(pid);
    }

    function test_RAC_06_PolicyCountersIncrementOnCreate() public {
        uint256 startActive = shield.activePolicies();
        uint256 startTotal = shield.totalPolicies();
        _create();
        _create();
        assertEq(shield.activePolicies(), startActive + 2);
        assertEq(shield.totalPolicies(), startTotal + 2);
    }

    function test_RAC_07_TotalActiveCoverageReflectsSum() public {
        IShield.CreatePolicyParams memory p = _defaultParams();
        p.coverageAmount = 500e6;
        shield.createPolicy(p);
        p.coverageAmount = 1500e6;
        shield.createPolicy(p);
        assertEq(shield.totalActiveCoverage(), 2000e6);
    }

    function test_RAC_08_DistinctPolicyIdsMonotonic() public {
        uint256 a = _create();
        uint256 b = _create();
        uint256 c = _create();
        assertEq(b, a + 1);
        assertEq(c, b + 1);
    }
}

// =========================================================================
// Mock oracle covering both IOracle and the IOracleV2 EIP-712 surface used
// by BaseShield._verifyPriceProofEIP712. Signature acceptance is gated by
// a single boolean for deterministic testing -- no ECDSA inputs needed.
// =========================================================================
contract MockOracleEE {
    mapping(bytes32 => int256) public prices;
    uint256 public downtime;
    bool public signerOk;
    address public authorizedSigner;

    constructor() {
        authorizedSigner = makeAddr_("oracle-signer");
    }

    function setPrice(bytes32 asset, int256 price) external {
        prices[asset] = price;
    }

    function setDowntime(uint256 d) external {
        downtime = d;
    }

    function setSignerOk(bool ok) external {
        signerOk = ok;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return prices[asset];
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return downtime;
    }

    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return signerOk ? authorizedSigner : address(0);
    }

    function oracleKey() external view returns (address) {
        return authorizedSigner;
    }

    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata) external view returns (address) {
        return signerOk ? authorizedSigner : address(0);
    }

    function verifyExploitGovProofEIP712(int256, int256, bytes32, uint256, bytes calldata)
        external
        view
        returns (address)
    {
        return signerOk ? authorizedSigner : address(0);
    }

    function priceProofDigest(int256, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exploitReceiptProofDigest(bool, bool, bytes32, uint256) external pure returns (bytes32) {
        return bytes32(0);
    }

    function DOMAIN_SEPARATOR() external pure returns (bytes32) {
        return bytes32(0);
    }

    // Inline makeAddr to avoid Forge cheatcode dependencies inside the oracle.
    function makeAddr_(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }
}
