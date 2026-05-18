// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {FlashETHShield24h} from "../../../src/products/FlashETHShield24h.sol";
import {IShield} from "../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {IOracleV2} from "../../../src/interfaces/IOracleV2.sol";
import {ProxyDeployer} from "../../helpers/ProxyDeployer.sol";

// +============================================================================+
// | Sprint EE -- Phase E: 10 fork-Sepolia E2E tests for FlashETHShield24h.     |
// |                                                                            |
// | Fork target: Base Sepolia (alias `base_sepolia` resolved from              |
// | BASE_SEPOLIA_RPC). Tests skip gracefully if the env var is unset.          |
// |                                                                            |
// | SET A oracle (0x8cAbC4...D194). We do NOT depend on its live price -- all  |
// | oracle calls are mocked at the call site via vm.mockCall, mirroring the    |
// | pattern from `FounderVestingV2E2EFlows.t.sol`. The fork is needed so the   |
// | shield proxy is deployed against a real Base-Sepolia chain context (chain  |
// | id, block info, EIP-712 domain separator that pins to chainId).            |
// |                                                                            |
// | Per memory `foundry_via_ir_warp.md`, all warps anchor to absolute          |
// | timestamps captured at setUp (t0), never `block.timestamp + delta`.        |
// +============================================================================+

