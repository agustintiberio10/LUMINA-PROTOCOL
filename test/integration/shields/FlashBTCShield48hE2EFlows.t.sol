// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield48h} from "../../../src/products/FlashBTCShield48h.sol";
import {BaseShield} from "../../../src/products/BaseShield.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

/// @title FlashBTCShield48hE2EFlows
/// @notice Sprint EE Phase E -- 10 fork-Sepolia E2E tests for FlashBTCShield48h.
///         Validates the full policy lifecycle (create, verify, settle, payout)
///         against a Base Sepolia fork. The SET A oracle proof verifier is
///         mocked via vm.mockCall at the call sites so tests are not coupled to
///         the live oracle's signing key. Spot prices and sequencer downtime
///         are also mocked, keeping the tests deterministic.
///
///         Fork target: Base Sepolia (alias `base_sepolia` resolved from
///         BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.
contract FlashBTCShield48hE2EFlows is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    // Re-declare events for vm.expectEmit matching. Solidity 0.8.20 requires
    // events to be in scope of the emitting contract.
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

    // ===== Test constants =====
    uint32 internal constant DURATION = 172_800; // 48h
    uint256 internal constant COVERAGE = 1_000e6; // $1,000 (USDC 6-dec)
    uint256 internal constant PREMIUM = 10e6;
    bytes32 internal constant ASSET_BTC = bytes32("BTC");
    uint256 internal constant BTC_STRIKE = 60_000e8;
    int256 internal constant BTC_TRIGGER = int256((60_000e8 * 8500) / 10000); // 0.85 * strike

    address internal buyer;
    address internal router; // this contract acts as router

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

    function _mockSpot(int256 price) internal {
        vm.mockCall(ORACLE_SET_A, abi.encodeWithSelector(IOracle.getLatestPrice.selector, ASSET_BTC), abi.encode(price));
    }

    function _mockSequencerDowntime(uint256 downtime) internal {
        // The selector takes a uint256 argument but BaseShield ignores the input
        // and we want the mock to answer for any input. Using a partial-match
        // mockCall keyed on the selector only would be ideal, but vm.mockCall
        // matches full calldata; the shield always passes cp.expiresAt which we
        // do not know precisely until createPolicy returns. Workaround: mock the
        // full selector via vm.mockCall with abi.encodeWithSelector + no args.
        // Forge's matcher will still match when calldata starts with this
        // selector, since the mock data is a prefix of the actual call.
        bytes memory selectorOnly = abi.encodeWithSelector(IOracle.getSequencerDowntime.selector);
        vm.mockCall(ORACLE_SET_A, selectorOnly, abi.encode(downtime));
    }

    function _mockEIP712Success() internal {
        // verifyPriceProofEIP712 returns a non-zero signer = valid.
        vm.mockCall(
            ORACLE_SET_A,
            abi.encodeWithSelector(IOracleV2.verifyPriceProofEIP712.selector),
            abi.encode(address(0xC0FFEE))
        );
    }

    function _mockEIP712Failure() internal {
        // verifyPriceProofEIP712 returns address(0) = invalid.
        vm.mockCall(
            ORACLE_SET_A, abi.encodeWithSelector(IOracleV2.verifyPriceProofEIP712.selector), abi.encode(address(0))
        );
    }

    function _deployShield() internal returns (FlashBTCShield48h) {
        return ProxyDeployer.deployFlashBTCShield48h(router, ORACLE_SET_A);
    }

    function _params(address who) internal view returns (IShield.CreatePolicyParams memory p) {
        p.buyer = who;
        p.coverageAmount = COVERAGE;
        p.premiumAmount = PREMIUM;
        p.durationSeconds = DURATION;
        p.asset = ASSET_BTC;
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes(""));
    }

    function setUp() public {
        router = address(this);
        buyer = makeAddr("buyer");
    }

    // ---------------------------------------------------------------------
    // 1. Full happy-path: create -> warp 30m -> trigger via verify -> mark paid
    // ---------------------------------------------------------------------
    function test_E2E_FullFlow_TriggerAtHour1_PaidOut() public requiresFork {
        _mockSpot(int256(BTC_STRIKE));
        _mockSequencerDowntime(0);
        _mockEIP712Success();

        FlashBTCShield48h shield = _deployShield();
        uint256 t0 = block.timestamp;

        uint256 pid = shield.createPolicy(_params(buyer));
        assertEq(shield.totalPolicies(), 1);

        // 1 hour in -- still WAITING ends == ACTIVE (wp=0). Submit proof below trigger.
        vm.warp(t0 + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertTrue(r.triggered, "must trigger");
        assertEq(r.payoutAmount, (COVERAGE * 8000) / 10000, "80% of coverage");
        assertEq(r.recipient, buyer);

        // Router marks the policy paid (off-chain payment would have happened in production).
        vm.expectEmit(true, true, false, true);
        emit PolicyPaidOut(pid, buyer, (COVERAGE * 8000) / 10000, bytes32("PAID_OUT"));
        shield.markPaidOut(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // 2. Full happy-path via permissionless settle (no proof, just spot check)
    // ---------------------------------------------------------------------
    function test_E2E_PermissionlessSettle_Triggered() public requiresFork {
        // Mock spot at the strike level for createPolicy so the trigger band is
        // computed at 85% of BTC_STRIKE. We then drop the spot below trigger
        // BEFORE checkAndSettlePolicy reads it via _checkTriggerCondition.
        _mockSpot(int256(BTC_STRIKE));
        _mockSequencerDowntime(0);

        FlashBTCShield48h shield = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params(buyer));

        // Crash spot below trigger so the settlement detects the loss.
        _mockSpot(BTC_TRIGGER - 1);

        // Wait for expiry + safety window.
        vm.warp(t0 + DURATION + 24 hours + 1);

        // Anyone (not the router) calls checkAndSettlePolicy.
        vm.expectEmit(true, true, false, true);
        emit PolicySettledTriggered(pid, buyer, (COVERAGE * 8000) / 10000);
        vm.prank(makeAddr("random"));
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // 3. Full expired-without-claim flow (spot stays above trigger throughout)
    // ---------------------------------------------------------------------
    function test_E2E_ExpiredWithoutClaim() public requiresFork {
        _mockSpot(int256(BTC_STRIKE)); // never drops
        _mockSequencerDowntime(0);

        FlashBTCShield48h shield = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params(buyer));

        vm.warp(t0 + DURATION + 24 hours + 1);
        vm.expectEmit(true, false, false, false);
        emit PolicySettledExpired(pid);
        shield.checkAndSettlePolicy(pid);
        assertEq(uint256(shield.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // 4. Sequencer downtime extends cleanup: verify succeeds past nominal cleanup
    // ---------------------------------------------------------------------
    function test_E2E_SequencerDowntime_ExtendsCleanupWindow() public requiresFork {
        _mockSpot(int256(BTC_STRIKE));
        _mockEIP712Success();
        // 1h downtime configured. Practical claim window is bounded by
        // MAX_PROOF_AGE=900s AND verifiedAt <= expiresAt, so we warp just past
        // expiresAt with verifiedAt=expiresAt to exercise the downtime branch
        // while keeping the proof fresh.
        _mockSequencerDowntime(1 hours);

        FlashBTCShield48h shield = _deployShield();
        uint256 pid = shield.createPolicy(_params(buyer));

        // Read expiresAt from policy storage (stable across vm.warp under via_ir).
        uint256 expiresAt = shield.getPolicyInfo(pid).expiresAt;
        vm.warp(expiresAt + 600);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, expiresAt);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertTrue(r.triggered, "downtime extension code path runs");
    }

    // ---------------------------------------------------------------------
    // 5. EIP-712 verifier failure -> revert
    // ---------------------------------------------------------------------
    function test_E2E_EIP712Failure_Reverts() public requiresFork {
        _mockSpot(int256(BTC_STRIKE));
        _mockSequencerDowntime(0);
        _mockEIP712Failure();

        FlashBTCShield48h shield = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params(buyer));

        vm.warp(t0 + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        vm.expectRevert(FlashBTCShield48h.InvalidOracleProof.selector);
        shield.verifyAndCalculate(pid, pr);
    }

    // ---------------------------------------------------------------------
    // 6. Stale proof (older than MAX_PROOF_AGE = 900s) -> revert
    // ---------------------------------------------------------------------
    function test_E2E_StaleProof_Reverts() public requiresFork {
        _mockSpot(int256(BTC_STRIKE));
        _mockSequencerDowntime(0);
        _mockEIP712Success();

        FlashBTCShield48h shield = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params(buyer));

        vm.warp(t0 + 2 hours);
        uint256 stale = block.timestamp - 901; // strictly older than 900s
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, stale);
        vm.expectRevert(abi.encodeWithSelector(FlashBTCShield48h.ProofTooOld.selector, stale, block.timestamp));
        shield.verifyAndCalculate(pid, pr);
    }

    // ---------------------------------------------------------------------
    // 7. Multiple policies for distinct buyers; each settles independently
    // ---------------------------------------------------------------------
    function test_E2E_MultiPolicy_IndependentSettlement() public requiresFork {
        _mockSpot(int256(BTC_STRIKE));
        _mockSequencerDowntime(0);
        _mockEIP712Success();

        FlashBTCShield48h shield = _deployShield();
        uint256 t0 = block.timestamp;

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        IShield.CreatePolicyParams memory pa = _params(alice);
        IShield.CreatePolicyParams memory pb = _params(bob);
        uint256 pidA = shield.createPolicy(pa);
        uint256 pidB = shield.createPolicy(pb);
        assertEq(shield.activePolicies(), 2);
        assertEq(shield.totalActiveCoverage(), 2 * COVERAGE);

        // Alice triggers, Bob expires.
        vm.warp(t0 + 1 hours);
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, block.timestamp - 10);
        IShield.PayoutResult memory rA = shield.verifyAndCalculate(pidA, pr);
        assertTrue(rA.triggered);
        shield.markPaidOut(pidA);

        // Spot recovers above trigger, then Bob's policy expires.
        _mockSpot(int256(BTC_STRIKE));
        vm.warp(t0 + DURATION + 24 hours + 1);
        shield.checkAndSettlePolicy(pidB);

        assertEq(uint256(shield.getPolicyStatus(pidA)), uint256(IShield.PolicyStatus.PAID_OUT));
        assertEq(uint256(shield.getPolicyStatus(pidB)), uint256(IShield.PolicyStatus.EXPIRED));
        assertEq(shield.activePolicies(), 0);
    }

    // ---------------------------------------------------------------------
    // 8. Trigger flickers: spot dips below then recovers; off-chain proof captures dip
    // ---------------------------------------------------------------------
    function test_E2E_FlickerDip_OffChainProofCaptures() public requiresFork {
        _mockSpot(int256(BTC_STRIKE));
        _mockSequencerDowntime(0);
        _mockEIP712Success();

        FlashBTCShield48h shield = _deployShield();
        uint256 t0 = block.timestamp;
        uint256 pid = shield.createPolicy(_params(buyer));

        // Flicker at hour 12: dip below trigger then back up.
        vm.warp(t0 + 12 hours);
        uint256 dipAt = block.timestamp - 60; // 1 minute ago
        // Off-chain proof captures the dip price -- recovery doesn't erase it.
        bytes memory pr = _proof(BTC_TRIGGER - 1, ASSET_BTC, dipAt);
        IShield.PayoutResult memory r = shield.verifyAndCalculate(pid, pr);
        assertTrue(r.triggered, "Off-chain proof of the dip suffices");
    }

    // ---------------------------------------------------------------------
    // 9. Oracle revert at create time -> shield reverts (failsafe)
    // ---------------------------------------------------------------------
    function test_E2E_OracleRevert_AtCreate_Reverts() public requiresFork {
        vm.mockCallRevert(
            ORACLE_SET_A, abi.encodeWithSelector(IOracle.getLatestPrice.selector, ASSET_BTC), "oracle-down"
        );
        _mockSequencerDowntime(0);

        FlashBTCShield48h shield = _deployShield();
        // createPolicy reverts because the underlying getLatestPrice call reverts.
        vm.expectRevert("oracle-down");
        shield.createPolicy(_params(buyer));
    }

    // ---------------------------------------------------------------------
    // 10. SET A oracle wiring round-trip: shield reads the oracle we deployed against
    // ---------------------------------------------------------------------
    function test_E2E_OracleWiring_RoundTrip() public requiresFork {
        _mockSpot(int256(BTC_STRIKE));
        _mockSequencerDowntime(0);
        _mockEIP712Success();

        FlashBTCShield48h shield = _deployShield();
        assertEq(shield.oracle(), ORACLE_SET_A, "oracle wired to SET A");
        assertEq(shield.router(), router, "router wired to test contract");

        // Sanity: createPolicy stamps the strike at the mocked spot price.
        uint256 pid = shield.createPolicy(_params(buyer));
        assertEq(shield.getBSSData(pid).strikePrice, int256(BTC_STRIKE));
        assertEq(shield.getBSSData(pid).triggerPrice, BTC_TRIGGER);
    }
}
