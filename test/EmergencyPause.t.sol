// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {EmergencyPause} from "../src/core/EmergencyPause.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

contract EmergencyPauseTest is Test {
    EmergencyPause ep;
    VolatileShortVault vault;
    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;

    address owner = address(0xA);
    address pauser = address(0xBB);
    address router = address(0xD);
    address policyManager = address(0xE);
    address user = address(0xB);

    function setUp() public {
        // Deploy EmergencyPause
        ep = new EmergencyPause(owner, 1 hours);

        // Grant emergency role to pauser
        vm.prank(owner);
        ep.grantEmergencyRole(pauser);

        // Deploy vault
        usdc = new MockERC20("USDC", "USDC", 6);
        aToken = new MockERC20("aUSDC", "aUSDC", 6);
        aavePool = new MockAavePool(address(aToken));
        usdc.mint(address(aavePool), 100_000_000e6);

        VolatileShortVault impl = new VolatileShortVault();
        bytes memory data = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, address(usdc), router, policyManager, address(aavePool), address(aToken))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        vault = VolatileShortVault(address(proxy));

        // Set emergency pause on vault
        vm.prank(owner);
        vault.setEmergencyPause(address(ep));
    }

    function _mintAndApprove(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(vault), amount);
    }

    // ═══════════════════════════════════════════════════════════
    //  PAUSE BLOCKS DEPOSITS
    // ═══════════════════════════════════════════════════════════

    function test_PauseBlocksDeposits() public {
        _mintAndApprove(user, 1000e6);

        vm.prank(pauser);
        ep.emergencyPauseAll();

        vm.prank(user);
        vm.expectRevert("Protocol emergency paused");
        vault.depositAssets(1000e6, user);
    }

    // ═══════════════════════════════════════════════════════════
    //  PAUSE BLOCKS WITHDRAWALS
    // ═══════════════════════════════════════════════════════════

    function test_PauseBlocksWithdrawals() public {
        // Deposit first
        _mintAndApprove(user, 1000e6);
        vm.prank(user);
        vault.depositAssets(1000e6, user);

        // Request withdrawal
        uint256 shares = vault.balanceOf(user);
        vm.prank(user);
        vault.requestWithdrawal(shares);

        // Warp past cooldown
        vm.warp(block.timestamp + 37 days);

        // Pause
        vm.prank(pauser);
        ep.emergencyPauseAll();

        // Complete withdrawal should fail
        vm.prank(user);
        vm.expectRevert("Protocol emergency paused");
        vault.completeWithdrawal(user);
    }

    // ═══════════════════════════════════════════════════════════
    //  ONLY EMERGENCY ROLE CAN PAUSE
    // ═══════════════════════════════════════════════════════════

    function test_OnlyEmergencyRoleCanPause() public {
        vm.prank(address(0x999));
        vm.expectRevert(EmergencyPause.NotEmergencyRole.selector);
        ep.emergencyPauseAll();
    }

    // ═══════════════════════════════════════════════════════════
    //  UNPAUSE REACTIVATES EVERYTHING
    // ═══════════════════════════════════════════════════════════

    function test_UnpauseReactivates() public {
        _mintAndApprove(user, 1000e6);

        // Pause
        vm.prank(pauser);
        ep.emergencyPauseAll();

        // Unpause
        vm.prank(pauser);
        ep.emergencyUnpauseAll();

        // Deposit should work
        vm.prank(user);
        vault.depositAssets(1000e6, user);
        assertGt(vault.balanceOf(user), 0);
    }

    // ═══════════════════════════════════════════════════════════
    //  COOLDOWN BETWEEN PAUSE CYCLES
    // ═══════════════════════════════════════════════════════════

    function test_CooldownPreventsRePause() public {
        // Pause → unpause
        vm.startPrank(pauser);
        ep.emergencyPauseAll();
        ep.emergencyUnpauseAll();

        // Try to pause again immediately → should fail (cooldown)
        vm.expectRevert();
        ep.emergencyPauseAll();
        vm.stopPrank();

        // Warp past cooldown (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        // Now pause should work
        vm.prank(pauser);
        ep.emergencyPauseAll();
        assertTrue(ep.protocolPaused());
    }

    // ═══════════════════════════════════════════════════════════
    //  EVENTS
    // ═══════════════════════════════════════════════════════════

    event ProtocolPaused(address indexed by);
    event ProtocolUnpaused(address indexed by);

    function test_EmitsEvents() public {
        vm.prank(pauser);
        vm.expectEmit(true, false, false, false);
        emit ProtocolPaused(pauser);
        ep.emergencyPauseAll();

        vm.prank(pauser);
        vm.expectEmit(true, false, false, false);
        emit ProtocolUnpaused(pauser);
        ep.emergencyUnpauseAll();
    }

    // ═══════════════════════════════════════════════════════════
    //  VAULT WORKS NORMALLY WITHOUT EMERGENCY PAUSE SET
    // ═══════════════════════════════════════════════════════════

    function test_VaultWorksWithoutEmergencyPause() public {
        // Remove emergency pause reference
        vm.prank(owner);
        vault.setEmergencyPause(address(0));

        // Deposit should still work
        _mintAndApprove(user, 1000e6);
        vm.prank(user);
        vault.depositAssets(1000e6, user);
        assertGt(vault.balanceOf(user), 0);
    }
}
