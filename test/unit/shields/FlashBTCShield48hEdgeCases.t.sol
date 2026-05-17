// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield48h} from "../../../src/products/FlashBTCShield48h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// +============================================================================+
// | Sprint EE -- Phase C: 60 edge-case tests for FlashBTCShield48h.            |
// |                                                                            |
// | Groups (60 total):                                                         |
// |   T-ORC  x12  Oracle revert / staleness / asset-mismatch / EIP-712 fail    |
// |   T-WIN  x10  Window boundaries (waitingEndsAt / expiresAt / safety / cleanup) |
// |   T-PRC  x10  Price sanity bounds + trigger math (15% drop)                |
// |   T-SEQ  x6   Sequencer downtime extending cleanup window                  |
// |   T-PAY  x8   Payout math (80% of coverage) + maxPayout cap                |
// |   T-PEM  x6   Permissions / onlyRouter / lifecycle finalization            |
// |   T-RAC  x8   Race / re-entrancy / replay-protection / double-finalize     |
// |                                                                            |
// | NOTE on warp: foundry.toml has via_ir=true; per memory                     |
// | `foundry_via_ir_warp.md`, vm.warp(block.timestamp + delta) caches the      |
// | initial block.timestamp under via_ir. We anchor warps to ANCHOR_TS         |
// | (captured at setUp() time) and always pass absolute timestamps.            |
// |                                                                            |
// | NOTE on proofs: BaseShield uses IOracleV2.verifyPriceProofEIP712 inside    |
// | _doVerifyAndCalculate. We mock the oracle contract entirely so we can     |
// | drive verifier outcomes (signer != 0 = valid, signer == 0 = invalid)      |
// | without needing real EIP-712 signing. The mock implements both IOracle    |
// | and IOracleV2 surfaces.                                                    |
// +============================================================================+

// -----------------------------------------------------------------------------
// Mocks
// -----------------------------------------------------------------------------

