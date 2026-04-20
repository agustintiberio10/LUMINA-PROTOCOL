// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDexRouter
/// @notice Abstraction for DEX swap operations. Implemented by UniswapV3Adapter, AerodromeAdapter, etc.
interface IDexRouter {
    /// @notice Execute a swap
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);

    /// @notice Get expected output for a given input
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 expectedOut);
}
