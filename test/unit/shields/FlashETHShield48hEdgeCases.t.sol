// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield48h} from "../../../src/products/FlashETHShield48h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// +============================================================================+
// | Sprint EE -- Phase C: 60 edge-case tests for FlashETHShield48h.            |
// |                                                                            |
// | Groups (60 total):                                                         |
// |   T-INIT   x6   Initialization / immutables / proxy wiring                 |
// |   T-CREATE x8   createPolicy gating + storage assignment                   |
// |   T-PRICE  x12  Per-asset sanity bounds [MIN_PRICE, MAX_PRICE]             |
// |   T-DUR    x6   Duration window (172800s == 48h, single-value range)       |
// |   T-PAYOUT x4   Max payout = 80% (20% deductible)                          |
// |   T-TRIG   x10  Trigger logic at +/-18% (TRIGGER_DROP_BPS=1800)            |
// |   T-PROOF  x8   EIP-712 proof verification + MAX_PROOF_AGE (900s)          |
// |   T-AUTH   x3   onlyRouter + setOracle authorisation                       |
// |   T-VIEW   x3   getBSSData + getPolicyInfo + counters                      |
// |                                                                            |
// | NOTE on warp: foundry.toml has via_ir=true; per memory                     |
// | `foundry_via_ir_warp.md`, `vm.warp(block.timestamp + delta)` caches the    |
// | initial block.timestamp under via_ir. We anchor warps to `t0` captured at  |
// | setUp() and always pass absolute timestamps.                               |
// +============================================================================+

// -----------------------------------------------------------------------------
// Mocks
// -----------------------------------------------------------------------------

/// @notice Mock oracle that implements both IOracle and the EIP-712 surface.
///         Sufficient for FlashETHShield48h: it consumes getLatestPrice() in
///         _doCreatePolicy and verifyPriceProofEIP712 in _doVerifyAndCalculate.
contract MockOracle48 {
    int256 public ethPrice;
    address public expectedSigner;
    uint256 public downtime;
    bool public revertOnPrice;
    bool public rejectAllSignatures;

    constructor() {
        expectedSigner = address(this);
        ethPrice = 3_000e8;
    }

    function setPrice(bytes32, int256 p) external {
        ethPrice = p;
    }

    function setEthPrice(int256 p) external {
        ethPrice = p;
    }

    function setRevertOnPrice(bool v) external {
        revertOnPrice = v;
    }

    function setRejectSignatures(bool v) external {
        rejectAllSignatures = v;
    }

    function setDowntime(uint256 d) external {
        downtime = d;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        if (revertOnPrice) revert("oracle down");
        if (asset == bytes32("ETH")) return ethPrice;
        return 0;
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return downtime;
    }

    function verifySignature(bytes32, bytes calldata) external view returns (address) {
        return rejectAllSignatures ? address(0) : expectedSigner;
    }

    function oracleKey() external view returns (address) {
        return expectedSigner;
    }

    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata sig) external view returns (address) {
        if (rejectAllSignatures) return address(0);
        if (sig.length == 0) return address(0);
        return expectedSigner;
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
        return bytes32(uint256(0xdeadbeef));
    }
}

// -----------------------------------------------------------------------------
// Test Contract
// -----------------------------------------------------------------------------