contract FlashETHShield24hE2EFlows is Test {
    // ===== Hardcoded Sepolia addresses =====
    address internal constant ORACLE_SET_A = 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194;

    // ===== Re-declared events for vm.expectEmit =====
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
    function _mockPrice(int256 price) internal {
        vm.mockCall(
            ORACLE_SET_A, abi.encodeWithSelector(IOracle.getLatestPrice.selector, bytes32("ETH")), abi.encode(price)
        );
    }

    function _mockSeqDowntime(uint256 d) internal {
        // Mock the bare selector so any `sinceTimestamp` matches.
        vm.mockCall(ORACLE_SET_A, abi.encodeWithSelector(IOracle.getSequencerDowntime.selector), abi.encode(d));
    }

    function _mockEip712Signer(address signer) internal {
        // Match any (price,asset,verifiedAt,sig) inputs to return `signer`.
        vm.mockCall(ORACLE_SET_A, abi.encodeWithSelector(IOracleV2.verifyPriceProofEIP712.selector), abi.encode(signer));
    }

    function _params(address buyer) internal pure returns (IShield.CreatePolicyParams memory p) {
        p.buyer = buyer;
        p.coverageAmount = 1_000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = 86400; // 24h
        p.asset = "ETH";
        p.stablecoin = bytes32(0);
        p.protocol = address(0);
        p.extraData = "";
    }

    function _proof(int256 price, bytes32 asset, uint256 verifiedAt) internal pure returns (bytes memory) {
        return abi.encode(price, asset, verifiedAt, bytes("sig"));
    }

    function _triggerOf(int256 strike) internal pure returns (int256) {
        return (strike * int256(uint256(8800))) / int256(uint256(10000));
    }

    function _deploy() internal returns (FlashETHShield24h s) {
        // Router = this contract (so it can call createPolicy / verifyAndCalculate).
        s = ProxyDeployer.deployFlashETHShield24h(address(this), ORACLE_SET_A);
    }

    // ---------------------------------------------------------------------
    // 1. PATH full E2E -- create, drop ETH 13%, verify+payout
    // ---------------------------------------------------------------------
    function test_E2E_FullFlow_Drop13Percent_PaysOut() public requiresFork {
        _mockPrice(3_000e8);
        _mockEip712Signer(address(0xBEEF));
        _mockSeqDowntime(0);
        FlashETHShield24h s = _deploy();

        uint256 t0 = block.timestamp;
        address buyer = makeAddr("e2e_buyer");
        uint256 pid = s.createPolicy(_params(buyer));

        // Verify with a proof showing a 13% drop (below 12% trigger).
        int256 dropped = (3_000e8 * int256(uint256(8700))) / int256(uint256(10000));
        bytes memory proof = _proof(dropped, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        IShield.PayoutResult memory r = s.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered, "must trigger at 13% drop");
        assertEq(r.recipient, buyer);
        assertEq(r.payoutAmount, (1_000e6 * 8000) / 10000);
        assertEq(r.reason, bytes32("FLASHETH24_DROP12"));

        s.markPaidOut(pid);
        assertEq(uint256(s.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.PAID_OUT));
    }

    // ---------------------------------------------------------------------
    // 2. PATH no-trigger -- 5% drop, policy expires
    // ---------------------------------------------------------------------
    function test_E2E_NoTrigger_5PercentDrop_Expires() public requiresFork {
        _mockPrice(3_000e8);
        _mockEip712Signer(address(0xBEEF));
        _mockSeqDowntime(0);
        FlashETHShield24h s = _deploy();

        uint256 t0 = block.timestamp;
        address buyer = makeAddr("e2e_buyer2");
        uint256 pid = s.createPolicy(_params(buyer));

        // Only 5% drop -> still above trigger.
        int256 priceAbove = (3_000e8 * int256(uint256(9500))) / int256(uint256(10000));
        bytes memory proof = _proof(priceAbove, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        vm.expectRevert();
        s.verifyAndCalculate(pid, proof);

        // Expire after 24h + cleanup window
        vm.warp(t0 + 86400 + 24 hours + 1);
        s.checkAndSettlePolicy(pid);
        assertEq(uint256(s.getPolicyStatus(pid)), uint256(IShield.PolicyStatus.EXPIRED));
    }

    // ---------------------------------------------------------------------
    // 3. Permissionless settle on trigger -- anyone can call after safety win
    // ---------------------------------------------------------------------
    function test_E2E_PermissionlessSettle_OnTrigger() public requiresFork {
        _mockPrice(3_000e8);
        _mockEip712Signer(address(0xBEEF));
        _mockSeqDowntime(0);
        FlashETHShield24h s = _deploy();

        uint256 t0 = block.timestamp;
        address buyer = makeAddr("e2e_buyer3");
        uint256 pid = s.createPolicy(_params(buyer));

        // Past safety window with depressed spot price -> settles to PAID_OUT.
        _mockPrice(_triggerOf(3_000e8) - 1);
        vm.warp(t0 + 86400 + 24 hours + 1);

        address randomCaller = makeAddr("randomCaller");
        vm.prank(randomCaller);
        vm.expectEmit(true, true, false, true, address(s));
        emit PolicySettledTriggered(pid, buyer, (1_000e6 * 8000) / 10000);
        s.checkAndSettlePolicy(pid);
    }

    // ---------------------------------------------------------------------
    // 4. Sequencer downtime extends the cleanup window -- late verify OK
    // ---------------------------------------------------------------------
    function test_E2E_SequencerDowntime_ExtendsCleanup() public requiresFork {
        _mockPrice(3_000e8);
        _mockEip712Signer(address(0xBEEF));
        _mockSeqDowntime(1 days);
        FlashETHShield24h s = _deploy();

        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params(makeAddr("e2e_buyer4")));

        // Downtime extension (1d) is configured -- exercises the
        // _validateStatusForTrigger downtime branch. Actual claim window is
        // bounded by MAX_PROOF_AGE=900s AND verifiedAt <= expiresAt; we warp
        // just past expiresAt with verifiedAt=expiresAt so the proof remains
        // fresh and the downtime path is the only thing keeping us alive.
        bytes memory proof = _proof(_triggerOf(3_000e8) - 1, "ETH", t0 + 86400);
        vm.warp(t0 + 86400 + 600);
        IShield.PayoutResult memory r = s.verifyAndCalculate(pid, proof);
        assertTrue(r.triggered);
    }

    // ---------------------------------------------------------------------
    // 5. Proof too old -- > MAX_PROOF_AGE
    // ---------------------------------------------------------------------
    function test_E2E_ProofTooOld_Reverts() public requiresFork {
        _mockPrice(3_000e8);
        _mockEip712Signer(address(0xBEEF));
        _mockSeqDowntime(0);
        FlashETHShield24h s = _deploy();

        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params(makeAddr("e2e_buyer5")));

        // verifiedAt = t0; current = t0 + MAX_PROOF_AGE + 100 -> ProofTooOld
        bytes memory proof = _proof(_triggerOf(3_000e8) - 1, "ETH", t0);
        vm.warp(t0 + 900 + 100);
        vm.expectRevert();
        s.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // 6. Oracle revert at create time -- shield reverts
    // ---------------------------------------------------------------------
    function test_E2E_OracleRevert_AtCreate() public requiresFork {
        vm.mockCallRevert(
            ORACLE_SET_A, abi.encodeWithSelector(IOracle.getLatestPrice.selector, bytes32("ETH")), "feed down"
        );
        FlashETHShield24h s = _deploy();
        vm.expectRevert();
        s.createPolicy(_params(makeAddr("e2e_buyer6")));
    }

    // ---------------------------------------------------------------------
    // 7. Wrong asset in proof -- AssetMismatch
    // ---------------------------------------------------------------------
    function test_E2E_AssetMismatch_Reverts() public requiresFork {
        _mockPrice(3_000e8);
        _mockEip712Signer(address(0xBEEF));
        _mockSeqDowntime(0);
        FlashETHShield24h s = _deploy();

        uint256 t0 = block.timestamp;
        uint256 pid = s.createPolicy(_params(makeAddr("e2e_buyer7")));

        bytes memory proof = _proof(_triggerOf(3_000e8) - 1, "BTC", t0 + 100);
        vm.warp(t0 + 200);
        vm.expectRevert();
        s.verifyAndCalculate(pid, proof);
    }

    // ---------------------------------------------------------------------
    // 8. Two policies same shield -- independent triggers
    // ---------------------------------------------------------------------
    function test_E2E_TwoPolicies_IndependentTriggers() public requiresFork {
        _mockPrice(3_000e8);
        _mockEip712Signer(address(0xBEEF));
        _mockSeqDowntime(0);
        FlashETHShield24h s = _deploy();

        uint256 t0 = block.timestamp;
        address b1 = makeAddr("buyer8a");
        address b2 = makeAddr("buyer8b");

        uint256 pid1 = s.createPolicy(_params(b1));
        // Move spot for second policy.
        _mockPrice(2_500e8);
        IShield.CreatePolicyParams memory p2 = _params(b2);
        uint256 pid2 = s.createPolicy(p2);

        // pid1 strike = 3000, trigger ~ 2640. pid2 strike = 2500, trigger ~ 2200.
        // Verify pid1 against a 2600 price (triggers pid1 only).
        bytes memory proof1 = _proof(2_600e8, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        IShield.PayoutResult memory r1 = s.verifyAndCalculate(pid1, proof1);
        assertTrue(r1.triggered, "pid1 must trigger at 2600");

        // pid2 at the same 2600 price is ABOVE its trigger (2200) -> reverts.
        bytes memory proof2 = _proof(2_600e8, "ETH", t0 + 100);
        vm.expectRevert();
        s.verifyAndCalculate(pid2, proof2);
    }

    // ---------------------------------------------------------------------
    // 9. Sanity bounds enforced at create on fork -- extreme price reverts
    // ---------------------------------------------------------------------
    function test_E2E_SanityBounds_ExtremePrice_Reverts() public requiresFork {
        _mockPrice(500_000e8); // 10x above MAX_PRICE
        FlashETHShield24h s = _deploy();
        vm.expectRevert();
        s.createPolicy(_params(makeAddr("e2e_buyer9")));
    }

    // ---------------------------------------------------------------------
    // 10. Triple-check counters after full lifecycle (paid + expired + active)
    // ---------------------------------------------------------------------
    function test_E2E_Counters_FullLifecycle() public requiresFork {
        _mockPrice(3_000e8);
        _mockEip712Signer(address(0xBEEF));
        _mockSeqDowntime(0);
        FlashETHShield24h s = _deploy();

        uint256 t0 = block.timestamp;
        uint256 pid1 = s.createPolicy(_params(makeAddr("buyerA")));
        uint256 pid2 = s.createPolicy(_params(makeAddr("buyerB")));
        uint256 pid3 = s.createPolicy(_params(makeAddr("buyerC")));

        assertEq(s.totalPolicies(), 3);
        assertEq(s.activePolicies(), 3);

        // pid1 paid out
        bytes memory proof = _proof(_triggerOf(3_000e8) - 1, "ETH", t0 + 100);
        vm.warp(t0 + 200);
        s.verifyAndCalculate(pid1, proof);
        s.markPaidOut(pid1);

        // pid2 expired explicitly
        s.markExpired(pid2);

        // pid3 still active
        assertEq(s.activePolicies(), 1);
        assertEq(s.totalActiveCoverage(), 1_000e6);
        assertEq(uint256(s.getPolicyStatus(pid3)), uint256(IShield.PolicyStatus.ACTIVE));
    }
}
