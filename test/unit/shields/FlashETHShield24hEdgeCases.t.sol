// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield24h} from "../../../src/products/FlashETHShield24h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// +============================================================================+
// | Sprint EE -- Phase C: 60 edge-case tests for FlashETHShield24h.            |
// |                                                                            |
// | Product: FLASHETH24-001 (ETH, 24h flash crash, 12% trigger drop).          |
// |                                                                            |
// | Groups (60 total):                                                         |
// |   T-ORC x12  Oracle revert / corruption / sanity-bounds                    |
// |   T-WIN x10  Window / duration / waiting-period boundaries                 |
// |   T-PRC x10  Price math / trigger threshold / deductible                   |
// |   T-SEQ x6   Sequencer downtime / status validation                        |
// |   T-PAY x8   Payout math / maxPayout cap / recipient routing               |
// |   T-PEM x6   Permission / onlyRouter / finalized-state guards              |
// |   T-RAC x8   Race conditions / replay / cross-asset / settle window        |
// |                                                                            |
// | NOTE: foundry.toml has via_ir=true. Per memory `foundry_via_ir_warp.md`,   |
// | we anchor warps to `t0` captured at setUp() and always pass absolute       |
// | timestamps -- never `block.timestamp + delta`.                             |
// +============================================================================+

// -----------------------------------------------------------------------------
// Mocks
// -----------------------------------------------------------------------------

/// @notice Mock IOracleV2 surface for the shield. Per-asset price + per-asset
///         revert toggles. EIP-712 verifier returns a configurable signer
///         (zero by default => proof rejected).
contract MockOracleV2Shield is IOracleV2 {
    mapping(bytes32 => int256) public priceFor;
    mapping(bytes32 => bool) public revertFor;
    bool public revertOnAny;
    uint256 public sequencerDowntime;
    address public oracleKeyAddr;
    address public eip712Signer;

    constructor() {
        oracleKeyAddr = address(this);
        eip712Signer = address(this);
    }

    // ---- setters ----
    function setPrice(bytes32 asset, int256 p) external {
        priceFor[asset] = p;
    }

    function setRevertFor(bytes32 asset, bool v) external {
        revertFor[asset] = v;
    }

    function setRevertOnAny(bool v) external {
        revertOnAny = v;
    }

    function setSequencerDowntime(uint256 d) external {
        sequencerDowntime = d;
    }

    function setEip712Signer(address s) external {
        eip712Signer = s;
    }

    function setOracleKey(address k) external {
        oracleKeyAddr = k;
    }

    // ---- IOracle ----
    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (revertOnAny) revert("oracle down");
        if (revertFor[asset]) revert("feed down");
        return priceFor[asset];
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return sequencerDowntime;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function oracleKey() external view returns (address) {
        return oracleKeyAddr;
    }

    // ---- IOracleV2 ----
    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata) external view returns (address) {
        return eip712Signer;
    }

    function verifyExploitGovProofEIP712(int256, int256, bytes32, uint256, bytes calldata)
        external
        pure
        returns (address)
    {
        return address(0);
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
}

// -----------------------------------------------------------------------------
// Test Harness
// -----------------------------------------------------------------------------

