// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SecurityControlsTest is Test {
    VolatileShortVault vault;
    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;

    address owner = address(0xA);
    address user1 = address(0xB);
    address user2 = address(0xC);
    address router = address(0xD);
    address policyManager = address(0xE);
    address attacker = address(0x666);

    uint32 constant COOLDOWN = 30 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave Base USDC", "aBasUSDC", 6);
        aavePool = new MockAavePool(address(aToken));

        VolatileShortVault impl = new VolatileShortVault();
        bytes memory initData = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, address(usdc), router, policyManager, address(aavePool), address(aToken))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = VolatileShortVault(address(proxy));
    }

    function _depositAs(address who, uint256 usdcAmount) internal {
        usdc.mint(who, usdcAmount);
        vm.startPrank(who);
        usdc.approve(address(vault), usdcAmount);
        vault.depositAssets(usdcAmount, who);
        vm.stopPrank();
    }

    function _mintAndApprove(address who, uint256 usdcAmount) internal {
        usdc.mint(who, usdcAmount);
        vm.prank(who);
        usdc.approve(address(vault), usdcAmount);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: emergency pause stops deposits
    // ═══════════════════════════════════════════════════════════

    function test_emergencyPauseStopsDeposits() public {
        // Owner pauses the vault (global emergency pause via Pausable)
        vm.prank(owner);
        vault.pause();

        // Deposit should revert
        _mintAndApprove(user1, 1000e6);
        vm.prank(user1);
        vm.expectRevert(); // EnforcedPause
        vault.depositAssets(1000e6, user1);

        // Owner unpauses
        vm.prank(owner);
        vault.unpause();

        // Deposit should work now
        vm.prank(user1);
        vault.depositAssets(1000e6, user1);
        assertGt(vault.balanceOf(user1), 0, "User should have shares after unpaused deposit");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: granular pause — deposits only
    // ═══════════════════════════════════════════════════════════

    function test_granularPauseDepositsOnly() public {
        // First deposit so user has shares for withdrawal test
        _depositAs(user1, 1000e6);

        // Pause only deposits
        vm.prank(owner);
        vault.pauseDeposits();

        // New deposit should revert
        _mintAndApprove(user2, 500e6);
        vm.prank(user2);
        vm.expectRevert("Deposits paused");
        vault.depositAssets(500e6, user2);

        // Withdrawal request should still work
        uint256 shares = vault.balanceOf(user1);
        vm.prank(user1);
        vault.requestWithdrawal(shares); // should NOT revert

        IVault.WithdrawalRequest memory req = vault.getWithdrawalRequest(user1);
        assertGt(req.cooldownEnd, 0, "Withdrawal request should be active");

        // Unpause deposits
        vm.prank(owner);
        vault.unpauseDeposits();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: granular pause — withdrawals only
    // ═══════════════════════════════════════════════════════════

    function test_granularPauseWithdrawalsOnly() public {
        _depositAs(user1, 1000e6);
        uint256 shares = vault.balanceOf(user1);

        // Request withdrawal and warp past cooldown
        vm.prank(user1);
        vault.requestWithdrawal(shares);
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Pause only withdrawals
        vm.prank(owner);
        vault.pauseWithdrawals();

        // Complete withdrawal should revert
        vm.prank(user1);
        vm.expectRevert("Withdrawals paused");
        vault.completeWithdrawal(user1);

        // But new deposit should still work
        _depositAs(user2, 500e6);
        assertGt(vault.balanceOf(user2), 0, "Deposit should work when only withdrawals paused");

        // Unpause
        vm.prank(owner);
        vault.unpauseWithdrawals();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: max total deposit cap
    // ═══════════════════════════════════════════════════════════

    function test_maxTotalDepositCap() public {
        uint256 cap = 5000e6; // $5,000 cap

        vm.prank(owner);
        vault.setMaxTotalDeposit(cap);

        // Deposit up to cap — should work
        _depositAs(user1, 3000e6);
        _depositAs(user2, 2000e6);

        // totalAssets should be at cap
        assertEq(vault.totalAssets(), cap, "Total assets should equal cap");

        // Deposit over cap — should revert
        _mintAndApprove(user1, 500e6);
        vm.prank(user1);
        vm.expectRevert("Vault cap reached");
        vault.depositAssets(500e6, user1);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: max deposit per user cap
    // ═══════════════════════════════════════════════════════════

    function test_maxDepositPerUserCap() public {
        uint256 userCap = 2000e6; // $2,000 per user

        vm.prank(owner);
        vault.setMaxDepositPerUser(userCap);

        // User1 deposits to cap
        _depositAs(user1, 2000e6);

        // User1 tries to deposit more — should revert
        _mintAndApprove(user1, 500e6);
        vm.prank(user1);
        vm.expectRevert("User cap reached");
        vault.depositAssets(500e6, user1);

        // Different user can still deposit
        _depositAs(user2, 2000e6);
        assertGt(vault.balanceOf(user2), 0, "User2 should be able to deposit under their own cap");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: max payout per tx limit
    // ═══════════════════════════════════════════════════════════

    function test_maxPayoutPerTxLimit() public {
        _depositAs(user1, 10_000e6);

        uint256 maxPayout = 1000e6;
        vm.prank(owner);
        vault.setMaxPayoutPerTx(maxPayout);

        bytes32 productId = keccak256("TEST");

        // Small payout should work
        vm.prank(router);
        vault.executePayout(address(0xBEEF), 500e6, productId, 1, address(0xBEEF));
        assertEq(usdc.balanceOf(address(0xBEEF)), 500e6, "Small payout should succeed");

        // Large payout should revert
        vm.prank(router);
        vm.expectRevert("Payout exceeds max");
        vault.executePayout(address(0xBEEF), 2000e6, productId, 2, address(0xBEEF));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: daily withdraw limit
    // ═══════════════════════════════════════════════════════════

    function test_dailyWithdrawLimit() public {
        // Deposit enough for test
        _depositAs(user1, 5000e6);
        _depositAs(user2, 5000e6);

        // Set daily withdraw limit to 20% of TVL (2000 bps)
        vm.prank(owner);
        vault.setDailyWithdrawLimit(2000);

        // TVL = 10000e6, 20% = 2000e6 daily limit

        // Both users request withdrawals now (before any time warp)
        // so they share the same cooldown window.
        uint256 shares1 = vault.convertToShares(1500e6);
        vm.prank(user1);
        vault.requestWithdrawal(shares1);

        uint256 shares2 = vault.convertToShares(1500e6);
        vm.prank(user2);
        vault.requestWithdrawal(shares2);

        // Warp past cooldown (but less than 1 day beyond the reset point)
        vm.warp(block.timestamp + COOLDOWN + 1);

        // First withdrawal (1500e6) within 2000e6 limit — should work
        vm.prank(user1);
        vault.completeWithdrawal(user1);
        assertGt(usdc.balanceOf(user1), 0, "First withdrawal should succeed");

        // Second withdrawal (1500e6) would push total to 3000e6, exceeding 20% of TVL
        // TVL is now ~8500e6 after first withdrawal, 20% = ~1700e6.
        // dailyWithdrawn is already ~1500e6, so 1500e6 more exceeds limit.
        vm.prank(user2);
        vm.expectRevert("Daily limit reached");
        vault.completeWithdrawal(user2);
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: emergency withdraw from Aave
    // ═══════════════════════════════════════════════════════════

    function test_emergencyWithdrawFromAave() public {
        uint256 depositAmount = 5000e6;
        _depositAs(user1, depositAmount);

        // Verify funds are in Aave (aToken balance)
        assertEq(aToken.balanceOf(address(vault)), depositAmount, "Funds should be in Aave");
        assertEq(usdc.balanceOf(address(vault)), 0, "Vault should have no raw USDC");

        // Owner triggers emergency withdraw
        vm.prank(owner);
        vault.emergencyWithdrawFromAave();

        // Now vault should hold raw USDC, not aTokens
        assertEq(aToken.balanceOf(address(vault)), 0, "Vault should have no aTokens after emergency");
        assertEq(usdc.balanceOf(address(vault)), depositAmount, "Vault should hold raw USDC after emergency");

        // totalAssets should be unchanged
        assertEq(vault.totalAssets(), depositAmount, "totalAssets should be unchanged after emergency");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: only owner can pause / emergency
    // ═══════════════════════════════════════════════════════════

    function test_onlyOwnerCanPause() public {
        // Non-owner tries pause — should revert
        vm.prank(attacker);
        vm.expectRevert();
        vault.pause();

        vm.prank(attacker);
        vm.expectRevert();
        vault.pauseDeposits();

        vm.prank(attacker);
        vm.expectRevert();
        vault.pauseWithdrawals();

        vm.prank(attacker);
        vm.expectRevert();
        vault.emergencyWithdrawFromAave();

        vm.prank(attacker);
        vm.expectRevert();
        vault.setMaxTotalDeposit(1000e6);

        vm.prank(attacker);
        vm.expectRevert();
        vault.setMaxDepositPerUser(1000e6);

        vm.prank(attacker);
        vm.expectRevert();
        vault.setMaxPayoutPerTx(1000e6);

        vm.prank(attacker);
        vm.expectRevert();
        vault.setDailyWithdrawLimit(5000);
    }
}
