// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlashBTCShield24h} from "../../src/products/FlashBTCShield24h.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";

/// @title CheckAndSettlePolicy unit tests (Sprint Fix 7.4 C1)
/// @notice Covers the new `FlashShieldAdapter.checkAndSettlePolicy(uint256)`
///         permissionless settle path that ShieldKeeper consumes. Closes the
///         interface-mismatch gap reported by the 7.4 Functional Audit V1.

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
    int256 public answer;
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

contract MockPolicyManager {
    struct Call {
        bytes32 productId;
        uint256 policyId;
        bool triggered;
    }

    Call[] public calls;
    bool public revertOnSettle;

    function settlePolicy(bytes32 productId, uint256 policyId, bool triggered) external {
        require(!revertOnSettle, "PM_REVERT");
        calls.push(Call({productId: productId, policyId: policyId, triggered: triggered}));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function setRevertOnSettle(bool r) external {
        revertOnSettle = r;
    }
}

contract CheckAndSettlePolicyTest is Test {
    FlashBTCShield24h shield;
    FlashShieldAdapter adapter;
    MockChainlinkAggregator oracle;
    MockSequencerFeed sequencer;
    MockPolicyManager pm;

    address owner = address(this);
    address holder = makeAddr("holder");
    address randomCaller = makeAddr("random");
    // [legacy-migration] F-01.3: checkAndSettlePolicy is now onlyKeeperOrRelayer.
    // Wire a keeper and prank as it before every settle call.
    address keeper = makeAddr("keeper");

    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC24-001");
    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6;
    uint16 constant TRIGGER_DROP_BPS = 600; // 6%
    uint32 constant WINDOW = 86_400; // 24h
    uint256 constant POLICY_ID = 1;
    // [legacy-migration] F-01 multi-block confirmation params (BaseFlashShield).
    uint256 constant MIN_DWELL = 5 minutes; // MIN_DWELL_PERIOD
    uint32 constant CONF_INTERVAL = 60; // CONFIRMATION_INTERVAL

    function setUp() public {
        vm.warp(T0);
        oracle = new MockChainlinkAggregator(STRIKE, T0);
        sequencer = new MockSequencerFeed();
        pm = new MockPolicyManager();

        // adapter proxy deployed first so we have its address before the shield
        FlashShieldAdapter adapterImpl = new FlashShieldAdapter();
        ERC1967Proxy proxy = new ERC1967Proxy(address(adapterImpl), "");
        adapter = FlashShieldAdapter(address(proxy));

        // shield trusts the adapter as its `router`
        shield = FlashBTCShield24h(
            address(
                new ERC1967Proxy(
                    address(new FlashBTCShield24h()),
                    abi.encodeCall(
                        FlashBTCShield24h.initialize, (address(adapter), address(oracle), address(sequencer))
                    )
                )
            )
        );

        adapter.initialize(address(shield), PRODUCT_ID);
        adapter.setPolicyManager(address(pm));
        // [legacy-migration] F-01.3: wire the keeper authorised to settle.
        adapter.setKeeper(keeper);

        // mint a policy (caller must be the shield's router = the adapter)
        vm.prank(address(adapter));
        shield.createPolicy(POLICY_ID, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    /// @dev [legacy-migration] F-01: a trigger needs THREE spaced sub-barrier
    ///      observations (distinct blocks, >= CONF_INTERVAL apart, after
    ///      start + MIN_DWELL). checkAndSettlePolicy routes to
    ///      shield.verifyAndCalculate, so it accrues one confirmation per call;
    ///      the first two RETURN reason "ACCRUING" (adapter early-returns without
    ///      settling), the third finalises and settles TRUE. Drives all 3 as the
    ///      keeper. `dropped` must sit at/below the barrier.
    function _drive3SettleConfirmations(uint256 policyId, int256 dropped) internal {
        uint256 base = T0 + MIN_DWELL;
        uint256 baseBlock = block.number; // capture ONCE (via_ir caching gotcha)
        for (uint256 i = 0; i < 3; i++) {
            uint256 ts = base + i * CONF_INTERVAL;
            vm.warp(ts);
            vm.roll(baseBlock + 1 + i); // ABSOLUTE, strictly-increasing blocks
            oracle.setAnswer(dropped, ts); // fresh round each observation
            vm.prank(keeper);
            adapter.checkAndSettlePolicy(policyId);
        }
    }

    // ─────────── trigger path ───────────

    function testCheckAndSettle_TriggersAtThreshold_SettlesWithTrue() public {
        // [legacy-migration] F-01: a single keeper call no longer triggers
        // (pre-dwell + needs 3 spaced confirmations). The first two calls accrue
        // (adapter early-returns, no settle); the 3rd finalises → settles TRUE.
        int256 dropped = (STRIKE * int256(uint256(10_000 - TRIGGER_DROP_BPS))) / 10_000;
        _drive3SettleConfirmations(POLICY_ID, dropped);

        assertEq(pm.callCount(), 1);
        (bytes32 pid, uint256 policyId, bool triggered) = pm.calls(0);
        assertEq(pid, PRODUCT_ID);
        assertEq(policyId, POLICY_ID);
        assertTrue(triggered);
    }

    function testCheckAndSettle_NoTriggerBelowThreshold_SettlesWithFalse() public {
        // [legacy-migration] F-01 + F-03: during the LIVE window a below-barrier
        // observation no longer settles the policy false. It RESETs the accrual
        // (adapter early-returns, NO settlePolicy call). False-settlement now
        // happens ONLY on window expiry (see _WindowExpired test). Drive past the
        // dwell gate so we exercise the price/reset path, not DWELL_NOT_ELAPSED.
        vm.warp(T0 + MIN_DWELL);
        vm.roll(block.number + 1);
        int256 dropped = (STRIKE * int256(uint256(10_000 - (TRIGGER_DROP_BPS - 1)))) / 10_000;
        oracle.setAnswer(dropped, T0 + MIN_DWELL);

        vm.prank(keeper);
        adapter.checkAndSettlePolicy(POLICY_ID);

        // Below-barrier in the live window: no settlement (accrual reset only).
        assertEq(pm.callCount(), 0, "below-barrier live observation must not settle");
        // Policy remains non-finalized / pending for retry.
        (,,,,, bool finalized) = shield.getPolicyInfo(POLICY_ID);
        assertFalse(finalized, "policy still pending after a below-barrier reset");
    }

    // ─────────── window-expired path (the keeper auto-settle case) ───────────

    function testCheckAndSettle_WindowExpired_CatchesAndSettlesFalse() public {
        vm.warp(T0 + WINDOW + 1);
        // [legacy-migration] F-03: the expiry settlement path now reads the feed
        // and requires it evaluable under SETTLEMENT_STALENESS; otherwise it
        // reverts ORACLE_UNAVAILABLE (never blindly finalises false). Refresh the
        // oracle so the window-expired policy legitimately settles false.
        oracle.setAnswer(STRIKE, T0 + WINDOW + 1);
        // [legacy-migration] F-01.3: settle as the wired keeper.
        vm.prank(keeper);
        adapter.checkAndSettlePolicy(POLICY_ID);

        assertEq(pm.callCount(), 1);
        (,, bool triggered) = pm.calls(0);
        assertFalse(triggered);
    }

    // ─────────── revert paths that must bubble up ───────────

    function testCheckAndSettle_RevertsWhenAlreadyFinalized() public {
        // [legacy-migration] F-01: a single live call at T0+60 no longer
        // finalises (pre-dwell). Finalise the policy first via the window-expiry
        // settle path (oracle refreshed so it's evaluable), then a second settle
        // must bubble up ALREADY_FINALIZED from the shield.
        vm.warp(T0 + WINDOW + 1);
        oracle.setAnswer(STRIKE, T0 + WINDOW + 1);
        vm.prank(keeper);
        adapter.checkAndSettlePolicy(POLICY_ID);

        vm.prank(keeper);
        vm.expectRevert(bytes("ALREADY_FINALIZED"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    function testCheckAndSettle_RevertsWhenSequencerDown() public {
        // [legacy-migration] F-01: the dwell gate is checked BEFORE the sequencer
        // guard, so warp past start + MIN_DWELL to reach the SEQUENCER_DOWN check
        // (a pre-dwell call would revert DWELL_NOT_ELAPSED → NOT_SETTLEABLE_YET).
        vm.warp(T0 + MIN_DWELL);
        sequencer.setDown(true);
        // [legacy-migration] F-01.3 + F-03: settle as the wired keeper. The shield
        // reverts SEQUENCER_DOWN, which the adapter's catch REMAPS to
        // "ORACLE_UNAVAILABLE" (oracle/sequencer unavailability bucket → keeper
        // retries once the sequencer recovers; never settled false).
        vm.prank(keeper);
        vm.expectRevert(bytes("ORACLE_UNAVAILABLE"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    function testCheckAndSettle_RevertsWhenOracleStale() public {
        // staleness threshold is 1h; warp 2h forward but stay inside the
        // policy window (24h) so the LIVE staleness check fires first.
        // [legacy-migration] F-03: the adapter REMAPS the shield's ORACLE_STALE
        // into ORACLE_UNAVAILABLE (so the keeper retries once the oracle
        // recovers and the policy is never settled false on a stale read).
        vm.warp(T0 + 2 hours);
        // [legacy-migration] F-01.3: settle as the wired keeper.
        vm.prank(keeper);
        vm.expectRevert(bytes("ORACLE_UNAVAILABLE"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    function testCheckAndSettle_RevertsWhenPolicyNotFound() public {
        // [legacy-migration] F-01.3: settle as the wired keeper so the call
        // reaches the shield's POLICY_NOT_FOUND revert (not the keeper gate).
        vm.prank(keeper);
        vm.expectRevert(bytes("POLICY_NOT_FOUND"));
        adapter.checkAndSettlePolicy(999);
    }

    function testCheckAndSettle_RevertsWhenPolicyManagerUnset() public {
        FlashShieldAdapter adapterImpl2 = new FlashShieldAdapter();
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(adapterImpl2), "");
        FlashShieldAdapter adapter2 = FlashShieldAdapter(address(proxy2));
        adapter2.initialize(address(shield), PRODUCT_ID);
        // intentionally skip setPolicyManager
        // [legacy-migration] F-01.3: still wire a keeper so the call passes the
        // onlyKeeperOrRelayer gate and reaches the "Policy manager unset" guard
        // (the modifier is checked BEFORE the policyManager require).
        adapter2.setKeeper(keeper);

        vm.prank(keeper);
        vm.expectRevert(bytes("Policy manager unset"));
        adapter2.checkAndSettlePolicy(POLICY_ID);
    }

    // ─────────── permissioning ───────────

    // [legacy-migration] OBSOLETE→REWORKED. checkAndSettlePolicy is NO LONGER
    // permissionless (F-01.3). Original intent ("anyone can settle") is dead;
    // this now asserts the NEW access-control behavior: a random non-keeper/
    // non-relayer caller REVERTS ONLY_KEEPER_OR_RELAYER, while the wired keeper
    // AND relayer are authorized to call it (settling a window-expired policy).
    function testCheckAndSettle_IsAccessGated() public {
        // 1. Random caller is rejected by the gate (before any other logic).
        vm.prank(randomCaller);
        vm.expectRevert(bytes("ONLY_KEEPER_OR_RELAYER"));
        adapter.checkAndSettlePolicy(POLICY_ID);

        // 2. The wired keeper IS authorized — settle the policy via window expiry.
        vm.warp(T0 + WINDOW + 1);
        oracle.setAnswer(STRIKE, T0 + WINDOW + 1);
        vm.prank(keeper);
        adapter.checkAndSettlePolicy(POLICY_ID);
        assertEq(pm.callCount(), 1, "keeper settle succeeded");

        // 3. A wired relayer is ALSO authorized (passes the gate). Use a fresh
        //    policy/adapter so we exercise the relayer branch on a live policy.
        FlashShieldAdapter adapterImpl3 = new FlashShieldAdapter();
        FlashShieldAdapter adapter3 = FlashShieldAdapter(address(new ERC1967Proxy(address(adapterImpl3), "")));
        MockChainlinkAggregator oracle3 = new MockChainlinkAggregator(STRIKE, block.timestamp);
        FlashBTCShield24h shield3 = FlashBTCShield24h(
            address(
                new ERC1967Proxy(
                    address(new FlashBTCShield24h()),
                    abi.encodeCall(
                        FlashBTCShield24h.initialize, (address(adapter3), address(oracle3), address(sequencer))
                    )
                )
            )
        );
        adapter3.initialize(address(shield3), PRODUCT_ID);
        adapter3.setPolicyManager(address(pm));
        address relayer = makeAddr("relayer");
        adapter3.setRelayer(relayer);
        uint256 start3 = block.timestamp;
        vm.prank(address(adapter3));
        shield3.createPolicy(POLICY_ID, holder, COVERAGE, uint64(start3), uint64(start3 + WINDOW));

        // A random caller is still rejected on adapter3 by the gate.
        vm.prank(randomCaller);
        vm.expectRevert(bytes("ONLY_KEEPER_OR_RELAYER"));
        adapter3.checkAndSettlePolicy(POLICY_ID);

        // [legacy-migration] The relayer PASSES the gate. On a fresh live policy
        // (pre-dwell) the call proceeds past the gate and the shield reverts
        // DWELL_NOT_ELAPSED → adapter remaps to "NOT_SETTLEABLE_YET". Getting that
        // (not ONLY_KEEPER_OR_RELAYER) proves the relayer is authorized — without
        // depending on the window-expiry oracle-freshness path.
        vm.prank(relayer);
        vm.expectRevert(bytes("NOT_SETTLEABLE_YET"));
        adapter3.checkAndSettlePolicy(POLICY_ID);
        // The relayer passed the gate (NOT_SETTLEABLE_YET, not ONLY_KEEPER_OR_RELAYER);
        // adapter3 routes to a separate pm-less settle path so no settle is recorded here.
    }

    function testSetPolicyManager_OnlyOwner() public {
        address newPm = makeAddr("new-pm");
        vm.prank(randomCaller);
        vm.expectRevert();
        adapter.setPolicyManager(newPm);
    }

    function testSetPolicyManager_RevertsOnZero() public {
        vm.expectRevert(bytes("Zero PM"));
        adapter.setPolicyManager(address(0));
    }
}
