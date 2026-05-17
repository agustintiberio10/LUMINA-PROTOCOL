// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield24h} from "../../../src/products/FlashBTCShield24h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashBTCShield24hE2EFlows
/// @notice Sprint EE Phase E -- 10 fork-Sepolia E2E tests for FlashBTCShield24h.
///         Validates full lifecycle (create -> verify/trigger -> mark) against
///         the canonical SET A oracle (LuminaOracleV2 0x8cAb..D194).
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from the
///         BASE_SEPOLIA_RPC env var). Tests skip gracefully with vm.skip(true)
///         when the env var is unset so the suite still runs on CI shards that
///         do not configure RPC.
///
///         All oracle interactions are mocked via vm.mockCall keyed on the
///         SET A address. We do NOT depend on the on-chain price values --
///         this keeps tests deterministic and resilient to live feed drift.
contract FlashBTCShield24hE2EFlows is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    // Mirror events for vm.expectEmit
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

    // Mirror constants from src/products/FlashBTCShield24h.sol
    uint32 constant DURATION = 86_400; // 24h
    uint256 constant TRIGGER_DROP_BPS = 1000; // 10%
    uint256 constant DEDUCTIBLE_BPS = 2000;
    uint256 constant BPS = 10_000;
    uint256 constant MAX_PROOF_AGE = 900;
    int256 constant BTC_60K = 60_000e8;
    int256 constant TRIGGER_60K = 54_000e8; // 60_000 * 0.90
    uint256 constant DEFAULT_COVERAGE = 1_000e6;

    address router; // address(this) in setUp
    address buyer = makeAddr("buyer");

    // ===== Skip gracefully if BASE_SEPOLIA_RPC is not configured =====
    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    // ===== Helpers =====
    function _deployShield() internal returns (FlashBTCShield24h s) {
        router = address(this);
        s = ProxyDeployer.deployFlashBTCShield24h(router, ORACLE_SET_A);
    }

    function _mockPrice(int256 btcPrice) internal {
        vm.mockCall(
            ORACLE_SET_A, abi.encodeWithSelector(IOracle.getLatestPrice.selector, bytes32("BTC")), abi.encode(btcPrice)
        );
    }

    function _mockSequencerDowntime(uint256 d) internal {
        vm.mockCall(ORACLE_SET_A, abi.encodeWithSelector(IOracle.getSequencerDowntime.selector), abi.encode(d));
    }

    function _mockEip712Signer(address signer) internal {
        // verifyPriceProofEIP712 returns the recovered signer; BaseShield treats
        // any non-zero return as valid. We mock to return a non-zero address.
        vm.mockCall(ORACLE_SET_A, abi.encodeWithSelector(IOracleV2.verifyPriceProofEIP712.selector), abi.encode(signer));
    }

    function _params(bytes32 asset) internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = DEFAULT_COVERAGE;
        p.premiumAmount = 10e6;
        p.durationSeconds = DURATION;
        p.asset = asset;
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes("sig"));
    }

    // ---------------------------------------------------------------------
    // E1 -- Happy path: create, drop 12%, verify, markPaidOut
    // ---------------------------------------------------------------------
    function test_E2E_E1_HappyPath_CreateDropVerifyPaidOut() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);
        _mockEip712Signer(address(0xABCD));

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        // 12% drop -> price = 52_800e8, well below 54_000e8 trigger
        vm.warp(t0 + 6 hours);
        int256 crashed = (BTC_60K * 88) / 100;
        bytes memory proof = _proof(crashed, "BTC", t0 + 6 hours);
        IShield.PayoutResult memory r = s.verifyAndCalculate(pid, proof);

        assertTrue(r.triggered, "Should trigger on 12% drop");
        assertEq(r.payoutAmount, (DEFAULT_COVERAGE * (BPS - DEDUCTIBLE_BPS)) / BPS, "80% payout");
        assertEq(r.reason, bytes32("FLASHBTC24_DROP10"));
        assertEq(r.recipient, buyer);

        s.markPaidOut(pid);
        assertEq(uint8(s.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
        assertEq(s.activePolicies(), 0);
    }

    // ---------------------------------------------------------------------
    // E2 -- No trigger: 5% drop, verifyAndCalculate reverts, markExpired
    // ---------------------------------------------------------------------
    function test_E2E_E2_NoTrigger_5PctDrop_Expires() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);
        _mockEip712Signer(address(0xABCD));

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        // 5% drop -> price = 57_000e8 > 54_000e8 trigger -> revert TriggerNotMet
        vm.warp(t0 + 1 hours);
        int256 modest = (BTC_60K * 95) / 100;
        bytes memory proof = _proof(modest, "BTC", t0 + 1 hours);
        vm.expectRevert();
        s.verifyAndCalculate(pid, proof);

        // After expiry, mark expired succeeds.
        vm.warp(t0 + DURATION + 1);
        s.markExpired(pid);
        assertEq(uint8(s.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // E3 -- Trigger exactly at -10.001% (just past trigger)
    // ---------------------------------------------------------------------
    function test_E2E_E3_TriggerAtThreshold_OneWeiBelow() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);
        _mockEip712Signer(address(0xABCD));

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        // triggerPrice = 54_000e8; passing 54_000e8 reverts (strict `>=` on
        // verifiedPrice >= triggerPrice means equal-to is "above trigger" -> revert).
        // We test 1 wei below trigger -> exact-trigger boundary firing on the
        // success side.
        vm.warp(t0 + 1);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + 1);
        IShield.PayoutResult memory r = s.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered, "1 wei below trigger should fire");
    }

    // ---------------------------------------------------------------------
    // E4 -- Sequencer downtime extends cleanup window
    // ---------------------------------------------------------------------
    function test_E2E_E4_SequencerDowntimeExtension() public requiresFork {
        _mockPrice(BTC_60K);
        _mockEip712Signer(address(0xABCD));

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        // Without downtime, 25h past expiry exceeds the 24h CLAIM_GRACE_PERIOD.
        // With downtime=2h, the effective cleanupAt extends to expiresAt + 26h.
        _mockSequencerDowntime(2 hours);
        vm.warp(t0 + DURATION + 24 hours + 1 hours);

        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + DURATION);
        IShield.PayoutResult memory r = s.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered, "Downtime extension should preserve trigger eligibility");
    }

    // ---------------------------------------------------------------------
    // E5 -- Stale proof: verifiedAt > MAX_PROOF_AGE ago -> revert
    // ---------------------------------------------------------------------
    function test_E2E_E5_StaleProof_Reverts() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);
        _mockEip712Signer(address(0xABCD));

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        uint256 verifiedAt = t0;
        vm.warp(verifiedAt + MAX_PROOF_AGE + 1); // 1s past freshness
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", verifiedAt);
        vm.expectRevert();
        s.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // E6 -- EIP-712 verification fails: signer == address(0) -> revert
    // ---------------------------------------------------------------------
    function test_E2E_E6_EIP712SignerZero_Reverts() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);
        _mockEip712Signer(address(0)); // forged signature

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        vm.warp(t0 + 1);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + 1);
        vm.expectRevert(FlashBTCShield24h.InvalidOracleProof.selector);
        s.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // E7 -- Asset mismatch between policy (BTC) and proof (ETH)
    // ---------------------------------------------------------------------
    function test_E2E_E7_AssetMismatch_Reverts() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);
        _mockEip712Signer(address(0xABCD));

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        vm.warp(t0 + 1);
        bytes memory proof = _proof(TRIGGER_60K - 1, "ETH", t0 + 1);
        vm.expectRevert();
        s.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // E8 -- Permissionless settlement after safety window -- triggered
    // ---------------------------------------------------------------------
    function test_E2E_E8_PermissionlessSettle_Triggered() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        // Crash BTC, then warp past expiry + SAFETY_WINDOW (24h).
        _mockPrice(TRIGGER_60K - 1);
        vm.warp(t0 + DURATION + 24 hours);

        address randomCaller = makeAddr("randomCaller");
        vm.expectEmit(true, true, false, true);
        emit PolicySettledTriggered(pid, buyer, (DEFAULT_COVERAGE * (BPS - DEDUCTIBLE_BPS)) / BPS);
        vm.prank(randomCaller);
        s.checkAndSettlePolicy(pid);
        assertEq(uint8(s.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // E9 -- Permissionless settlement -- not triggered -> EXPIRED
    // ---------------------------------------------------------------------
    function test_E2E_E9_PermissionlessSettle_NoTriggerExpires() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params("BTC"));

        // BTC stays at 60k -- not triggered. Warp past SAFETY_WINDOW.
        vm.warp(t0 + DURATION + 24 hours);
        vm.expectEmit(true, false, false, true);
        emit PolicySettledExpired(pid);
        s.checkAndSettlePolicy(pid);
        assertEq(uint8(s.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
        assertEq(s.activePolicies(), 0);
    }

    // ---------------------------------------------------------------------
    // E10 -- Multiple policies, multiple buyers, independent state
    // ---------------------------------------------------------------------
    function test_E2E_E10_MultiplePolicies_IndependentSettlement() public requiresFork {
        _mockPrice(BTC_60K);
        _mockSequencerDowntime(0);
        _mockEip712Signer(address(0xABCD));

        FlashBTCShield24h s = _deployShield();
        uint256 t0 = block.timestamp;

        // Create three policies under different buyers.
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        IShield.CreatePolicyParams memory pa = _params("BTC");
        pa.buyer = alice;
        uint256 pidA = s.createPolicy(pa);

        IShield.CreatePolicyParams memory pb = _params("BTC");
        pb.buyer = bob;
        uint256 pidB = s.createPolicy(pb);

        IShield.CreatePolicyParams memory pc = _params("BTC");
        pc.buyer = carol;
        uint256 pidC = s.createPolicy(pc);

        assertEq(s.totalPolicies(), 3);
        assertEq(s.activePolicies(), 3);
        assertEq(s.totalActiveCoverage(), 3 * DEFAULT_COVERAGE);

        // Crash mid-window -- all three should trigger if verified.
        vm.warp(t0 + 2 hours);
        bytes memory proof = _proof(TRIGGER_60K - 1, "BTC", t0 + 2 hours);

        IShield.PayoutResult memory rA = s.verifyAndCalculate(pidA, proof);
        assertTrue(rA.triggered);
        assertEq(rA.recipient, alice);

        // Alice paid out -- counters drop by one policy.
        s.markPaidOut(pidA);
        assertEq(s.activePolicies(), 2);
        assertEq(s.totalActiveCoverage(), 2 * DEFAULT_COVERAGE);

        // Bob also verifies; his payout independent of Alice's.
        IShield.PayoutResult memory rB = s.verifyAndCalculate(pidB, proof);
        assertTrue(rB.triggered);
        assertEq(rB.recipient, bob);
        s.markPaidOut(pidB);

        // Carol never claims; markExpired after window closes.
        vm.warp(t0 + DURATION + 1);
        s.markExpired(pidC);
        assertEq(uint8(s.getPolicyStatus(pidC)), uint8(IShield.PolicyStatus.EXPIRED));
        assertEq(s.activePolicies(), 0);
        assertEq(s.totalActiveCoverage(), 0);
    }
}
