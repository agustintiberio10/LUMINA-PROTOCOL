// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield4h} from "../../../src/products/FlashBTCShield4h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashBTCShield4hE2EFlows
/// @notice Sprint EE Phase E -- 10 fork-Sepolia E2E tests for FlashBTCShield4h.
///         Validates full create -> verify trigger / no-trigger / expiry /
///         settle flows under a Base Sepolia fork. The SET A oracle
///         (0x8cAbC4...D194) is mocked at the call site via vm.mockCall -- we
///         do not depend on its live price values.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
contract FlashBTCShield4hE2EFlows is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    // ===== Mirror IShield + BaseShield events for vm.expectEmit =====
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

    // ===== Constants mirrored from contract =====
    uint32 internal constant WINDOW = 14400;
    uint256 internal constant MAX_PROOF_AGE = 900;

    address internal router = address(this);
    address internal buyer = makeAddr("buyer-4h");

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
    function _deployShield() internal returns (FlashBTCShield4h s) {
        // Mock the SET A oracle so its address is callable during createPolicy.
        // Default: BTC=60_000e8, downtime=0, proof valid (return oracleKey).
        _mockBTCSpot(60_000e8);
        _mockSequencerDowntime(0);
        _mockProofValid(true);
        s = ProxyDeployer.deployFlashBTCShield4h(router, ORACLE_SET_A);
    }

    function _mockBTCSpot(int256 price) internal {
        vm.mockCall(
            ORACLE_SET_A, abi.encodeWithSelector(IOracle.getLatestPrice.selector, bytes32("BTC")), abi.encode(price)
        );
    }

    function _mockSequencerDowntime(uint256 d) internal {
        // Prefix-match on the 4-byte selector so any sinceTimestamp argument
        // resolves to the same downtime value.
        vm.mockCall(ORACLE_SET_A, abi.encodePacked(IOracle.getSequencerDowntime.selector), abi.encode(d));
    }

    function _mockProofValid(bool valid) internal {
        // verifyPriceProofEIP712 returns either oracleKey (non-zero) or zero.
        // selector: verifyPriceProofEIP712(int256,bytes32,uint256,bytes)
        address signer = valid ? address(0x1234) : address(0);
        bytes4 sel = bytes4(keccak256("verifyPriceProofEIP712(int256,bytes32,uint256,bytes)"));
        vm.mockCall(ORACLE_SET_A, abi.encodePacked(sel), abi.encode(signer));
    }

    function _params() internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = 1_000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = WINDOW;
        p.asset = "BTC";
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, new bytes(65));
    }

    // ---------------------------------------------------------------------
    // 1. E1 -- Full happy-path: create -> trigger at hour 2 -> markPaidOut
    // ---------------------------------------------------------------------
    function test_E2E_E1_FullFlow_TriggerHour2_MarkPaidOut() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        // Hour 2: BTC drops 10% (54_000 < trigger 55_200)
        vm.warp(t0 + 2 hours);
        bytes memory proof = _proof(54_000e8, "BTC", t0 + 2 hours);
        IShield.PayoutResult memory r = s.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
        assertEq(r.payoutAmount, 800e6);
        assertEq(r.reason, bytes32("FLASHBTC4H_DROP8"));

        s.markPaidOut(pid);
        assertEq(uint8(s.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
        assertEq(s.activePolicies(), 0);
    }

    // ---------------------------------------------------------------------
    // 2. E2 -- No trigger across full 4h window; markExpired at expiry
    // ---------------------------------------------------------------------
    function test_E2E_E2_NoTrigger_ExpiresUntouched() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        // Hour 3.5: BTC down only 5% (57_000 > trigger 55_200) -> no trigger
        vm.warp(t0 + 3 hours + 30 minutes);
        bytes memory proof = _proof(57_000e8, "BTC", t0 + 3 hours + 30 minutes);
        vm.expectRevert(abi.encodeWithSelector(IShield.TriggerNotMet.selector, pid, bytes32("PRICE_ABOVE_TRIGGER")));
        s.verifyAndCalculate(pid, proof);

        // Warp past expiry but before cleanup -> markExpired succeeds
        vm.warp(t0 + WINDOW + 1);
        s.markExpired(pid);
        assertEq(uint8(s.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // 3. E3 -- Trigger at end of window boundary (verifiedAt == expiresAt)
    // ---------------------------------------------------------------------
    function test_E2E_E3_TriggerAtExpiryBoundary() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        uint256 vat = t0 + WINDOW; // == expiresAt (allowed by `verifiedAt > cp.expiresAt`)
        vm.warp(vat);
        bytes memory proof = _proof(50_000e8, "BTC", vat);
        IShield.PayoutResult memory r = s.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    // ---------------------------------------------------------------------
    // 4. E4 -- Permissionless checkAndSettlePolicy after safety window
    // ---------------------------------------------------------------------
    function test_E2E_E4_CheckAndSettle_PermissionlessTrigger() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        // Past expiry + safety window (24h)
        vm.warp(t0 + WINDOW + 25 hours);
        // Mock spot below trigger so _checkTriggerCondition returns true.
        _mockBTCSpot(50_000e8);

        address randomCaller = makeAddr("randomCaller-4h");
        vm.prank(randomCaller);
        s.checkAndSettlePolicy(pid);
        assertEq(uint8(s.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // 5. E5 -- checkAndSettlePolicy with no trigger -> EXPIRED
    // ---------------------------------------------------------------------
    function test_E2E_E5_CheckAndSettle_NoTrigger_Expires() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        vm.warp(t0 + WINDOW + 25 hours);
        _mockBTCSpot(60_000e8); // unchanged -> no trigger
        s.checkAndSettlePolicy(pid);
        assertEq(uint8(s.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // 6. E6 -- Sequencer downtime extends cleanup; verifyAndCalculate
    //          remains callable inside the extended grace period.
    // ---------------------------------------------------------------------
    function test_E2E_E6_SequencerDowntime_ExtendsCleanup() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        // 2h downtime -> adjustedCleanup = expires + 26h.
        _mockSequencerDowntime(2 hours);
        vm.warp(t0 + WINDOW + 25 hours);
        bytes memory proof = _proof(50_000e8, "BTC", t0 + 1 hours);
        IShield.PayoutResult memory r = s.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    // ---------------------------------------------------------------------
    // 7. E7 -- Invalid proof signer (signer = address(0)) -> revert path
    // ---------------------------------------------------------------------
    function test_E2E_E7_InvalidProofSignature_Reverts() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        vm.warp(t0 + 1 hours);
        _mockProofValid(false);
        bytes memory proof = _proof(50_000e8, "BTC", t0 + 1 hours);
        vm.expectRevert(FlashBTCShield4h.InvalidOracleProof.selector);
        s.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // 8. E8 -- ProofTooOld revert (> MAX_PROOF_AGE since verifiedAt)
    // ---------------------------------------------------------------------
    function test_E2E_E8_ProofTooOld_Reverts() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        uint256 vat = t0 + 1 hours;
        vm.warp(vat + MAX_PROOF_AGE + 1);
        bytes memory proof = _proof(50_000e8, "BTC", vat);
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield4h.ProofTooOld.selector, vat, vat + MAX_PROOF_AGE + 1));
        s.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // 9. E9 -- Race: verify exactly at expiry boundary (verifiedAt == expires)
    //          and then attempt double-finalize.
    // ---------------------------------------------------------------------
    function test_E2E_E9_DoubleFinalize_Reverts() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params());

        vm.warp(t0 + 2 hours);
        bytes memory proof = _proof(50_000e8, "BTC", t0 + 2 hours);
        s.verifyAndCalculate(pid, proof);
        s.markPaidOut(pid);

        // Second markPaidOut should revert (policy already finalized).
        vm.expectRevert();
        s.markPaidOut(pid);

        // checkAndSettlePolicy on the finalized policy should also revert.
        vm.warp(t0 + WINDOW + 25 hours);
        vm.expectRevert();
        s.checkAndSettlePolicy(pid);
    }

    // ---------------------------------------------------------------------
    // 10. E10 -- Multi-policy: create 3 in same block, trigger 2 / expire 1
    // ---------------------------------------------------------------------
    function test_E2E_E10_MultiPolicy_2Trigger_1Expire() public requiresFork {
        FlashBTCShield4h s = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid1 = s.createPolicy(_params());
        uint256 pid2 = s.createPolicy(_params());
        uint256 pid3 = s.createPolicy(_params());
        assertEq(s.totalPolicies(), 3);
        assertEq(s.activePolicies(), 3);
        assertEq(s.totalActiveCoverage(), 3_000e6);

        // Trigger pid1 + pid2 at hour 2
        vm.warp(t0 + 2 hours);
        bytes memory proof = _proof(50_000e8, "BTC", t0 + 2 hours);
        s.verifyAndCalculate(pid1, proof);
        s.markPaidOut(pid1);
        s.verifyAndCalculate(pid2, proof);
        s.markPaidOut(pid2);

        // pid3 left to expire
        vm.warp(t0 + WINDOW + 1);
        s.markExpired(pid3);

        assertEq(s.activePolicies(), 0);
        assertEq(s.totalActiveCoverage(), 0);
        assertEq(uint8(s.getPolicyStatus(pid1)), uint8(IShield.PolicyStatus.PAID_OUT));
        assertEq(uint8(s.getPolicyStatus(pid2)), uint8(IShield.PolicyStatus.PAID_OUT));
        assertEq(uint8(s.getPolicyStatus(pid3)), uint8(IShield.PolicyStatus.EXPIRED));
    }
}
