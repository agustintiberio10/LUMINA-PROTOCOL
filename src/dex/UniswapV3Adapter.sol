// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexRouter} from "../interfaces/IDexRouter.sol";

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniswapV3Adapter
/// @notice Wraps Uniswap V3 SwapRouter into the IDexRouter abstraction.
contract UniswapV3Adapter is IDexRouter, Ownable {
    using SafeERC20 for IERC20;

    ISwapRouter public immutable router;
    uint24 public poolFee;

    constructor(address _router, uint24 _poolFee) Ownable(msg.sender) {
        require(_router != address(0), "Zero router");
        router = ISwapRouter(_router);
        poolFee = _poolFee;
    }

    /// @inheritdoc IDexRouter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: poolFee,
                recipient: msg.sender,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @inheritdoc IDexRouter
    /// @dev Returns 0 — in production this would query the pool for a TWAP or spot quote.
    ///      TWAPBurner treats 0 as "no quote available" and falls back to first router.
    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function setPoolFee(uint24 _fee) external onlyOwner {
        poolFee = _fee;
    }
}
