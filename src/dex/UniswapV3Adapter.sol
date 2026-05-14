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

interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// @title UniswapV3Adapter
/// @notice Wraps Uniswap V3 SwapRouter + QuoterV2 into the IDexRouter abstraction.
contract UniswapV3Adapter is IDexRouter, Ownable {
    using SafeERC20 for IERC20;

    ISwapRouter public immutable router;
    IQuoterV2 public immutable quoter;
    uint24 public poolFee;

    /// @notice [Sprint AA] Emitted when swap completes successfully.
    event SwapExecuted(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    /// @notice [Sprint AA] Emitted when owner updates the pool fee tier.
    event PoolFeeUpdated(uint24 oldFee, uint24 newFee);

    constructor(address _router, address _quoter, uint24 _poolFee) Ownable(msg.sender) {
        require(_router != address(0), "Zero router");
        require(_quoter != address(0), "Zero quoter");
        router = ISwapRouter(_router);
        quoter = IQuoterV2(_quoter);
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

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @inheritdoc IDexRouter
    /// @dev [M-02 fix] Real quote via Uniswap V3 QuoterV2. Returns 0 if the
    ///      quoter reverts (pool missing, fee tier wrong, etc.) so caller
    ///      can fall back to oracle-based minOut.
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external override returns (uint256) {
        if (amountIn == 0) return 0;
        try quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: poolFee, sqrtPriceLimitX96: 0
            })
        ) returns (
            uint256 amountOut, uint160, uint32, uint256
        ) {
            return amountOut;
        } catch {
            return 0;
        }
    }

    function setPoolFee(uint24 _fee) external onlyOwner {
        uint24 old = poolFee;
        poolFee = _fee;
        emit PoolFeeUpdated(old, _fee);
    }
}
