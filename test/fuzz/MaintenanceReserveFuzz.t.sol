// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract MockUSDCForMaint {
    string public name = "MockUSDC";
    string public symbol = "MUSDC";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
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

/// @title MaintenanceReserveFuzz
/// @notice Fuzz tests for MaintenanceReserve spend tracking.
contract MaintenanceReserveFuzz is Test {
    using ProxyDeployer for *;

    MaintenanceReserve reserve;
    MockUSDCForMaint usdc;

    address admin = makeAddr("admin");
    address recipient = makeAddr("recipient");
    uint256 constant FUND_AMOUNT = 10_000_000e6; // $10M USDC

    function setUp() public {
        vm.chainId(8453);
        usdc = new MockUSDCForMaint();
        vm.prank(admin);
        reserve = ProxyDeployer.deployMaintenanceReserve(address(usdc), admin);

        // Fund the reserve
        usdc.mint(address(reserve), FUND_AMOUNT);
    }

    /// @notice Fuzz: spend never succeeds for amounts exceeding the reserve balance.
    function testFuzz_Spend_NeverExceedsBalance(uint256 amount) public {
        uint256 balance = usdc.balanceOf(address(reserve));
        amount = bound(amount, balance + 1, type(uint256).max);

        vm.prank(admin);
        vm.expectRevert(); // SafeERC20 or transfer failure
        reserve.spend(recipient, amount, MaintenanceReserve.SpendCategory.Infrastructure, "Fuzz test");
    }

    /// @notice Fuzz: totalSpent tracking is correct after successful spends.
    function testFuzz_Spend_TrackingCorrect(uint256 amount, uint8 categoryRaw) public {
        // [legacy-migration] F-15 seeded a DEFAULT_MONTHLY_CAP on the reserve;
        // spend() reverts ("Monthly cap exceeded") above it. Bound the fuzzed
        // amount to the per-month cap (<= balance here) so inputs stay valid.
        uint256 cap = reserve.monthlyCap();
        uint256 balance = usdc.balanceOf(address(reserve));
        uint256 upper = cap < balance ? cap : balance;
        amount = bound(amount, 1, upper);
        uint256 catIdx = bound(categoryRaw, 0, 5);
        MaintenanceReserve.SpendCategory category = MaintenanceReserve.SpendCategory(catIdx);

        uint256 totalBefore = reserve.totalSpent();

        vm.prank(admin);
        reserve.spend(recipient, amount, category, "Fuzz tracking test");

        uint256 totalAfter = reserve.totalSpent();
        assertEq(totalAfter, totalBefore + amount, "totalSpent should increase by spend amount");
    }
}
