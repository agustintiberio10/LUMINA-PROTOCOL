// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IVault} from "../src/interfaces/IVault.sol";

contract WithdrawalQueueV2Test is Test {
    VolatileShortVault vault;
    MockERC20 usdc;

    address owner = address(0xA);
    address user = address(0xB);
    address router = address(0xC);
    address policyManager = address(0xD);
    address aavePool = address(0xE);
    MockERC20 aToken;

    uint256 constant USDC_DECIMALS = 1e6;
    uint32 constant COOLDOWN = 30 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave Base USDC", "aBasUSDC", 6);

        // Deploy vault via proxy
        VolatileShortVault impl = new VolatileShortVault();
        bytes memory initData = abi.encodeCall(
            VolatileShortVault.initialize, (owner, address(usdc), router, policyManager, aavePool, address(aToken))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = VolatileShortVault(address(proxy));
    }

    function _depositAs(address who, uint256 usdAmount) internal {
        uint256 amount = usdAmount * USDC_DECIMALS;
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.depositAssets(amount, who);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    // TEST 1: Basic requestWithdrawalV2
    // ═══════════════════════════════════════════

    function testRequestWithdrawalV2_basic() public {
        _depositAs(user, 1000);

        uint256 shares = vault.convertToShares(500 * USDC_DECIMALS);

        vm.prank(user);
        vault.requestWithdrawalV2(shares);

        IVault.WithdrawalRequest[] memory queue = vault.getWithdrawalQueue(user);
        assertEq(queue.length, 1);
        assertEq(queue[0].shares, shares);
        assertEq(queue[0].cooldownEnd, block.timestamp + COOLDOWN);
    }

    // ═══════════════════════════════════════════
    // TEST 2: Multiple requests
    // ═══════════════════════════════════════════

    function testRequestWithdrawalV2_multiple() public {
        _depositAs(user, 2000);

        uint256 s500 = vault.convertToShares(500 * USDC_DECIMALS);
        uint256 s300 = vault.convertToShares(300 * USDC_DECIMALS);
        uint256 s200 = vault.convertToShares(200 * USDC_DECIMALS);

        vm.startPrank(user);
        vault.requestWithdrawalV2(s500);
        vault.requestWithdrawalV2(s300);
        vault.requestWithdrawalV2(s200);
        vm.stopPrank();

        IVault.WithdrawalRequest[] memory queue = vault.getWithdrawalQueue(user);
        assertEq(queue.length, 3);
        assertEq(queue[0].shares, s500);
        assertEq(queue[1].shares, s300);
        assertEq(queue[2].shares, s200);
    }

    // ═══════════════════════════════════════════
    // TEST 3: Max 10 requests limit
    // ═══════════════════════════════════════════

    function testRequestWithdrawalV2_maxLimit() public {
        _depositAs(user, 5000);

        uint256 s100 = vault.convertToShares(100 * USDC_DECIMALS);

        vm.startPrank(user);
        for (uint256 i = 0; i < 10; i++) {
            vault.requestWithdrawalV2(s100);
        }

        // 11th should revert
        vm.expectRevert(abi.encodeWithSelector(IVault.TooManyWithdrawalRequests.selector, user));
        vault.requestWithdrawalV2(s100);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    // TEST 4: Insufficient balance
    // ═══════════════════════════════════════════

    function testRequestWithdrawalV2_insufficientBalance() public {
        _depositAs(user, 500);

        uint256 s600 = vault.convertToShares(600 * USDC_DECIMALS);

        vm.prank(user);
        vm.expectRevert(); // InsufficientShares — $600 > $500 balance
        vault.requestWithdrawalV2(s600);
    }

    // ═══════════════════════════════════════════
    // TEST 5: Pending exceeds balance
    // ═══════════════════════════════════════════

    function testRequestWithdrawalV2_pendingExceedsBalance() public {
        _depositAs(user, 1000);

        uint256 s600 = vault.convertToShares(600 * USDC_DECIMALS);
        uint256 s500 = vault.convertToShares(500 * USDC_DECIMALS);

        vm.startPrank(user);
        vault.requestWithdrawalV2(s600);

        // s600 + s500 = $1100 > $1000 balance
        vm.expectRevert(); // InsufficientShares
        vault.requestWithdrawalV2(s500);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════
    // TEST 6: Complete withdrawal after cooldown
    // ═══════════════════════════════════════════

    function testCompleteWithdrawalV2_basic() public {
        _depositAs(user, 1000);

        uint256 s500 = vault.convertToShares(500 * USDC_DECIMALS);

        vm.prank(user);
        vault.requestWithdrawalV2(s500);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        uint256 usdcBefore = usdc.balanceOf(user);

        vm.prank(user);
        uint256 assets = vault.completeWithdrawalV2(user);

        uint256 usdcAfter = usdc.balanceOf(user);
        assertGt(assets, 0);
        assertEq(usdcAfter - usdcBefore, assets);

        // Queue should be empty
        IVault.WithdrawalRequest[] memory queue = vault.getWithdrawalQueue(user);
        assertEq(queue.length, 0);
    }

    // ═══════════════════════════════════════════
    // TEST 7: Complete before cooldown reverts
    // ═══════════════════════════════════════════

    function testCompleteWithdrawalV2_cooldownNotExpired() public {
        _depositAs(user, 1000);

        uint256 s500 = vault.convertToShares(500 * USDC_DECIMALS);

        vm.prank(user);
        vault.requestWithdrawalV2(s500);

        // Try to complete immediately (before cooldown)
        vm.prank(user);
        vm.expectRevert(); // CooldownNotExpired
        vault.completeWithdrawalV2(user);
    }

    // ═══════════════════════════════════════════
    // TEST 8: Cancel withdrawal by index
    // ═══════════════════════════════════════════

    function testCancelWithdrawalV2_basic() public {
        _depositAs(user, 1000);

        uint256 s500 = vault.convertToShares(500 * USDC_DECIMALS);

        vm.prank(user);
        vault.requestWithdrawalV2(s500);

        vm.prank(user);
        vault.cancelWithdrawalV2(0);

        IVault.WithdrawalRequest[] memory queue = vault.getWithdrawalQueue(user);
        assertEq(queue.length, 0);
    }

    // ═══════════════════════════════════════════
    // TEST 9: V1 and V2 coexistence
    // ═══════════════════════════════════════════

    function testV1andV2_coexistence() public {
        _depositAs(user, 1000);

        uint256 s300 = vault.convertToShares(300 * USDC_DECIMALS);
        uint256 s200 = vault.convertToShares(200 * USDC_DECIMALS);
        uint256 balance = vault.balanceOf(user);

        // V1 request for $300
        vm.prank(user);
        vault.requestWithdrawal(s300);

        // V2 request for $200
        vm.prank(user);
        vault.requestWithdrawalV2(s200);

        // Verify V1 request exists
        IVault.WithdrawalRequest memory v1req = vault.getWithdrawalRequest(user);
        assertEq(v1req.shares, s300);

        // Verify V2 queue has 1 entry
        IVault.WithdrawalRequest[] memory queue = vault.getWithdrawalQueue(user);
        assertEq(queue.length, 1);
        assertEq(queue[0].shares, s200);

        // Try to request more than remaining free balance ($1000 - $300 - $200 = $500 free)
        // Requesting $600 should fail
        uint256 s600 = vault.convertToShares(600 * USDC_DECIMALS);
        vm.prank(user);
        vm.expectRevert(); // InsufficientShares — pending V1+V2 ($500) + $600 > $1000
        vault.requestWithdrawalV2(s600);

        // But requesting $400 should work (total pending = $300 + $200 + $400 = $900 < $1000)
        uint256 s400 = vault.convertToShares(400 * USDC_DECIMALS);
        vm.prank(user);
        vault.requestWithdrawalV2(s400);

        queue = vault.getWithdrawalQueue(user);
        assertEq(queue.length, 2);
    }
}
