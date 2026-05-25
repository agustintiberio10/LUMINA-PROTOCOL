// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexRouter} from "../interfaces/IDexRouter.sol";

interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, Route[] memory routes) external view returns (uint256[] memory amounts);
}

/// @title AerodromeAdapter
/// @notice Wraps Aerodrome Router (Base L2) into the IDexRouter abstraction.
contract AerodromeAdapter is IDexRouter, Ownable {
    using SafeERC20 for IERC20;

    IAerodromeRouter public immutable router;
    address public factory;
    bool public stable;

    /// @notice [Sprint AA] Emitted when swap completes successfully.
    event SwapExecuted(
        address indexed caller, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    /// @notice [Sprint AA] Emitted when owner updates the pool factory.
    event FactoryUpdated(address indexed oldFactory, address indexed newFactory);

    /// @notice [Sprint AA] Emitted when owner toggles stable/volatile pool mode.
    event StableUpdated(bool oldStable, bool newStable);

    constructor(address _router, address _factory, bool _stable) Ownable(msg.sender) {
        require(_router != address(0), "Zero router");
        require(_factory != address(0), "Zero factory");
        router = IAerodromeRouter(_router);
        factory = _factory;
        stable = _stable;
    }

    /// @inheritdoc IDexRouter
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        // [MR-M06 fix] This adapter is permissionless (no allowlist, to preserve
        // composability and the existing TWAPBurner wiring), so `minAmountOut`
        // MUST be oracle-derived by the caller. Reject a zero floor outright: a
        // swap with minOut=0 has no slippage protection and is trivially
        // sandwiched. The live TWAPBurner caller always passes an oracle-derived
        // minOut>0 (see TWAPBurner._swapAndBurn), so this is non-breaking.
        require(minAmountOut > 0, "DexAdapter: minOut=0");

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({from: tokenIn, to: tokenOut, stable: stable, factory: factory});

        // [MR-M06 fix] Aerodrome has no sqrtPriceLimit equivalent; `amountOutMin`
        // (now required > 0 above) is the sole slippage protection for this swap.
        uint256[] memory amounts =
            router.swapExactTokensForTokens(amountIn, minAmountOut, routes, msg.sender, block.timestamp);

        // Last element in amounts is the output
        amountOut = amounts[amounts.length - 1];

        emit SwapExecuted(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @inheritdoc IDexRouter
    /// @dev [M-02 fix] Real quote via Aerodrome's `getAmountsOut`. Returns 0
    ///      if the router reverts (pool missing, stable/volatile mismatch,
    ///      etc.) so caller can fall back to oracle-based minOut.
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external view override returns (uint256) {
        if (amountIn == 0) return 0;
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({from: tokenIn, to: tokenOut, stable: stable, factory: factory});
        try router.getAmountsOut(amountIn, routes) returns (uint256[] memory amounts) {
            if (amounts.length == 0) return 0;
            return amounts[amounts.length - 1];
        } catch {
            return 0;
        }
    }

    function setFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Zero factory");
        address old = factory;
        factory = _factory;
        emit FactoryUpdated(old, _factory);
    }

    function setStable(bool _stable) external onlyOwner {
        bool old = stable;
        stable = _stable;
        emit StableUpdated(old, _stable);
    }
}
