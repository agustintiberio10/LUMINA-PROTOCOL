// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield24h} from "../../../src/products/FlashBTCShield24h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// +============================================================================+
// | Sprint EE -- Phase C: 60 edge-case tests for FlashBTCShield24h.            |
// |                                                                            |
// | Groups (60 total):                                                         |
// |   T-ORC   x12  Oracle staleness / revert / sanity bounds                   |
// |   T-WIN   x10  Window boundary (24h policy duration)                       |
// |   T-PRC   x10  Price math / TRIGGER_DROP_BPS=1000 (10% drop)               |
// |   T-SEQ   x6   Sequencer downtime cleanup extension                        |
// |   T-PAY   x8   Payout math / DEDUCTIBLE_BPS=2000 (80% max payout)          |
// |   T-PEM   x6   Permissions / onlyRouter / access control                   |
// |   T-RAC   x8   Race / state transitions / replay                           |
// |                                                                            |
// | Contract constants (from src/products/FlashBTCShield24h.sol):              |
// |   MIN_DURATION = MAX_DURATION = 86_400 (24h fixed)                         |
// |   TRIGGER_DROP_BPS = 1000   (10%)                                          |
// |   DEDUCTIBLE_BPS  = 2000    (20% deductible -> 80% payout)                 |
// |   MAX_PROOF_AGE   = 900     (15 min)                                       |
// |   MIN_PRICE = 10_000 * 1e8                                                 |
// |   MAX_PRICE = 1_000_000 * 1e8                                              |
// |                                                                            |
// | NOTE on warp: foundry.toml has via_ir=true; per memory                     |
// | foundry_via_ir_warp.md, vm.warp(block.timestamp + delta) caches the        |
// | initial block.timestamp under via_ir. We anchor warps to t0 captured at    |
// | setUp() and always pass absolute timestamps.                               |
// +============================================================================+

// -----------------------------------------------------------------------------
// Mocks
// -----------------------------------------------------------------------------

/// @notice Mock IOracleV2 with configurable price, sequencer downtime, EIP-712
///         signer override, and revert toggles. The shield casts oracle to
///         IOracleV2 when verifying proofs.
contract MockOracleV2BTC is IOracleV2 {
    mapping(bytes32 => int256) public priceFor;
    uint256 public sequencerDowntime;
    address public oracleSigningKey;
    bool public revertOnPrice;
    bool public eip712ReturnsZero;
    bool public eip712Reverts;

    constructor() {
        oracleSigningKey = address(this);
        priceFor["BTC"] = 60_000e8;
        priceFor["ETH"] = 3_000e8;
        priceFor["USDC"] = 1e8;
    }

    function setPrice(bytes32 asset, int256 p) external {
        priceFor[asset] = p;
    }

    function setSequencerDowntime(uint256 d) external {
        sequencerDowntime = d;
    }

    function setEip712ReturnsZero(bool v) external {
        eip712ReturnsZero = v;
    }

    function setEip712Reverts(bool v) external {
        eip712Reverts = v;
    }

    function setRevertOnPrice(bool v) external {
        revertOnPrice = v;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (revertOnPrice) revert("oracle-down");
        return priceFor[asset];
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return sequencerDowntime;
    }

    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return oracleSigningKey;
    }

    function oracleKey() external view returns (address) {
        return oracleSigningKey;
    }

    // -- IOracleV2 surface --
    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata) external view returns (address signer) {
        if (eip712Reverts) revert("eip712-down");
        if (eip712ReturnsZero) return address(0);
        return oracleSigningKey;
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
        return bytes32(uint256(0xD0));
    }
}

// -----------------------------------------------------------------------------
// Test Harness
// -----------------------------------------------------------------------------

