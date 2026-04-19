// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";

contract MockLuminaForCEX {
    string public name = "MockLumina";
    string public symbol = "MLUM";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

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

/// @title CEXReserveFuzz
/// @notice Fuzz tests for CEXLiquidityReserve monthly cap enforcement.
contract CEXReserveFuzz is Test {
    CEXLiquidityReserve reserve;
    MockLuminaForCEX lumina;

    address admin = makeAddr("admin");
    address recipient = makeAddr("recipient");

    function setUp() public {
        lumina = new MockLuminaForCEX();
        vm.prank(admin);
        reserve = new CEXLiquidityReserve(address(lumina), admin);

        // Fund the reserve with the full ImmediateUse amount
        lumina.mint(address(reserve), 2_800_000 * 1e18);
    }

    /// @notice Fuzz: monthly cap of 1M LUMINA is never exceeded in a single month.
    function testFuzz_MonthlyCap_NeverExceeded(uint256 amount) public {
        uint256 monthlyCap = reserve.MONTHLY_CAP(); // 1_000_000e18
        uint256 immediateAvail = reserve.getAvailableInBucket(CEXLiquidityReserve.SubBucket.ImmediateUse);

        // Bound to amounts that would exceed the monthly cap
        amount = bound(amount, monthlyCap + 1, immediateAvail > monthlyCap + 1 ? immediateAvail : monthlyCap + 1);

        // If amount exceeds available bucket, it will revert for a different reason.
        // We only test amounts within bucket but over monthly cap.
        if (amount > immediateAvail) return;

        vm.prank(admin);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(
            recipient,
            amount,
            CEXLiquidityReserve.SubBucket.ImmediateUse,
            CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL,
            "Fuzz test allocation"
        );
    }
}
