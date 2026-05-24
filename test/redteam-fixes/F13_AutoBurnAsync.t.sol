// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ProxyDeployer} from "../helpers/ProxyDeployer.sol";
import {TWAPBurner} from "../../src/core/TWAPBurner.sol";
import {IDexRouter} from "../../src/interfaces/IDexRouter.sol";

contract F13MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract F13MockLumina is ERC20 {
    constructor() ERC20("LUMINA", "LUMINA") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}

contract F13MockDex is IDexRouter {
    using SafeERC20 for IERC20;

    address public usdc;
    address public lumina;
    uint256 public swapOutput;

    constructor(address _usdc, address _lumina) {
        usdc = _usdc;
        lumina = _lumina;
        swapOutput = 1e18;
    }

    function setSwapOutput(uint256 v) external {
        swapOutput = v;
    }

    function getQuote(address, address, uint256) external view returns (uint256) {
        return swapOutput;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        external
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = swapOutput;
        require(amountOut >= minOut, "slippage");
        if (IERC20(tokenOut).balanceOf(address(this)) >= amountOut) {
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
    }
}

contract F13MockOracle {
    uint256 public price = 1e16; // $0.01 in 18-dec

    function setPrice(uint256 p) external {
        price = p;
    }

    function getLuminaPrice() external view returns (uint256) {
        return price;
    }
}

/// @notice F-13 (+F-22, +F-24): premium-driven auto-burn must be ASYNC,
///         must never derive a recipient from tx.origin, and must respect
///         the burn cooldown.
contract F13AutoBurnAsyncTest is Test {
    using SafeERC20 for IERC20;

    F13MockUSDC internal usdc;
    F13MockLumina internal lumina;
    F13MockDex internal dex;
    F13MockOracle internal oracle;
    TWAPBurner internal burner;

    address internal constant ROUTER_CALLER = address(0xA0);
    address internal constant BUYER = address(0xB1);

    uint256 internal constant MAX_PURCHASES = 50;
    uint256 internal constant MAX_USDC = 500e6;

    function setUp() public {
        vm.chainId(8453);
        // Realistic chain time so the burnCooldown gate (lastBurnTimestamp==0 +
        // cooldown) isn't spuriously tripped at Foundry's default ts=1.
        vm.warp(1_700_000_000);
        usdc = new F13MockUSDC();
        lumina = new F13MockLumina();
        dex = new F13MockDex(address(usdc), address(lumina));
        oracle = new F13MockOracle();
        lumina.mint(address(dex), 1_000_000e18);

        burner = ProxyDeployer.deployTWAPBurner(address(usdc), address(lumina), address(dex));
        burner.setCapacityOracle(address(oracle));
        burner.initializeV2(MAX_PURCHASES, MAX_USDC, false, 0, address(0));
        // F-19: minOut is now oracle-derived. At $0.01 a 600 USDC burn expects
        // ~60,000 LUMINA out; the mock must deliver above that floor or the swap
        // (correctly) reverts "slippage". Give it ample, realistic output.
        dex.setSwapOutput(100_000e18);

        usdc.mint(ROUTER_CALLER, 10_000_000e6);
        vm.prank(ROUTER_CALLER);
        usdc.approve(address(burner), type(uint256).max);
    }

    function _send(uint256 amount) internal {
        // tx.origin = BUYER, msg.sender = ROUTER_CALLER
        vm.prank(ROUTER_CALLER, BUYER);
        burner.receivePremium(amount);
    }

    /// receivePremium must NOT execute a swap, even when thresholds are crossed.
    function test_ReceivePremiumDoesNotSwapSynchronously() external {
        // Cross BOTH thresholds in a single receipt: 600 USDC > 500, 1 >= ... no.
        _send(600e6);

        assertEq(burner.totalUSDCBurned(), 0, "no synchronous burn");
        assertEq(burner.totalLUMINABurned(), 0, "no LUMINA burned synchronously");
        // Funds simply accrued in the burner.
        assertEq(usdc.balanceOf(address(burner)), 600e6, "USDC accrued, not swapped");
        assertEq(burner.accumulatedUSDCSinceBurn(), 600e6, "accumulator increments");
        assertEq(burner.purchaseCounter(), 1, "counter increments");

        // And the async path is flagged ready for a keeper.
        assertTrue(burner.autoBurnReady(), "auto-burn should be ready for keeper");
    }

    /// No tx.origin dependence: result is identical regardless of tx.origin.
    function test_NoTxOrigin() external {
        // Send with one tx.origin.
        vm.prank(ROUTER_CALLER, BUYER);
        burner.receivePremium(100e6);

        // Send with a DIFFERENT tx.origin; behaviour identical (pure accrual).
        vm.prank(ROUTER_CALLER, address(0xDEAD));
        burner.receivePremium(100e6);

        assertEq(burner.accumulatedUSDCSinceBurn(), 200e6, "accrual unaffected by tx.origin");
        assertEq(burner.totalUSDCBurned(), 0, "still no burn");
        // No ETH ever moves (no gas-refund path remains).
        assertEq(BUYER.balance, 0, "no refund to tx.origin");
        assertEq(address(0xDEAD).balance, 0, "no refund to second tx.origin");
    }

    /// The async burn path (executeBurn) must respect burnCooldown.
    function test_AutoBurnRespectsCooldown() external {
        // Accrue enough to be "ready".
        _send(600e6);
        assertTrue(burner.autoBurnReady(), "ready after threshold");

        // First burn succeeds.
        burner.executeBurn();
        assertGt(burner.totalUSDCBurned(), 0, "first burn happened");
        assertEq(burner.purchaseCounter(), 0, "counter reset on burn");
        assertEq(burner.accumulatedUSDCSinceBurn(), 0, "accumulator reset on burn");

        // Accrue again immediately; cooldown (900s) not elapsed.
        _send(600e6);
        assertFalse(burner.autoBurnReady(), "not ready during cooldown");
        vm.expectRevert(bytes("Cooldown active"));
        burner.executeBurn();

        // After cooldown elapses, it's ready and succeeds again.
        vm.warp(block.timestamp + 901);
        assertTrue(burner.autoBurnReady(), "ready after cooldown");
        burner.executeBurn();
    }
}
