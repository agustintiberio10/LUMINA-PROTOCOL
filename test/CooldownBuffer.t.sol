// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {VolatileLongVault} from "../src/vaults/VolatileLongVault.sol";
import {StableShortVault} from "../src/vaults/StableShortVault.sol";
import {StableLongVault} from "../src/vaults/StableLongVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

/**
 * @title CooldownBufferTest
 * @notice Verifies all vaults have +7d safety buffer on cooldowns.
 *         Buffer ensures claims resolve before LP withdrawals.
 */
contract CooldownBufferTest is Test {
    VolatileShortVault volatileShort;
    VolatileLongVault volatileLong;
    StableShortVault stableShort;
    StableLongVault stableLong;

    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;

    address owner = address(0xA);
    address router = address(0xD);
    address policyManager = address(0xE);
    address user = address(0xB);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        aToken = new MockERC20("aUSDC", "aUSDC", 6);
        aavePool = new MockAavePool(address(aToken));
        usdc.mint(address(aavePool), 100_000_000e6);

        volatileShort = VolatileShortVault(_deployVault(address(new VolatileShortVault())));
        volatileLong = VolatileLongVault(_deployVault(address(new VolatileLongVault())));
        stableShort = StableShortVault(_deployVault(address(new StableShortVault())));
        stableLong = StableLongVault(_deployVault(address(new StableLongVault())));
    }

    function _deployVault(address impl) internal returns (address) {
        bytes memory data = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, address(usdc), router, policyManager, address(aavePool), address(aToken))
        );
        return address(new ERC1967Proxy(impl, data));
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 1: All cooldowns include +7d buffer
    // ═══════════════════════════════════════════════════════════

    function test_CooldownPeriods() public {
        assertEq(volatileShort.cooldownDuration(), 37 days, "VolatileShort should be 37 days");
        assertEq(volatileLong.cooldownDuration(), 97 days, "VolatileLong should be 97 days");
        assertEq(stableShort.cooldownDuration(), 97 days, "StableShort should be 97 days");
        assertEq(stableLong.cooldownDuration(), 372 days, "StableLong should be 372 days");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST 2: Cannot withdraw at old cooldown (30d), can at new (37d)
    // ═══════════════════════════════════════════════════════════

    function test_CannotWithdrawAtOldCooldown() public {
        _depositAs(user, 1000e6, address(volatileShort));
        uint256 shares = volatileShort.balanceOf(user);

        vm.prank(user);
        volatileShort.requestWithdrawal(shares);

        // Warp 30 days (old cooldown) — should still fail
        vm.warp(block.timestamp + 30 days);
        vm.prank(user);
        vm.expectRevert();
        volatileShort.completeWithdrawal(user);
    }

    function test_CanWithdrawAtNewCooldown() public {
        _depositAs(user, 1000e6, address(volatileShort));
        uint256 shares = volatileShort.balanceOf(user);

        vm.prank(user);
        volatileShort.requestWithdrawal(shares);

        // Warp 37 days (new cooldown) — should succeed
        vm.warp(block.timestamp + 37 days);
        vm.prank(user);
        volatileShort.completeWithdrawal(user);

        assertEq(volatileShort.balanceOf(user), 0, "User should have 0 shares after withdrawal");
    }

    function _depositAs(address who, uint256 amount, address vault) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(vault, amount);
        VolatileShortVault(vault).depositAssets(amount, who);
        vm.stopPrank();
    }
}
