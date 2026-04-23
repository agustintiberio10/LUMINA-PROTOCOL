// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IDexRouter
/// @notice Abstraction for DEX swap operations. Implemented by UniswapV3Adapter, AerodromeAdapter, etc.
interface IDexRouter {
    /// @notice Execute a swap
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);

    /// @notice Get expected output for a given input.
    /// @dev Non-view to allow adapters that wrap Uniswap V3's QuoterV2
    ///      (which uses revert-based quoting and cannot be called from a
    ///      view function). Adapters that wrap pure-view quoters (like
    ///      Aerodrome's `getAmountsOut`) may still implement this as a
    ///      view — Solidity allows a `view` implementation of a non-view
    ///      interface (more restrictive is acceptable).
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 expectedOut);
}
