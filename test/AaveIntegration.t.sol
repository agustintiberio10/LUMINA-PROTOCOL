// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {VolatileShortVault} from "../src/vaults/VolatileShortVault.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAavePool} from "../src/mocks/MockAavePool.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AaveIntegrationTest is Test {
    VolatileShortVault vault;
    MockERC20 usdc;
    MockERC20 aToken;
    MockAavePool aavePool;

    address owner = address(0xA);
    address user1 = address(0xB);
    address user2 = address(0xC);
    address router = address(0xD);
    address policyManager = address(0xE);
    address beneficiary = address(0xF);

    uint32 constant COOLDOWN = 30 days;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        aToken = new MockERC20("Aave Base USDC", "aBasUSDC", 6);
        aavePool = new MockAavePool(address(aToken));

        // Fund the MockAavePool with USDC so it can pay out withdrawals
        // (when aavePool.withdraw is called, it transfers USDC to the recipient)

        // Deploy vault via UUPS proxy
        VolatileShortVault impl = new VolatileShortVault();
        bytes memory initData = abi.encodeCall(
            VolatileShortVault.initialize,
            (owner, address(usdc), router, policyManager, address(aavePool), address(aToken))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = VolatileShortVault(address(proxy));
    }

    // ── Helpers ──

    function _depositAs(address who, uint256 usdcAmount) internal {
        usdc.mint(who, usdcAmount);
        vm.startPrank(who);
        usdc.approve(address(vault), usdcAmount);
        vault.depositAssets(usdcAmount, who);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: deposit supplies to Aave
    // ═══════════════════════════════════════════════════════════

    function test_depositSuppliesToAave() public {
        uint256 amount = 1000e6;
        _depositAs(user1, amount);

        // After deposit, vault should hold aTokens (not raw USDC)
        uint256 vaultATokenBal = aToken.balanceOf(address(vault));
        assertEq(vaultATokenBal, amount, "Vault should hold aTokens equal to deposit");

        // Vault should have 0 raw USDC (all supplied to Aave)
        uint256 vaultUsdcBal = usdc.balanceOf(address(vault));
        assertEq(vaultUsdcBal, 0, "Vault should have no raw USDC after Aave supply");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: totalAssets reflects aToken balance
    // ═══════════════════════════════════════════════════════════

    function test_totalAssetsReflectsAToken() public {
        uint256 depositAmount = 1000e6;
        _depositAs(user1, depositAmount);

        uint256 totalBefore = vault.totalAssets();
        assertEq(totalBefore, depositAmount, "totalAssets should equal deposit");

        // Simulate Aave yield by minting extra aTokens directly to vault
        uint256 yieldAmount = 50e6; // $50 yield
        aToken.mint(address(vault), yieldAmount);

        uint256 totalAfter = vault.totalAssets();
        assertEq(totalAfter, depositAmount + yieldAmount, "totalAssets should reflect yield from aToken");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: withdraw from Aave only after cooldown
    // ═══════════════════════════════════════════════════════════

    function test_withdrawFromAaveOnlyAfterCooldown() public {
        uint256 depositAmount = 1000e6;
        _depositAs(user1, depositAmount);

        uint256 shares = vault.balanceOf(user1);

        // Request withdrawal
        vm.prank(user1);
        vault.requestWithdrawal(shares);

        // Try completing before cooldown — should revert
        vm.prank(user1);
        vm.expectRevert();
        vault.completeWithdrawal(user1);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN + 1);

        // Complete withdrawal — should succeed
        vm.prank(user1);
        uint256 assets = vault.completeWithdrawal(user1);

        assertEq(assets, depositAmount, "Should withdraw full deposit amount");
        assertEq(usdc.balanceOf(user1), depositAmount, "User should receive USDC");
        assertEq(vault.balanceOf(user1), 0, "User should have no shares left");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: withdrawal during cooldown still earns yield
    // ═══════════════════════════════════════════════════════════

    function test_withdrawDuringCooldownStillEarnsYield() public {
        uint256 depositAmount = 1000e6;
        _depositAs(user1, depositAmount);

        uint256 shares = vault.balanceOf(user1);

        // Request withdrawal
        vm.prank(user1);
        vault.requestWithdrawal(shares);

        // Warp halfway through cooldown
        vm.warp(block.timestamp + COOLDOWN / 2);

        // Simulate Aave yield (aToken rebase) — mint extra aTokens to vault
        uint256 yieldAmount = 100e6; // $100 yield
        aToken.mint(address(vault), yieldAmount);

        // Fund the MockAavePool with extra USDC so it can pay out the yield
        // (the pool only holds the original deposit amount in USDC)
        usdc.mint(address(aavePool), yieldAmount);

        // Warp past cooldown
        vm.warp(block.timestamp + COOLDOWN / 2 + 1);

        // Complete withdrawal
        vm.prank(user1);
        uint256 assets = vault.completeWithdrawal(user1);

        // User should receive more than originally deposited (principal + yield)
        assertGt(assets, depositAmount, "User should receive more than deposited due to yield");
        assertEq(usdc.balanceOf(user1), assets, "User USDC balance should match withdrawn assets");
    }

    // ═══════════════════════════════════════════════════════════
    //  TEST: payout withdraws from Aave instantly
    // ═══════════════════════════════════════════════════════════

    function test_payoutWithdrawsFromAaveInstantly() public {
        uint256 depositAmount = 5000e6;
        _depositAs(user1, depositAmount);

        uint256 payoutAmount = 1000e6;
        bytes32 productId = keccak256("TEST-PRODUCT");
        uint256 policyId = 1;

        // Execute payout as router
        vm.prank(router);
        vault.executePayout(beneficiary, payoutAmount, productId, policyId, beneficiary);

        // Beneficiary should have received USDC
        assertEq(usdc.balanceOf(beneficiary), payoutAmount, "Beneficiary should receive payout in USDC");

        // Vault aToken balance should have decreased
        assertEq(
            aToken.balanceOf(address(vault)),
            depositAmount - payoutAmount,
            "Vault aToken balance should decrease by payout amount"
        );
    }
}