contract FlashETHShield48hEdgeCases is Test {
    // Constants
    uint32 internal constant DURATION_48H = 172800;
    bytes32 internal constant ETH_ASSET = bytes32("ETH");
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TRIGGER_DROP_BPS = 1800;
    uint256 internal constant DEDUCTIBLE_BPS = 2000;
    uint256 internal constant MAX_PROOF_AGE = 900;
    uint256 internal constant MIN_PRICE = 500 * 1e8;
    uint256 internal constant MAX_PRICE = 50_000 * 1e8;
    uint256 internal constant SAFETY_WINDOW = 24 hours;

    // Roles
    address internal router;
    address internal buyer;
    address internal stranger;

    // SUT
    FlashETHShield48h internal shield;
    MockOracle48 internal oracle;

    // Time anchor (via_ir-safe)
    uint256 internal t0;

    // Re-declared events for vm.expectEmit
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

    function setUp() public {
        vm.chainId(8453);
        router = makeAddr("router");
        buyer = makeAddr("buyer");
        stranger = makeAddr("stranger");

        oracle = new MockOracle48();
        oracle.setEthPrice(3_000e8);

        shield = ProxyDeployer.deployFlashETHShield48h(router, address(oracle));

        t0 = block.timestamp;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _params(uint256 coverage, uint32 dur, bytes32 asset)
        internal
        view
        returns (IShield.CreatePolicyParams memory p)
    {
        p.buyer = buyer;
        p.coverageAmount = coverage;
        p.premiumAmount = coverage / 100;
        p.durationSeconds = dur;
        p.asset = asset;
    }

    function _create(uint256 coverage) internal returns (uint256 pid) {
        vm.prank(router);
        pid = shield.createPolicy(_params(coverage, DURATION_48H, ETH_ASSET));
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes(hex"01"));
    }

    // =========================================================================
    // T-INIT (6): initialization, immutables, proxy wiring
    // =========================================================================

    function test_TINIT_01_ProductId_Matches_FLASHETH48_001() public view {
        assertEq(shield.productId(), keccak256("FLASHETH48-001"));
    }

    function test_TINIT_02_RiskType_Volatile() public view {
        assertEq(shield.riskType(), keccak256("VOLATILE"));
    }

    function test_TINIT_03_MaxAllocationBps_3000() public view {
        assertEq(shield.maxAllocationBps(), uint16(3000));
    }

    function test_TINIT_04_Router_And_Oracle_Wired() public view {
        assertEq(shield.router(), router);
        assertEq(shield.oracle(), address(oracle));
    }

    function test_TINIT_05_Reinitialize_Reverts() public {
        vm.expectRevert();
        shield.initialize(router, address(oracle));
    }

    function test_TINIT_06_ZeroOracle_AtInit_Reverts() public {
        vm.expectRevert();
        ProxyDeployer.deployFlashETHShield48h(router, address(0));
    }

    // =========================================================================
    // T-CREATE (8): createPolicy gating + storage assignment
    // =========================================================================

    function test_TCREATE_01_HappyPath_StoresStrike_And_Trigger() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);

        FlashETHShield48h.BSSData memory d = shield.getBSSData(pid);
        assertEq(d.asset, ETH_ASSET);
        assertEq(d.strikePrice, 3_000e8);
        // strike * (10000 - 1800) / 10000 = strike * 82 / 100
        int256 expected = int256(uint256(3_000e8) * (BPS - TRIGGER_DROP_BPS) / BPS);
        assertEq(d.triggerPrice, expected);
    }

    function test_TCREATE_02_NonRouter_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.createPolicy(_params(1_000e6, DURATION_48H, ETH_ASSET));
    }

    function test_TCREATE_03_WrongAsset_BTC_Reverts() public {
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(FlashETHShield48h.InvalidAsset.selector, bytes32("BTC")));
        shield.createPolicy(_params(1_000e6, DURATION_48H, bytes32("BTC")));
    }

    function test_TCREATE_04_WrongAsset_USDC_Reverts() public {
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(FlashETHShield48h.InvalidAsset.selector, bytes32("USDC")));
        shield.createPolicy(_params(1_000e6, DURATION_48H, bytes32("USDC")));
    }

    function test_TCREATE_05_ZeroPriceFromOracle_Reverts() public {
        oracle.setEthPrice(0);
        vm.prank(router);
        vm.expectRevert(FlashETHShield48h.InvalidOracleProof.selector);
        shield.createPolicy(_params(1_000e6, DURATION_48H, ETH_ASSET));
    }

    function test_TCREATE_06_NegativePriceFromOracle_Reverts() public {
        oracle.setEthPrice(-1);
        vm.prank(router);
        vm.expectRevert(FlashETHShield48h.InvalidOracleProof.selector);
        shield.createPolicy(_params(1_000e6, DURATION_48H, ETH_ASSET));
    }

    function test_TCREATE_07_CoverageBelowMin_Reverts() public {
        vm.prank(router);
        vm.expectRevert();
        shield.createPolicy(_params(50e6, DURATION_48H, ETH_ASSET));
    }

    function test_TCREATE_08_PolicyCounter_Increments() public {
        _create(1_000e6);
        _create(1_000e6);
        _create(1_000e6);
        assertEq(shield.totalPolicies(), 3);
        assertEq(shield.activePolicies(), 3);
        assertEq(shield.totalActiveCoverage(), 3_000e6);
    }

    // =========================================================================
    // T-PRICE (12): per-asset sanity bounds at create + at settlement
    // =========================================================================

    function test_TPRICE_01_AtMin_500_Accepted() public {
        oracle.setEthPrice(int256(MIN_PRICE));
        uint256 pid = _create(1_000e6);
        assertEq(shield.getBSSData(pid).strikePrice, int256(MIN_PRICE));
    }

    function test_TPRICE_02_AtMax_50k_Accepted() public {
        oracle.setEthPrice(int256(MAX_PRICE));
        uint256 pid = _create(1_000e6);
        assertEq(shield.getBSSData(pid).strikePrice, int256(MAX_PRICE));
    }

    function test_TPRICE_03_OneWeiBelowMin_Reverts() public {
        oracle.setEthPrice(int256(MIN_PRICE) - 1);
        vm.prank(router);
        vm.expectRevert();
        shield.createPolicy(_params(1_000e6, DURATION_48H, ETH_ASSET));
    }

    function test_TPRICE_04_OneWeiAboveMax_Reverts() public {
        oracle.setEthPrice(int256(MAX_PRICE) + 1);
        vm.prank(router);
        vm.expectRevert();
        shield.createPolicy(_params(1_000e6, DURATION_48H, ETH_ASSET));
    }

    function test_TPRICE_05_ExtremeAbove_100x_Reverts() public {
        oracle.setEthPrice(5_000_000e8);
        vm.prank(router);
        vm.expectRevert();
        shield.createPolicy(_params(1_000e6, DURATION_48H, ETH_ASSET));
    }

    function test_TPRICE_06_ExtremeBelow_1Dollar_Reverts() public {
        oracle.setEthPrice(1e8);
        vm.prank(router);
        vm.expectRevert();
        shield.createPolicy(_params(1_000e6, DURATION_48H, ETH_ASSET));
    }

    function test_TPRICE_07_Constants_MinPrice() public view {
        assertEq(shield.MIN_PRICE(), MIN_PRICE);
    }

    function test_TPRICE_08_Constants_MaxPrice() public view {
        assertEq(shield.MAX_PRICE(), MAX_PRICE);
    }

    function test_TPRICE_09_VerifiedPriceBelowMin_AtSettlement_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 100);
        bytes memory pf = _proof(int256(MIN_PRICE) - 1, ETH_ASSET, block.timestamp);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TPRICE_10_VerifiedPriceAboveMax_AtSettlement_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 100);
        bytes memory pf = _proof(int256(MAX_PRICE) + 1, ETH_ASSET, block.timestamp);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TPRICE_11_VerifiedPriceZero_AtSettlement_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 100);
        bytes memory pf = _proof(0, ETH_ASSET, block.timestamp);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TPRICE_12_VerifiedPriceNegative_AtSettlement_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 100);
        bytes memory pf = _proof(-1, ETH_ASSET, block.timestamp);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    // =========================================================================
    // T-DUR (6): duration window must be exactly 172800s
    // =========================================================================

    function test_TDUR_01_DurationRange_Is_48h_Fixed() public view {
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, DURATION_48H);
        assertEq(mx, DURATION_48H);
    }

    function test_TDUR_02_WaitingPeriod_Zero() public view {
        assertEq(shield.waitingPeriod(), uint32(0));
    }

    function test_TDUR_03_DurationBelow_Reverts() public {
        vm.prank(router);
        vm.expectRevert();
        shield.createPolicy(_params(1_000e6, DURATION_48H - 1, ETH_ASSET));
    }

    function test_TDUR_04_DurationAbove_Reverts() public {
        vm.prank(router);
        vm.expectRevert();
        shield.createPolicy(_params(1_000e6, DURATION_48H + 1, ETH_ASSET));
    }

    function test_TDUR_05_DurationZero_Reverts() public {
        vm.prank(router);
        vm.expectRevert();
        shield.createPolicy(_params(1_000e6, 0, ETH_ASSET));
    }

    function test_TDUR_06_ExpiresAt_EqualsStart_Plus_48h() public {
        uint256 pid = _create(1_000e6);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.expiresAt, info.startTimestamp + DURATION_48H);
        assertEq(info.waitingEndsAt, info.startTimestamp);
    }

    // =========================================================================
    // T-PAYOUT (4): max payout = 80% of coverage
    // =========================================================================

    function test_TPAYOUT_01_MaxPayout_Equals_80Pct_1000USDC() public {
        uint256 pid = _create(1_000e6);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, 800e6);
    }

    function test_TPAYOUT_02_MaxPayout_Equals_80Pct_5kUSDC() public {
        uint256 pid = _create(5_000e6);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, 4_000e6);
    }

    function test_TPAYOUT_03_DeductibleConstant_Is_2000Bps() public view {
        assertEq(shield.DEDUCTIBLE_BPS(), DEDUCTIBLE_BPS);
    }

    function test_TPAYOUT_04_TriggerDropConstant_Is_1800Bps() public view {
        assertEq(shield.TRIGGER_DROP_BPS(), TRIGGER_DROP_BPS);
    }

    // =========================================================================
    // T-TRIG (10): trigger fires at strike * 82%; not below if price >= trigger
    // =========================================================================

    function test_TTRIG_01_PriceAtTrigger_Triggers() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        int256 trig = shield.getBSSData(pid).triggerPrice;
        vm.warp(t0 + 1 hours);

        // verifiedPrice == trigger should NOT trigger (strict less-than payout: >= is rejected).
        bytes memory pf = _proof(trig, ETH_ASSET, block.timestamp);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TTRIG_02_PriceOneBelowTrigger_Triggers() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        int256 trig = shield.getBSSData(pid).triggerPrice;
        vm.warp(t0 + 1 hours);
        bytes memory pf = _proof(trig - 1, ETH_ASSET, block.timestamp);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered);
        assertEq(r.payoutAmount, 800e6);
        assertEq(r.reason, bytes32("FLASHETH48_DROP18"));
    }

    function test_TTRIG_03_PriceAboveStrike_NoTrigger() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 1 hours);
        bytes memory pf = _proof(3_500e8, ETH_ASSET, block.timestamp);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TTRIG_04_PriceAt15PctDrop_DoesNotTrigger() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 1 hours);
        int256 p15 = int256(uint256(3_000e8) * 8500 / BPS); // -15%
        bytes memory pf = _proof(p15, ETH_ASSET, block.timestamp);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TTRIG_05_PriceAt20PctDrop_Triggers() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 1 hours);
        int256 p20 = int256(uint256(3_000e8) * 8000 / BPS); // -20%
        bytes memory pf = _proof(p20, ETH_ASSET, block.timestamp);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered);
    }

    function test_TTRIG_06_CheckTrigger_OracleAtStrike_False() public {
        oracle.setEthPrice(3_000e8);
        _create(1_000e6);
        // No direct exposure to _checkTriggerCondition; use settlement after safety window.
        vm.warp(t0 + DURATION_48H + SAFETY_WINDOW + 1);
        // No revert: permissionless settle. Oracle still at strike -> not triggered.
        oracle.setEthPrice(3_000e8);
        vm.expectEmit(true, false, false, false);
        emit PolicySettledExpired(1);
        shield.checkAndSettlePolicy(1);
    }

    function test_TTRIG_07_CheckTrigger_OracleBelowTrigger_TriggersAtSettle() public {
        oracle.setEthPrice(3_000e8);
        _create(1_000e6);
        vm.warp(t0 + DURATION_48H + SAFETY_WINDOW + 1);
        // Now oracle goes below strike * 82%.
        oracle.setEthPrice(2_400e8); // -20%
        vm.expectEmit(true, true, false, false);
        emit PolicySettledTriggered(1, buyer, 800e6);
        shield.checkAndSettlePolicy(1);
    }

    function test_TTRIG_08_AssetMismatch_InProof_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 1 hours);
        bytes memory pf = _proof(2_400e8, bytes32("BTC"), block.timestamp);
        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(FlashETHShield48h.AssetMismatch.selector, bytes32("ETH"), bytes32("BTC"))
        );
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TTRIG_09_VerifiedAtBeforeWaiting_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 100);
        // verifiedAt strictly less than waitingEndsAt (== startTimestamp here).
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        bytes memory pf = _proof(2_400e8, ETH_ASSET, info.waitingEndsAt - 1);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TTRIG_10_VerifiedAtAfterExpiry_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        // Warp past expiry but inside cleanup grace.
        vm.warp(info.expiresAt + 1);
        bytes memory pf = _proof(2_400e8, ETH_ASSET, info.expiresAt + 1);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    // =========================================================================
    // T-PROOF (8): EIP-712 proof verification + MAX_PROOF_AGE
    // =========================================================================

    function test_TPROOF_01_InvalidSignature_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 1 hours);
        oracle.setRejectSignatures(true);
        bytes memory pf = _proof(2_400e8, ETH_ASSET, block.timestamp);
        vm.prank(router);
        vm.expectRevert(FlashETHShield48h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TPROOF_02_EmptySignature_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 1 hours);
        bytes memory pf = abi.encode(int256(2_400e8), ETH_ASSET, block.timestamp, bytes(""));
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TPROOF_03_ProofExactlyAt_MaxAge_Accepted() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        // verifiedAt = block.timestamp - 900: edge condition
        // block.timestamp > verifiedAt + MAX_PROOF_AGE iff block.timestamp > verifiedAt + 900.
        // We want equality (not strictly greater) -> accepted.
        vm.warp(t0 + 5_000);
        uint256 verifiedAt = block.timestamp - MAX_PROOF_AGE; // strict equality at boundary
        bytes memory pf = _proof(2_400e8, ETH_ASSET, verifiedAt);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered);
    }

    function test_TPROOF_04_ProofOneSecondTooOld_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 5_000);
        uint256 verifiedAt = block.timestamp - MAX_PROOF_AGE - 1;
        bytes memory pf = _proof(2_400e8, ETH_ASSET, verifiedAt);
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    function test_TPROOF_05_ProofConstant_Equals_900s() public view {
        assertEq(shield.MAX_PROOF_AGE(), MAX_PROOF_AGE);
    }

    function test_TPROOF_06_MalformedProof_Reverts() public {
        oracle.setEthPrice(3_000e8);
        _create(1_000e6);
        vm.warp(t0 + 100);
        bytes memory pf = hex"deadbeef"; // not abi.decodable as (int256, bytes32, uint256, bytes)
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(1, pf);
    }

    function test_TPROOF_07_NonRouterCannot_VerifyAndCalculate() public {
        oracle.setEthPrice(3_000e8);
        _create(1_000e6);
        vm.warp(t0 + 100);
        bytes memory pf = _proof(2_400e8, ETH_ASSET, block.timestamp);
        vm.prank(stranger);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.verifyAndCalculate(1, pf);
    }

    function test_TPROOF_08_PolicyAlreadyFinalized_Reverts() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        vm.warp(t0 + 1 hours);
        bytes memory pf = _proof(2_400e8, ETH_ASSET, block.timestamp);

        vm.prank(router);
        shield.verifyAndCalculate(pid, pf);

        vm.prank(router);
        shield.markPaidOut(pid);

        // Second call after finalization must revert.
        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    // =========================================================================
    // T-AUTH (3): onlyRouter + setOracle
    // =========================================================================

    function test_TAUTH_01_MarkPaidOut_NonRouter_Reverts() public {
        oracle.setEthPrice(3_000e8);
        _create(1_000e6);
        vm.prank(stranger);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markPaidOut(1);
    }

    function test_TAUTH_02_MarkExpired_NonRouter_Reverts() public {
        oracle.setEthPrice(3_000e8);
        _create(1_000e6);
        vm.prank(stranger);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markExpired(1);
    }

    function test_TAUTH_03_SetOracle_NonOwner_Reverts() public {
        MockOracle48 newOracle = new MockOracle48();
        vm.prank(stranger);
        vm.expectRevert();
        shield.setOracle(address(newOracle));
    }

    // =========================================================================
    // T-VIEW (3): getBSSData, getPolicyInfo, counters
    // =========================================================================

    function test_TVIEW_01_GetBSSData_UnknownPolicy_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IShield.PolicyNotFound.selector, uint256(999)));
        shield.getBSSData(999);
    }

    function test_TVIEW_02_GetPolicyInfo_UnknownPolicy_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IShield.PolicyNotFound.selector, uint256(999)));
        shield.getPolicyInfo(999);
    }

    function test_TVIEW_03_Counters_DecrementOnPaidOut() public {
        oracle.setEthPrice(3_000e8);
        uint256 pid = _create(1_000e6);
        assertEq(shield.activePolicies(), 1);
        assertEq(shield.totalActiveCoverage(), 1_000e6);

        vm.warp(t0 + 1 hours);
        bytes memory pf = _proof(2_400e8, ETH_ASSET, block.timestamp);
        vm.prank(router);
        shield.verifyAndCalculate(pid, pf);
        vm.prank(router);
        shield.markPaidOut(pid);

        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
        assertEq(shield.totalPolicies(), 1);
    }
}
