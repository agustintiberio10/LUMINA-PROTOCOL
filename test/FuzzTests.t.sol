// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";

contract FuzzTests is Test {
    VolatileShortVault vault;
    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;
    address owner = address(0xA);
    address router = address(0xD);
    address policyManager = address(0xE);

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        aToken = new MockERC20("aUSDC", "aUSDC", 6);
        aavePool = new MockAavePool(address(aToken));
        usdc.mint(address(aavePool), 1_000_000_000e6);

        VolatileShortVault impl = new VolatileShortVault();
        bytes memory data = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, address(usdc), router, policyManager, address(aavePool), address(aToken))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), data);
        vault = VolatileShortVault(address(proxy));
    }

    // Fuzz: any deposit amount >= MIN_DEPOSIT produces shares > 0
    function testFuzz_DepositAlwaysMintsShares(uint256 amount) public {
        amount = bound(amount, 100e6, 10_000_000e6); // $100 to $10M
        address depositor = address(0xBEEF);
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        vault.depositAssets(amount, depositor);
        vm.stopPrank();
        assertGt(vault.balanceOf(depositor), 0, "Shares must be > 0");
    }

    // Fuzz: deposit then withdraw returns <= original (no free money)
    function testFuzz_NoFreeMoneyOnDepositWithdraw(uint256 amount) public {
        amount = bound(amount, 100e6, 1_000_000e6);
        address depositor = address(0xBEEF);
        usdc.mint(depositor, amount);
        vm.startPrank(depositor);
        usdc.approve(address(vault), amount);
        vault.depositAssets(amount, depositor);
        uint256 shares = vault.balanceOf(depositor);
        vault.requestWithdrawal(shares);
        vm.stopPrank();

        vm.warp(block.timestamp + 37 days);
        vm.prank(depositor);
        uint256 received = vault.completeWithdrawal(depositor);
        // Without yield, received should be <= deposited (rounding favors vault)
        // Performance fee only applies on positive yield so net effect is neutral here
        assertLe(received, amount + 1, "Cannot withdraw more than deposited without yield");
    }

    // Fuzz: lockCollateral never exceeds totalAssets
    function testFuzz_LockNeverExceedsTotalAssets(uint256 depositAmt, uint256 lockAmt) public {
        depositAmt = bound(depositAmt, 100e6, 10_000_000e6);
        address depositor = address(0xBEEF);
        usdc.mint(depositor, depositAmt);
        vm.startPrank(depositor);
        usdc.approve(address(vault), depositAmt);
        vault.depositAssets(depositAmt, depositor);
        vm.stopPrank();

        uint256 total = vault.totalAssets();
        uint256 maxLock = (total * 9500) / 10000; // 95% max utilization
        lockAmt = bound(lockAmt, 1, maxLock);

        vm.prank(policyManager);
        vault.lockCollateral(lockAmt, keccak256("TEST"), 1);
        assertLe(vault.allocatedAssets(), vault.totalAssets(), "Allocated must never exceed total");
    }

    // Fuzz: convertToAssets(convertToShares(x)) <= x (rounding favors vault)
    function testFuzz_RoundingFavorsVault(uint256 assets) public {
        assets = bound(assets, 1, 1_000_000_000e6);
        // Need some deposits first for non-zero supply
        address depositor = address(0xBEEF);
        usdc.mint(depositor, 1_000_000e6);
        vm.startPrank(depositor);
        usdc.approve(address(vault), 1_000_000e6);
        vault.depositAssets(1_000_000e6, depositor);
        vm.stopPrank();

        uint256 shares = vault.convertToShares(assets);
        uint256 backToAssets = vault.convertToAssets(shares);
        assertLe(backToAssets, assets, "Round-trip must not create value");
    }
}
