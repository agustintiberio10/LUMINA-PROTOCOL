// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";
import {FlashShieldAdapter} from "../../src/shields/FlashShieldAdapter.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {FlexAggregator, FlexSequencer} from "./helpers/FlexAggregator.sol";

/// @title F-01 trigger-gating tests (red-team fix)
/// @notice Asserts the POST-FIX multi-block confirmation + dwell model and
///         keeper/relayer-gated settlement. Each test fails against the old
///         single-tx "free barrier option" behavior.
contract F01_TriggerGating is Test {
    FlashBTCShield1h shield;
    FlexAggregator oracle;
    FlexSequencer seq;

    address router = makeAddr("router"); // shield's onlyRouter caller
    address holder = makeAddr("holder");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6;
    uint32 constant WINDOW = 3600;
    uint16 constant TRIGGER_DROP_BPS = 250; // 2.5%

    // a price comfortably below the 2.5% barrier (3% drop)
    int256 constant BELOW_BARRIER = (STRIKE * 9700) / 10_000;

    function setUp() public {
        vm.warp(T0);
        oracle = new FlexAggregator(STRIKE, T0);
        seq = new FlexSequencer();
        shield = new FlashBTCShield1h(router, address(oracle), address(seq));

        vm.prank(router);
        shield.createPolicy(1, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
    }

    /// Accrue one valid sub-barrier observation (must RETURN, not revert, so the
    /// observation persists). Asserts the returned reason is "ACCRUING".
    function _accrue(uint256 pid) internal {
        vm.prank(router);
        (bool triggered,,, bytes32 reason) = shield.verifyAndCalculate(pid);
        assertFalse(triggered, "accrual step must not trigger");
        assertEq(reason, bytes32("ACCRUING"), "accrual reason");
    }

    /// One verify call accrues AT MOST one confirmation; trigger requires 3
    /// spaced observations across distinct blocks. The accrual PERSISTS across
    /// calls (returns, does not revert) — this is the core F-01 invariant.
    function test_TriggerRequiresMultiBlockConfirmation() public {
        uint256 t = T0 + 5 minutes;
        vm.warp(t);
        vm.roll(100);
        oracle.push(BELOW_BARRIER, t);

        // Confirmation #1: accrues and PERSISTS (no revert).
        _accrue(1);
        (uint8 c1,) = shield.getConfirmation(1);
        assertEq(c1, 1, "first observation accrued");

        // Same block re-call cannot add a second observation (reverts, no change).
        vm.prank(router);
        vm.expectRevert(bytes("SAME_BLOCK_OBSERVATION"));
        shield.verifyAndCalculate(1);
        (uint8 cStill,) = shield.getConfirmation(1);
        assertEq(cStill, 1, "rejected observation does not advance count");

        // Confirmation #2: new block, newer round, >=60s later.
        t += 60;
        vm.warp(t);
        vm.roll(101);
        oracle.push(BELOW_BARRIER, t);
        _accrue(1);
        (uint8 c2,) = shield.getConfirmation(1);
        assertEq(c2, 2, "second observation accrued");

        // Confirmation #3 → triggers.
        t += 60;
        vm.warp(t);
        vm.roll(102);
        oracle.push(BELOW_BARRIER, t);
        vm.prank(router);
        (bool triggered, uint256 payout,, bytes32 reason) = shield.verifyAndCalculate(1);
        assertTrue(triggered, "third confirmation triggers");
        assertEq(reason, bytes32("TRIGGER_DROP"), "trigger reason");
        assertEq(payout, (COVERAGE * 8000) / 10_000, "80% payout");
    }

    /// Confirmations too close together (<60s) are rejected even across blocks.
    function test_ConfirmationInterval_Enforced() public {
        uint256 t = T0 + 5 minutes;
        vm.warp(t);
        vm.roll(100);
        oracle.push(BELOW_BARRIER, t);
        _accrue(1); // confirmation #1 persists

        // Next block, newer round, but only 30s later → too soon.
        t += 30;
        vm.warp(t);
        vm.roll(101);
        oracle.push(BELOW_BARRIER, t);
        vm.prank(router);
        vm.expectRevert(bytes("CONFIRMATION_TOO_SOON"));
        shield.verifyAndCalculate(1);
        (uint8 c,) = shield.getConfirmation(1);
        assertEq(c, 1, "too-soon observation rejected, count unchanged");
    }

    /// No trigger/settle before start + MIN_DWELL_PERIOD (5 min).
    function test_MinDwellPeriodEnforced() public {
        // 1s into the window, well before dwell elapses.
        uint256 t = T0 + 1;
        vm.warp(t);
        vm.roll(50);
        oracle.push(BELOW_BARRIER, t);
        vm.prank(router);
        vm.expectRevert(bytes("DWELL_NOT_ELAPSED"));
        shield.verifyAndCalculate(1);

        // Exactly at the dwell boundary it becomes evaluable (accrues, no dwell revert).
        t = T0 + 5 minutes;
        vm.warp(t);
        vm.roll(51);
        oracle.push(BELOW_BARRIER, t);
        _accrue(1);
        (uint8 c,) = shield.getConfirmation(1);
        assertEq(c, 1, "accrual begins exactly at dwell boundary");
    }

    /// The single-block buy+trigger barrier-option exploit must NOT work.
    function test_BarrierOptionExploitDoesNotWork() public {
        // Fresh policy created this block; attacker tries to trigger in the SAME
        // block by crashing the oracle and calling verify immediately.
        vm.prank(router);
        shield.createPolicy(2, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));
        oracle.push(STRIKE / 2, T0); // 50% crash
        vm.prank(router);
        // Dwell not elapsed (same block as start) → cannot exercise the option.
        vm.expectRevert(bytes("DWELL_NOT_ELAPSED"));
        shield.verifyAndCalculate(2);

        // Even after dwell, a single call in a single block cannot trigger: it
        // can only accrue ONE observation (count stays 1, triggered=false).
        uint256 t = T0 + 5 minutes;
        vm.warp(t);
        vm.roll(200);
        oracle.push(STRIKE / 2, t);
        vm.prank(router);
        (bool triggered,,,) = shield.verifyAndCalculate(2);
        assertFalse(triggered, "single block/call cannot trigger");
        (uint8 c,) = shield.getConfirmation(2);
        assertEq(c, 1, "only one observation possible per block/call");

        // A second same-block call is rejected (reverts), so the option still
        // cannot be exercised atomically.
        vm.prank(router);
        vm.expectRevert(bytes("SAME_BLOCK_OBSERVATION"));
        shield.verifyAndCalculate(2);
    }

    /// Recovery above the barrier resets accrual (confirmations must be sustained).
    function test_BarrierRecoveryResetsAccrual() public {
        uint256 t = T0 + 5 minutes;
        vm.warp(t);
        vm.roll(100);
        oracle.push(BELOW_BARRIER, t);
        _accrue(1);
        (uint8 c1,) = shield.getConfirmation(1);
        assertEq(c1, 1);

        // Price recovers above barrier → accrual resets to 0 (returns "RESET").
        t += 60;
        vm.warp(t);
        vm.roll(101);
        oracle.push(STRIKE, t);
        vm.prank(router);
        (bool triggered,,, bytes32 reason) = shield.verifyAndCalculate(1);
        assertFalse(triggered);
        assertEq(reason, bytes32("RESET"), "recovery returns RESET");
        (uint8 c2,) = shield.getConfirmation(1);
        assertEq(c2, 0, "recovery resets confirmation count");
    }

    /// checkAndSettlePolicy is gated to the wired keeper/relayer only (F-01.3).
    function test_SettleOnlyByKeeperOrRelayer() public {
        // Deploy a fresh shield whose router IS the adapter proxy address.
        FlashShieldAdapter impl = new FlashShieldAdapter();
        // Predict the PROXY address: `bound` is deployed next (current nonce),
        // the proxy follows (nonce + 1).
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        FlashBTCShield1h bound = new FlashBTCShield1h(predicted, address(oracle), address(seq));
        bytes memory initData = abi.encodeCall(FlashShieldAdapter.initialize, (address(bound), bytes32("P")));
        FlashShieldAdapter adapter = FlashShieldAdapter(address(new ERC1967Proxy(address(impl), initData)));
        // `bound` was deployed before the proxy; the proxy address must match.
        require(address(adapter) == predicted, "proxy addr mismatch");

        adapter.setPolicyManager(makeAddr("pm"));
        address keeper = makeAddr("keeper");
        address relayer = makeAddr("relayer");
        adapter.setKeeper(keeper);
        adapter.setRelayer(relayer);

        // Create a policy via the adapter (must be the PM).
        FlashShieldAdapter.LegacyCreatePolicyParams memory p;
        p.buyer = holder;
        p.coverageAmount = COVERAGE;
        p.durationSeconds = WINDOW;
        vm.prank(makeAddr("pm"));
        uint256 pid = adapter.createPolicy(p);

        // Unauthorized caller → ONLY_KEEPER_OR_RELAYER (checked BEFORE anything else).
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("ONLY_KEEPER_OR_RELAYER"));
        adapter.checkAndSettlePolicy(pid);

        // Keeper passes the auth gate; policy accrues one confirmation and the
        // call RETURNS (does not settle, does not revert) — proving the keeper
        // got PAST the auth modifier AND that accrual persists across keeper calls.
        vm.warp(T0 + 5 minutes);
        vm.roll(500);
        oracle.push(BELOW_BARRIER, T0 + 5 minutes);
        vm.prank(keeper);
        adapter.checkAndSettlePolicy(pid); // no revert
        (uint8 cnt,) = bound.getConfirmation(pid);
        assertEq(cnt, 1, "keeper-driven accrual persisted");

        // Relayer is also authorised: a same-block call is rejected by the
        // shield's spacing guard → adapter maps to NOT_SETTLEABLE_YET (proves
        // the relayer passed the auth gate too).
        vm.prank(relayer);
        vm.expectRevert(bytes("NOT_SETTLEABLE_YET"));
        adapter.checkAndSettlePolicy(pid);

        // An unauthorised settler is still rejected at the gate.
        vm.prank(makeAddr("attacker2"));
        vm.expectRevert(bytes("ONLY_KEEPER_OR_RELAYER"));
        adapter.checkAndSettlePolicy(pid);
    }
}
