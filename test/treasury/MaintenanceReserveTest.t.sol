// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Minimal ERC20 mock for USDC in MaintenanceReserve tests.
contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Another minimal ERC20 for recoverToken tests.
contract MockOtherToken {
    string public name = "Other";
    string public symbol = "OTH";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MaintenanceReserveTest is Test {
    using ProxyDeployer for *;

    MaintenanceReserve reserve;
    MockUSDC usdc;
    address admin;
    address recipient;
    address unauthorized;

    function setUp() public {
        vm.chainId(8453);
        admin = makeAddr("admin");
        recipient = makeAddr("recipient");
        unauthorized = makeAddr("unauthorized");

        usdc = new MockUSDC();

        vm.prank(admin);
        reserve = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        // Fund the reserve with USDC
        usdc.mint(address(reserve), 100_000e6);
    }

    // ═══════ CONSTRUCTOR ═══════

    function test_Constructor_SetsUSDC() public view {
        assertEq(address(reserve.usdc()), address(usdc));
    }

    function test_Constructor_GrantsAdminRole() public view {
        assertTrue(reserve.hasRole(reserve.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Constructor_GrantsSpenderRole() public view {
        assertTrue(reserve.hasRole(reserve.SPENDER_ROLE(), admin));
    }

    function test_Constructor_RevertIf_ZeroUSDC() public {
        MaintenanceReserve impl = new MaintenanceReserve();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(MaintenanceReserve.initialize.selector, address(0), admin)
        );
    }

    function test_Constructor_RevertIf_ZeroAdmin() public {
        MaintenanceReserve impl = new MaintenanceReserve();
        vm.expectRevert();
        new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(MaintenanceReserve.initialize.selector, address(usdc), address(0))
        );
    }

    // ═══════ SPEND ═══════

    function test_Spend_TransfersUSDC() public {
        vm.prank(admin);
        reserve.spend(recipient, 1000e6, MaintenanceReserve.SpendCategory.Infrastructure, "Server costs");

        assertEq(usdc.balanceOf(recipient), 1000e6);
        assertEq(usdc.balanceOf(address(reserve)), 99_000e6);
    }

    function test_Spend_UpdatesTotalSpent() public {
        vm.prank(admin);
        reserve.spend(recipient, 500e6, MaintenanceReserve.SpendCategory.Audit, "Audit Q1");

        assertEq(reserve.totalSpent(), 500e6);
    }

    function test_Spend_RecordsHistory() public {
        vm.prank(admin);
        reserve.spend(recipient, 200e6, MaintenanceReserve.SpendCategory.Tooling, "CI/CD pipeline");

        assertEq(reserve.spendCount(), 1);

        (address r, uint256 a, MaintenanceReserve.SpendCategory c, string memory m, uint256 ts) =
            reserve.spendHistory(0);
        assertEq(r, recipient);
        assertEq(a, 200e6);
        assertEq(uint256(c), uint256(MaintenanceReserve.SpendCategory.Tooling));
        assertEq(keccak256(bytes(m)), keccak256("CI/CD pipeline"));
        assertGt(ts, 0);
    }

    // ═══════ UNAUTHORIZED ═══════

    function test_Spend_RevertIf_Unauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        reserve.spend(recipient, 100e6, MaintenanceReserve.SpendCategory.Other, "Unauthorized spend");
    }

    // ═══════ INSUFFICIENT BALANCE ═══════

    function test_Spend_RevertIf_InsufficientBalance() public {
        // Try to spend more than available
        vm.prank(admin);
        vm.expectRevert(); // SafeERC20 will revert on insufficient balance
        reserve.spend(recipient, 200_000e6, MaintenanceReserve.SpendCategory.Infrastructure, "Too much");
    }

    // ═══════ ZERO AMOUNT ═══════

    function test_Spend_RevertIf_ZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert("Amount zero");
        reserve.spend(recipient, 0, MaintenanceReserve.SpendCategory.Other, "Zero spend");
    }

    // ═══════ ZERO RECIPIENT ═══════

    function test_Spend_RevertIf_ZeroRecipient() public {
        vm.prank(admin);
        vm.expectRevert("Recipient zero");
        reserve.spend(address(0), 100e6, MaintenanceReserve.SpendCategory.Other, "No recipient");
    }

    // ═══════ MONTHLY CAP ═══════

    function test_MonthlyCap_EnforcedWhenSet() public {
        vm.startPrank(admin);
        reserve.setMonthlyCap(5000e6); // $5K cap

        // First spend: OK
        reserve.spend(recipient, 4000e6, MaintenanceReserve.SpendCategory.Infrastructure, "First");

        // Second spend: exceeds cap
        vm.expectRevert("Monthly cap exceeded");
        reserve.spend(recipient, 2000e6, MaintenanceReserve.SpendCategory.Infrastructure, "Second");

        vm.stopPrank();
    }

    function test_MonthlyCap_ResetsNextMonth() public {
        vm.startPrank(admin);
        reserve.setMonthlyCap(5000e6);

        reserve.spend(recipient, 5000e6, MaintenanceReserve.SpendCategory.Infrastructure, "Full month");

        // Warp to next month (31 days)
        vm.warp(block.timestamp + 31 days);

        // Should work again
        reserve.spend(recipient, 3000e6, MaintenanceReserve.SpendCategory.Audit, "New month");
        vm.stopPrank();

        assertEq(usdc.balanceOf(recipient), 8000e6);
    }

    function test_MonthlyCap_ZeroDisablesSpending() public {
        // [F-15] cap == 0 now means spending DISABLED (was "unlimited").
        vm.startPrank(admin);
        reserve.setMonthlyCap(0);
        vm.expectRevert(bytes("Spending disabled (cap=0)"));
        reserve.spend(recipient, 1e6, MaintenanceReserve.SpendCategory.Infrastructure, "blocked");
        vm.stopPrank();
    }

    function test_MonthlyCap_DefaultSeededAtInit() public {
        // [F-15] initialize seeds DEFAULT_MONTHLY_CAP; a spend within it succeeds,
        // a spend exceeding it reverts.
        vm.startPrank(admin);
        reserve.spend(recipient, 8_000e6, MaintenanceReserve.SpendCategory.Infrastructure, "within default");
        vm.expectRevert(bytes("Monthly cap exceeded"));
        reserve.spend(recipient, 5_000e6, MaintenanceReserve.SpendCategory.Infrastructure, "over default");
        vm.stopPrank();
        assertEq(reserve.monthlyCap(), reserve.DEFAULT_MONTHLY_CAP());
    }

    // ═══════ CATEGORIES ═══════

    function test_Categories_AllValid() public {
        vm.startPrank(admin);

        reserve.spend(recipient, 10e6, MaintenanceReserve.SpendCategory.Infrastructure, "Infra");
        reserve.spend(recipient, 10e6, MaintenanceReserve.SpendCategory.Audit, "Audit");
        reserve.spend(recipient, 10e6, MaintenanceReserve.SpendCategory.Tooling, "Tools");
        reserve.spend(recipient, 10e6, MaintenanceReserve.SpendCategory.Marketing, "Marketing");
        reserve.spend(recipient, 10e6, MaintenanceReserve.SpendCategory.Legal, "Legal");
        reserve.spend(recipient, 10e6, MaintenanceReserve.SpendCategory.Other, "Other");

        vm.stopPrank();

        assertEq(reserve.spendCount(), 6);
        assertEq(reserve.totalSpent(), 60e6);
    }

    // ═══════ BALANCE VIEW ═══════

    function test_Balance_ReturnsCorrectAmount() public view {
        assertEq(reserve.balance(), 100_000e6);
    }

    // ═══════ MONTHLY REMAINING ═══════

    function test_MonthlyRemaining_DefaultCapAtInit() public view {
        // [F-15] initialize seeds DEFAULT_MONTHLY_CAP, so remaining == default
        // (not type(uint256).max as in the old "0 = unlimited" model).
        assertEq(reserve.monthlyRemaining(), reserve.DEFAULT_MONTHLY_CAP());
    }

    function test_MonthlyRemaining_TracksSpending() public {
        vm.startPrank(admin);
        reserve.setMonthlyCap(10_000e6);
        reserve.spend(recipient, 3000e6, MaintenanceReserve.SpendCategory.Infrastructure, "Partial");
        vm.stopPrank();

        assertEq(reserve.monthlyRemaining(), 7000e6);
    }
}
