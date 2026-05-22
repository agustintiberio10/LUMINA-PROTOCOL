// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {FlashShieldAdapter, ISlimShield} from "../../src/shields/FlashShieldAdapter.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title FlashShieldAdapter unit tests (Sprint T-30c Phase B)
/// @notice Covers the ~125 LOC adapter that bridges the slim T-30a flash-shield
///         surface to the legacy IShieldV2 struct-based surface that
///         PolicyManagerV2 still expects. Tests use absolute warps (via_ir
///         caching gotcha) and ASCII-only literals.

contract MockChainlinkAggregator {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public constant decimals = 8;

    constructor(int256 _a, uint256 _u) {
        answer = _a;
        updatedAt = _u;
    }

    function setAnswer(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

contract MockSequencerFeed {
    int256 public answer; // 0 = up, 1 = down
    uint256 public startedAt;

    constructor() {
        startedAt = block.timestamp > 2 hours ? block.timestamp - 2 hours : 0;
        answer = 0;
    }

    function setDown(bool down) external {
        answer = down ? int256(1) : int256(0);
        startedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, startedAt, 1);
    }
}

/// @notice Minimal upgrade target for UUPS authorization tests.
contract FlashShieldAdapterV2 is FlashShieldAdapter {
    function version() external pure returns (string memory) {
        return "V2";
    }
}

contract FlashShieldAdapterTest is Test {
    FlashShieldAdapter adapterImpl;
    FlashShieldAdapter adapter;
    FlashBTCShield1h shield;
    MockChainlinkAggregator oracle;
    MockSequencerFeed sequencer;

    address holder = makeAddr("holder");
    address attacker = makeAddr("attacker");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8; // BTC at $50k
    uint256 constant COVERAGE = 10_000e6; // $10k USDC
    uint32 constant WINDOW = 3600; // 1h
    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC1H-001");

    function setUp() public {
        vm.warp(T0);
        oracle = new MockChainlinkAggregator(STRIKE, T0);
        sequencer = new MockSequencerFeed();

        // Deploy adapter impl + proxy uninitialized so we can wire the shield
        // with the proxy address as `router` before initializing the adapter.
        adapterImpl = new FlashShieldAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(adapterImpl), "");
        adapter = FlashShieldAdapter(address(proxy));

        shield = new FlashBTCShield1h(address(adapter), address(oracle), address(sequencer));
        adapter.initialize(address(shield), PRODUCT_ID);
    }

    // ── helpers ────────────────────────────────────────────────────────────────
    function _legacyParams(address buyer, uint256 coverage, uint32 duration)
        internal
        pure
        returns (FlashShieldAdapter.LegacyCreatePolicyParams memory)
    {
        return FlashShieldAdapter.LegacyCreatePolicyParams({
            buyer: buyer,
            coverageAmount: coverage,
            premiumAmount: 0,
            durationSeconds: duration,
            asset: bytes32("BTC"),
            stablecoin: bytes32("USDC"),
            protocol: address(0),
            extraData: ""
        });
    }

    // ── 1. initialize stores correct shield + productId ──────────────────────
    function testInitialize_SetsCorrectShield() public {
        assertEq(address(adapter.shield()), address(shield), "shield address stored");
        assertEq(adapter.productIdLocal(), PRODUCT_ID, "productId stored");
        assertEq(adapter.productId(), PRODUCT_ID, "productId() getter mirrors local");
        assertEq(adapter.nextPolicyId(), 1, "policy counter starts at 1");
        assertEq(adapter.owner(), address(this), "deployer is owner");
    }

    // ── 2. initialize reverts on zero shield ─────────────────────────────────
    function testInitialize_RevertsIfShieldZero() public {
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(adapterImpl), "");
        FlashShieldAdapter fresh = FlashShieldAdapter(address(proxy2));
        vm.expectRevert(bytes("Zero shield"));
        fresh.initialize(address(0), PRODUCT_ID);
    }

    // ── 3. initialize cannot be called twice ─────────────────────────────────
    function testInitialize_RevertsIfCalledTwice() public {
        vm.expectRevert(); // Initializable: invalid initialization
        adapter.initialize(address(shield), PRODUCT_ID);
    }

    // ── 4. createPolicy translates struct → slim signature ───────────────────
    function testCreatePolicy_TranslatesCorrectly() public {
        FlashShieldAdapter.LegacyCreatePolicyParams memory p = _legacyParams(holder, COVERAGE, WINDOW);
        uint256 policyId = adapter.createPolicy(p);
        assertEq(policyId, 1, "first policy id assigned by adapter");
        assertEq(adapter.nextPolicyId(), 2, "counter increments");

        // Confirm shield received the same coverage/holder and snapshotted strike.
        (address h, uint256 cov, uint256 strike, uint64 start, uint64 end, bool finalized) =
            shield.getPolicyInfo(policyId);
        assertEq(h, holder, "shield stored holder");
        assertEq(cov, COVERAGE, "shield stored coverage");
        assertEq(strike, uint256(STRIKE), "shield snapshot strike");
        assertEq(start, uint64(T0), "shield start ts == block.timestamp");
        assertEq(end, uint64(T0 + WINDOW), "shield expiresAt == start + duration");
        assertFalse(finalized, "policy not yet finalized");
    }

    // ── 5. createPolicy increments id monotonically ──────────────────────────
    function testCreatePolicy_AssignsMonotonicIds() public {
        for (uint256 i = 0; i < 3; i++) {
            uint256 id = adapter.createPolicy(_legacyParams(holder, COVERAGE, WINDOW));
            assertEq(id, i + 1, "monotonic ids starting at 1");
        }
        assertEq(adapter.nextPolicyId(), 4, "next-id after 3 creates");
    }

    // ── 6. verifyAndCalculate returns LegacyPayoutResult on trigger ─────────
    function testVerifyAndCalculate_HandlesTriggered() public {
        uint256 policyId = adapter.createPolicy(_legacyParams(holder, COVERAGE, WINDOW));
        vm.warp(T0 + 60);
        // Force a drop above the 2.5% trigger.
        int256 dropped = (STRIKE * 9700) / 10_000;
        oracle.setAnswer(dropped, T0 + 60);

        FlashShieldAdapter.LegacyPayoutResult memory r = adapter.verifyAndCalculate(policyId, "");
        assertTrue(r.triggered, "triggered flag set");
        assertEq(r.payoutAmount, (COVERAGE * 8000) / 10_000, "payout = 80% coverage");
        assertEq(r.recipient, holder, "recipient echoed");
        assertEq(r.reason, bytes32("TRIGGER_DROP"), "reason TRIGGER_DROP");
    }

    // ── 7. verifyAndCalculate returns no-trigger result when below threshold ─
    function testVerifyAndCalculate_HandlesNoTrigger() public {
        uint256 policyId = adapter.createPolicy(_legacyParams(holder, COVERAGE, WINDOW));
        vm.warp(T0 + 60);
        // Drop only 1% (below 2.5%).
        int256 dropped = (STRIKE * 9900) / 10_000;
        oracle.setAnswer(dropped, T0 + 60);

        FlashShieldAdapter.LegacyPayoutResult memory r = adapter.verifyAndCalculate(policyId, "");
        assertFalse(r.triggered, "not triggered");
        assertEq(r.payoutAmount, 0, "no payout");
        assertEq(r.recipient, holder, "recipient echoed even on no-trigger");
        assertEq(r.reason, bytes32("NO_TRIGGER"), "reason NO_TRIGGER");
    }

    // ── 8. verifyAndCalculate ignores oracleProof arg (slim reads Chainlink) ─
    function testVerifyAndCalculate_IgnoresOracleProof() public {
        uint256 policyId = adapter.createPolicy(_legacyParams(holder, COVERAGE, WINDOW));
        vm.warp(T0 + 60);
        oracle.setAnswer((STRIKE * 9700) / 10_000, T0 + 60);

        // Garbage proof bytes — must not affect outcome (slim reads on-chain).
        bytes memory junk = hex"deadbeefcafebabe";
        FlashShieldAdapter.LegacyPayoutResult memory r = adapter.verifyAndCalculate(policyId, junk);
        assertTrue(r.triggered, "proof bytes ignored, drop still triggers");
    }

    // ── 9. verifyAndCalculate reverts when underlying shield rejects ─────────
    function testVerifyAndCalculate_PropagatesShieldRevert() public {
        // No policy ever created → shield reverts POLICY_NOT_FOUND
        vm.expectRevert(bytes("POLICY_NOT_FOUND"));
        adapter.verifyAndCalculate(999, "");
    }

    // ── 10. getPolicyInfo translates slim → legacy 6-tuple ───────────────────
    function testGetPolicyInfo_TranslatesFromShield() public {
        uint256 policyId = adapter.createPolicy(_legacyParams(holder, COVERAGE, WINDOW));
        (address agent, uint256 cov, uint256 premium, uint256 maxPayout, uint256 expiresAt, uint8 status) =
            adapter.getPolicyInfo(policyId);
        assertEq(agent, holder, "insured agent = holder");
        assertEq(cov, COVERAGE, "coverage forwarded");
        assertEq(premium, 0, "premium always 0 (PM tracks it)");
        assertEq(maxPayout, (COVERAGE * 8000) / 10_000, "maxPayout = 80% coverage");
        assertEq(expiresAt, T0 + WINDOW, "expiresAt forwarded");
        assertEq(status, 0, "status 0 = active");
    }

    // ── 11. getPolicyInfo reflects finalized status after verify ─────────────
    function testGetPolicyInfo_StatusFinalizedAfterVerify() public {
        uint256 policyId = adapter.createPolicy(_legacyParams(holder, COVERAGE, WINDOW));
        vm.warp(T0 + 60);
        oracle.setAnswer((STRIKE * 9700) / 10_000, T0 + 60);
        adapter.verifyAndCalculate(policyId, "");

        (,,,,, uint8 status) = adapter.getPolicyInfo(policyId);
        assertEq(status, 2, "status 2 = finalized");
    }

    // ── 12. getPolicyInfo on missing policy returns zeros (no revert) ────────
    function testGetPolicyInfo_NonExistentReturnsZeros() public view {
        (address agent, uint256 cov, uint256 premium, uint256 maxPayout, uint256 expiresAt, uint8 status) =
            adapter.getPolicyInfo(424242);
        assertEq(agent, address(0));
        assertEq(cov, 0);
        assertEq(premium, 0);
        assertEq(maxPayout, 0);
        assertEq(expiresAt, 0);
        assertEq(status, 0);
    }

    // ── 13. UUPS upgrade gated to owner ──────────────────────────────────────
    function testUUPS_OnlyOwnerCanUpgrade() public {
        FlashShieldAdapterV2 v2 = new FlashShieldAdapterV2();
        vm.prank(attacker);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        adapter.upgradeToAndCall(address(v2), "");
    }

    // ── 14. UUPS upgrade succeeds for owner and storage persists ─────────────
    function testUUPS_UpgradeAuthorization() public {
        // Take an action so storage is non-trivial before upgrade.
        uint256 policyId = adapter.createPolicy(_legacyParams(holder, COVERAGE, WINDOW));
        FlashShieldAdapterV2 v2 = new FlashShieldAdapterV2();
        adapter.upgradeToAndCall(address(v2), "");

        // V2 selectors live.
        assertEq(FlashShieldAdapterV2(address(adapter)).version(), "V2", "upgraded impl reachable");
        // Storage preserved across the upgrade.
        assertEq(adapter.productIdLocal(), PRODUCT_ID, "productId persists");
        assertEq(adapter.nextPolicyId(), 2, "counter persists post-upgrade");
        (address h,,,,,) = adapter.getPolicyInfo(policyId);
        assertEq(h, holder, "underlying shield storage reachable post-upgrade");
    }

    // ── 15. Sequencer-down inherited from shield blocks createPolicy ─────────
    function testSequencerCheck_Inherited() public {
        sequencer.setDown(true);
        vm.expectRevert(bytes("SEQUENCER_DOWN"));
        adapter.createPolicy(_legacyParams(holder, COVERAGE, WINDOW));
    }

    // ── 16. Shield only accepts adapter as router (sanity) ───────────────────
    function testShield_RejectsCallsNotFromAdapter() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("NOT_ROUTER"));
        shield.createPolicy(1, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }
}
