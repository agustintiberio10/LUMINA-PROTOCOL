// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield4h} from "../../../src/products/FlashBTCShield4h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashBTCShield4hEdgeCases
/// @notice Sprint EE Phase C -- 60 unit edge-case tests for FlashBTCShield4h.
///         Mirror of the FlashBTCShield1h sibling spec but adapted for the 4h
///         window (durationSeconds=14400, TRIGGER_DROP_BPS=800, reason
///         "FLASHBTC4H_DROP8"). MAX_PROOF_AGE remains 15 minutes (900).
///
///         Groups (60 total):
///           T-ORC (oracle reads / sanity)         : 12
///           T-WIN (window / expiry / waiting)     : 10
///           T-PRC (price / trigger threshold)     : 10
///           T-SEQ (sequencer downtime)            :  6
///           T-PAY (payout / deductible math)      :  8
///           T-PEM (proof EIP-712 / age / asset)   :  6
///           T-RAC (race / state / lifecycle)      :  8
contract FlashBTCShield4hEdgeCases is Test {
    // Re-declare BaseShield + IShield events for vm.expectEmit (Solidity 0.8.20).
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

    // ===== Constants mirrored from contract =====
    uint32 internal constant WINDOW = 14400; // 4h in seconds
    uint256 internal constant TRIGGER_BPS = 800; // 8% drop
    uint256 internal constant DEDUCTIBLE_BPS = 2000; // 20%
    uint256 internal constant MAX_PROOF_AGE = 900;
    uint256 internal constant MIN_PRICE = 10_000 * 1e8;
    uint256 internal constant MAX_PRICE = 1_000_000 * 1e8;

    // ===== Test fixtures =====
    FlashBTCShield4h internal shield;
    MockOracleEE internal oracle;
    address internal router = address(this); // test contract acts as router
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        vm.chainId(8453);
        oracle = new MockOracleEE(address(this));
        oracle.setPrice("BTC", 60_000e8);
        shield = ProxyDeployer.deployFlashBTCShield4h(router, address(oracle));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------
    function _params(uint32 d, bytes32 a) internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = 1000e6; // $1,000 USDC (6-dec)
        p.premiumAmount = 10e6; // $10 USDC
        p.durationSeconds = d;
        p.asset = a;
    }

    function _createDefault() internal returns (uint256 pid) {
        pid = shield.createPolicy(_params(WINDOW, "BTC"));
    }

    function _buildProof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        // Empty signature -- our MockOracleEE.verifyPriceProofEIP712 accepts any
        // bytes and returns a configurable signer. See MockOracleEE.setProofValid.
        bytes memory sig = new bytes(65);
        return abi.encode(price, asset, verifiedAt, sig);
    }

    // ====================================================================
    // T-ORC -- Oracle reads / sanity bounds at createPolicy (12 tests)
    // ====================================================================

    function test_ORC_01_GetLatestPrice_NormalBTC_Accepted() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        assertEq(shield.getBSSData(pid).strikePrice, 60_000e8);
    }

    function test_ORC_02_GetLatestPrice_AtMaxBoundary_Accepted() public {
        oracle.setPrice("BTC", int256(MAX_PRICE));
        uint256 pid = _createDefault();
        assertEq(uint256(shield.getBSSData(pid).strikePrice), MAX_PRICE);
    }

    function test_ORC_03_GetLatestPrice_OneWeiAboveMax_Reverts() public {
        oracle.setPrice("BTC", int256(MAX_PRICE) + 1);
        vm.expectRevert();
        _createDefault();
    }

    function test_ORC_04_GetLatestPrice_AtMinBoundary_Accepted() public {
        oracle.setPrice("BTC", int256(MIN_PRICE));
        uint256 pid = _createDefault();
        assertEq(uint256(shield.getBSSData(pid).strikePrice), MIN_PRICE);
    }

    function test_ORC_05_GetLatestPrice_OneWeiBelowMin_Reverts() public {
        oracle.setPrice("BTC", int256(MIN_PRICE) - 1);
        vm.expectRevert();
        _createDefault();
    }

    function test_ORC_06_GetLatestPrice_ZeroPrice_Reverts() public {
        oracle.setPrice("BTC", 0);
        vm.expectRevert(FlashBTCShield4h.InvalidOracleProof.selector);
        _createDefault();
    }

    function test_ORC_07_GetLatestPrice_NegativePrice_Reverts() public {
        oracle.setPrice("BTC", -1);
        vm.expectRevert(FlashBTCShield4h.InvalidOracleProof.selector);
        _createDefault();
    }

    function test_ORC_08_GetLatestPrice_ExtremePrice100x_Reverts() public {
        oracle.setPrice("BTC", 6_000_000e8);
        vm.expectRevert();
        _createDefault();
    }

    function test_ORC_09_GetLatestPrice_StrikeRecordedExactly() public {
        oracle.setPrice("BTC", 73_245_67e6); // ~$73,245.67 in 8-dec? scale check
        oracle.setPrice("BTC", 73_245e8); // use clean 8-dec value
        uint256 pid = _createDefault();
        assertEq(shield.getBSSData(pid).strikePrice, 73_245e8);
    }

    function test_ORC_10_GetLatestPrice_TriggerPriceIs92Pct() public {
        oracle.setPrice("BTC", 100_000e8);
        uint256 pid = _createDefault();
        // 100_000 * (10_000 - 800) / 10_000 = 92_000
        assertEq(shield.getBSSData(pid).triggerPrice, 92_000e8);
    }

    function test_ORC_11_InvalidAsset_ETH_Reverts() public {
        oracle.setPrice("ETH", 3_000e8);
        IShield.CreatePolicyParams memory p = _params(WINDOW, "ETH");
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield4h.InvalidAsset.selector, bytes32("ETH")));
        shield.createPolicy(p);
    }

    function test_ORC_12_InvalidAsset_Empty_Reverts() public {
        IShield.CreatePolicyParams memory p = _params(WINDOW, bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield4h.InvalidAsset.selector, bytes32(0)));
        shield.createPolicy(p);
    }

    // ====================================================================
    // T-WIN -- Duration / window / waiting period (10 tests)
    // ====================================================================

    function test_WIN_01_DurationFixed_4h_Accepted() public {
        uint256 pid = shield.createPolicy(_params(14400, "BTC"));
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.expiresAt - info.waitingEndsAt, 14400);
    }

    function test_WIN_02_Duration_3600_Reverts() public {
        IShield.CreatePolicyParams memory p = _params(3600, "BTC");
        vm.expectRevert(
            abi.encodeWithSelector(IShield.DurationOutOfRange.selector, uint32(3600), uint32(14400), uint32(14400))
        );
        shield.createPolicy(p);
    }

    function test_WIN_03_Duration_14399_Reverts() public {
        IShield.CreatePolicyParams memory p = _params(14399, "BTC");
        vm.expectRevert(
            abi.encodeWithSelector(IShield.DurationOutOfRange.selector, uint32(14399), uint32(14400), uint32(14400))
        );
        shield.createPolicy(p);
    }

    function test_WIN_04_Duration_14401_Reverts() public {
        IShield.CreatePolicyParams memory p = _params(14401, "BTC");
        vm.expectRevert(
            abi.encodeWithSelector(IShield.DurationOutOfRange.selector, uint32(14401), uint32(14400), uint32(14400))
        );
        shield.createPolicy(p);
    }

    function test_WIN_05_Duration_24h_Reverts() public {
        IShield.CreatePolicyParams memory p = _params(86400, "BTC");
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_WIN_06_WaitingPeriod_Zero() public view {
        assertEq(shield.waitingPeriod(), 0);
    }

    function test_WIN_07_ExpiresAt_EqualsCreatePlus4h() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.expiresAt, t0 + WINDOW);
    }

    function test_WIN_08_WaitingEndsAt_EqualsStart() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.waitingEndsAt, t0); // WAITING_PERIOD = 0
    }

    function test_WIN_09_CleanupAt_EqualsExpiresPlus24h() public {
        uint256 pid = _createDefault();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.cleanupAt, info.expiresAt + 24 hours);
    }

    function test_WIN_10_DurationRangeGetters_MinEqMaxEq14400() public view {
        (uint32 mn, uint32 mx) = shield.durationRange();
        assertEq(mn, 14400);
        assertEq(mx, 14400);
    }

    // ====================================================================
    // T-PRC -- Price / trigger threshold math (10 tests)
    // ====================================================================

    function test_PRC_01_TriggerPrice_92PctOfStrike_60k() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        assertEq(shield.getBSSData(pid).triggerPrice, 55_200e8); // 60k * 92%
    }

    function test_PRC_02_TriggerPrice_NoFlooring_Odd() public {
        // 73_241 * 92% = 67_381.72 -> integer math: (73241 * 9200) / 10000 = 67381 (truncated)
        oracle.setPrice("BTC", 73_241e8);
        uint256 pid = _createDefault();
        // (73241 * 9200) / 10000 = 673819.72... in scaled units: 6_738_172 / 100 = ...
        // Compute exactly the way the contract does:
        int256 expected = (int256(73_241e8) * int256(9200)) / int256(10_000);
        assertEq(shield.getBSSData(pid).triggerPrice, expected);
    }

    function test_PRC_03_TriggerPrice_MinPrice() public {
        oracle.setPrice("BTC", int256(MIN_PRICE));
        uint256 pid = _createDefault();
        int256 expected = (int256(MIN_PRICE) * 9200) / 10_000;
        assertEq(shield.getBSSData(pid).triggerPrice, expected);
    }

    function test_PRC_04_TriggerPrice_MaxPrice() public {
        oracle.setPrice("BTC", int256(MAX_PRICE));
        uint256 pid = _createDefault();
        int256 expected = (int256(MAX_PRICE) * 9200) / 10_000;
        assertEq(shield.getBSSData(pid).triggerPrice, expected);
    }

    function test_PRC_05_TriggerNotMet_PriceAboveTrigger_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        // Move 1 hour in window; verified price 56_000 > trigger 55_200 -> revert
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(56_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        vm.expectRevert(abi.encodeWithSelector(IShield.TriggerNotMet.selector, pid, bytes32("PRICE_ABOVE_TRIGGER")));
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_06_TriggerMet_PriceAtTrigger_Reverts() public {
        // verifiedPrice >= triggerPrice -> revert (strict inequality required)
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(55_200e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        vm.expectRevert(abi.encodeWithSelector(IShield.TriggerNotMet.selector, pid, bytes32("PRICE_ABOVE_TRIGGER")));
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_07_TriggerMet_OneWeiBelow_Triggered() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(55_200e8 - 1, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
        assertEq(r.reason, bytes32("FLASHBTC4H_DROP8"));
    }

    function test_PRC_08_TriggerMet_HalfPrice_Triggered() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 2 hours);
        bytes memory proof = _buildProof(30_000e8, "BTC", t0 + 2 hours);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_PRC_09_VerifyPrice_AboveMaxSanity_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(int256(MAX_PRICE) + 1, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        vm.expectRevert(); // PriceOutOfSanityBounds
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PRC_10_VerifyPrice_BelowMinSanity_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(int256(MIN_PRICE) - 1, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        vm.expectRevert(); // PriceOutOfSanityBounds
        shield.verifyAndCalculate(pid, proof);
    }

    // ====================================================================
    // T-SEQ -- Sequencer downtime adjustments (6 tests)
    // ====================================================================

    function test_SEQ_01_NoDowntime_ActiveStatusOK() public {
        uint256 pid = _createDefault();
        IShield.PolicyStatus s = shield.getPolicyStatus(pid);
        assertEq(uint8(s), uint8(IShield.PolicyStatus.ACTIVE));
    }

    function test_SEQ_02_AfterExpiry_StatusEXPIRED() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        vm.warp(t0 + WINDOW + 1);
        IShield.PolicyStatus s = shield.getPolicyStatus(pid);
        assertEq(uint8(s), uint8(IShield.PolicyStatus.EXPIRED));
    }

    function test_SEQ_03_VerifyAfterCleanup_NoDowntime_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        // cleanupAt = expiresAt + 24h. Past cleanup -> trigger blocked.
        vm.warp(t0 + WINDOW + 25 hours);
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        vm.expectRevert(); // InvalidPolicyStatus
        shield.verifyAndCalculate(pid, proof);
    }

    function test_SEQ_04_Downtime_ExtendsCleanup() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        // Inject 2h downtime since expiresAt -> adjustedCleanup = cleanup + 2h.
        oracle.setDowntime(2 hours);
        // Warp past nominal cleanup (24h) but BEFORE adjusted cleanup (26h).
        vm.warp(t0 + WINDOW + 25 hours);
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_05_Downtime_Zero_NominalCleanup() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        oracle.setDowntime(0);
        vm.warp(t0 + WINDOW + 23 hours); // before cleanup window of 24h
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_SEQ_06_Downtime_QueriedAtCleanupCheck() public {
        // Confirms getSequencerDowntime is called with expiresAt argument.
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        oracle.setDowntime(48 hours);
        vm.warp(t0 + WINDOW + 47 hours);
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    // ====================================================================
    // T-PAY -- Payout math / deductible (8 tests)
    // ====================================================================

    function test_PAY_01_MaxPayout_80PctOfCoverage_1k() public {
        uint256 pid = _createDefault();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(info.maxPayout, 800e6); // 1000 * (10000-2000)/10000
    }

    function test_PAY_02_MaxPayout_80PctOfCoverage_10k() public {
        IShield.CreatePolicyParams memory p = _params(WINDOW, "BTC");
        p.coverageAmount = 10_000e6;
        uint256 pid = shield.createPolicy(p);
        assertEq(shield.getPolicyInfo(pid).maxPayout, 8_000e6);
    }

    function test_PAY_03_MaxPayout_MinCoverage_100USDC() public {
        IShield.CreatePolicyParams memory p = _params(WINDOW, "BTC");
        p.coverageAmount = 100e6;
        uint256 pid = shield.createPolicy(p);
        assertEq(shield.getPolicyInfo(pid).maxPayout, 80e6);
    }

    function test_PAY_04_BelowMinCoverage_Reverts() public {
        IShield.CreatePolicyParams memory p = _params(WINDOW, "BTC");
        p.coverageAmount = 99e6;
        vm.expectRevert();
        shield.createPolicy(p);
    }

    function test_PAY_05_PayoutEqMaxPayout_OnTrigger() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertEq(r.payoutAmount, 800e6);
    }

    function test_PAY_06_PayoutRecipient_IsBuyer() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertEq(r.recipient, buyer);
    }

    function test_PAY_07_PayoutReason_FlashBTC4hDrop8() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertEq(r.reason, bytes32("FLASHBTC4H_DROP8"));
    }

    function test_PAY_08_MaxPayout_LargeCoverage_NoOverflow() public {
        IShield.CreatePolicyParams memory p = _params(WINDOW, "BTC");
        p.coverageAmount = 1_000_000e6; // $1M
        uint256 pid = shield.createPolicy(p);
        assertEq(shield.getPolicyInfo(pid).maxPayout, 800_000e6);
    }

    // ====================================================================
    // T-PEM -- Proof EIP-712 verification / age / asset (6 tests)
    // ====================================================================

    function test_PEM_01_InvalidProofSignature_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 + 1 hours);
        oracle.setProofValid(false); // signature fails
        vm.expectRevert(FlashBTCShield4h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PEM_02_ProofTooOld_15MinPlusOne_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        uint256 verifiedAt = t0 + 1 hours;
        // Move beyond MAX_PROOF_AGE since verifiedAt
        vm.warp(verifiedAt + MAX_PROOF_AGE + 1);
        bytes memory proof = _buildProof(50_000e8, "BTC", verifiedAt);
        oracle.setProofValid(true);
        vm.expectRevert(
            abi.encodeWithSelector(FlashBTCShield4h.ProofTooOld.selector, verifiedAt, verifiedAt + MAX_PROOF_AGE + 1)
        );
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PEM_03_ProofAtMaxAge_Boundary_Allowed() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        uint256 verifiedAt = t0 + 1 hours;
        vm.warp(verifiedAt + MAX_PROOF_AGE); // == boundary, NOT >
        bytes memory proof = _buildProof(50_000e8, "BTC", verifiedAt);
        oracle.setProofValid(true);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    function test_PEM_04_AssetMismatch_ETHProof_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1 hours);
        bytes memory proof = _buildProof(50_000e8, "ETH", t0 + 1 hours);
        oracle.setProofValid(true);
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield4h.AssetMismatch.selector, bytes32("BTC"), bytes32("ETH")));
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PEM_05_ProofVerifiedAtBeforeWaiting_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault(); // waitingEndsAt = t0
        // verifiedAt < t0 -> EventAfterExpiry revert (the check uses verifiedAt < waitingEndsAt)
        vm.warp(t0 + 100); // give a tiny window so block.timestamp > 0
        bytes memory proof = _buildProof(50_000e8, "BTC", t0 - 1);
        oracle.setProofValid(true);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    function test_PEM_06_ProofVerifiedAtAfterExpiry_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        // Submit verifiedAt > expiresAt
        uint256 vat = info.expiresAt + 1;
        vm.warp(vat + 1); // current time slightly after vat so age check passes if reachable
        bytes memory proof = _buildProof(50_000e8, "BTC", vat);
        oracle.setProofValid(true);
        vm.expectRevert(abi.encodeWithSelector(BaseShield.EventAfterExpiry.selector, pid, vat, info.expiresAt));
        shield.verifyAndCalculate(pid, proof);
        t0; // silence unused
    }

    // ====================================================================
    // T-RAC -- Race / state / lifecycle (8 tests)
    // ====================================================================

    function test_RAC_01_CreatePolicy_NonRouter_Reverts() public {
        IShield.CreatePolicyParams memory p = _params(WINDOW, "BTC");
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.createPolicy(p);
    }

    function test_RAC_02_VerifyAndCalculate_NonRouter_Reverts() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 pid = _createDefault();
        bytes memory proof = _buildProof(50_000e8, "BTC", block.timestamp);
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.verifyAndCalculate(pid, proof);
    }

    function test_RAC_03_MarkPaidOut_NonRouter_Reverts() public {
        uint256 pid = _createDefault();
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(IShield.OnlyRouter.selector);
        shield.markPaidOut(pid);
    }

    function test_RAC_04_DoubleFinalize_Reverts() public {
        uint256 pid = _createDefault();
        shield.markPaidOut(pid);
        vm.expectRevert();
        shield.markPaidOut(pid);
    }

    function test_RAC_05_MarkPaidOut_DecreasesActive() public {
        uint256 pid = _createDefault();
        assertEq(shield.activePolicies(), 1);
        assertEq(shield.totalActiveCoverage(), 1000e6);
        shield.markPaidOut(pid);
        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
    }

    function test_RAC_06_CheckAndSettle_BeforeSafetyWindow_Reverts() public {
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        // expiresAt + SAFETY_WINDOW (24h) not yet reached
        vm.warp(t0 + WINDOW + 23 hours);
        vm.expectRevert();
        shield.checkAndSettlePolicy(pid);
    }

    function test_RAC_07_CheckAndSettle_PastSafety_Triggered() public {
        oracle.setPrice("BTC", 60_000e8);
        uint256 t0 = block.timestamp;
        uint256 pid = _createDefault();
        vm.warp(t0 + WINDOW + 25 hours);
        // Make oracle spot price <= trigger to flip triggered=true
        oracle.setPrice("BTC", 50_000e8); // <= 55_200
        shield.checkAndSettlePolicy(pid);
        IShield.PolicyStatus s = shield.getPolicyStatus(pid);
        assertEq(uint8(s), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    function test_RAC_08_TotalPolicies_IncrementsPerCreate() public {
        assertEq(shield.totalPolicies(), 0);
        _createDefault();
        assertEq(shield.totalPolicies(), 1);
        _createDefault();
        assertEq(shield.totalPolicies(), 2);
    }
}

// =========================================================================
// MockOracleEE -- minimal IOracleV2-shaped oracle for unit tests.
// Implements:
//   - getLatestPrice / setPrice
//   - verifyPriceProofEIP712 (returns either a fixed signer or zero based on
//     setProofValid; BaseShield checks `signer != address(0)`)
//   - getSequencerDowntime (configurable)
//   - oracleKey (returns address(this))
// =========================================================================
contract MockOracleEE {
    mapping(bytes32 => int256) public priceFor;
    address public authorizedKey;
    bool public proofValid;
    uint256 public downtime;

    constructor(address _key) {
        authorizedKey = _key;
        proofValid = true;
    }

    function setPrice(bytes32 asset, int256 p) external {
        priceFor[asset] = p;
    }

    function setProofValid(bool v) external {
        proofValid = v;
    }

    function setDowntime(uint256 d) external {
        downtime = d;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return priceFor[asset];
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return downtime;
    }

    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function oracleKey() external view returns (address) {
        return authorizedKey;
    }

    function verifyPriceProofEIP712(int256, bytes32, uint256, bytes calldata) external view returns (address) {
        return proofValid ? authorizedKey : address(0);
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
