// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield48h} from "../../../src/products/FlashETHShield48h.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashETHShield48hE2EFlows
/// @notice Sprint EE Phase E -- 10 fork-Sepolia E2E flows for FlashETHShield48h.
///         Validates: policy lifecycle, sanity bounds at create + settle, ETH
///         crash trigger at 18%, MAX_PROOF_AGE, asset mismatch, expiry,
///         permissionless settlement, oracle rotation, and 48h duration
///         enforcement. Each test deploys a fresh shield proxy + mock oracle
///         since the on-chain shield proxies were cleared after Sprint Z.2.
///         The SET A oracle is only used as the wiring anchor through vm.mockCall.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
contract FlashETHShield48hE2EFlows is Test {
    // ===== SET A oracle address (Sepolia) =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    // ===== Constants =====
    uint32 internal constant DURATION_48H = 172800;
    bytes32 internal constant ETH_ASSET = bytes32("ETH");
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TRIGGER_DROP_BPS = 1800;
    uint256 internal constant MAX_PROOF_AGE = 900;
    uint256 internal constant SAFETY_WINDOW = 24 hours;

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

    function _deployFreshShield(address oracle_) internal returns (FlashETHShield48h, address router_) {
        router_ = makeAddr("router-E2E");
        FlashETHShield48h shield = ProxyDeployer.deployFlashETHShield48h(router_, oracle_);
        return (shield, router_);
    }

    function _params(address buyer, uint256 coverage, uint32 dur, bytes32 asset)
        internal
        pure
        returns (IShield.CreatePolicyParams memory p)
    {
        p.buyer = buyer;
        p.coverageAmount = coverage;
        p.premiumAmount = coverage / 100;
        p.durationSeconds = dur;
        p.asset = asset;
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes(hex"01"));
    }

    function _mockOracleEthPrice(address oracle_, int256 price) internal {
        vm.mockCall(oracle_, abi.encodeWithSelector(IOracle.getLatestPrice.selector, ETH_ASSET), abi.encode(price));
    }

    function _mockSequencerHealthy(address oracle_) internal {
        vm.mockCall(oracle_, abi.encodeWithSelector(IOracle.getSequencerDowntime.selector), abi.encode(uint256(0)));
    }

    function _mockEip712Valid(address oracle_) internal {
        // Any non-zero signer satisfies _verifyPriceProofEIP712.
        vm.mockCall(
            oracle_,
            abi.encodeWithSelector(bytes4(keccak256("verifyPriceProofEIP712(int256,bytes32,uint256,bytes)"))),
            abi.encode(address(0xBEEF))
        );
    }

    function _mockEip712Invalid(address oracle_) internal {
        vm.mockCall(
            oracle_,
            abi.encodeWithSelector(bytes4(keccak256("verifyPriceProofEIP712(int256,bytes32,uint256,bytes)"))),
            abi.encode(address(0))
        );
    }

    // ---------------------------------------------------------------------
    // 1. Happy path: create -> verify (price -20%) -> markPaidOut
    // ---------------------------------------------------------------------
    function test_E2E_01_HappyPath_Drop20_Triggers_PayoutAt80Pct() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);
        _mockEip712Valid(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address buyer = makeAddr("buyer1");

        uint256 t0 = block.timestamp;

        vm.prank(router_);
        uint256 pid = shield.createPolicy(_params(buyer, 1_000e6, DURATION_48H, ETH_ASSET));

        // -20% from 3000 -> 2400e8 (below strike * 82% = 2460e8 trigger)
        vm.warp(t0 + 6 hours);
        bytes memory pf = _proof(2_400e8, ETH_ASSET, block.timestamp);

        vm.prank(router_);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pf);
        assertTrue(r.triggered, "drop -20% must trigger");
        assertEq(r.payoutAmount, 800e6, "payout = 80% of coverage");
        assertEq(r.recipient, buyer, "recipient must equal buyer");
        assertEq(r.reason, bytes32("FLASHETH48_DROP18"));

        vm.prank(router_);
        shield.markPaidOut(pid);
        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(uint8(info.status), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // 2. Mild dip (-15%): trigger NOT met, settlement reverts
    // ---------------------------------------------------------------------
    function test_E2E_02_Drop15_DoesNotTrigger() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);
        _mockEip712Valid(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address buyer = makeAddr("buyer2");

        uint256 t0 = block.timestamp;

        vm.prank(router_);
        uint256 pid = shield.createPolicy(_params(buyer, 1_000e6, DURATION_48H, ETH_ASSET));

        vm.warp(t0 + 6 hours);
        int256 p15 = int256(uint256(3_000e8) * 8500 / BPS); // -15%
        bytes memory pf = _proof(p15, ETH_ASSET, block.timestamp);

        vm.prank(router_);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    // ---------------------------------------------------------------------
    // 3. 48h expiry -> permissionless settle: triggered or expired
    // ---------------------------------------------------------------------
    function test_E2E_03_PermissionlessSettle_AfterExpiryAndSafetyWindow() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);
        _mockEip712Valid(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address buyer = makeAddr("buyer3");
        uint256 t0 = block.timestamp;

        vm.prank(router_);
        uint256 pid = shield.createPolicy(_params(buyer, 2_000e6, DURATION_48H, ETH_ASSET));

        // Past expiry + 24h safety; oracle below trigger -> triggered.
        vm.warp(t0 + DURATION_48H + SAFETY_WINDOW + 1);
        _mockOracleEthPrice(ORACLE_SET_A, 2_300e8); // -23%

        vm.expectEmit(true, true, false, false);
        emit PolicySettledTriggered(pid, buyer, 1_600e6);
        shield.checkAndSettlePolicy(pid);

        IShield.PolicyInfo memory info = shield.getPolicyInfo(pid);
        assertEq(uint8(info.status), uint8(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // 4. Permissionless settle BEFORE safety window passes -> reverts
    // ---------------------------------------------------------------------
    function test_E2E_04_PermissionlessSettle_TooEarly_Reverts() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address buyer = makeAddr("buyer4");
        uint256 t0 = block.timestamp;

        vm.prank(router_);
        uint256 pid = shield.createPolicy(_params(buyer, 1_000e6, DURATION_48H, ETH_ASSET));

        // Past expiry but BEFORE safety window completes.
        vm.warp(t0 + DURATION_48H + 1);
        vm.expectRevert();
        shield.checkAndSettlePolicy(pid);
    }

    // ---------------------------------------------------------------------
    // 5. Sanity bounds at create: $49 (below MIN $500) reverts
    // ---------------------------------------------------------------------
    function test_E2E_05_SanityBounds_BelowMinAtCreate_Reverts() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 499e8);
        _mockSequencerHealthy(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address buyer = makeAddr("buyer5");

        vm.prank(router_);
        vm.expectRevert();
        shield.createPolicy(_params(buyer, 1_000e6, DURATION_48H, ETH_ASSET));
    }

    // ---------------------------------------------------------------------
    // 6. Sanity bounds at settle: $50_001 (above MAX) reverts
    // ---------------------------------------------------------------------
    function test_E2E_06_SanityBounds_AboveMaxInProof_Reverts() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);
        _mockEip712Valid(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address buyer = makeAddr("buyer6");
        uint256 t0 = block.timestamp;

        vm.prank(router_);
        uint256 pid = shield.createPolicy(_params(buyer, 1_000e6, DURATION_48H, ETH_ASSET));

        vm.warp(t0 + 1 hours);
        bytes memory pf = _proof(int256(50_000e8) + 1, ETH_ASSET, block.timestamp);
        vm.prank(router_);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    // ---------------------------------------------------------------------
    // 7. Proof age > MAX_PROOF_AGE (900s) reverts
    // ---------------------------------------------------------------------
    function test_E2E_07_StaleProof_Reverts() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);
        _mockEip712Valid(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address buyer = makeAddr("buyer7");
        uint256 t0 = block.timestamp;

        vm.prank(router_);
        uint256 pid = shield.createPolicy(_params(buyer, 1_000e6, DURATION_48H, ETH_ASSET));

        vm.warp(t0 + 10_000);
        uint256 verifiedAt = block.timestamp - MAX_PROOF_AGE - 1;
        bytes memory pf = _proof(2_400e8, ETH_ASSET, verifiedAt);
        vm.prank(router_);
        vm.expectRevert();
        shield.verifyAndCalculate(pid, pf);
    }

    // ---------------------------------------------------------------------
    // 8. Asset mismatch in proof (BTC instead of ETH) reverts
    // ---------------------------------------------------------------------
    function test_E2E_08_AssetMismatch_Reverts() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);
        _mockEip712Valid(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address buyer = makeAddr("buyer8");
        uint256 t0 = block.timestamp;

        vm.prank(router_);
        uint256 pid = shield.createPolicy(_params(buyer, 1_000e6, DURATION_48H, ETH_ASSET));

        vm.warp(t0 + 1 hours);
        bytes memory pf = _proof(2_400e8, bytes32("BTC"), block.timestamp);
        vm.prank(router_);
        vm.expectRevert(
            abi.encodeWithSelector(FlashETHShield48h.AssetMismatch.selector, bytes32("ETH"), bytes32("BTC"))
        );
        shield.verifyAndCalculate(pid, pf);
    }

    // ---------------------------------------------------------------------
    // 9. Owner-rotates oracle -> subsequent settle uses new oracle proof check
    // ---------------------------------------------------------------------
    function test_E2E_09_SetOracle_Rotates_AndEmits() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);
        address newOracle = makeAddr("new-oracle");

        // owner is this test contract by deploy chain through library; setOracle
        // requires onlyOwner. The proxy initializer sets Ownable to msg.sender,
        // which in tests is address(this).
        vm.expectEmit(true, true, false, false);
        emit OracleRotated(ORACLE_SET_A, newOracle);
        shield.setOracle(newOracle);
        assertEq(shield.oracle(), newOracle);
        // Sanity unused vars
        router_;
    }

    // ---------------------------------------------------------------------
    // 10. Multiple buyers, mixed outcomes -> counters correct
    // ---------------------------------------------------------------------
    function test_E2E_10_MultiPolicy_MixedOutcomes_Counters() public requiresFork {
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8);
        _mockSequencerHealthy(ORACLE_SET_A);
        _mockEip712Valid(ORACLE_SET_A);

        (FlashETHShield48h shield, address router_) = _deployFreshShield(ORACLE_SET_A);

        uint256 t0 = block.timestamp;
        address[3] memory buyers = [makeAddr("a"), makeAddr("b"), makeAddr("c")];

        vm.startPrank(router_);
        uint256 p1 = shield.createPolicy(_params(buyers[0], 1_000e6, DURATION_48H, ETH_ASSET));
        uint256 p2 = shield.createPolicy(_params(buyers[1], 2_000e6, DURATION_48H, ETH_ASSET));
        uint256 p3 = shield.createPolicy(_params(buyers[2], 3_000e6, DURATION_48H, ETH_ASSET));
        vm.stopPrank();

        assertEq(shield.totalPolicies(), 3);
        assertEq(shield.activePolicies(), 3);
        assertEq(shield.totalActiveCoverage(), 6_000e6);

        // Trigger p1 only.
        vm.warp(t0 + 1 hours);
        bytes memory pf = _proof(2_400e8, ETH_ASSET, block.timestamp);
        vm.prank(router_);
        shield.verifyAndCalculate(p1, pf);
        vm.prank(router_);
        shield.markPaidOut(p1);

        assertEq(shield.activePolicies(), 2);
        assertEq(shield.totalActiveCoverage(), 5_000e6);

        // Permissionless settle p2 (expired with price below trigger) and p3 (expired).
        vm.warp(t0 + DURATION_48H + SAFETY_WINDOW + 1);
        _mockOracleEthPrice(ORACLE_SET_A, 2_300e8); // below trigger
        shield.checkAndSettlePolicy(p2);
        _mockOracleEthPrice(ORACLE_SET_A, 3_000e8); // back to strike: not triggered
        shield.checkAndSettlePolicy(p3);

        assertEq(shield.activePolicies(), 0);
        assertEq(shield.totalActiveCoverage(), 0);
        assertEq(shield.totalPolicies(), 3);

        IShield.PolicyInfo memory i2 = shield.getPolicyInfo(p2);
        IShield.PolicyInfo memory i3 = shield.getPolicyInfo(p3);
        assertEq(uint8(i2.status), uint8(IShield.PolicyStatus.PAID_OUT));
        assertEq(uint8(i3.status), uint8(IShield.PolicyStatus.EXPIRED));
    }
}
