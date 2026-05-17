// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield1h} from "../../../src/products/FlashETHShield1h.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashETHShield1hE2EFlows
/// @notice Sprint EE Phase E -- 10 fork-Sepolia E2E flows for FlashETHShield1h.
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
///
///         Shield is deployed fresh per test against the SET A oracle address.
///         All oracle reads are pinned via vm.mockCall so the suite does not
///         depend on live SET A price liveness (which has been flaky on
///         Sepolia post Sprint Z.2).
contract FlashETHShield1hE2EFlows is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    // ===== Constants mirroring FlashETHShield1h =====
    uint256 internal constant ETH_OK = 4_000e8;
    uint32 internal constant DURATION = 3600;
    uint256 internal constant DEDUCTIBLE_BPS = 2000;
    uint256 internal constant TRIGGER_DROP_BPS = 700;
    uint256 internal constant BPS = 10_000;

    address internal buyer = makeAddr("buyer");
    address internal router; // address(this) acts as router

    // Mirror events
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

    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            router = address(this);
            _;
        } catch {
            vm.skip(true);
        }
    }

    // ===== Helpers =====
    function _mockPrice(int256 price) internal {
        vm.mockCall(
            ORACLE_SET_A,
            abi.encodeWithSelector(IOracle.getLatestPrice.selector, bytes32("ETH")),
            abi.encode(price)
        );
    }

    function _mockDowntime(uint256 dt) internal {
        vm.mockCall(
            ORACLE_SET_A,
            abi.encodeWithSelector(IOracle.getSequencerDowntime.selector),
            abi.encode(dt)
        );
    }

    function _mockSignerOk(address signer) internal {
        // Accept any verifyPriceProofEIP712 call by returning a non-zero signer.
        vm.mockCall(
            ORACLE_SET_A,
            abi.encodeWithSelector(IOracleV2.verifyPriceProofEIP712.selector),
            abi.encode(signer)
        );
    }

    function _mockSignerBad() internal {
        vm.mockCall(
            ORACLE_SET_A,
            abi.encodeWithSelector(IOracleV2.verifyPriceProofEIP712.selector),
            abi.encode(address(0))
        );
    }

    function _params() internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = 1_000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = DURATION;
        p.asset = "ETH";
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes("sig"));
    }

    function _deployShield() internal returns (FlashETHShield1h) {
        _mockDowntime(0);
        _mockSignerOk(makeAddr("signer"));
        return ProxyDeployer.deployFlashETHShield1h(router, ORACLE_SET_A);
    }

    // ---------------------------------------------------------------------
    // 1. Happy-path: create -> trigger at -8% -> markPaidOut
    // ---------------------------------------------------------------------
    function test_E2E_HappyPath_CreateTriggerPayout() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();

        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params());
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);

        vm.warp(t0 + 300);
        // verifiedPrice 8% drop -> below trigger (-7%)
        bytes memory proof = _proof(data.strikePrice * 92 / 100, "ETH", t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
        assertEq(r.reason, bytes32("FLASHETH1H_DROP7"));

        vm.expectEmit(true, true, false, true);
        emit PolicyPaidOut(pid, buyer, r.payoutAmount, "PAID_OUT");
        shield.markPaidOut(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // 2. Expiration path: no trigger, markExpired after expiry
    // ---------------------------------------------------------------------
    function test_E2E_ExpirationPath_NoTrigger() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();

        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params());

        // Price drops only 5% (above the -7% trigger).
        vm.warp(t0 + 1800);
        bytes memory proof = _proof(int256(ETH_OK) * 95 / 100, "ETH", t0 + 1000);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);

        // Move past expiry but still within cleanup -> markExpired works.
        vm.warp(t0 + DURATION + 1);
        vm.expectEmit(true, false, false, false);
        emit PolicyExpired(pid);
        shield.markExpired(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // 3. Permissionless settlement: triggered branch
    // ---------------------------------------------------------------------
    function test_E2E_CheckAndSettle_Triggered() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();

        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params());
        FlashETHShield1h.BSSData memory data = shield.getBSSData(pid);

        // After safety window -- mock a low price so trigger condition holds.
        vm.warp(t0 + DURATION + 24 hours + 1);
        _mockPrice(data.triggerPrice - 1);

        address caller = makeAddr("settler");
        vm.expectEmit(true, true, false, false);
        emit PolicySettledTriggered(pid, buyer, 0);
        vm.prank(caller);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // 4. Permissionless settlement: expired branch (price stays above trigger)
    // ---------------------------------------------------------------------
    function test_E2E_CheckAndSettle_Expired() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();

        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params());

        vm.warp(t0 + DURATION + 24 hours + 1);
        _mockPrice(int256(ETH_OK)); // unchanged -> above trigger

        vm.expectEmit(true, false, false, false);
        emit PolicySettledExpired(pid);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint8(shield.getPolicyStatus(pid)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // 5. Stale proof rejected even after fork warp
    // ---------------------------------------------------------------------
    function test_E2E_StaleProof_Rejected() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();

        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params());

        // 15min+1s after verifiedAt -> ProofTooOld
        vm.warp(t0 + 16 minutes);
        bytes memory proof = _proof(int256(ETH_OK) * 92 / 100, "ETH", t0);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // 6. Cross-asset proof rejected (BTC proof on ETH policy)
    // ---------------------------------------------------------------------
    function test_E2E_AssetMismatch_BTCProofOnETHPolicy() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();

        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params());

        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "BTC", t0 + 100);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // 7. Invalid signature rejected (mocked signer = 0)
    // ---------------------------------------------------------------------
    function test_E2E_BadSignature_Rejected() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();
        _mockSignerBad();

        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params());

        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        vm.expectRevert(FlashETHShield1h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // 8. Multi-policy flow: 3 policies, 2 triggered, 1 expired
    // ---------------------------------------------------------------------
    function test_E2E_MultiPolicy_2Triggered_1Expired() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();

        uint256 t0 = block.timestamp;
        uint256 p1 = shield.createPolicy(_params());
        uint256 p2 = shield.createPolicy(_params());
        uint256 p3 = shield.createPolicy(_params());
        assertEq(shield.activePolicies(), 3);

        vm.warp(t0 + 300);
        FlashETHShield1h.BSSData memory data = shield.getBSSData(p1);

        // p1 triggers
        shield.verifyAndCalculate(p1, _proof(data.triggerPrice - 1, "ETH", t0 + 100));
        shield.markPaidOut(p1);
        // p2 triggers
        shield.verifyAndCalculate(p2, _proof(data.triggerPrice - 2, "ETH", t0 + 150));
        shield.markPaidOut(p2);
        // p3 expires
        vm.warp(t0 + DURATION + 1);
        shield.markExpired(p3);

        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
        assertEq(uint8(shield.getPolicyStatus(p1)), uint8(IShield.PolicyStatus.PAID_OUT));
        assertEq(uint8(shield.getPolicyStatus(p2)), uint8(IShield.PolicyStatus.PAID_OUT));
        assertEq(uint8(shield.getPolicyStatus(p3)), uint8(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // 9. Oracle rotation mid-flight: deploy with mocked SET A, rotate to new
    //    mocked oracle, verify create + verify use the new oracle.
    // ---------------------------------------------------------------------
    function test_E2E_OracleRotation_NewOracleHonored() public requiresFork {
        _mockPrice(int256(ETH_OK));
        FlashETHShield1h shield = _deployShield();

        // Rotate to a fresh mocked oracle address.
        address newOracle = makeAddr("newOracle");
        vm.mockCall(
            newOracle,
            abi.encodeWithSelector(IOracle.getLatestPrice.selector, bytes32("ETH")),
            abi.encode(int256(ETH_OK))
        );
        vm.mockCall(
            newOracle,
            abi.encodeWithSelector(IOracle.getSequencerDowntime.selector),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            newOracle,
            abi.encodeWithSelector(IOracleV2.verifyPriceProofEIP712.selector),
            abi.encode(makeAddr("signer2"))
        );
        shield.setOracle(newOracle);
        assertEq(shield.oracle(), newOracle);

        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params());
        vm.warp(t0 + 300);
        bytes memory proof = _proof(int256(ETH_OK) * 90 / 100, "ETH", t0 + 100);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    // ---------------------------------------------------------------------
    // 10. Price at sanity-bound edges on real fork chain
    // ---------------------------------------------------------------------
    function test_E2E_SanityBounds_OnFork() public requiresFork {
        // Min boundary
        _mockPrice(int256(500e8));
        FlashETHShield1h shield = _deployShield();
        uint256 pid = shield.createPolicy(_params());
        assertEq(shield.getBSSData(pid).strikePrice, int256(500e8));

        // One wei below min on a fresh shield -> revert
        _mockPrice(int256(500e8) - 1);
        FlashETHShield1h shield2 = _deployShield();
        vm.expectRevert();
        shield2.createPolicy(_params());

        // Max boundary
        _mockPrice(int256(50_000e8));
        FlashETHShield1h shield3 = _deployShield();
        uint256 pid3 = shield3.createPolicy(_params());
        assertEq(shield3.getBSSData(pid3).strikePrice, int256(50_000e8));
    }
}
