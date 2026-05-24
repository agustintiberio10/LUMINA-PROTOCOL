// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MaintenanceReserve} from "../../src/treasury/MaintenanceReserve.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract F15_MaintenanceCap is Test {
    MaintenanceReserve reserve;
    MockUSDC usdc;

    address admin = makeAddr("admin");
    address payee = makeAddr("payee");

    function setUp() public {
        usdc = new MockUSDC();
        MaintenanceReserve impl = new MaintenanceReserve();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl), abi.encodeWithSelector(MaintenanceReserve.initialize.selector, address(usdc), admin)
        );
        reserve = MaintenanceReserve(address(proxy));
        usdc.mint(address(reserve), 1_000_000e6);
    }

    function test_DefaultCapIsTenThousand() public view {
        assertEq(reserve.monthlyCap(), 10_000e6, "default cap = $10k");
        assertEq(reserve.monthlyCap(), reserve.DEFAULT_MONTHLY_CAP());
    }

    function test_ZeroCapMeansDisabled() public {
        // Admin sets cap to 0 -> spending must be DISABLED (fail-closed), not unlimited.
        vm.prank(admin);
        reserve.setMonthlyCap(0);

        assertEq(reserve.monthlyRemaining(), 0, "remaining 0 when disabled");

        vm.prank(admin);
        vm.expectRevert(bytes("Spending disabled (cap=0)"));
        reserve.spend(payee, 1e6, MaintenanceReserve.SpendCategory.Other, "x");
    }

    function test_DefaultCapEnforced() public {
        // Within default cap: OK.
        vm.prank(admin);
        reserve.spend(payee, 10_000e6, MaintenanceReserve.SpendCategory.Other, "ok");
        assertEq(usdc.balanceOf(payee), 10_000e6);

        // One more wei over the monthly cap in the same month: revert.
        vm.prank(admin);
        vm.expectRevert(bytes("Monthly cap exceeded"));
        reserve.spend(payee, 1, MaintenanceReserve.SpendCategory.Other, "over");
    }

    function test_AdminCanRaiseCap() public {
        vm.prank(admin);
        reserve.setMonthlyCap(50_000e6);
        vm.prank(admin);
        reserve.spend(payee, 40_000e6, MaintenanceReserve.SpendCategory.Other, "ok");
        assertEq(usdc.balanceOf(payee), 40_000e6);
    }
}
