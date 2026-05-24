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

    bytes32 constant PRODUCT_ID = keccak256("FLASHBTC24-001");
    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6;
    uint16 constant TRIGGER_DROP_BPS = 600; // 6%
    uint32 constant WINDOW = 86_400; // 24h
    uint256 constant POLICY_ID = 1;

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
        shield = new FlashBTCShield24h(address(adapter), address(oracle), address(sequencer));

        adapter.initialize(address(shield), PRODUCT_ID);
        adapter.setPolicyManager(address(pm));
        // [F-01] checkAndSettlePolicy is now onlyKeeperOrRelayer. This test
        // contract acts as the keeper.
        adapter.setKeeper(address(this));

        // mint a policy (caller must be the shield's router = the adapter)
        vm.prank(address(adapter));
        shield.createPolicy(POLICY_ID, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    /// [F-01] Drives the policy to a TRUE settlement via the keeper path: 3
    /// spaced sub-barrier observations across distinct blocks (>=60s apart,
    /// strictly-increasing updatedAt) after the 5-min dwell. The first two
    /// checkAndSettlePolicy calls only ACCRUE (no PM settle); the 3rd settles.
    function _driveTriggerViaKeeper(int256 droppedAnswer) internal {
        if (block.timestamp < T0 + 5 minutes) vm.warp(T0 + 5 minutes + 1);
        for (uint256 i = 0; i < 3; i++) {
            uint256 ts = block.timestamp;
            oracle.setAnswer(droppedAnswer, ts);
            adapter.checkAndSettlePolicy(POLICY_ID);
            if (i < 2) {
                vm.roll(block.number + 1);
                vm.warp(ts + 61);
            }
        }
    }

    // ─────────── trigger path ───────────

    function testCheckAndSettle_TriggersAtThreshold_SettlesWithTrue() public {
        int256 dropped = (STRIKE * int256(uint256(10_000 - TRIGGER_DROP_BPS))) / 10_000;
        _driveTriggerViaKeeper(dropped);

        // Only the 3rd (triggering) call settles → exactly one PM settle.
        assertEq(pm.callCount(), 1);
        (bytes32 pid, uint256 policyId, bool triggered) = pm.calls(0);
        assertEq(pid, PRODUCT_ID);
        assertEq(policyId, POLICY_ID);
        assertTrue(triggered);
    }

    // [F-01] A sub-threshold price mid-window must NOT settle false (the keeper
    // cannot conclude "no trigger" until the window closes). Settlement-false is
    // exclusively the window-expiry path below.
    function testCheckAndSettle_BelowThreshold_DoesNotSettleMidWindow() public {
        vm.warp(T0 + 5 minutes + 1);
        int256 dropped = (STRIKE * int256(uint256(10_000 - (TRIGGER_DROP_BPS - 1)))) / 10_000;
        oracle.setAnswer(dropped, block.timestamp);

        adapter.checkAndSettlePolicy(POLICY_ID);
        assertEq(pm.callCount(), 0, "no settlement while window is open");
    }

    // ─────────── window-expired path (the keeper auto-settle case) ───────────

    function testCheckAndSettle_WindowExpired_CatchesAndSettlesFalse() public {
        vm.warp(T0 + WINDOW + 1);
        // [F-03] window-expiry settle-FALSE now requires the oracle to be
        // evaluable within SETTLEMENT_STALENESS, so refresh the feed.
        oracle.setAnswer(STRIKE, block.timestamp);
        adapter.checkAndSettlePolicy(POLICY_ID);

        assertEq(pm.callCount(), 1);
        (,, bool triggered) = pm.calls(0);
        assertFalse(triggered);
    }

    // ─────────── revert paths that must bubble up ───────────

    function testCheckAndSettle_RevertsWhenAlreadyFinalized() public {
        // Drive a real trigger to finalize, then a re-settle must bubble.
        _driveTriggerViaKeeper((STRIKE * int256(uint256(10_000 - TRIGGER_DROP_BPS))) / 10_000);

        vm.expectRevert(bytes("ALREADY_FINALIZED"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    // [F-03] Sequencer-down is an oracle-availability failure → ORACLE_UNAVAILABLE
    // (retryable), never an auto-settle-false.
    function testCheckAndSettle_RevertsWhenSequencerDown() public {
        vm.warp(T0 + 5 minutes + 1);
        sequencer.setDown(true);
        vm.expectRevert(bytes("ORACLE_UNAVAILABLE"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    // [F-03] Stale oracle within the window → ORACLE_UNAVAILABLE (was ORACLE_STALE).
    function testCheckAndSettle_RevertsWhenOracleStale() public {
        // warp 2h forward (past 1h staleness) but inside the 24h window
        vm.warp(T0 + 2 hours);
        vm.expectRevert(bytes("ORACLE_UNAVAILABLE"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    function testCheckAndSettle_RevertsWhenPolicyNotFound() public {
        vm.warp(T0 + 5 minutes + 1);
        vm.expectRevert(bytes("POLICY_NOT_FOUND"));
        adapter.checkAndSettlePolicy(999);
    }

    function testCheckAndSettle_RevertsWhenPolicyManagerUnset() public {
        FlashShieldAdapter adapterImpl2 = new FlashShieldAdapter();
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(adapterImpl2), "");
        FlashShieldAdapter adapter2 = FlashShieldAdapter(address(proxy2));
        adapter2.initialize(address(shield), PRODUCT_ID);
        adapter2.setKeeper(address(this)); // pass the keeper gate to reach the PM check
        // intentionally skip setPolicyManager

        vm.expectRevert(bytes("Policy manager unset"));
        adapter2.checkAndSettlePolicy(POLICY_ID);
    }

    // ─────────── permissioning ───────────

    // [F-01] Settlement is NO LONGER permissionless — it is gated to the keeper
    // or relayer. A random caller reverts; the keeper succeeds.
    function testCheckAndSettle_OnlyKeeperOrRelayer() public {
        vm.warp(T0 + 5 minutes + 1);
        oracle.setAnswer(STRIKE, block.timestamp);

        vm.prank(randomCaller);
        vm.expectRevert(bytes("ONLY_KEEPER_OR_RELAYER"));
        adapter.checkAndSettlePolicy(POLICY_ID);

        // keeper (this contract) can call; below-threshold → no settle, no revert.
        adapter.checkAndSettlePolicy(POLICY_ID);
        assertEq(pm.callCount(), 0);
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
