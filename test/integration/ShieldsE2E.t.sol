// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import {FlashBTCShield1h} from "../../src/products/FlashBTCShield1h.sol";

/// @title ShieldsE2E.t.sol — Sprint T-30a Phase F integration
/// @notice End-to-end coverage of the new flash-shield set wired through a
///         minimal mock router (the production CoverRouterV2/PolicyManagerV2
///         path still uses the legacy IShieldV2 surface and is therefore not
///         exercised here — see TODO below).
/// @dev    via_ir gotcha: all `vm.warp` calls use absolute timestamps.

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

contract ShieldsE2ETest is Test {
    FlashBTCShield1h shield;
    MockChainlinkAggregator oracle;
    MockSequencerFeed sequencer;

    address router = makeAddr("router");
    address holder = makeAddr("holder");

    uint256 constant T0 = 1_800_000_000;
    int256 constant STRIKE = 50_000e8;
    uint256 constant COVERAGE = 10_000e6;
    uint32 constant WINDOW = 3600;

    function setUp() public {
        vm.warp(T0);
        oracle = new MockChainlinkAggregator(STRIKE, T0);
        sequencer = new MockSequencerFeed();
        shield = new FlashBTCShield1h(router, address(oracle), address(sequencer));
    }

    // ── 1. purchase-through-router happy path ─────────────────────────────────
    /// @notice Mock router calls `createPolicy` on the shield; the shield
    ///         persists the policy with strike snapshot.
    function testPurchasePolicy_Through_CoverRouter() public {
        vm.prank(router);
        shield.createPolicy(101, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));

        (address h, uint256 cov, uint256 strike, uint64 start, uint64 end, bool finalized) = shield.getPolicyInfo(101);
        assertEq(h, holder, "holder stored");
        assertEq(cov, COVERAGE, "coverage stored");
        assertEq(strike, uint256(STRIKE), "strike snapshot");
        assertEq(start, uint64(T0), "start ts stored");
        assertEq(end, uint64(T0 + WINDOW), "expiry stored");
        assertFalse(finalized, "policy not yet finalized");
    }

    // ── 2. trigger flow: price drops below threshold, payout calculated ──────
    /// @notice After purchase, price drops below the 2.5% trigger; the shield
    ///         returns (triggered=true, payout=80% coverage). In production a
    ///         BondVault.issueBond() call would follow — that wiring lives in
    ///         PolicyManagerV2 against the LEGACY IShieldV2; the new shield
    ///         surface is not yet routed there. See TODO below.
    function testTrigger_EmitsBond() public {
        // 1) Purchase
        vm.prank(router);
        shield.createPolicy(202, holder, COVERAGE, uint64(T0), uint64(T0 + WINDOW));

        // 2) Move forward 5 min and drop spot by 3% (above the 2.5% trigger).
        vm.warp(T0 + 300);
        int256 dropped = (STRIKE * 9700) / 10_000;
        oracle.setAnswer(dropped, T0 + 300);

        // 3) Verify — should fire
        vm.prank(router);
        (bool triggered, uint256 payout, address h, bytes32 reason) = shield.verifyAndCalculate(202);

        assertTrue(triggered, "must trigger");
        assertEq(payout, (COVERAGE * 8000) / 10_000, "payout = 80%");
        assertEq(h, holder, "holder echoed");
        assertEq(reason, bytes32("TRIGGER_DROP"), "reason TRIGGER_DROP");

        // Policy is finalized
        (,,,,, bool finalized) = shield.getPolicyInfo(202);
        assertTrue(finalized, "finalized after verify");

        // TODO (Phase G or later): wire new shields into PolicyManagerV2 (new
        // IShieldV2 surface differs from the legacy struct-based one) and
        // assert ERC-1155 ClaimBond mint to `holder` via BondVault.issueBond.
    }

    // TODO (Phase G or later): `testNoTrigger_PolicyExpires` — purchase, warp
    // past windowEnd, verify expects revert WINDOW_EXPIRED (already covered by
    // the per-shield unit tests; integration variant is redundant for now).

    // TODO (Phase G or later): `testBondRedemption_RespectsThrottle` — needs
    // the new-shield-to-BondVault wiring to land first; the throttle path
    // itself is already covered end-to-end by BondVault.throttle.t.sol.
}