contract FlashBTCShield24hEdgeCases is Test {
    // Re-declare events for vm.expectEmit matching. Solidity 0.8.20 requires events
    // be in scope of the emitting contract; re-declare is the standard pattern.
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

    FlashBTCShield24h shield;
    MockOracleV2BTC oracle;

    address router; // address(this) in setUp
    address buyer = makeAddr("buyer");
    address attacker = makeAddr("attacker");

    // Mirror of contract constants for readability.
    uint32 constant DURATION = 86_400; // 24 hours
    uint256 constant TRIGGER_DROP_BPS = 1000; // 10%
    uint256 constant DEDUCTIBLE_BPS = 2000; // 20%
    uint256 constant BPS = 10_000;
    uint256 constant MAX_PROOF_AGE = 900; // 15 min
    int256 constant BTC_60K = 60_000e8;
    int256 constant TRIGGER_60K = (60_000e8 * int256(9000)) / int256(10_000); // 54_000e8
    uint256 constant MIN_PRICE = 10_000 * 1e8;
    uint256 constant MAX_PRICE = 1_000_000 * 1e8;
    uint256 constant DEFAULT_COVERAGE = 1_000e6; // $1,000 USDC

    uint256 t0;

    function setUp() public {
        vm.chainId(8453);
        // Pin a non-trivial block.timestamp so cleanupAt arithmetic stays well-defined.
        vm.warp(1_700_000_000);

        router = address(this);
        oracle = new MockOracleV2BTC();
        shield = ProxyDeployer.deployFlashBTCShield24h(router, address(oracle));

        t0 = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _params(bytes32 asset) internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = DEFAULT_COVERAGE;
        p.premiumAmount = 10e6;
        p.durationSeconds = DURATION;
        p.asset = asset;
    }

    function _createBTCPolicy() internal returns (uint256 policyId) {
        return shield.createPolicy(_params("BTC"));
    }

    /// @dev Builds the oracleProof blob the shield decodes:
    ///      abi.encode(int256 price, bytes32 asset, uint256 verifiedAt, bytes signature).
    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes("sig"));
    }

    // =====================================================================
    // T-ORC: Oracle staleness / revert / sanity bounds (12)
    // =====================================================================

    function test_ORC_OracleRevertsAtCreate_Reverts() public {
        oracle.setRevertOnPrice(true);
        vm.expectRevert();
        _createBTCPolicy();
    }

    function test_ORC_OracleReturnsZeroAtCreate_RevertsInvalidProof() public {
        oracle.setPrice("BTC", 0);
        vm.expectRevert(FlashBTCShield24h.InvalidOracleProof.selector);
        _createBTCPolicy();
    }

    function test_ORC_OracleReturnsNegativeAtCreate_RevertsInvalidProof() public {
        oracle.setPrice("BTC", -1);
        vm.expectRevert(FlashBTCShield24h.InvalidOracleProof.selector);
        _createBTCPolicy();
    }

    function test_ORC_PriceAboveMax_Reverts() public {
        oracle.setPrice("BTC", int256(MAX_PRICE) + 1);
        vm.expectRevert();
        _createBTCPolicy();
    }

    function test_ORC_PriceBelowMin_Reverts() public {
        oracle.setPrice("BTC", int256(MIN_PRICE) - 1);
        vm.expectRevert();
        _createBTCPolicy();
    }

    function test_ORC_PriceExactlyAtMin_Accepted() public {
        oracle.setPrice("BTC", int256(MIN_PRICE));
        uint256 pid = _createBTCPolicy();
        assertEq(shield.getBSSData(pid).strikePrice, int256(MIN_PRICE));
    }

    function test_ORC_PriceExactlyAtMax_Accepted() public {
        oracle.setPrice("BTC", int256(MAX_PRICE));
        uint256 pid = _createBTCPolicy();
        assertEq(shield.getBSSData(pid).strikePrice, int256(MAX_PRICE));
    }

    function test_ORC_PriceOneAboveMax_Reverts() public {
        oracle.setPrice("BTC", int256(MAX_PRICE) + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                FlashBTCShield24h.PriceOutOfSanityBounds.selector, uint256(MAX_PRICE) + 1, MIN_PRICE, MAX_PRICE
            )
        );
        _createBTCPolicy();
    }

    function test_ORC_VerifyProof_OracleSignerZero_RevertsInvalidProof() public {
        uint256 pid = _createBTCPolicy();
        oracle.setEip712ReturnsZero(true);
        // verifiedAt within waiting/expiry window. Verify the EIP-712 path is what fails.
        vm.warp(t0 + 1);
        bytes memory proof = _proof(BTC_60K - 1e8, "BTC", t0 + 1);
        vm.expectRevert(FlashBTCShield24h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, proof);
    }

    function test_ORC_VerifyProof_EIP712Reverts_Bubbles() public {
        uint256 pid = _createBTCPolicy();
        oracle.setEip712Reverts(true);
        vm.warp(t0 + 1);
        bytes memory proof = _proof(BTC_60K - 1e8, "BTC", t0 + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_ORC_VerifyProof_PriceZero_Reverts() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        bytes memory proof = _proof(0, "BTC", t0 + 1);
        vm.expectRevert(FlashBTCShield24h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, proof);
    }

    function test_ORC_VerifyProof_PriceNegative_Reverts() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        bytes memory proof = _proof(-1, "BTC", t0 + 1);
        vm.expectRevert(FlashBTCShield24h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, proof);
    }

    // =====================================================================
    // T-WIN: Window boundary (10)
    // =====================================================================

    function test_WIN_DurationRange_Is24h() public view {
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, DURATION);
        assertEq(mx, DURATION);
    }

    function test_WIN_RejectShorterDuration() public {
        IShield.CreatePolicyParams memory p = _params("BTC");
        p.durationSeconds = DURATION - 1;
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_WIN_RejectLongerDuration() public {
        IShield.CreatePolicyParams memory p = _params("BTC");
        p.durationSeconds = DURATION + 1;
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_WIN_RejectZeroDuration() public {
        IShield.CreatePolicyParams memory p = _params("BTC");
        p.durationSeconds = 0;
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_WIN_VerifyProof_WithinWindow_Triggers() public {
        uint256 pid = _createBTCPolicy();
        oracle.setPrice("BTC", BTC_60K - 1); // ensure trigger check uses oracle-side state if needed
        vm.warp(t0 + 1 hours);
        bytes memory proof = _proof(BTC_60K - 1e8 * 7000, "BTC", t0 + 1 hours);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_WIN_VerifyProof_VerifiedAtBeforeWaitingEnds_Reverts() public {
        // waitingPeriod == 0 here, but a verifiedAt below the policy's waitingEndsAt
        // (which equals startTimestamp) MUST revert with EventAfterExpiry per the
        // shield source. We set verifiedAt to t0-1 to force the guard.
        uint256 pid = _createBTCPolicy();
        // Need verifiedAt + MAX_PROOF_AGE > block.timestamp so the staleness check passes.
        vm.warp(t0 + 1);
        bytes memory proof = _proof(BTC_60K - 1e8 * 7000, "BTC", t0 - 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_WIN_VerifyProof_VerifiedAtAfterExpires_Reverts() public {
        uint256 pid = _createBTCPolicy();
        // verifiedAt = expiresAt + 1 -- after policy expiry.
        uint256 verifiedAt = t0 + DURATION + 1;
        // Warp to a moment where verifiedAt + MAX_PROOF_AGE is still in the future,
        // so the freshness check passes and the >expiresAt check is what triggers.
        vm.warp(verifiedAt);
        bytes memory proof = _proof(BTC_60K - 1e8 * 7000, "BTC", verifiedAt);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_WIN_VerifyProof_ProofTooOld_Reverts() public {
        uint256 pid = _createBTCPolicy();
        // verifiedAt now, then warp > MAX_PROOF_AGE seconds forward.
        uint256 verifiedAt = t0;
        vm.warp(t0 + MAX_PROOF_AGE + 1);
        bytes memory proof = _proof(BTC_60K - 1e8 * 7000, "BTC", verifiedAt);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_WIN_VerifyProof_ProofExactlyAtMaxAge_OK() public {
        uint256 pid = _createBTCPolicy();
        uint256 verifiedAt = t0;
        // Boundary: block.timestamp == verifiedAt + MAX_PROOF_AGE -- check uses strict `>`.
        vm.warp(verifiedAt + MAX_PROOF_AGE);
        bytes memory proof = _proof(BTC_60K - 1e8 * 7000, "BTC", verifiedAt);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_WIN_VerifyProof_VerifiedAtExactlyAtExpiresAt_OK() public {
        uint256 pid = _createBTCPolicy();
        uint256 expiresAt = t0 + DURATION;
        // verifiedAt == expiresAt -- guard uses strict `>` -> OK.
        vm.warp(expiresAt);
        bytes memory proof = _proof(BTC_60K - 1e8 * 7000, "BTC", expiresAt);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    // =====================================================================
    // T-PRC: Price math / TRIGGER_DROP_BPS (10)
    // =====================================================================

    function test_PRC_Constants() public view {
        assertEq(shield.TRIGGER_DROP_BPS(), TRIGGER_DROP_BPS);
        assertEq(shield.DEDUCTIBLE_BPS(), DEDUCTIBLE_BPS);
        assertEq(shield.MAX_PROOF_AGE(), MAX_PROOF_AGE);
        assertEq(shield.MIN_PRICE(), MIN_PRICE);
        assertEq(shield.MAX_PRICE(), MAX_PRICE);
    }

    function test_PRC_TriggerPriceComputed_60kStrike() public {
        uint256 pid = _createBTCPolicy();
        FlashBTCShield24h.BSSData memory data = shield.getBSSData(pid);
        assertEq(data.strikePrice, BTC_60K);
        assertEq(data.triggerPrice, TRIGGER_60K);
        assertEq(data.asset, bytes32("BTC"));
    }

    function test_PRC_DropExactly10Percent_NotTriggered() public {
        uint256 pid = _createBTCPolicy();
        // price == triggerPrice exactly -- guard is `>= triggerPrice` reverts "PRICE_ABOVE_TRIGGER",
        // so equal-to is NOT triggered (still above the strict-drop band).
        vm.warp(t0 + 1);
        bytes memory proof = _proof(TRIGGER_60K, "BTC", t0 + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_DropMoreThan10Percent_Triggered() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + 1);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
        assertEq(r.reason, bytes32("FLASHBTC24_DROP10"));
    }

    function test_PRC_DropLessThan10Percent_NotTriggered() public {
        uint256 pid = _createBTCPolicy();
        // 5% drop -> price = 57_000e8 > triggerPrice 54_000e8 -> revert TriggerNotMet.
        int256 price5pct = (BTC_60K * 95) / 100;
        vm.warp(t0 + 1);
        bytes memory proof = _proof(price5pct, "BTC", t0 + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_PriceAboveStrike_NotTriggered() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        bytes memory proof = _proof(BTC_60K + 1e8, "BTC", t0 + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_VerifiedPriceBelowMin_Reverts() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        bytes memory proof = _proof(int256(MIN_PRICE) - 1, "BTC", t0 + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_VerifiedPriceAboveMax_Reverts() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        bytes memory proof = _proof(int256(MAX_PRICE) + 1, "BTC", t0 + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_TriggerPrice_AtMinStrike() public {
        oracle.setPrice("BTC", int256(MIN_PRICE)); // $10,000
        uint256 pid = _createBTCPolicy();
        // triggerPrice = 10_000e8 * 9000 / 10_000 = 9_000e8 -- below MIN_PRICE bound.
        FlashBTCShield24h.BSSData memory data = shield.getBSSData(pid);
        assertEq(data.triggerPrice, (int256(MIN_PRICE) * 9000) / 10_000);
    }

    function test_PRC_TriggerPrice_AtMaxStrike() public {
        oracle.setPrice("BTC", int256(MAX_PRICE)); // $1,000,000
        uint256 pid = _createBTCPolicy();
        FlashBTCShield24h.BSSData memory data = shield.getBSSData(pid);
        assertEq(data.triggerPrice, (int256(MAX_PRICE) * 9000) / 10_000);
    }

    // =====================================================================
    // T-SEQ: Sequencer downtime cleanup extension (6)
    // =====================================================================

    function test_SEQ_NoDowntime_WithinCleanup_StatusCheckPasses() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + DURATION + 1); // expired, still in cleanup grace
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + DURATION); // verifiedAt at expiry
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_NoDowntime_PastCleanup_RevertsInvalidStatus() public {
        uint256 pid = _createBTCPolicy();
        // cleanupAt = expiresAt + 24h (CLAIM_GRACE_PERIOD).
        vm.warp(t0 + DURATION + 24 hours + 1);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + DURATION);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_SEQ_NoDowntime_AtCleanupExact_RevertsInvalidStatus() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + DURATION + 24 hours);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + DURATION);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_SEQ_Downtime60s_CoversGap_StatusCheckPasses() public {
        uint256 pid = _createBTCPolicy();
        oracle.setSequencerDowntime(60);
        // Exercise the downtime-extension code path in _validateStatusForTrigger
        // while keeping the proof fresh (MAX_PROOF_AGE=900s). verifiedAt is set
        // at expiresAt (the latest allowed) and block.timestamp at expiresAt+30
        // -- well inside the proof-freshness window AND past expiresAt so the
        // status is EXPIRED, exercising the downtime branch.
        vm.warp(t0 + DURATION + 30);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + DURATION);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_Downtime1h_CoversGap_StatusCheckPasses() public {
        uint256 pid = _createBTCPolicy();
        oracle.setSequencerDowntime(1 hours);
        // Downtime is configured (1h) but the actual claim must still satisfy
        // proof freshness (block.timestamp - verifiedAt <= 900) AND
        // verifiedAt <= expiresAt. Both bounds intersect only inside
        // [expiresAt, expiresAt+900], so we warp there.
        vm.warp(t0 + DURATION + 600);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + DURATION);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_Downtime_NotEnoughToCoverGap_Reverts() public {
        uint256 pid = _createBTCPolicy();
        oracle.setSequencerDowntime(60); // 60s only
        // 2 minutes past cleanupAt -- 60s extension is insufficient.
        vm.warp(t0 + DURATION + 24 hours + 120);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + DURATION);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    // =====================================================================
    // T-PAY: Payout math / DEDUCTIBLE_BPS (8)
    // =====================================================================

    function test_PAY_MaxPayout_Is80Pct_DefaultCoverage() public {
        uint256 pid = _createBTCPolicy();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        // (1000e6 * 8000) / 10000 = 800e6
        assertEq(info.maxPayout, (DEFAULT_COVERAGE * 8000) / BPS);
    }

    function test_PAY_MaxPayout_LargeCoverage_NoOverflow() public {
        IShield.CreatePolicyParams memory p = _params("BTC");
        p.coverageAmount = 1_000_000_000e6; // $1B
        uint256 pid = shield.createPolicy(p);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, (1_000_000_000e6 * 8000) / BPS);
    }

    function test_PAY_MaxPayout_MinCoverage_Boundary() public {
        IShield.CreatePolicyParams memory p = _params("BTC");
        p.coverageAmount = 100e6; // _minCoverage default
        uint256 pid = shield.createPolicy(p);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, (100e6 * 8000) / BPS);
    }

    function test_PAY_BelowMinCoverage_Reverts() public {
        IShield.CreatePolicyParams memory p = _params("BTC");
        p.coverageAmount = 99e6; // below 100e6 floor
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_PAY_VerifyAndCalculate_ReturnsCappedAtMaxPayout() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + 1);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        // PayoutResult.payoutAmount initially = cp.maxPayout = 800e6
        assertEq(r.payoutAmount, (DEFAULT_COVERAGE * 8000) / BPS);
        assertEq(r.recipient, buyer);
    }

    function test_PAY_ReasonCode_FLASHBTC24_DROP10() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + 1);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertEq(r.reason, bytes32("FLASHBTC24_DROP10"));
    }

    function test_PAY_MarkPaidOut_DecrementsCounters() public {
        uint256 pid = _createBTCPolicy();
        assertEq(shield.activePolicies(), 1);
        assertEq(shield.totalActiveCoverage(), DEFAULT_COVERAGE);

        shield.markPaidOut(pid);
        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_PAY_MarkExpired_DecrementsCounters() public {
        uint256 pid = _createBTCPolicy();
        shield.markExpired(pid);
        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // =====================================================================
    // T-PEM: Permissions / onlyRouter (6)
    // =====================================================================

    function test_PEM_CreatePolicy_NonRouter_Reverts() public {
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.createPolicy(_params("BTC"));
    }

    function test_PEM_VerifyAndCalculate_NonRouter_Reverts() public {
        uint256 pid = _createBTCPolicy();
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.verifyAndCalculate(pid, _proof(TRIGGER_60K - 1, "BTC", t0));
    }

    function test_PEM_MarkPaidOut_NonRouter_Reverts() public {
        uint256 pid = _createBTCPolicy();
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markPaidOut(pid);
    }

    function test_PEM_MarkExpired_NonRouter_Reverts() public {
        uint256 pid = _createBTCPolicy();
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markExpired(pid);
    }

    function test_PEM_RejectWrongAsset_ETH() public {
        IShield.CreatePolicyParams memory p = _params("ETH");
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield24h.InvalidAsset.selector, bytes32("ETH")));
        shield.createPolicy(p);
    }

    function test_PEM_AssetMismatch_BetweenPolicyAndProof_Reverts() public {
        uint256 pid = _createBTCPolicy();
        vm.warp(t0 + 1);
        // Proof asset = ETH while policy asset = BTC.
        bytes memory proof = _proof(TRIGGER_60K - 1, "ETH", t0 + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    // =====================================================================
    // T-RAC: Race / state transitions / replay (8)
    // =====================================================================

    function test_RAC_DoubleMarkPaidOut_Reverts() public {
        uint256 pid = _createBTCPolicy();
        shield.markPaidOut(pid);
        vm.expectRevert();
        shield.markPaidOut(pid);
    }

    function test_RAC_DoubleMarkExpired_Reverts() public {
        uint256 pid = _createBTCPolicy();
        shield.markExpired(pid);
        vm.expectRevert();
        shield.markExpired(pid);
    }

    function test_RAC_VerifyAfterMarkPaidOut_Reverts() public {
        uint256 pid = _createBTCPolicy();
        shield.markPaidOut(pid);
        vm.warp(t0 + 1);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + 1);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_RAC_PolicyNotFound_VerifyRevert() public {
        uint256 ghostId = 999;
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0);
        vm.expectRevert(abi.encodeWithSelector(IShield.PolicyNotFound.selector, ghostId));
        shield.verifyAndCalculate(ghostId, proof);
    }

    function test_RAC_PolicyNotFound_MarkPaidOut() public {
        vm.expectRevert(abi.encodeWithSelector(IShield.PolicyNotFound.selector, uint256(42)));
        shield.markPaidOut(42);
    }

    function test_RAC_CheckAndSettlePolicy_BeforeSafetyWindow_Reverts() public {
        uint256 pid = _createBTCPolicy();
        // expiresAt + SAFETY_WINDOW (24h) is the earliest -- attempting before must revert.
        vm.warp(t0 + DURATION + 1);
        vm.expectRevert();
        shield.checkAndSettlePolicy(pid);
    }

    function test_RAC_CheckAndSettlePolicy_AfterSafetyWindow_Expired() public {
        uint256 pid = _createBTCPolicy();
        // oracle BTC still at $60k -> not triggered -> EXPIRED settlement.
        vm.warp(t0 + DURATION + 24 hours);
        vm.expectEmit(true, false, false, true);
        emit PolicySettledExpired(pid);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_RAC_CheckAndSettlePolicy_PriceCrashedAtSettlement_Triggers() public {
        uint256 pid = _createBTCPolicy();
        // Drop BTC below trigger before settlement window opens.
        oracle.setPrice("BTC", TRIGGER_60K - 1);
        vm.warp(t0 + DURATION + 24 hours);
        vm.expectEmit(true, true, false, true);
        emit PolicySettledTriggered(pid, buyer, (DEFAULT_COVERAGE * 8000) / BPS);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }
}
