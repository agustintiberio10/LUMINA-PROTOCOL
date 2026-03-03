// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ISwapHandler
 * @notice Pluggable DEX adapter interface for MutualPoolRouter.
 *         Implementations wrap a specific DEX (Fluid, Uniswap V3, etc.)
 *         and expose a uniform swap(tokenIn, tokenOut, amountIn, minOut) API.
 *
 *         The Router calls swap() to convert MPOOLV3 → USDC before depositing
 *         into MutualPoolV3.
 */
interface ISwapHandler {
    /**
     * @notice Swap exact amount of tokenIn for tokenOut.
     * @dev Caller must have already transferred `amountIn` of `tokenIn` to this contract
     *      OR approved this contract to pull `amountIn`.
     *      Implementation decides pull vs push model — Router always approves first.
     *
     * @param tokenIn   Address of the input token (e.g. MPOOLV3).
     * @param tokenOut  Address of the output token (e.g. USDC).
     * @param amountIn  Exact amount of tokenIn to swap.
     * @param minOut    Minimum acceptable output (slippage protection).
     * @param recipient Address that receives the output tokens.
     * @return amountOut Actual amount of tokenOut received.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address recipient
    ) external returns (uint256 amountOut);

    /**
     * @notice Preview the expected output for a given input amount.
     * @param tokenIn   Input token address.
     * @param tokenOut  Output token address.
     * @param amountIn  Input amount.
     * @return amountOut Expected output amount (before slippage).
     */
    function quote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}
