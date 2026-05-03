// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {BaseShield} from "../../../../../src/products/BaseShield.sol";
import {FlashBTCShield1h} from "../../../../../src/products/FlashBTCShield1h.sol";
import {FlashBTCShield4h} from "../../../../../src/products/FlashBTCShield4h.sol";
import {FlashBTCShield24h} from "../../../../../src/products/FlashBTCShield24h.sol";
import {FlashBTCShield48h} from "../../../../../src/products/FlashBTCShield48h.sol";
import {FlashETHShield1h} from "../../../../../src/products/FlashETHShield1h.sol";
import {FlashETHShield24h} from "../../../../../src/products/FlashETHShield24h.sol";
import {FlashETHShield48h} from "../../../../../src/products/FlashETHShield48h.sol";
import {MicroDepegShield} from "../../../../../src/products/MicroDepegShield.sol";
import {IShield} from "../../../../../src/interfaces/IShield.sol";
import {IOracle} from "../../../../../src/interfaces/IOracle.sol";

/// @notice Mock IOracle with a configurable `sequencerDowntime`. `getSequencerDowntime`
///         always returns the stored value regardless of `sinceTimestamp` so tests can
///         precisely assert the shield side of the contract.
contract MockSequencerOracle is IOracle {
    mapping(bytes32 => int256) public priceFor;
    uint256 public sequencerDowntime;
    address public authorizedKey;

    constructor() {
        authorizedKey = address(this);
        priceFor["BTC"] = 60_000e8;
        priceFor["ETH"] = 3_000e8;
        priceFor["USDC"] = 1e8;
        priceFor["USDT"] = 1e8;
    }

    function setPrice(bytes32 asset, int256 p) external {
        priceFor[asset] = p;
    }

    function setSequencerDowntime(uint256 d) external {
        sequencerDowntime = d;
    }

    function getLatestPrice(bytes32 asset) external view returns (int256) {
        return priceFor[asset];
    }

    function getSequencerDowntime(uint256) external view returns (uint256) {
        return sequencerDowntime;
    }

    /// @dev [Audit fix H-13] Stub for the new IOracle method.
    ///      Tests that exercise Chainlink-grace logic configure
    ///      this mock via a setter (or override) — the default
    ///      `0` keeps every other test green.
    function getChainlinkDowntime(bytes32, uint256) external view returns (uint256) {
        return 0;
    }


    function verifySignature(bytes32, bytes calldata) external pure returns (address) {
        return address(0);
    }

    function oracleKey() external view returns (address) {
        return authorizedKey;
    }
}

/**
 * @title SequencerDowntime
 * @notice Audits how LUMINA V5.1 handles Base L2 sequencer downtime.
 *
 * Findings (see REPORT.md):
 *   - BaseShield._validateStatusForTrigger() is the ONLY place that integrates
 *     sequencer awareness — it extends the cleanup window by the reported
 *     downtime so users don't lose a valid trigger because a sequencer outage
 *     ate into their cleanup grace period.
 *   - All Flash* and MicroDepeg shields inherit this via BaseShield (no overrides).
 *   - No other contract (CoverRouterV2, PolicyManagerV2, BondVault, TWAPBurner,
 *     Marketplace*) gates on sequencer status. This is by design: if a tx is
 *     mined, the sequencer is up — only time-based state that ticks even when
 *     txs aren't being processed (policy cleanup) needs explicit awareness.
 *
 * Test strategy: the oracle mock returns an arbitrary `sequencerDowntime`,
 * and tests assert that the shield's `verifyAndCalculate` reverts with
 * `InvalidPolicyStatus` only when `block.timestamp >= cleanupAt + downtime`.
 * When `downtime` covers the gap, the status check passes and the revert
 * that follows is an oracle-proof error — a strictly different selector,
 * which is what proves the extension took effect.
 */
