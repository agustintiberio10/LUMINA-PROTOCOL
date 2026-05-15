// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UniswapV3Adapter, ISwapRouter, IQuoterV2} from "../../../src/dex/UniswapV3Adapter.sol";

/// @notice Mintable ERC20 for swap path coverage.
contract UV3TestERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

/// @notice Mock Uniswap V3 SwapRouter with configurable output.
contract MockSwapRouter is ISwapRouter {
    uint256 public rate = 30;

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        UV3TestERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn * rate;
        require(amountOut >= params.amountOutMinimum, "Mock: minOut");
        UV3TestERC20(params.tokenOut).mint(params.recipient, amountOut);
    }
}

/// @notice Mock QuoterV2 with revert/output modes.
contract MockQuoterV2 is IQuoterV2 {
    bool public shouldRevert;
    uint256 public quoteRate = 30;

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function setRate(uint256 r) external {
        quoteRate = r;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        view
        override
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate)
    {
        if (shouldRevert) revert("Mock: quote revert");
        amountOut = params.amountIn * quoteRate;
        sqrtPriceX96After = 0;
        initializedTicksCrossed = 0;
        gasEstimate = 21000;
    }
}

contract UniswapV3AdapterCoverage is Test {
    UniswapV3Adapter adapter;
    MockSwapRouter router;
    MockQuoterV2 quoter;
    UV3TestERC20 tokenIn;
    UV3TestERC20 tokenOut;
    address user = makeAddr("user");

    function setUp() public {
        vm.chainId(8453);
        router = new MockSwapRouter();
        quoter = new MockQuoterV2();
        tokenIn = new UV3TestERC20("IN", "IN");
        tokenOut = new UV3TestERC20("OUT", "OUT");
        adapter = new UniswapV3Adapter(address(router), address(quoter), 10000);
    }

    // ─────────────── Constructor ───────────────

    function test_Constructor_Success() public {
        UniswapV3Adapter a = new UniswapV3Adapter(address(router), address(quoter), 3000);
        assertEq(address(a.router()), address(router));
        assertEq(address(a.quoter()), address(quoter));
        assertEq(a.poolFee(), 3000);
    }

    function test_Constructor_RevertIf_ZeroRouter() public {
        vm.expectRevert(bytes("Zero router"));
        new UniswapV3Adapter(address(0), address(quoter), 10000);
    }

    function test_Constructor_RevertIf_ZeroQuoter() public {
        vm.expectRevert(bytes("Zero quoter"));
        new UniswapV3Adapter(address(router), address(0), 10000);
    }

    // ─────────────── swap ───────────────

    function test_Swap_HappyPath_ReturnsAmount() public {
        tokenIn.mint(user, 1000e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1000e18);
        uint256 out = adapter.swap(address(tokenIn), address(tokenOut), 1000e18, 25_000e18);
        vm.stopPrank();
        assertEq(out, 30_000e18, "swap output mismatch");
        assertEq(tokenOut.balanceOf(user), 30_000e18, "user did not receive tokenOut");
    }

    function test_Swap_RevertIf_BelowMinOut() public {
        tokenIn.mint(user, 1000e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1000e18);
        vm.expectRevert(bytes("Mock: minOut"));
        adapter.swap(address(tokenIn), address(tokenOut), 1000e18, 100_000e18);
        vm.stopPrank();
    }

    // ─────────────── getQuote ───────────────

    function test_GetQuote_HappyPath() public {
        uint256 q = adapter.getQuote(address(tokenIn), address(tokenOut), 1000e18);
        assertEq(q, 30_000e18, "quote mismatch");
    }

    function test_GetQuote_AmountInZero_Returns0() public {
        uint256 q = adapter.getQuote(address(tokenIn), address(tokenOut), 0);
        assertEq(q, 0, "expected 0 for amountIn=0");
    }

    function test_GetQuote_QuoterReverts_Returns0() public {
        quoter.setRevert(true);
        uint256 q = adapter.getQuote(address(tokenIn), address(tokenOut), 1000e18);
        assertEq(q, 0, "expected 0 when quoter reverts");
    }

    // ─────────────── setPoolFee ───────────────

    function test_SetPoolFee_Owner_Success() public {
        adapter.setPoolFee(3000);
        assertEq(adapter.poolFee(), 3000);
    }

    function test_SetPoolFee_RevertIf_NotOwner() public {
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        adapter.setPoolFee(3000);
    }
}
