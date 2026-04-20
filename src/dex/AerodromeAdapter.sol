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
}

/// @title AerodromeAdapter
/// @notice Wraps Aerodrome Router (Base L2) into the IDexRouter abstraction.
contract AerodromeAdapter is IDexRouter, Ownable {
    using SafeERC20 for IERC20;

    IAerodromeRouter public immutable router;
    address public factory;
    bool public stable;

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
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({from: tokenIn, to: tokenOut, stable: stable, factory: factory});

        uint256[] memory amounts =
            router.swapExactTokensForTokens(amountIn, minAmountOut, routes, msg.sender, block.timestamp);

        // Last element in amounts is the output
        amountOut = amounts[amounts.length - 1];
    }

    /// @inheritdoc IDexRouter
    /// @dev Returns 0 — in production this would query Aerodrome pool reserves.
    function getQuote(address, address, uint256) external pure override returns (uint256) {
        return 0;
    }

    function setFactory(address _factory) external onlyOwner {
        require(_factory != address(0), "Zero factory");
        factory = _factory;
    }

    function setStable(bool _stable) external onlyOwner {
        stable = _stable;
    }
}
