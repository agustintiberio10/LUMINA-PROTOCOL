// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";

/// @title MRM07_SetUsdcGuards
/// @notice [MR-M07 fix] `setUsdc` must reject re-pointing the premium token
///         while accrual is non-zero or the contract still holds a balance of
///         the old token. Ops must drain/sweep first so 6-dec accounting is
///         never silently attributed to a new token.
contract MRM07_SetUsdcGuardsTest is Test {
    using SafeERC20 for IERC20;

    MockUSDC internal usdc;
    MockLumina internal lumina;
    MockDex internal dex;
    TWAPBurner internal burner;

    address internal newUsdc;

    address internal constant ROUTER_CALLER = address(0xA0);

    function setUp() public {
        vm.chainId(8453);
        usdc = new MockUSDC();
        lumina = new MockLumina();
        dex = new MockDex(address(usdc), address(lumina));
        lumina.mint(address(dex), 1_000_000e18);

        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(dex));
        // Enable auto-burn accrual so receivePremium bumps accumulatedUSDCSinceBurn.
        burner.initializeV2(50, 500e6, false, 0, address(0xCAFE));

        usdc.mint(ROUTER_CALLER, 10_000_000e6);
        vm.prank(ROUTER_CALLER);
        usdc.approve(address(burner), type(uint256).max);

        newUsdc = address(new MockUSDC());
    }

    // ─────────────────────────── reverts ───────────────────────────

    function test_setUsdc_revertsWhenAccrualNonzero() public {
        // A premium receipt bumps accumulatedUSDCSinceBurn AND leaves a balance.
        vm.prank(ROUTER_CALLER);
        burner.receivePremium(100e6);

        assertGt(burner.accumulatedUSDCSinceBurn(), 0, "accrual should be set");

        vm.expectRevert(bytes("TWAPBurner: drain accrual first"));
        burner.setUsdc(newUsdc);
    }

    function test_setUsdc_revertsWhenBalanceNonzero() public {
        // Drive a raw transfer to create a balance WITHOUT touching accrual.
        usdc.mint(address(burner), 50e6);
        assertEq(burner.accumulatedUSDCSinceBurn(), 0, "accrual must be clean");
        assertGt(usdc.balanceOf(address(burner)), 0, "balance should be set");

        vm.expectRevert(bytes("TWAPBurner: sweep balance first"));
        burner.setUsdc(newUsdc);
    }

    function test_setUsdc_revertsOnZeroAddress() public {
        vm.expectRevert(bytes("Zero USDC"));
        burner.setUsdc(address(0));
    }

    // ─────────────────────────── success ───────────────────────────

    function test_setUsdc_succeedsWhenClean() public {
        // Clean slate: no accrual, no balance.
        assertEq(burner.accumulatedUSDCSinceBurn(), 0, "accrual clean");
        assertEq(usdc.balanceOf(address(burner)), 0, "balance clean");

        burner.setUsdc(newUsdc);
        assertEq(address(burner.usdc()), newUsdc, "usdc re-pointed");
    }
}

// ─────────────────────────────── Mocks ────────────────────────────────

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockLumina is ERC20 {
    constructor() ERC20("LUMINA", "LUMINA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract MockDex is IDexRouter {
    using SafeERC20 for IERC20;

    address public usdc;
    address public lumina;

    constructor(address _usdc, address _lumina) {
        usdc = _usdc;
        lumina = _lumina;
    }

    function getQuote(address, address, uint256) external pure returns (uint256) {
        return 1e18;
    }

    function swap(address tokenIn, address, uint256 amountIn, uint256)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = 1e18;
    }
}