contract SequencerDowntime is Test {
    MockSequencerOracle oracle;

    // Fixed anchor so cleanupAt math is predictable.
    uint256 constant ANCHOR_TS = 1_700_000_000;

    function setUp() public {
        oracle = new MockSequencerOracle();
        vm.warp(ANCHOR_TS);
    }

    // ─────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────

    function _btc1h() internal returns (FlashBTCShield1h) {
        return ProxyDeployer.deployFlashBTCShield1h(address(this), address(oracle));
    }

    function _btc4h() internal returns (FlashBTCShield4h) {
        return ProxyDeployer.deployFlashBTCShield4h(address(this), address(oracle));
    }

    function _btc24h() internal returns (FlashBTCShield24h) {
        return ProxyDeployer.deployFlashBTCShield24h(address(this), address(oracle));
    }

    function _btc48h() internal returns (FlashBTCShield48h) {
        return ProxyDeployer.deployFlashBTCShield48h(address(this), address(oracle));
    }

    function _eth1h() internal returns (FlashETHShield1h) {
        return ProxyDeployer.deployFlashETHShield1h(address(this), address(oracle));
    }

    function _eth24h() internal returns (FlashETHShield24h) {
        return ProxyDeployer.deployFlashETHShield24h(address(this), address(oracle));
    }

    function _eth48h() internal returns (FlashETHShield48h) {
        return ProxyDeployer.deployFlashETHShield48h(address(this), address(oracle));
    }

    function _micro() internal returns (MicroDepegShield) {
        return ProxyDeployer.deployMicroDepegShield(address(this), address(oracle));
    }

    function _params(uint32 duration, bytes32 asset) internal returns (IShield.CreatePolicyParams memory p) {
        p.buyer = makeAddr("buyer");
        p.coverageAmount = 1000e6;
        p.premiumAmount = 10e6;
        p.durationSeconds = duration;
        p.asset = asset;
    }

    /// @dev Attempts `verifyAndCalculate`; returns the first 4 bytes (selector) of
    ///      the revert data. If the call doesn't revert, returns bytes4(0) which
    ///      no test expects as a valid selector — callers should always expect a
    ///      revert because our mock signatures never validate.
    function _revertSelector(IShield shield, uint256 policyId) internal returns (bytes4) {
        try shield.verifyAndCalculate(policyId, "") {
            return bytes4(0);
        } catch (bytes memory data) {
            if (data.length < 4) return bytes4(0);
            return bytes4(data);
        }
    }

    // ═══════════════════════════════════════════════════════════
    // A. CLEANUP WINDOW — BASELINE (no downtime)
    // ═══════════════════════════════════════════════════════════

    function test_Sequencer_UUPS_NoDowntime_WithinCleanup_StatusCheckPasses() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        // Expire the policy then warp to 1 sec into the cleanup window.
        vm.warp(ANCHOR_TS + 3600 + 1);
        // Still BEFORE cleanupAt = expiresAt + 24h, status-check must pass.
        // The mock oracle doesn't implement IOracleV2, so the downstream
        // proof-verification call reverts with no data (data.length < 4).
        // What matters here is that the revert selector is NOT
        // InvalidPolicyStatus — i.e. we got past _validateStatusForTrigger.
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertTrue(sel != IShield.InvalidPolicyStatus.selector, "status check should not fire here");
    }

    function test_Sequencer_UUPS_NoDowntime_PastCleanup_RevertsInvalidPolicyStatus() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        // Past cleanupAt = expiresAt + 24h.
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 1);
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertEq(sel, IShield.InvalidPolicyStatus.selector, "status check should fire past cleanup");
    }

    function test_Sequencer_UUPS_NoDowntime_AtExactCleanup_RevertsInvalidPolicyStatus() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        // Exactly at cleanupAt — the check is `block.timestamp >= adjustedCleanupAt`.
        vm.warp(ANCHOR_TS + 3600 + 24 hours);
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertEq(sel, IShield.InvalidPolicyStatus.selector, "status check should fire at exact cleanup");
    }

    // ═══════════════════════════════════════════════════════════
    // B. CLEANUP WINDOW — EXTENSION (downtime > 0)
    // ═══════════════════════════════════════════════════════════

    function test_Sequencer_UUPS_Downtime60s_CoversGap_StatusCheckPasses() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        // 30 sec past cleanupAt — without extension this reverts.
        oracle.setSequencerDowntime(60);
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 30);
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertTrue(sel != IShield.InvalidPolicyStatus.selector, "60s downtime should extend cleanup to cover 30s gap");
    }

    function test_Sequencer_UUPS_Downtime1h_CoversGap_StatusCheckPasses() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 30 minutes);
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertTrue(sel != IShield.InvalidPolicyStatus.selector, "1h downtime should cover 30m past cleanup");
    }

    function test_Sequencer_UUPS_Downtime1h_PastExtendedBy1s_RevertsInvalidPolicyStatus() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        oracle.setSequencerDowntime(1 hours);
        // 1 second past (cleanupAt + 1h).
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 1 hours + 1);
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertEq(sel, IShield.InvalidPolicyStatus.selector, "past extended window must revert");
    }

    function test_Sequencer_UUPS_LargeDowntime24h_ExtendsCorrectly() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        oracle.setSequencerDowntime(24 hours);
        // 12h past cleanupAt — well within extended window.
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 12 hours);
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertTrue(sel != IShield.InvalidPolicyStatus.selector, "24h extension must cover 12h past cleanup");
    }

    function test_Sequencer_UUPS_DowntimeChanged_ReflectsLatestValue() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        // 2h past cleanupAt.
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 2 hours);
        // First: 1h downtime → insufficient.
        oracle.setSequencerDowntime(1 hours);
        assertEq(_revertSelector(IShield(address(s)), pid), IShield.InvalidPolicyStatus.selector);
        // Then: 3h downtime → sufficient (same block, same policy).
        oracle.setSequencerDowntime(3 hours);
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertTrue(sel != IShield.InvalidPolicyStatus.selector, "updated downtime must be re-read on each call");
    }

    // ═══════════════════════════════════════════════════════════
    // C. IOracle INTEGRATION — interface contract
    // ═══════════════════════════════════════════════════════════

    function test_Sequencer_UUPS_Oracle_GetSequencerDowntime_Callable() public {
        oracle.setSequencerDowntime(12_345);
        assertEq(oracle.getSequencerDowntime(0), 12_345);
        assertEq(oracle.getSequencerDowntime(block.timestamp - 100), 12_345);
    }

    function test_Sequencer_UUPS_Oracle_DefaultDowntimeIsZero() public view {
        // A freshly deployed oracle defaults to no reported downtime, matching
        // the archived LuminaOracle's "sequencer was up" case.
        assertEq(oracle.getSequencerDowntime(0), 0);
    }

    function test_Sequencer_UUPS_Oracle_DowntimeZero_NoExtensionApplied() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        oracle.setSequencerDowntime(0);
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 1);
        assertEq(_revertSelector(IShield(address(s)), pid), IShield.InvalidPolicyStatus.selector);
    }

    // ═══════════════════════════════════════════════════════════
    // D. COVERAGE MATRIX — every shield inherits the extension
    //    (no overrides of _validateStatusForTrigger exist)
    // ═══════════════════════════════════════════════════════════

    function test_Sequencer_UUPS_FlashBTC1h_InheritsExtension() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 30 minutes);
        assertTrue(_revertSelector(IShield(address(s)), pid) != IShield.InvalidPolicyStatus.selector);
    }

    function test_Sequencer_UUPS_FlashBTC4h_InheritsExtension() public {
        FlashBTCShield4h s = _btc4h();
        uint256 pid = s.createPolicy(_params(4 hours, "BTC"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 4 hours + 24 hours + 30 minutes);
        assertTrue(_revertSelector(IShield(address(s)), pid) != IShield.InvalidPolicyStatus.selector);
    }

    function test_Sequencer_UUPS_FlashBTC24h_InheritsExtension() public {
        FlashBTCShield24h s = _btc24h();
        uint256 pid = s.createPolicy(_params(24 hours, "BTC"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 24 hours + 24 hours + 30 minutes);
        assertTrue(_revertSelector(IShield(address(s)), pid) != IShield.InvalidPolicyStatus.selector);
    }

    function test_Sequencer_UUPS_FlashBTC48h_InheritsExtension() public {
        FlashBTCShield48h s = _btc48h();
        uint256 pid = s.createPolicy(_params(48 hours, "BTC"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 48 hours + 24 hours + 30 minutes);
        assertTrue(_revertSelector(IShield(address(s)), pid) != IShield.InvalidPolicyStatus.selector);
    }

    function test_Sequencer_UUPS_FlashETH1h_InheritsExtension() public {
        FlashETHShield1h s = _eth1h();
        uint256 pid = s.createPolicy(_params(3600, "ETH"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 30 minutes);
        assertTrue(_revertSelector(IShield(address(s)), pid) != IShield.InvalidPolicyStatus.selector);
    }

    function test_Sequencer_UUPS_FlashETH24h_InheritsExtension() public {
        FlashETHShield24h s = _eth24h();
        uint256 pid = s.createPolicy(_params(24 hours, "ETH"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 24 hours + 24 hours + 30 minutes);
        assertTrue(_revertSelector(IShield(address(s)), pid) != IShield.InvalidPolicyStatus.selector);
    }

    function test_Sequencer_UUPS_FlashETH48h_InheritsExtension() public {
        FlashETHShield48h s = _eth48h();
        uint256 pid = s.createPolicy(_params(48 hours, "ETH"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 48 hours + 24 hours + 30 minutes);
        assertTrue(_revertSelector(IShield(address(s)), pid) != IShield.InvalidPolicyStatus.selector);
    }

    function test_Sequencer_UUPS_MicroDepeg_InheritsExtension() public {
        MicroDepegShield s = _micro();
        // MicroDepegShield has fixed 7-day duration.
        uint256 pid = s.createPolicy(_params(7 days, "USDT"));
        oracle.setSequencerDowntime(1 hours);
        vm.warp(ANCHOR_TS + 7 days + 24 hours + 30 minutes);
        assertTrue(_revertSelector(IShield(address(s)), pid) != IShield.InvalidPolicyStatus.selector);
    }

    // ═══════════════════════════════════════════════════════════
    // E. NON-GATING — createPolicy and policy-state queries are NOT
    //    gated on sequencer status (by design: if tx mined, sequencer up)
    // ═══════════════════════════════════════════════════════════

    function test_Sequencer_UUPS_CreatePolicy_NotGatedOnDowntime() public {
        // Even reporting a huge downtime does not block policy creation —
        // the "the sequencer is up because my tx mined" invariant holds.
        oracle.setSequencerDowntime(48 hours);
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        assertGt(pid, 0);
    }

    function test_Sequencer_UUPS_GetPolicyInfo_NotGatedOnDowntime() public {
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        oracle.setSequencerDowntime(48 hours);
        // View calls that read on-chain state are independent of sequencer status.
        IShield.PolicyInfo memory info = s.getPolicyInfo(pid);
        assertEq(info.insuredAgent, makeAddr("buyer"));
    }

    // ═══════════════════════════════════════════════════════════
    // F. EDGE CASES
    // ═══════════════════════════════════════════════════════════

    function test_Sequencer_UUPS_Downtime_SumOverflow_Reverts() public {
        // `adjustedCleanupAt = cleanupAt + downtime` — with downtime == type(uint256).max
        // the addition overflows under Solidity 0.8 checked math and reverts. This
        // documents the bound: any downtime that would make the cleanupAt
        // non-representable aborts the call rather than silently wrapping.
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        oracle.setSequencerDowntime(type(uint256).max);
        vm.warp(ANCHOR_TS + 3600 + 24 hours + 1);
        vm.expectRevert();
        s.verifyAndCalculate(pid, "");
    }

    function test_Sequencer_UUPS_FinalizedPolicy_NotExtendedByDowntime() public {
        // The sequencer-downtime extension is inside _validateStatusForTrigger,
        // which is only reached after `cp.finalized` is checked. A paid-out
        // policy cannot be re-triggered regardless of reported downtime.
        FlashBTCShield1h s = _btc1h();
        uint256 pid = s.createPolicy(_params(3600, "BTC"));
        s.markPaidOut(pid);
        oracle.setSequencerDowntime(24 hours);
        bytes4 sel = _revertSelector(IShield(address(s)), pid);
        assertEq(sel, IShield.InvalidPolicyStatus.selector, "finalized must revert before sequencer check");
    }
}
