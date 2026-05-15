// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";

contract MockERC20ForTWAP {
    string public name = "MockToken";
    string public symbol = "MCK";
    uint8 public decimals = 6;

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

contract MockSwapRouter {
    function swap(address, address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function getQuote(address, address, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @title TWAPBurnerFuzz
/// @notice Fuzz tests for TWAPBurner constants and premium tracking.
contract TWAPBurnerFuzz is Test {
    TWAPBurner burner;
    MockERC20ForTWAP usdc;
    MockERC20ForTWAP lumina;
    MockSwapRouter router;

    function setUp() public {
        vm.chainId(8453);
        usdc = new MockERC20ForTWAP();
        lumina = new MockERC20ForTWAP();
        router = new MockSwapRouter();
        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(router));
    }

    /// @notice Verify fallback distribution constants sum to exactly 10000 BPS.
    function testFuzz_FallbackDistribution_SumsTo10000() public view {
        uint256 total = burner.FALLBACK_BURN_BPS() + burner.FALLBACK_BUYBACK_BPS() + burner.FALLBACK_OPS_BPS()
            + burner.FALLBACK_MAINTENANCE_BPS();

        assertEq(total, 10000, "Fallback distribution must sum to 10000 BPS");
    }

    /// @notice Fuzz: receivePremium correctly tracks totalUSDCReceived.
    function testFuzz_ReceivePremium_TracksTotal(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000_000e6); // 1 wei to $1B USDC

        // Mint USDC to this contract and approve the burner
        usdc.mint(address(this), amount);
        usdc.approve(address(burner), amount);

        uint256 totalBefore = burner.totalUSDCReceived();

        burner.receivePremium(amount);

        uint256 totalAfter = burner.totalUSDCReceived();
        assertEq(totalAfter, totalBefore + amount, "totalUSDCReceived should increase by amount");
    }
}
