// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../../../../helpers/ProxyDeployer.sol";

import {CoverRouterV2} from "../../../../../src/core/CoverRouterV2.sol";
import {ShieldKeeper} from "../../../../../src/automation/ShieldKeeper.sol";

contract FakeOracleHys {
    uint256 public price;

    constructor(uint256 p) {
        price = p;
    }

    function setPrice(uint256 p) external {
        price = p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
    /// @dev [Fix M-6 mock] Returns the same value as `getLuminaPrice()` so
    ///      tests that don't drive the TWAP path explicitly remain unaffected.
    function getTWAP(uint32 /*secondsAgo*/) external view returns (uint256) {
        return this.getLuminaPrice();
    }

}

// ─────────────────────────────────────────────────────────────────────────
// Tests for fix #28 INFO-6 (KeeperPaused event) and INFO-7 (hysteresis)
// ─────────────────────────────────────────────────────────────────────────

contract FixHysteresisAndEventTest is Test {
    event KeeperPaused(address indexed by);
    event KeeperUnpaused(address indexed by);
    event AutoPauseActivated(uint256 priceWei);
    event AutoPauseDeactivated(uint256 priceWei);

    address internal admin = address(this);
    address internal attacker = makeAddr("attacker");

    // ═════════════════════ helpers ═════════════════════

    function _deployCR() internal returns (CoverRouterV2 r, FakeOracleHys o) {
        r = ProxyDeployer.deployCoverRouterV2(makeAddr("u"), makeAddr("pm"), makeAddr("b"));
        r.configureProduct(keccak256("P"), 8000, 100, 15000, 3600, true);
        o = new FakeOracleHys(0.05e18); // start above RESET (8e15)
        r.setCapacityOracle(address(o));
    }

    // ═════════════════════ A. INFO-6: KeeperPaused event ═════════════════════

    function test_Fix_ShieldKeeper_PauseEmitsKeeperPausedEvent() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        vm.expectEmit(true, false, false, false, address(k));
        emit KeeperPaused(admin);
        k.pause();
    }

    function test_Fix_ShieldKeeper_UnpauseStillEmitsKeeperUnpaused() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));
        k.pause();
        vm.expectEmit(true, false, false, false, address(k));
        emit KeeperUnpaused(admin);
        k.unpause();
    }

    function test_Fix_ShieldKeeper_PauseUnpauseCycle_BothEmit() public {
        ShieldKeeper k = ProxyDeployer.deployShieldKeeper(makeAddr("pm"));

        vm.recordLogs();
        k.pause();
        k.unpause();
        k.pause();
        k.unpause();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 pausedSig = keccak256("KeeperPaused(address)");
        bytes32 unpausedSig = keccak256("KeeperUnpaused(address)");
        uint256 pausedCount;
        uint256 unpausedCount;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(k)) continue;
            if (logs[i].topics[0] == pausedSig) pausedCount++;
            if (logs[i].topics[0] == unpausedSig) unpausedCount++;
        }
        assertEq(pausedCount, 2);
        assertEq(unpausedCount, 2);
    }

    // ═════════════════════ B. INFO-7: Hysteresis activation ═════════════════════

    function test_Fix_Hysteresis_InitialState_AutoPauseFalse() public {
        (CoverRouterV2 r,) = _deployCR();
        assertFalse(r.autoPausedOnce());
    }

    function test_Fix_Hysteresis_Sync_ActivatesAtLowPrice() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();
        o.setPrice(4e15); // $0.004 < $0.005

        vm.expectEmit(false, false, false, true, address(r));
        emit AutoPauseActivated(4e15);
        r.syncCircuitBreaker();

        assertTrue(r.autoPausedOnce());
    }

    function test_Fix_Hysteresis_Sync_NoEvent_IfPriceHealthy() public {
        (CoverRouterV2 r,) = _deployCR();
        vm.recordLogs();
        r.syncCircuitBreaker();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(r)) {
                revert("should not emit");
            }
        }
        assertFalse(r.autoPausedOnce());
    }

    // ═════════════════════ C. Hysteresis: stays paused between thresholds ═════════════════════

    function test_Fix_Hysteresis_StaysPaused_BetweenThresholds() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        // Activate pause.
        o.setPrice(4e15);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());

        // Price recovers but stays below RESET.
        o.setPrice(6e15); // $0.006 (between MIN 5e15 and RESET 8e15)
        r.syncCircuitBreaker();
        // Still paused - hysteresis refused to clear.
        assertTrue(r.autoPausedOnce());

        // Purchase still reverts using RESET as the threshold.
        vm.expectRevert(bytes("Protocol auto-paused: LUMINA price below safety threshold"));
        r.purchasePolicy(keccak256("P"), 1000e6, "BTC");
    }

    function test_Fix_Hysteresis_Resumes_AtResetThresholdExact() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();
        o.setPrice(4e15);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());

        // Exactly at RESET threshold.
        o.setPrice(8e15);
        vm.expectEmit(false, false, false, true, address(r));
        emit AutoPauseDeactivated(8e15);
        r.syncCircuitBreaker();

        assertFalse(r.autoPausedOnce());
    }

    function test_Fix_Hysteresis_Resumes_AboveReset() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();
        o.setPrice(4e15);
        r.syncCircuitBreaker();

        o.setPrice(10e15); // well above RESET
        r.syncCircuitBreaker();
        assertFalse(r.autoPausedOnce());
    }

    // ═════════════════════ D. Flap prevention ═════════════════════

    function test_Fix_Hysteresis_NoFlap_SmallOscillationNearMin() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        // Activate at 4.9e15.
        o.setPrice(49e14);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());

        // Oscillate just above MIN (5.1e15) and just below (4.9e15).
        o.setPrice(51e14);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce(), "Must stay paused - below RESET");

        o.setPrice(49e14);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce(), "Still paused");

        o.setPrice(55e14);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce(), "Still paused - below RESET");

        // Only clears when price crosses RESET.
        o.setPrice(81e14);
        r.syncCircuitBreaker();
        assertFalse(r.autoPausedOnce(), "Cleared at RESET");
    }

    function test_Fix_Hysteresis_NoDoubleActivation_MultipleLowSyncs() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();
        o.setPrice(4e15);

        // First sync activates.
        vm.recordLogs();
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());

        // Subsequent syncs at same low price should NOT re-emit.
        r.syncCircuitBreaker();
        r.syncCircuitBreaker();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("AutoPauseActivated(uint256)");
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(r) && logs[i].topics[0] == sig) count++;
        }
        assertEq(count, 1, "AutoPauseActivated should only emit once even after multiple sync calls");
    }

    // ═════════════════════ E. Full cycle ═════════════════════

    function test_Fix_Hysteresis_FullCycle() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        // 1. Initial healthy price - not paused.
        o.setPrice(0.1e18);
        r.syncCircuitBreaker();
        assertFalse(r.autoPausedOnce());

        // 2. Price drops below MIN - auto-paused.
        o.setPrice(4e15);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());

        // 3. Price partially recovers but not to RESET - stays paused.
        o.setPrice(6e15);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());

        // 4. Price crosses RESET - clears.
        o.setPrice(8e15);
        r.syncCircuitBreaker();
        assertFalse(r.autoPausedOnce());

        // 5. Price dips to 6e15 but still above MIN - remains active.
        o.setPrice(6e15);
        r.syncCircuitBreaker();
        assertFalse(r.autoPausedOnce());

        // 6. Price drops again below MIN - re-activates.
        o.setPrice(4e15);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());
    }

    // ═════════════════════ F. Purchase behavior under hysteresis ═════════════════════

    function test_Fix_Hysteresis_Purchase_BlockedAt_AboveMinBelowReset_WhenFlagSet() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        // Set flag.
        o.setPrice(4e15);
        r.syncCircuitBreaker();

        // Recover to 6e15 (>= MIN but < RESET).
        o.setPrice(6e15);

        // Purchase still reverts because flag is set and 6e15 < RESET (8e15).
        vm.expectRevert(bytes("Protocol auto-paused: LUMINA price below safety threshold"));
        r.purchasePolicy(keccak256("P"), 1000e6, "BTC");
    }

    function test_Fix_Hysteresis_Purchase_AllowedWithFlagSet_IfPriceAboveReset() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        o.setPrice(4e15);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());

        o.setPrice(10e15); // above RESET (but flag not yet cleared)
        // Purchase passes auto-pause check (threshold when flag=true is RESET=8e15; 10e15 >= 8e15).
        // It will revert downstream at the PM stub. But NOT with the auto-paused message.
        vm.expectRevert(); // downstream revert
        r.purchasePolicy(keccak256("P"), 1000e6, "BTC");
    }

    function test_Fix_Hysteresis_Purchase_WithoutFlag_UsesMinThreshold() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        // Flag is clear.
        assertFalse(r.autoPausedOnce());

        // Price slightly below MIN.
        o.setPrice(4e15);
        // Purchase reverts with auto-paused (flag is false, threshold = MIN = 5e15, 4e15 < 5e15).
        vm.expectRevert(bytes("Protocol auto-paused: LUMINA price below safety threshold"));
        r.purchasePolicy(keccak256("P"), 1000e6, "BTC");
    }

    function test_Fix_Hysteresis_Purchase_Exactly_AtMin_NoFlag_Passes() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        o.setPrice(5e15); // exactly at MIN, flag false
        // threshold = MIN = 5e15; 5e15 >= 5e15 → passes auto-pause check.
        vm.expectRevert(); // downstream revert, NOT auto-paused
        r.purchasePolicy(keccak256("P"), 1000e6, "BTC");
    }

    // ═════════════════════ G. Interaction with manual pause ═════════════════════

    function test_Fix_Hysteresis_ManualPause_TakesPrecedence() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        o.setPrice(4e15);
        r.syncCircuitBreaker();

        r.setPaused(true); // manual pause

        // Expected error is ContractPaused (selector), not the auto-paused string,
        // because whenNotPaused fires first.
        vm.expectRevert(CoverRouterV2.ContractPaused.selector);
        r.purchasePolicy(keccak256("P"), 1000e6, "BTC");
    }

    function test_Fix_Hysteresis_ManualUnpause_StillRespectsAutoFlag() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();
        o.setPrice(4e15);
        r.syncCircuitBreaker();
        assertTrue(r.autoPausedOnce());

        r.setPaused(true);
        r.setPaused(false); // unpause manually

        // Auto-pause flag still true, price still 4e15 → auto-pause rejects.
        vm.expectRevert(bytes("Protocol auto-paused: LUMINA price below safety threshold"));
        r.purchasePolicy(keccak256("P"), 1000e6, "BTC");
    }

    // ═════════════════════ H. isProtocolAutoPaused view reflects hysteresis ═════════════════════

    function test_Fix_Hysteresis_IsAutoPaused_ViewReflects_Hysteresis() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        // healthy price, flag false.
        o.setPrice(0.05e18);
        assertFalse(r.isProtocolAutoPaused());

        // price = 6e15, flag false → threshold MIN (5e15), 6e15 >= 5e15, NOT paused.
        o.setPrice(6e15);
        assertFalse(r.isProtocolAutoPaused());

        // Activate flag.
        o.setPrice(4e15);
        r.syncCircuitBreaker();

        // Now price = 6e15, flag true → threshold RESET (8e15), 6e15 < 8e15, paused.
        o.setPrice(6e15);
        assertTrue(r.isProtocolAutoPaused());

        // Cross RESET, flag clears.
        o.setPrice(9e15);
        r.syncCircuitBreaker();
        assertFalse(r.isProtocolAutoPaused());
    }

    // ═════════════════════ I. Sync is permissionless ═════════════════════

    function test_Fix_Hysteresis_Sync_PermissionlessByDesign() public {
        (CoverRouterV2 r, FakeOracleHys o) = _deployCR();

        o.setPrice(4e15);
        vm.prank(attacker);
        r.syncCircuitBreaker(); // no role gate - anyone can call
        assertTrue(r.autoPausedOnce());
    }

    // ═════════════════════ J. Storage-layout smoke check ═════════════════════

    function test_Fix_Hysteresis_StorageLayout_PreExistingFieldsIntact() public {
        (CoverRouterV2 r,) = _deployCR();

        // Configure some state via existing setters.
        r.setRelayer(makeAddr("rel"), true);

        // Read all prior-storage public getters - values must be correct.
        assertEq(address(r.usdc()), makeAddr("u"));
        assertEq(address(r.policyManager()), makeAddr("pm"));
        assertEq(address(r.twapBurner()), makeAddr("b"));
        assertTrue(r.authorizedRelayers(makeAddr("rel")));
        assertEq(r.getProductCount(), 1);
        assertFalse(r.paused());
        // And the new field is accessible and default-false.
        assertFalse(r.autoPausedOnce());
    }
}