contract FlashETHShield24hEdgeCases is Test {
    // Re-declare events for vm.expectEmit (Solidity 0.8.20 emit scope rule).
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
    event OracleRotated(address indexed oldOracle, address indexed newOracle);

    FlashETHShield24h internal shield;
    MockOracleV2Shield internal oracle;

    address internal routerAddr;
    address internal buyer;
    address internal stranger;
    uint256 internal t0;

    // Local mirrors of contract constants for readability.
    uint32 constant DUR = 86400; // 24h
    uint256 constant COVERAGE = 1_000e6; // $1,000 (6-dec USDC)
    uint256 constant PREMIUM = 10e6; // $10
    uint256 constant DEDUCTIBLE_BPS = 2000;
    uint256 constant TRIGGER_DROP_BPS = 1200;
    uint256 constant BPS = 10_000;
    uint256 constant MAX_PROOF_AGE = 900;
    int256 constant ETH_NORMAL = 3_000e8; // $3,000 -- well within [500, 50_000]
    int256 constant ETH_MIN = 500e8;
    int256 constant ETH_MAX = 50_000e8;

    function setUp() public {
        vm.chainId(8453);
        // Pin a non-trivial timestamp so subtractions never wrap.
        vm.warp(1_800_000_000);
        t0 = block.timestamp;

        routerAddr = address(this);
        buyer = makeAddr("buyer");
        stranger = makeAddr("stranger");

        oracle = new MockOracleV2Shield();
        oracle.setPrice("ETH", ETH_NORMAL);

        shield = ProxyDeployer.deployFlashETHShield24h(routerAddr, address(oracle));
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _params() internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = COVERAGE;
        p.premiumAmount = PREMIUM;
        p.durationSeconds = DUR;
        p.asset = "ETH";
        p.stablecoin = bytes32(0);
        p.protocol = address(0);
        p.extraData = "";
    }

    function _paramsWith(bytes32 asset, uint32 dur, uint256 cov)
        internal
        view
        returns (IShield.CreatePolicyParams memory p)
    {
        p = _params();
        p.asset = asset;
        p.durationSeconds = dur;
        p.coverageAmount = cov;
    }

    function _create() internal returns (uint256 pid) {
        pid = shield.createPolicy(_params());
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes("sig"));
    }

    function _triggerPrice(int256 strike) internal pure returns (int256) {
        return (strike * int256(BPS - TRIGGER_DROP_BPS)) / int256(BPS);
    }

    // =====================================================================
    // T-ORC: Oracle revert / corruption / sanity-bounds (12)
    // =====================================================================

    function test_ORC_CreatePolicy_OracleRevertsETH() public {
        oracle.setRevertFor("ETH", true);
        vm.expectRevert(bytes("feed down"));
        shield.createPolicy(_params());
    }

    function test_ORC_CreatePolicy_ZeroPrice_Reverts() public {
        oracle.setPrice("ETH", 0);
        vm.expectRevert(); // InvalidOracleProof
        shield.createPolicy(_params());
    }

    function test_ORC_CreatePolicy_NegativePrice_Reverts() public {
        oracle.setPrice("ETH", -1);
        vm.expectRevert();
        shield.createPolicy(_params());
    }

    function test_ORC_CreatePolicy_AtMinBoundary_Accepted() public {
        oracle.setPrice("ETH", ETH_MIN);
        uint256 pid = shield.createPolicy(_params());
        assertEq(shield.getBSSData(pid).strikePrice, ETH_MIN);
    }

    function test_ORC_CreatePolicy_OneBelowMin_Reverts() public {
        oracle.setPrice("ETH", ETH_MIN - 1);
        vm.expectRevert();
        shield.createPolicy(_params());
    }

    function test_ORC_CreatePolicy_AtMaxBoundary_Accepted() public {
        oracle.setPrice("ETH", ETH_MAX);
        uint256 pid = shield.createPolicy(_params());
        assertEq(shield.getBSSData(pid).strikePrice, ETH_MAX);
    }

    function test_ORC_CreatePolicy_OneAboveMax_Reverts() public {
        oracle.setPrice("ETH", ETH_MAX + 1);
        vm.expectRevert();
        shield.createPolicy(_params());
    }

    function test_ORC_CreatePolicy_ExtremePrice_Reverts() public {
        oracle.setPrice("ETH", 500_000e8);
        vm.expectRevert();
        shield.createPolicy(_params());
    }

    function test_ORC_Verify_PriceBelowMin_Reverts() public {
        uint256 pid = _create();
        oracle.setPrice("ETH", ETH_MIN - 1);
        bytes memory proof = _proof(ETH_MIN - 1, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_ORC_Verify_PriceAboveMax_Reverts() public {
        uint256 pid = _create();
        bytes memory proof = _proof(ETH_MAX + 1, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_ORC_Verify_NegativePrice_Reverts() public {
        uint256 pid = _create();
        bytes memory proof = _proof(-100, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_ORC_Verify_ZeroSigner_RevertsInvalidProof() public {
        uint256 pid = _create();
        oracle.setEip712Signer(address(0)); // proof rejected
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    // =====================================================================
    // T-WIN: Window / duration / waiting-period boundaries (10)
    // =====================================================================

    function test_WIN_Duration_BelowMin_Reverts() public {
        vm.expectRevert();
        shield.createPolicy(_paramsWith("ETH", DUR - 1, COVERAGE));
    }

    function test_WIN_Duration_AboveMax_Reverts() public {
        vm.expectRevert();
        shield.createPolicy(_paramsWith("ETH", DUR + 1, COVERAGE));
    }

    function test_WIN_Duration_Exact_24h_OK() public {
        shield.createPolicy(_paramsWith("ETH", DUR, COVERAGE));
    }

    function test_WIN_Duration_Zero_Reverts() public {
        vm.expectRevert();
        shield.createPolicy(_paramsWith("ETH", 0, COVERAGE));
    }

    function test_WIN_Waiting_IsZero_ActiveImmediately() public {
        uint256 pid = _create();
        // status at block.timestamp should be ACTIVE (waitingEndsAt == startTimestamp)
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.ACTIVE));
    }

    function test_WIN_Verify_BeforeExpiry_Triggers() public {
        uint256 pid = _create();
        // verifiedAt at t0+10 (still inside waiting->active window since WP=0)
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 10);
        vm.warp(t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_WIN_Verify_AfterExpiry_Reverts() public {
        uint256 pid = _create();
        // proof verifiedAt is AFTER expiresAt (t0 + 86400). expects EventAfterExpiry.
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + DUR + 1);
        vm.warp(t0 + DUR + 2);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_WIN_ProofTooOld_Reverts() public {
        uint256 pid = _create();
        // verifiedAt = t0; current = t0 + MAX_PROOF_AGE + 5 -> ProofTooOld
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0);
        vm.warp(t0 + MAX_PROOF_AGE + 5);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_WIN_ProofExactlyAtMaxAge_OK() public {
        uint256 pid = _create();
        // verifiedAt = t0; current = t0 + MAX_PROOF_AGE -> boundary is `>`, so equal still passes
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0);
        vm.warp(t0 + MAX_PROOF_AGE);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_WIN_ExpiresAt_Equals_StartPlus24h() public {
        uint256 pid = _create();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.expiresAt, info.startTimestamp + DUR);
        assertEq(info.waitingEndsAt, info.startTimestamp);
    }

    // =====================================================================
    // T-PRC: Price math / trigger threshold / deductible (10)
    // =====================================================================

    function test_PRC_TriggerPrice_88Percent_Stored() public {
        uint256 pid = _create();
        FlashETHShield24h.BSSData memory d = shield.getBSSData(pid);
        // trigger = strike * 8800 / 10000
        assertEq(d.triggerPrice, _triggerPrice(ETH_NORMAL));
        assertEq(d.strikePrice, ETH_NORMAL);
        assertEq(d.asset, bytes32("ETH"));
    }

    function test_PRC_PriceExactlyAtTrigger_DoesNotTrigger() public {
        uint256 pid = _create();
        // verifiedPrice >= triggerPrice -> TriggerNotMet (note: strict `>=` in code blocks trigger).
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL), "ETH", t0 + 50);
        vm.warp(t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_PriceOneBelowTrigger_Triggers() public {
        uint256 pid = _create();
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 50);
        vm.warp(t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
        assertEq(r.reason, bytes32("FLASHETH24_DROP12"));
    }

    function test_PRC_PriceAboveStrike_DoesNotTrigger() public {
        uint256 pid = _create();
        // up-spike -> price above strike, far above trigger -> reverts TriggerNotMet
        bytes memory proof = _proof(ETH_NORMAL + 100e8, "ETH", t0 + 50);
        vm.warp(t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_DeductibleBps_20Percent() public view {
        assertEq(shield.DEDUCTIBLE_BPS(), 2000);
    }

    function test_PRC_TriggerDropBps_12Percent() public view {
        assertEq(shield.TRIGGER_DROP_BPS(), 1200);
    }

    function test_PRC_MaxPayout_80Percent_OfCoverage() public {
        uint256 pid = _create();
        uint256 expected = (COVERAGE * (BPS - DEDUCTIBLE_BPS)) / BPS;
        assertEq(shield.getPolicyInfo(pid).maxPayout, expected);
    }

    function test_PRC_TriggerPrice_AtMinStrike_NoUnderflow() public {
        oracle.setPrice("ETH", ETH_MIN);
        uint256 pid = shield.createPolicy(_params());
        FlashETHShield24h.BSSData memory d = shield.getBSSData(pid);
        // 500e8 * 8800 / 10000 = 440e8
        assertEq(d.triggerPrice, (ETH_MIN * 8800) / 10000);
    }

    function test_PRC_TriggerPrice_AtMaxStrike_NoOverflow() public {
        oracle.setPrice("ETH", ETH_MAX);
        uint256 pid = shield.createPolicy(_params());
        FlashETHShield24h.BSSData memory d = shield.getBSSData(pid);
        // 50_000e8 * 8800 / 10000 = 44_000e8
        assertEq(d.triggerPrice, (ETH_MAX * 8800) / 10000);
    }

    function test_PRC_MaxPayout_ZeroCoverage_Reverts() public {
        IShield.CreatePolicyParams memory p = _paramsWith("ETH", DUR, 0);
        vm.expectRevert();
        shield.createPolicy(p);
    }

    // =====================================================================
    // T-SEQ: Sequencer downtime / status validation (6)
    // =====================================================================

    function test_SEQ_Downtime_Zero_AllowsTrigger() public {
        uint256 pid = _create();
        oracle.setSequencerDowntime(0);
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_Downtime_Extends_Cleanup_AllowsLateTrigger() public {
        uint256 pid = _create();
        // Downtime extension (1d) is configured. In practice the effective late-
        // trigger window is constrained by MAX_PROOF_AGE=900s AND verifiedAt
        // must remain <= expiresAt. We exercise the downtime branch by warping
        // just past expiresAt with a fresh proof at verifiedAt=expiresAt.
        oracle.setSequencerDowntime(1 days);
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + DUR);
        vm.warp(t0 + DUR + 600);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_PastAdjustedCleanup_Reverts() public {
        uint256 pid = _create();
        oracle.setSequencerDowntime(0);
        // cleanupAt = t0 + DUR + 24h. Past that with downtime=0 -> InvalidPolicyStatus.
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 100);
        vm.warp(t0 + DUR + 24 hours + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_SEQ_Status_Active_DuringWindow() public {
        uint256 pid = _create();
        vm.warp(t0 + DUR / 2);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.ACTIVE));
    }

    function test_SEQ_Status_Expired_AfterCleanup() public {
        uint256 pid = _create();
        vm.warp(t0 + DUR + 24 hours + 1);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    function test_SEQ_NonexistentPolicy_StatusIsNonexistent() public view {
        assertEq(uint256(shield.getPolicyStatus(999)), uint256(IShield.PolicyStatus.NONEXISTENT));
    }

    // =====================================================================
    // T-PAY: Payout math / maxPayout cap / recipient routing (8)
    // =====================================================================

    function test_PAY_Result_RecipientIsInsuredAgent() public {
        uint256 pid = _create();
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 50);
        vm.warp(t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertEq(r.recipient, buyer);
    }

    function test_PAY_Result_Amount_EqualsMaxPayout() public {
        uint256 pid = _create();
        uint256 expected = (COVERAGE * (BPS - DEDUCTIBLE_BPS)) / BPS;
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 50);
        vm.warp(t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertEq(r.payoutAmount, expected);
    }

    function test_PAY_MarkPaidOut_FinalizesPolicy() public {
        uint256 pid = _create();
        shield.markPaidOut(pid);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(uint256(info.status), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    function test_PAY_MarkPaidOut_EmitsEvent() public {
        uint256 pid = _create();
        uint256 expected = (COVERAGE * (BPS - DEDUCTIBLE_BPS)) / BPS;
        vm.expectEmit(true, true, false, true, address(shield));
        emit PolicyPaidOut(pid, buyer, expected, bytes32("PAID_OUT"));
        shield.markPaidOut(pid);
    }

    function test_PAY_MarkExpired_FinalizesPolicy() public {
        uint256 pid = _create();
        shield.markExpired(pid);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(uint256(info.status), uint256(IShield.PolicyStatus.EXPIRED));
    }

    function test_PAY_CountersDecrement_OnFinalize() public {
        uint256 pid1 = _create();
        uint256 pid2 = _create();
        assertEq(shield.activePolicies(), 2);
        assertEq(shield.totalActiveCoverage(), 2 * COVERAGE);
        shield.markPaidOut(pid1);
        assertEq(shield.activePolicies(), 1);
        assertEq(shield.totalActiveCoverage(), COVERAGE);
        shield.markExpired(pid2);
        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
    }

    function test_PAY_LargeCoverage_NoOverflow_In80Pct() public {
        oracle.setPrice("ETH", ETH_NORMAL);
        IShield.CreatePolicyParams memory p = _paramsWith("ETH", DUR, 1_000_000e6); // $1M
        uint256 pid = shield.createPolicy(p);
        assertEq(shield.getPolicyInfo(pid).maxPayout, (1_000_000e6 * 8000) / 10000);
    }

    function test_PAY_MinCoverage_100USDC_OK() public {
        // BaseShield._minCoverage() returns 100e6 (default). Anything below reverts.
        IShield.CreatePolicyParams memory p = _paramsWith("ETH", DUR, 99e6);
        vm.expectRevert();
        shield.createPolicy(p);
    }

    // =====================================================================
    // T-PEM: Permission / onlyRouter / finalized-state guards (6)
    // =====================================================================

    function test_PEM_CreatePolicy_OnlyRouter() public {
        vm.prank(stranger);
        vm.expectRevert(); // OnlyRouter
        shield.createPolicy(_params());
    }

    function test_PEM_VerifyAndCalculate_OnlyRouter() public {
        uint256 pid = _create();
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 50);
        vm.prank(stranger);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PEM_MarkPaidOut_OnlyRouter() public {
        uint256 pid = _create();
        vm.prank(stranger);
        vm.expectRevert();
        shield.markPaidOut(pid);
    }

    function test_PEM_MarkExpired_OnlyRouter() public {
        uint256 pid = _create();
        vm.prank(stranger);
        vm.expectRevert();
        shield.markExpired(pid);
    }

    function test_PEM_Finalized_CannotVerifyAgain() public {
        uint256 pid = _create();
        shield.markPaidOut(pid);
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 50);
        vm.warp(t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PEM_NonexistentPolicy_VerifyReverts() public {
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 50);
        vm.expectRevert();
        shield.verifyAndCalculate(999, proof);
    }

    // =====================================================================
    // T-RAC: Race / replay / cross-asset / settle window (8)
    // =====================================================================

    function test_RAC_WrongAssetInProof_Reverts() public {
        uint256 pid = _create();
        // valid signer, valid price, but asset mismatches (BTC vs policy ETH)
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "BTC", t0 + 50);
        vm.warp(t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_RAC_WrongAssetInCreate_Reverts() public {
        IShield.CreatePolicyParams memory p = _paramsWith("BTC", DUR, COVERAGE);
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_RAC_CheckAndSettle_BeforeSafetyWindow_Reverts() public {
        uint256 pid = _create();
        vm.warp(t0 + DUR + 1);
        vm.expectRevert(); // SafetyWindowNotPassed
        shield.checkAndSettlePolicy(pid);
    }

    function test_RAC_CheckAndSettle_AfterSafetyWindow_NotTriggered_Expires() public {
        uint256 pid = _create();
        // Past expiresAt + 24h (SAFETY_WINDOW); ETH price unchanged -> not triggered.
        oracle.setPrice("ETH", ETH_NORMAL);
        vm.warp(t0 + DUR + 24 hours + 1);
        vm.expectEmit(true, false, false, false, address(shield));
        emit PolicySettledExpired(pid);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    function test_RAC_CheckAndSettle_AfterSafetyWindow_Triggered_PaysOut() public {
        uint256 pid = _create();
        // Drop spot price below triggerPrice
        oracle.setPrice("ETH", _triggerPrice(ETH_NORMAL) - 1);
        vm.warp(t0 + DUR + 24 hours + 1);
        vm.expectEmit(true, true, false, true, address(shield));
        emit PolicySettledTriggered(pid, buyer, (COVERAGE * 8000) / 10000);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    function test_RAC_CheckAndSettle_DoubleSettle_Reverts() public {
        uint256 pid = _create();
        vm.warp(t0 + DUR + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        vm.expectRevert(); // already finalized
        shield.checkAndSettlePolicy(pid);
    }

    function test_RAC_TwoPolicies_IndependentCounters() public {
        uint256 pid1 = _create();
        // Move price slightly and create a second policy with different strike.
        oracle.setPrice("ETH", 2_500e8);
        IShield.CreatePolicyParams memory p2 = _params();
        p2.buyer = makeAddr("buyer2");
        uint256 pid2 = shield.createPolicy(p2);
        FlashETHShield24h.BSSData memory d1 = shield.getBSSData(pid1);
        FlashETHShield24h.BSSData memory d2 = shield.getBSSData(pid2);
        assertEq(d1.strikePrice, ETH_NORMAL);
        assertEq(d2.strikePrice, 2_500e8);
        assertTrue(pid1 != pid2);
        assertEq(shield.totalPolicies(), 2);
    }

    function test_RAC_ProofReplay_AfterFinalize_Reverts() public {
        uint256 pid = _create();
        bytes memory proof = _proof(_triggerPrice(ETH_NORMAL) - 1, "ETH", t0 + 50);
        vm.warp(t0 + 100);
        shield.verifyAndCalculate(pid, proof);
        shield.markPaidOut(pid);
        // Replay the exact same proof -- finalized guard rejects.
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }
}
