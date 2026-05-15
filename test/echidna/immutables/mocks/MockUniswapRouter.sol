// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISwapRouter, IQuoterV2} from "../../../../src/dex/UniswapV3Adapter.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockUniswapRouter is ISwapRouter {
    uint256 public rate = 30;

    function setRate(uint256 r) external {
        rate = r;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        MockERC20(p.tokenIn).transfer(address(this), p.amountIn);
        amountOut = p.amountIn * rate;
        require(amountOut >= p.amountOutMinimum, "minOut");
        MockERC20(p.tokenOut).mint(p.recipient, amountOut);
    }
}

contract MockQuoter is IQuoterV2 {
    function quoteExactInputSingle(QuoteExactInputSingleParams memory p)
        external
        pure
        returns (uint256, uint160, uint32, uint256)
    {
        return (p.amountIn * 30, 0, 0, 21000);
    }
}
