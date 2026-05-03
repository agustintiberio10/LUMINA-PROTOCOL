// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CEXLiquidityReserve} from "../../src/treasury/CEXLiquidityReserve.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

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
    using ProxyDeployer for *;

    CEXLiquidityReserve reserve;
    MockLuminaForCEX lumina;

    address admin = makeAddr("admin");
    address recipient = makeAddr("recipient");

    function setUp() public {
        lumina = new MockLuminaForCEX();
        vm.prank(admin);
        reserve = ProxyDeployer.deployCEXLiquidityReserve(address(lumina), admin);

        // Fund the reserve with the full 14M lifetime ceiling so the
        // total-reserve check is never the binding constraint in this fuzz.
        lumina.mint(address(reserve), 14_000_000 * 1e18);
    }

    /// @notice Fuzz: monthly cap of 1M LUMINA is never exceeded in a single month.
    function testFuzz_MonthlyCap_NeverExceeded(uint256 amount) public {
        uint256 monthlyCap = reserve.monthlyCap(); // 1_000_000e18 (default)
        uint256 totalAmount = reserve.TOTAL_AMOUNT();

        // Bound to amounts strictly above the monthly cap and at or below
        // the lifetime ceiling so only the monthly cap can cause the revert.
        amount = bound(amount, monthlyCap + 1, totalAmount);

        vm.prank(admin);
        vm.expectRevert("Monthly cap exceeded");
        reserve.allocate(recipient, amount, CEXLiquidityReserve.Purpose.DEX_SECONDARY_POOL, "Fuzz test allocation");
    }
}
