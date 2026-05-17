// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {RateShockShield, IAaveV3Pool} from "../../../src/products/RateShockShield.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title RateShockShieldE2EFlows
/// @notice Sprint EE -- Phase E: 10 fork-Sepolia E2E tests for RateShockShield.
///         Validates full create -> trigger -> settle flow against a forked
///         Base Sepolia, mocking Aave V3 pool replies via vm.mockCall.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
///
///         The real Aave V3 pool on Sepolia (0xcc0606b6...178a) is mocked at
///         the call site so we don't depend on its live USDC borrow rate. The
///         shield reads Aave on-chain (no oracle proof) -- so vm.mockCall over
///         `getReserveData(USDC_MOCK)` is the canonical way to control trigger.

// Mock IOracle: RateShock doesn't use price reads, but BaseShield needs an
// oracle for getSequencerDowntime + initialize zero-check.
contract _MockOracleE2E is IOracle {
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

contract RateShockShieldE2EFlows is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant AAVE_POOL_SEPOLIA = 0xcc0606b64275c08539770864081D209A8C9b178a;

    // USDC mock address -- only needed by the shield constructor + Aave reserve key.
    address internal constant USDC_MOCK = address(0xdeadbeef);

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
    event PolicySettledTriggered(uint256 indexed policyId, address indexed buyer, uint256 maxPayout);
    event PolicySettledExpired(uint256 indexed policyId);

    // ===== Skip gracefully if BASE_SEPOLIA_RPC is not configured =====
    modifier requiresFork() {
        try vm.envString("BASE_SEPOLIA_RPC") returns (string memory) {
            vm.createSelectFork("base_sepolia");
            _;
        } catch {
            vm.skip(true);
        }
    }

    // ===== Constants =====
    uint256 constant DURATION = 604800; // 7 days
    uint256 constant TRIGGER_RATE = 10e25;
    uint256 constant MIN_COVERAGE = 100e6;

    // ===== Helpers =====
    function _deployShield() internal returns (RateShockShield s, _MockOracleE2E o, address router) {
        o = new _MockOracleE2E();
        router = makeAddr("router");
        s = ProxyDeployer.deployRateShockShield(router, address(o), AAVE_POOL_SEPOLIA, USDC_MOCK);
    }

    function _mockAaveRate(uint128 rayRate) internal {
        IAaveV3Pool.ReserveData memory data;
        data.currentVariableBorrowRate = rayRate;
        vm.mockCall(
            AAVE_POOL_SEPOLIA, abi.encodeWithSelector(IAaveV3Pool.getReserveData.selector, USDC_MOCK), abi.encode(data)
        );
    }

    function _mockAaveRevert() internal {
        vm.mockCallRevert(
            AAVE_POOL_SEPOLIA, abi.encodeWithSelector(IAaveV3Pool.getReserveData.selector, USDC_MOCK), "aave-down"
        );
    }

    function _defaultParams(address buyer, uint256 coverage)
        internal
        pure
        returns (IShield.CreatePolicyParams memory p)
    {
        p.buyer = buyer;
        p.coverageAmount = coverage;
        p.premiumAmount = coverage / 10;
        p.durationSeconds = uint32(DURATION);
        p.asset = "USDC";
        p.stablecoin = "USDC";
        p.protocol = address(0);
        p.extraData = "";
    }

    // ---------------------------------------------------------------------
    // 1. PATH happy: create -> rate spike -> verifyAndCalculate triggers
    // ---------------------------------------------------------------------
    function test_E2E_HappyPath_RateSpike15Percent_Triggers() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        address buyer = makeAddr("buyer");
        uint256 t0 = block.timestamp;

        // Default Aave returns 5 percent -- no trigger yet.
        _mockAaveRate(uint128(uint256(500) * 1e23));

        vm.prank(router);
        uint256 pid = shield.createPolicy(_defaultParams(buyer, 1_000e6));

        // Day 3 -- rate spikes to 15 percent
        vm.warp(t0 + 3 days);
        _mockAaveRate(uint128(uint256(1500) * 1e23));

        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
        assertEq(r.reason, bytes32("RATESHOCK_AAVE_USDC_ABOVE_10"));
        assertEq(r.payoutAmount, (uint256(1_000e6) * 8000) / 10000);
    }

    // ---------------------------------------------------------------------
    // 2. No trigger end-to-end: rate stays low; settle as EXPIRED
    // ---------------------------------------------------------------------
    function test_E2E_NoTrigger_RateStaysLow_SettleExpired() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        address buyer = makeAddr("buyer");
        uint256 t0 = block.timestamp;

        _mockAaveRate(uint128(uint256(500) * 1e23)); // 5 percent throughout

        vm.prank(router);
        uint256 pid = shield.createPolicy(_defaultParams(buyer, 1_000e6));

        // Past expiry + SAFETY_WINDOW
        vm.warp(t0 + DURATION + 24 hours + 1);
        vm.expectEmit(true, false, false, false);
        emit PolicySettledExpired(pid);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // 3. Permissionless settle as triggered -- attacker calls
    // ---------------------------------------------------------------------
    function test_E2E_PermissionlessSettle_AttackerCalls_Triggered() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        address buyer = makeAddr("buyer");
        address randomCaller = makeAddr("anyone");
        uint256 t0 = block.timestamp;

        _mockAaveRate(uint128(uint256(1500) * 1e23)); // 15 percent
        vm.prank(router);
        uint256 pid = shield.createPolicy(_defaultParams(buyer, 1_000e6));

        vm.warp(t0 + DURATION + 24 hours + 1);
        vm.prank(randomCaller);
        vm.expectEmit(true, true, false, false);
        emit PolicySettledTriggered(pid, buyer, shield.getPolicyInfo(pid).maxPayout);
        shield.checkAndSettlePolicy(pid);
    }

    // ---------------------------------------------------------------------
    // 4. Rate exactly at threshold (10 percent) -- no trigger (strict >)
    // ---------------------------------------------------------------------
    function test_E2E_RateExactlyAtThreshold_NoTrigger() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        address buyer = makeAddr("buyer");

        _mockAaveRate(uint128(TRIGGER_RATE)); // exactly 10 percent
        vm.prank(router);
        uint256 pid = shield.createPolicy(_defaultParams(buyer, 1_000e6));

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(RateShockShield.RateBelowTrigger.selector, TRIGGER_RATE));
        shield.verifyAndCalculate(pid, "");
    }

    // ---------------------------------------------------------------------
    // 5. Aave reverts during verify -- shield bubbles the revert
    // ---------------------------------------------------------------------
    function test_E2E_AaveReverts_VerifyBubbles() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        address buyer = makeAddr("buyer");
        uint256 t0 = block.timestamp;

        _mockAaveRate(uint128(uint256(500) * 1e23));
        vm.prank(router);
        uint256 pid = shield.createPolicy(_defaultParams(buyer, 1_000e6));

        vm.warp(t0 + 1 days);
        _mockAaveRevert();

        vm.prank(router);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, "");
    }

    // ---------------------------------------------------------------------
    // 6. Rate spike + recovery -- only the snapshot at verify counts
    // ---------------------------------------------------------------------
    function test_E2E_SpikeAndRecovery_OnlySnapshotCounts() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        address buyer = makeAddr("buyer");
        uint256 t0 = block.timestamp;

        _mockAaveRate(uint128(uint256(500) * 1e23));
        vm.prank(router);
        uint256 pid = shield.createPolicy(_defaultParams(buyer, 1_000e6));

        // Mid-policy spike (no one reads it -- the trigger is on-demand)
        vm.warp(t0 + 2 days);
        _mockAaveRate(uint128(uint256(1500) * 1e23));

        // Recovers before anyone calls verify
        vm.warp(t0 + 4 days);
        _mockAaveRate(uint128(uint256(700) * 1e23));

        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(RateShockShield.RateBelowTrigger.selector, uint256(700) * 1e23));
        shield.verifyAndCalculate(pid, "");
    }

    // ---------------------------------------------------------------------
    // 7. Multiple policies, divergent outcomes (one triggered, one expired)
    // ---------------------------------------------------------------------
    function test_E2E_MultiPolicy_DivergentOutcomes() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        address buyerA = makeAddr("buyerA");
        address buyerB = makeAddr("buyerB");
        uint256 t0 = block.timestamp;

        _mockAaveRate(uint128(uint256(500) * 1e23));
        vm.prank(router);
        uint256 pidA = shield.createPolicy(_defaultParams(buyerA, 1_000e6));

        // Wait 3 days, create the second policy
        vm.warp(t0 + 3 days);
        vm.prank(router);
        uint256 pidB = shield.createPolicy(_defaultParams(buyerB, 2_000e6));

        // Spike on day 5 -- policy A still active (expires day 7); policy B still active (expires day 10)
        vm.warp(t0 + 5 days);
        _mockAaveRate(uint128(uint256(1500) * 1e23));
        vm.prank(router);
        IShield.PayoutResult memory rA = shield.verifyAndCalculate(pidA, "");
        assertTrue(rA.triggered, "policy A triggers");

        // Markk A as paid out
        vm.prank(router);
        shield.markPaidOut(pidA);

        // Rate recovers before B verifies
        _mockAaveRate(uint128(uint256(700) * 1e23));
        vm.warp(t0 + 6 days);
        vm.prank(router);
        vm.expectRevert(abi.encodeWithSelector(RateShockShield.RateBelowTrigger.selector, uint256(700) * 1e23));
        shield.verifyAndCalculate(pidB, "");
    }

    // ---------------------------------------------------------------------
    // 8. Aave pool rotation mid-policy -- new pool's rates apply
    // ---------------------------------------------------------------------
    function test_E2E_AavePoolRotation_NewPoolApplies() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        address buyer = makeAddr("buyer");
        uint256 t0 = block.timestamp;

        _mockAaveRate(uint128(uint256(500) * 1e23));
        vm.prank(router);
        uint256 pid = shield.createPolicy(_defaultParams(buyer, 1_000e6));

        // Deploy a fresh adversarial mock pool at a non-Sepolia address.
        // The shield owner rotates the pool reference.
        address newPool = makeAddr("newAavePool");
        IAaveV3Pool.ReserveData memory data;
        data.currentVariableBorrowRate = uint128(uint256(1500) * 1e23);
        vm.mockCall(newPool, abi.encodeWithSelector(IAaveV3Pool.getReserveData.selector, USDC_MOCK), abi.encode(data));

        // owner == deployer (this test contract since `new RateShockShield` happens here via proxy)
        shield.setAavePool(newPool);

        vm.warp(t0 + 1 days);
        vm.prank(router);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, "");
        assertTrue(r.triggered);
    }

    // ---------------------------------------------------------------------
    // 9. Sequencer-downtime extension: at expiry+25h with 2h downtime
    // ---------------------------------------------------------------------
    function test_E2E_SequencerDowntime_ExtendsCleanup() public requiresFork {
        (RateShockShield shield, _MockOracleE2E o, address router) = _deployShield();
        address buyer = makeAddr("buyer");
        uint256 t0 = block.timestamp;

        _mockAaveRate(uint128(uint256(1500) * 1e23));
        vm.prank(router);
        uint256 pid = shield.createPolicy(_defaultParams(buyer, 1_000e6));

        // 2-hour sequencer downtime extends cleanupAt from +24h to +26h.
        o.setSequencerDowntime(2 hours);

        // At +25h, status check passes (cleanupAt extended); _doVerifyAndCalculate
        // then complains EventAfterExpiry -- proves the extension fired.
        vm.warp(t0 + DURATION + 25 hours);
        vm.prank(router);
        vm.expectRevert(
            abi.encodeWithSelector(BaseShield.EventAfterExpiry.selector, pid, t0 + DURATION + 25 hours, t0 + DURATION)
        );
        shield.verifyAndCalculate(pid, "");
    }

    // ---------------------------------------------------------------------
    // 10. Active coverage accounting: 3 policies, settle 2, counter matches
    // ---------------------------------------------------------------------
    function test_E2E_ActiveCoverageAccounting_3Policies() public requiresFork {
        (RateShockShield shield, , address router) = _deployShield();
        uint256 t0 = block.timestamp;

        _mockAaveRate(uint128(uint256(500) * 1e23)); // initially non-triggering

        vm.startPrank(router);
        uint256 p1 = shield.createPolicy(_defaultParams(makeAddr("b1"), 1_000e6));
        uint256 p2 = shield.createPolicy(_defaultParams(makeAddr("b2"), 2_000e6));
        uint256 p3 = shield.createPolicy(_defaultParams(makeAddr("b3"), 3_000e6));
        vm.stopPrank();

        assertEq(shield.totalActiveCoverage(), 6_000e6);
        assertEq(shield.activePolicies(), 3);

        // Spike rate for triggers
        _mockAaveRate(uint128(uint256(1500) * 1e23));
        vm.warp(t0 + DURATION + 24 hours + 1);

        shield.checkAndSettlePolicy(p1);
        shield.checkAndSettlePolicy(p2);

        assertEq(shield.totalActiveCoverage(), 3_000e6);
        assertEq(shield.activePolicies(), 1);
        assertEq(uint256(shield.getPolicyStatus(p1)), uint256(IShield.PolicyStatus.PAID_OUT));
        assertEq(uint256(shield.getPolicyStatus(p2)), uint256(IShield.PolicyStatus.PAID_OUT));
        assertEq(uint256(shield.getPolicyStatus(p3)), uint256(IShield.PolicyStatus.ACTIVE));
    }
}