/// @notice Mock IOracle + IOracleV2 surface tailored for FlashBTCShield48h.
///         Lets each test toggle: price-per-asset, sequencer downtime,
///         EIP-712 verifier success/failure, and asset-mismatch payloads.
contract MockOracleEE is IOracleV2 {
    mapping(bytes32 => int256) public priceFor;
    uint256 public sequencerDowntime;
    address public authorizedKey;
    bool public eip712ReturnsSigner; // if true, verifyPriceProofEIP712 returns authorizedKey

    constructor() {
        authorizedKey = address(this);
        priceFor["BTC"] = 60_000e8;
        priceFor["ETH"] = 3_000e8;
        priceFor["USDC"] = 1e8;
        eip712ReturnsSigner = true;
    }

    // --- setters ---
    function setPrice(bytes32 asset, int256 p) external {
        priceFor[asset] = p;
    }

    function setSequencerDowntime(uint256 d) external {
        sequencerDowntime = d;
    }

    function setEip712ReturnsSigner(bool v) external {
        eip712ReturnsSigner = v;
    }

    // --- IOracle ---
    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return priceFor[asset];
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

    // --- IOracleV2 ---
    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata) external view returns (address) {
        return eip712ReturnsSigner ? authorizedKey : address(0);
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

contract FlashBTCShield48hEdgeCases is Test {
    // Re-declare events for vm.expectEmit matching. Solidity 0.8.20 requires events
    // to be in scope of the emitting contract; re-declaring with identical signature
    // is the standard foundry pattern when the event lives in another contract.
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

    MockOracleEE oracle;
    FlashBTCShield48h shield;

    address router; // this contract acts as the router
    address buyer = makeAddr("buyer");

    uint256 constant ANCHOR_TS = 1_700_000_000;
    uint32 constant DURATION = 172_800; // 48h
    uint256 constant COVERAGE = 1_000e6; // $1,000 USDC (6-dec)
    uint256 constant PREMIUM = 10e6; // $10 USDC

    bytes32 constant ASSET_BTC = bytes32("BTC");
    bytes32 constant ASSET_ETH = bytes32("ETH");

    uint256 constant BTC_STRIKE = 60_000e8; // $60k base price
    // Trigger = strike * (10000 - 1500) / 10000 = strike * 0.85.
    int256 constant BTC_TRIGGER = int256((60_000e8 * 8500) / 10000);

    function setUp() public {
        vm.chainId(8453);
        vm.warp(ANCHOR_TS);

        oracle = new MockOracleEE();
        router = address(this);
        shield = ProxyDeployer.deployFlashBTCShield48h(router, address(oracle));
    }

    // --- helpers ---

    function _params(bytes32 asset) internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = COVERAGE;
        p.premiumAmount = PREMIUM;
        p.durationSeconds = DURATION;
        p.asset = asset;
    }

    function _paramsCustom(bytes32 asset, uint32 dur, uint256 cov)
        internal
        view
        returns (IShield.CreatePolicyParams memory p)
    {
        p.buyer = buyer;
        p.coverageAmount = cov;
        p.premiumAmount = PREMIUM;
        p.durationSeconds = dur;
        p.asset = asset;
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes(""));
    }

    function _createOK() internal returns (uint256) {
        return shield.createPolicy(_params(ASSET_BTC));
    }

    function _maxPayout() internal pure returns (uint256) {
        // 80% of coverage (20% deductible).
        return (COVERAGE * 8000) / 10000;
    }

    // =====================================================================
    // T-ORC: Oracle revert / staleness / asset-mismatch / EIP-712 (12)
    // =====================================================================

    function test_ORC_OracleReturnsZero_RevertsAtCreate() public {
        oracle.setPrice(ASSET_BTC, 0);
        vm.expectRevert(FlashBTCShield48h.InvalidOracleProof.selector);
        shield.createPolicy(_params(ASSET_BTC));
    }

    function test_ORC_OracleReturnsNegative_RevertsAtCreate() public {
        oracle.setPrice(ASSET_BTC, -1);
        vm.expectRevert(FlashBTCShield48h.InvalidOracleProof.selector);
        shield.createPolicy(_params(ASSET_BTC));
    }

    function test_ORC_ProofTooOld_Reverts() public {
        uint256 pid = _createOK();
        // verifiedAt is older than block.timestamp - MAX_PROOF_AGE (900s).
        // Warp 30 minutes into the policy then submit a proof from 1h ago.
        vm.warp(ANCHOR_TS + 30 minutes);
        uint256 stale = block.timestamp - 901; // strictly > MAX_PROOF_AGE
        bytes memory pr = _proof(int256(BTC_TRIGGER) - 1, ASSET_BTC, stale);
        vm.expectRevert(
            abi.encodeWithSelector(FlashBTCShield48h.ProofTooOld.selector, stale, block.timestamp)
        );
        shield.verifyAndCalculate(pid, pr);
    }

    function test_ORC_ProofAtExactMaxAge_Accepted() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 30 minutes);
        uint256 boundary = block.timestamp - 900; // == MAX_PROOF_AGE
        bytes memory pr = _proof(int256(BTC_TRIGGER) - 1, ASSET_BTC, boundary);
        // Should pass age check and trigger payout.
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertTrue(r.triggered);
    }

    function test_ORC_EIP712VerifierFails_Reverts() public {
        uint256 pid = _createOK();
        oracle.setEip712ReturnsSigner(false);
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(int256(BTC_TRIGGER) - 1, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert(FlashBTCShield48h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, pr);
    }

    function test_ORC_VerifiedPriceZero_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(0, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert(FlashBTCShield48h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, pr);
    }

    function test_ORC_VerifiedPriceNegative_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(-1, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert(FlashBTCShield48h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, pr);
    }

    function test_ORC_AssetMismatch_ETH_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        // proofAsset = ETH but policy asset = BTC.
        bytes memory pr = _proof(int256(BTC_TRIGGER) - 1, ASSET_ETH, block.timestamp - 10);
        vm.expectRevert(
            abi.encodeWithSelector(FlashBTCShield48h.AssetMismatch.selector, ASSET_BTC, ASSET_ETH)
        );
        shield.verifyAndCalculate(pid, pr);
    }

    function test_ORC_AssetMismatch_RandomBytes_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes32 garbage = bytes32(uint256(0xdeadbeef));
        bytes memory pr = _proof(int256(BTC_TRIGGER) - 1, garbage, block.timestamp - 10);
        vm.expectRevert(
            abi.encodeWithSelector(FlashBTCShield48h.AssetMismatch.selector, ASSET_BTC, garbage)
        );
        shield.verifyAndCalculate(pid, pr);
    }

    function test_ORC_InvalidAssetAtCreate_USDC_Reverts() public {
        // FlashBTCShield48h._doCreatePolicy enforces asset == "BTC".
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield48h.InvalidAsset.selector, bytes32("USDC")));
        shield.createPolicy(_params(bytes32("USDC")));
    }

    function test_ORC_InvalidAssetAtCreate_ETH_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield48h.InvalidAsset.selector, ASSET_ETH));
        shield.createPolicy(_params(ASSET_ETH));
    }

    function test_ORC_OracleRotate_NewOracleUsedOnNextCreate() public {
        // Deploy a second mock and rotate. The new oracle returns a different
        // price, which proves the shield is now reading from it.
        MockOracleEE newOracle = new MockOracleEE();
        newOracle.setPrice(ASSET_BTC, 90_000e8);
        vm.expectEmit(true, true, false, false);
        emit OracleRotated(address(oracle), address(newOracle));
        shield.setOracle(address(newOracle));
        uint256 pid = shield.createPolicy(_params(ASSET_BTC));
        assertEq(shield.getBSSData(pid).strikePrice, 90_000e8);
    }

    // =====================================================================
    // T-WIN: Window boundaries (10)
    // =====================================================================

    function test_WIN_DurationBelowMin_Reverts() public {
        // MIN_DURATION = MAX_DURATION = 172800 -- anything else reverts.
        vm.expectRevert(
            abi.encodeWithSelector(IShield.DurationOutOfRange.selector, uint32(172_799), DURATION, DURATION)
        );
        shield.createPolicy(_paramsCustom(ASSET_BTC, 172_799, COVERAGE));
    }

    function test_WIN_DurationAboveMax_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IShield.DurationOutOfRange.selector, uint32(172_801), DURATION, DURATION)
        );
        shield.createPolicy(_paramsCustom(ASSET_BTC, 172_801, COVERAGE));
    }

    function test_WIN_WaitingPeriodIsZero() public view {
        assertEq(shield.waitingPeriod(), 0, "WAITING_PERIOD must be 0 for flash shields");
    }

    function test_WIN_ExpiresAtIsStartPlusDuration() public {
        uint256 pid = _createOK();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.waitingEndsAt, ANCHOR_TS, "wait=0");
        assertEq(info.expiresAt, ANCHOR_TS + DURATION, "expiresAt=start+48h");
    }

    function test_WIN_ProofBeforeWaitingEnds_Reverts() public {
        // waitingEndsAt == startTimestamp (wp=0). Use verifiedAt strictly before
        // waitingEndsAt by giving it timestamp t0-1.
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        uint256 vAt = ANCHOR_TS - 1; // before waitingEndsAt
        bytes memory pr = _proof(int256(BTC_TRIGGER) - 1, ASSET_BTC, vAt);
        // verifiedAt < waitingEndsAt triggers EventAfterExpiry per the contract.
        vm.expectRevert(
            abi.encodeWithSelector(BaseShield.EventAfterExpiry.selector, pid, vAt, ANCHOR_TS + DURATION)
        );
        shield.verifyAndCalculate(pid, pr);
    }

    function test_WIN_ProofAfterExpiry_Reverts() public {
        uint256 pid = _createOK();
        // Warp slightly past expiry but still within cleanup window (24h grace).
        vm.warp(ANCHOR_TS + DURATION + 10);
        uint256 vAt = ANCHOR_TS + DURATION + 1; // strictly after expiresAt
        bytes memory pr = _proof(int256(BTC_TRIGGER) - 1, ASSET_BTC, vAt);
        vm.expectRevert(
            abi.encodeWithSelector(BaseShield.EventAfterExpiry.selector, pid, vAt, ANCHOR_TS + DURATION)
        );
        shield.verifyAndCalculate(pid, pr);
    }

    function test_WIN_ProofExactlyAtExpiry_Accepted() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + DURATION);
        // verifiedAt == expiresAt is allowed (check uses strict `>`).
        bytes memory pr = _proof(int256(BTC_TRIGGER) - 1, ASSET_BTC, ANCHOR_TS + DURATION);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertTrue(r.triggered);
    }

    function test_WIN_SettleBeforeSafetyWindow_Reverts() public {
        uint256 pid = _createOK();
        // safety window = 24h after expiry; calling earlier reverts.
        vm.warp(ANCHOR_TS + DURATION + 1 hours);
        uint256 earliest = ANCHOR_TS + DURATION + 24 hours;
        vm.expectRevert(
            abi.encodeWithSelector(BaseShield.SafetyWindowNotPassed.selector, pid, earliest, block.timestamp)
        );
        shield.checkAndSettlePolicy(pid);
    }

    function test_WIN_SettleAfterSafetyWindow_NoTrigger_Expired() public {
        uint256 pid = _createOK();
        // No price drop -> trigger condition false -> settled as expired.
        vm.warp(ANCHOR_TS + DURATION + 24 hours + 1);
        vm.expectEmit(true, false, false, false);
        emit PolicySettledExpired(pid);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    function test_WIN_SettleAfterSafetyWindow_Triggered_PaidOut() public {
        uint256 pid = _createOK();
        oracle.setPrice(ASSET_BTC, BTC_TRIGGER - 1); // below trigger -> settled-triggered
        vm.warp(ANCHOR_TS + DURATION + 24 hours + 1);
        vm.expectEmit(true, true, false, true);
        emit PolicySettledTriggered(pid, buyer, _maxPayout());
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    // =====================================================================
    // T-PRC: Price sanity bounds + trigger math (10)
    // =====================================================================

    function test_PRC_MinPriceBoundary_Accepted() public {
        oracle.setPrice(ASSET_BTC, int256(uint256(10_000e8))); // == MIN_PRICE
        uint256 pid = _createOK();
        assertEq(shield.getBSSData(pid).strikePrice, int256(uint256(10_000e8)));
    }

    function test_PRC_OneWeiBelowMin_Reverts() public {
        oracle.setPrice(ASSET_BTC, int256(uint256(10_000e8)) - 1);
        vm.expectRevert();
        shield.createPolicy(_params(ASSET_BTC));
    }

    function test_PRC_MaxPriceBoundary_Accepted() public {
        oracle.setPrice(ASSET_BTC, int256(uint256(1_000_000e8))); // == MAX_PRICE
        uint256 pid = _createOK();
        assertEq(shield.getBSSData(pid).strikePrice, int256(uint256(1_000_000e8)));
    }

    function test_PRC_OneWeiAboveMax_Reverts() public {
        oracle.setPrice(ASSET_BTC, int256(uint256(1_000_000e8)) + 1);
        vm.expectRevert();
        shield.createPolicy(_params(ASSET_BTC));
    }

    function test_PRC_TriggerEquals85Percent() public {
        uint256 pid = _createOK();
        FlashBTCShield48h.BSSData memory d = shield.getBSSData(pid);
        // Trigger = strike * (10000 - 1500) / 10000 = strike * 0.85.
        assertEq(d.triggerPrice, BTC_TRIGGER);
    }

    function test_PRC_PriceAboveTrigger_NotTriggered_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert(
            abi.encodeWithSelector(IShield.TriggerNotMet.selector, pid, bytes32("PRICE_ABOVE_TRIGGER"))
        );
        shield.verifyAndCalculate(pid, pr);
    }

    function test_PRC_PriceJustBelowTrigger_Triggered() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertTrue(r.triggered);
        assertEq(r.reason, bytes32("FLASHBTC48_DROP15"));
    }

    function test_PRC_VerifiedPriceAboveMaxBound_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(int256(uint256(1_000_000e8)) + 1, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pr);
    }

    function test_PRC_VerifiedPriceBelowMinBound_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(int256(uint256(10_000e8)) - 1, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pr);
    }

    function test_PRC_ExactlyAtTrigger_NotTriggered() public {
        // Contract uses `>=` to revert: verifiedPrice >= triggerPrice -> revert.
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert(
            abi.encodeWithSelector(IShield.TriggerNotMet.selector, pid, bytes32("PRICE_ABOVE_TRIGGER"))
        );
        shield.verifyAndCalculate(pid, pr);
    }

    // =====================================================================
    // T-SEQ: Sequencer downtime extends cleanup window (6)
    // =====================================================================

    function test_SEQ_NoDowntime_PastCleanup_StatusInvalid() public {
        uint256 pid = _createOK();
        // cleanupAt = expiresAt + CLAIM_GRACE_PERIOD(24h). Past that, status check
        // fires before oracle proof verification.
        vm.warp(ANCHOR_TS + DURATION + 24 hours + 1);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, ANCHOR_TS + DURATION);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pr);
    }

    function test_SEQ_Downtime1h_CoversGap_StatusPasses() public {
        uint256 pid = _createOK();
        oracle.setSequencerDowntime(1 hours);
        // 30 minutes past cleanup -- downtime extension makes this still valid.
        vm.warp(ANCHOR_TS + DURATION + 24 hours + 30 minutes);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, ANCHOR_TS + DURATION);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertTrue(r.triggered);
    }

    function test_SEQ_Downtime1h_PastExtendedCleanup_StatusInvalid() public {
        uint256 pid = _createOK();
        oracle.setSequencerDowntime(1 hours);
        // 1h + 1s past cleanup -- past the extended deadline.
        vm.warp(ANCHOR_TS + DURATION + 24 hours + 1 hours + 1);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, ANCHOR_TS + DURATION);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pr);
    }

    function test_SEQ_DowntimeZero_ExactlyAtCleanup_StatusInvalid() public {
        uint256 pid = _createOK();
        // adjustedCleanupAt = cleanupAt + 0. Check uses `>=` so exact = invalid.
        vm.warp(ANCHOR_TS + DURATION + 24 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, ANCHOR_TS + DURATION);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pr);
    }

    function test_SEQ_DowntimeLarge_FarPastCleanup_Covered() public {
        uint256 pid = _createOK();
        // 7-day downtime extension. Even 6 days past cleanup is still inside the
        // extended window.
        oracle.setSequencerDowntime(7 days);
        vm.warp(ANCHOR_TS + DURATION + 24 hours + 6 days);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, ANCHOR_TS + DURATION);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertTrue(r.triggered);
    }

    function test_SEQ_DowntimeExactlyMatchesGap_StatusInvalid() public {
        uint256 pid = _createOK();
        // adjustedCleanupAt = cleanupAt + downtime. Caller arrives exactly at it
        // -- `block.timestamp >= adjustedCleanupAt` -> revert.
        oracle.setSequencerDowntime(30 minutes);
        vm.warp(ANCHOR_TS + DURATION + 24 hours + 30 minutes);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, ANCHOR_TS + DURATION);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pr);
    }

    // =====================================================================
    // T-PAY: Payout math (8)
    // =====================================================================

    function test_PAY_MaxPayoutIs80Percent() public {
        uint256 pid = _createOK();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, (COVERAGE * 8000) / 10000, "maxPayout=80% of coverage");
    }

    function test_PAY_PayoutEqualsMaxPayout_OnTrigger() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertEq(r.payoutAmount, _maxPayout(), "payout==maxPayout(80%)");
        assertEq(r.recipient, buyer, "recipient is policy insured");
    }

    function test_PAY_PayoutReasonIsFlashBTC48Drop15() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertEq(r.reason, bytes32("FLASHBTC48_DROP15"));
    }

    function test_PAY_LargeCoverage_Payout80Percent() public {
        uint256 cov = 100_000e6; // $100k
        uint256 pid = shield.createPolicy(_paramsCustom(ASSET_BTC, DURATION, cov));
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertEq(r.payoutAmount, (cov * 8000) / 10000);
    }

    function test_PAY_MinCoverage_Accepted() public {
        // _minCoverage = 100e6 (= $100).
        uint256 pid = shield.createPolicy(_paramsCustom(ASSET_BTC, DURATION, 100e6));
        assertGt(pid, 0);
    }

    function test_PAY_BelowMinCoverage_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IShield.CoverageOutOfRange.selector, uint256(99e6), uint256(100e6), type(uint256).max)
        );
        shield.createPolicy(_paramsCustom(ASSET_BTC, DURATION, 99e6));
    }

    function test_PAY_RecipientIsBuyer_NotMsgSender() public {
        // The PayoutResult.recipient is forced to cp.insuredAgent (= params.buyer)
        // regardless of who called verifyAndCalculate.
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertEq(r.recipient, buyer);
    }

    function test_PAY_PayoutCappedAtMaxPayout_NotCoverage() public {
        // BaseShield clamps result.payoutAmount to cp.maxPayout. Since this
        // shield already sets payoutAmount = cp.maxPayout in _doVerifyAndCalculate,
        // the value never exceeds it -- this test pins down that invariant.
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertLe(r.payoutAmount, _maxPayout());
        assertEq(r.payoutAmount, _maxPayout());
    }

    // =====================================================================
    // T-PEM: Permissions / lifecycle (6)
    // =====================================================================

    function test_PEM_CreatePolicy_NonRouter_Reverts() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.createPolicy(_params(ASSET_BTC));
    }

    function test_PEM_VerifyAndCalculate_NonRouter_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.verifyAndCalculate(pid, pr);
    }

    function test_PEM_MarkPaidOut_NonRouter_Reverts() public {
        uint256 pid = _createOK();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markPaidOut(pid);
    }

    function test_PEM_MarkExpired_NonRouter_Reverts() public {
        uint256 pid = _createOK();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markExpired(pid);
    }

    function test_PEM_SetOracle_NonOwner_Reverts() public {
        MockOracleEE other = new MockOracleEE();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        shield.setOracle(address(other));
    }

    function test_PEM_GetBSSData_UnknownPolicy_Reverts() public {
        uint256 unknown = 12345;
        vm.expectRevert(abi.encodeWithSelector(IShield.PolicyNotFound.selector, unknown));
        shield.getBSSData(unknown);
    }

    // =====================================================================
    // T-RAC: Race / replay / double-finalize / counter accounting (8)
    // =====================================================================

    function test_RAC_DoubleMarkPaidOut_Reverts() public {
        uint256 pid = _createOK();
        shield.markPaidOut(pid);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShield.InvalidPolicyStatus.selector,
                pid,
                IShield.PolicyStatus.PAID_OUT,
                IShield.PolicyStatus.ACTIVE
            )
        );
        shield.markPaidOut(pid);
    }

    function test_RAC_MarkExpiredAfterPaidOut_Reverts() public {
        uint256 pid = _createOK();
        shield.markPaidOut(pid);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShield.InvalidPolicyStatus.selector,
                pid,
                IShield.PolicyStatus.PAID_OUT,
                IShield.PolicyStatus.ACTIVE
            )
        );
        shield.markExpired(pid);
    }

    function test_RAC_MarkPaidOutAfterExpired_Reverts() public {
        uint256 pid = _createOK();
        shield.markExpired(pid);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShield.InvalidPolicyStatus.selector,
                pid,
                IShield.PolicyStatus.EXPIRED,
                IShield.PolicyStatus.ACTIVE
            )
        );
        shield.markPaidOut(pid);
    }

    function test_RAC_DoubleSettle_Reverts() public {
        uint256 pid = _createOK();
        vm.warp(ANCHOR_TS + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pid);
        vm.expectRevert();
        shield.checkAndSettlePolicy(pid);
    }

    function test_RAC_VerifyAfterPaidOut_Reverts() public {
        uint256 pid = _createOK();
        shield.markPaidOut(pid);
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShield.InvalidPolicyStatus.selector,
                pid,
                IShield.PolicyStatus.PAID_OUT,
                IShield.PolicyStatus.ACTIVE
            )
        );
        shield.verifyAndCalculate(pid, pr);
    }

    function test_RAC_VerifyAfterExpired_Reverts() public {
        uint256 pid = _createOK();
        shield.markExpired(pid);
        vm.warp(ANCHOR_TS + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert(
            abi.encodeWithSelector(
                IShield.InvalidPolicyStatus.selector,
                pid,
                IShield.PolicyStatus.EXPIRED,
                IShield.PolicyStatus.ACTIVE
            )
        );
        shield.verifyAndCalculate(pid, pr);
    }

    function test_RAC_CountersAdvanceOnCreate() public {
        assertEq(shield.totalPolicies(), 0);
        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
        uint256 pid = _createOK();
        assertEq(shield.totalPolicies(), 1);
        assertEq(shield.activePolicies(), 1);
        assertEq(shield.totalActiveCoverage(), COVERAGE);
        // After finalization, activePolicies decrements but totalPolicies sticks.
        shield.markPaidOut(pid);
        assertEq(shield.totalPolicies(), 1);
        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
    }

    function test_RAC_VerifyUnknownPolicy_Reverts() public {
        uint256 unknown = 9999;
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, ANCHOR_TS + 1);
        vm.expectRevert(abi.encodeWithSelector(IShield.PolicyNotFound.selector, unknown));
        shield.verifyAndCalculate(unknown, pr);
    }
}
