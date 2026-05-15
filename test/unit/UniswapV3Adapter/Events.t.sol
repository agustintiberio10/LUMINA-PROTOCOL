// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {UniswapV3Adapter, ISwapRouter, IQuoterV2} from "../../../src/dex/UniswapV3Adapter.sol";

contract UAERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract UAMockSwap is ISwapRouter {
    uint256 public rate = 30;

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        UAERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = p.amountIn * rate;
        require(amountOut >= p.amountOutMinimum, "minOut");
        UAERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}

contract UAMockQuoter is IQuoterV2 {
    function quoteExactInputSingle(QuoteExactInputSingleParams memory p)
        external
        pure
        returns (uint256, uint160, uint32, uint256)
    {
        return (p.amountIn * 30, 0, 0, 21000);
    }
}

contract UniswapV3AdapterEvents is Test {
    event SwapExecuted(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );
    event PoolFeeUpdated(uint24 oldFee, uint24 newFee);

    UniswapV3Adapter adapter;
    UAMockSwap router;
    UAMockQuoter quoter;
    UAERC20 tokenIn;
    UAERC20 tokenOut;
    address user = makeAddr("user");

    function setUp() public {
        vm.chainId(8453);
        router = new UAMockSwap();
        quoter = new UAMockQuoter();
        tokenIn = new UAERC20("IN", "IN");
        tokenOut = new UAERC20("OUT", "OUT");
        adapter = new UniswapV3Adapter(address(router), address(quoter), 10000);
    }

    function test_Event_SwapExecuted_Emitted() public {
        tokenIn.mint(user, 1000e18);
        vm.startPrank(user);
        tokenIn.approve(address(adapter), 1000e18);
        vm.expectEmit(true, true, true, true);
        emit SwapExecuted(user, address(tokenIn), address(tokenOut), 1000e18, 30_000e18);
        adapter.swap(address(tokenIn), address(tokenOut), 1000e18, 25_000e18);
        vm.stopPrank();
    }

    function test_Event_PoolFeeUpdated_Emitted() public {
        vm.expectEmit(false, false, false, true);
        emit PoolFeeUpdated(10000, 3000);
        adapter.setPoolFee(3000);
    }
}
