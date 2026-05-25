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
        shield = FlashBTCShield24h(address(new ERC1967Proxy(address(new FlashBTCShield24h()), abi.encodeCall(FlashBTCShield24h.initialize, (address(adapter), address(oracle), address(sequencer))))));

        adapter.initialize(address(shield), PRODUCT_ID);
        adapter.setPolicyManager(address(pm));

        // mint a policy (caller must be the shield's router = the adapter)
        vm.prank(address(adapter));
        shield.createPolicy(POLICY_ID, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    // ─────────── trigger path ───────────

    function testCheckAndSettle_TriggersAtThreshold_SettlesWithTrue() public {
        vm.warp(T0 + 60);
        int256 dropped = (STRIKE * int256(uint256(10_000 - TRIGGER_DROP_BPS))) / 10_000;
        oracle.setAnswer(dropped, T0 + 60);

        adapter.checkAndSettlePolicy(POLICY_ID);

        assertEq(pm.callCount(), 1);
        (bytes32 pid, uint256 policyId, bool triggered) = pm.calls(0);
        assertEq(pid, PRODUCT_ID);
        assertEq(policyId, POLICY_ID);
        assertTrue(triggered);
    }

    function testCheckAndSettle_NoTriggerBelowThreshold_SettlesWithFalse() public {
        vm.warp(T0 + 60);
        int256 dropped = (STRIKE * int256(uint256(10_000 - (TRIGGER_DROP_BPS - 1)))) / 10_000;
        oracle.setAnswer(dropped, T0 + 60);

        adapter.checkAndSettlePolicy(POLICY_ID);

        assertEq(pm.callCount(), 1);
        (,, bool triggered) = pm.calls(0);
        assertFalse(triggered);
    }

    // ─────────── window-expired path (the keeper auto-settle case) ───────────

    function testCheckAndSettle_WindowExpired_CatchesAndSettlesFalse() public {
        vm.warp(T0 + WINDOW + 1);
        // oracle freshness is not required for the catch path since the
        // shield reverts on the window guard BEFORE reading the feed
        adapter.checkAndSettlePolicy(POLICY_ID);

        assertEq(pm.callCount(), 1);
        (,, bool triggered) = pm.calls(0);
        assertFalse(triggered);
    }

    // ─────────── revert paths that must bubble up ───────────

    function testCheckAndSettle_RevertsWhenAlreadyFinalized() public {
        vm.warp(T0 + 60);
        oracle.setAnswer(STRIKE, T0 + 60);
        adapter.checkAndSettlePolicy(POLICY_ID);

        vm.expectRevert(bytes("ALREADY_FINALIZED"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    function testCheckAndSettle_RevertsWhenSequencerDown() public {
        sequencer.setDown(true);
        vm.expectRevert(bytes("SEQUENCER_DOWN"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    function testCheckAndSettle_RevertsWhenOracleStale() public {
        // staleness threshold is 1h; warp 2h forward but stay inside the
        // policy window (24h) so the staleness check fires first
        vm.warp(T0 + 2 hours);
        vm.expectRevert(bytes("ORACLE_STALE"));
        adapter.checkAndSettlePolicy(POLICY_ID);
    }

    function testCheckAndSettle_RevertsWhenPolicyNotFound() public {
        vm.expectRevert(bytes("POLICY_NOT_FOUND"));
        adapter.checkAndSettlePolicy(999);
    }

    function testCheckAndSettle_RevertsWhenPolicyManagerUnset() public {
        FlashShieldAdapter adapterImpl2 = new FlashShieldAdapter();
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(adapterImpl2), "");
        FlashShieldAdapter adapter2 = FlashShieldAdapter(address(proxy2));
        adapter2.initialize(address(shield), PRODUCT_ID);
        // intentionally skip setPolicyManager

        vm.expectRevert(bytes("Policy manager unset"));
        adapter2.checkAndSettlePolicy(POLICY_ID);
    }

    // ─────────── permissioning ───────────

    function testCheckAndSettle_IsPermissionless() public {
        vm.warp(T0 + 60);
        oracle.setAnswer(STRIKE, T0 + 60);

        // anyone can call — keeper, EOA, whatever
        vm.prank(randomCaller);
        adapter.checkAndSettlePolicy(POLICY_ID);

        assertEq(pm.callCount(), 1);
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
