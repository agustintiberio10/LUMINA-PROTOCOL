// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {UniswapV3Adapter} from "../../../src/dex/UniswapV3Adapter.sol";
import {MockUniswapRouter, MockQuoter} from "./mocks/MockUniswapRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title EchidnaUniswapV3Adapter
/// @notice Sprint Z.1 — Echidna property fuzzing for UniswapV3Adapter immutable.
contract EchidnaUniswapV3Adapter {
    UniswapV3Adapter adapter;
    MockUniswapRouter router;
    MockQuoter quoter;
    MockERC20 tokenIn;
    MockERC20 tokenOut;

    uint256 totalSwaps;

    constructor() {
        router = new MockUniswapRouter();
        quoter = new MockQuoter();
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        adapter = new UniswapV3Adapter(address(router), address(quoter), 10000);
        tokenIn.mint(address(this), 1_000_000 * 1e18);
    }

    function setRate(uint256 r) external {
        router.setRate(r);
    }

    function trySwap(uint256 amountIn, uint256 minOut) external {
        if (amountIn == 0) return;
        if (amountIn > tokenIn.balanceOf(address(this))) return;
        try adapter.swap(address(tokenIn), address(tokenOut), amountIn, minOut) {
            totalSwaps++;
        } catch {}
    }

    function echidna_adapter_no_token_in_residue() public view returns (bool) {
        return tokenIn.balanceOf(address(adapter)) == 0;
    }

    function echidna_adapter_no_token_out_residue() public view returns (bool) {
        return tokenOut.balanceOf(address(adapter)) == 0;
    }

    function echidna_router_immutable() public view returns (bool) {
        return address(adapter.router()) == address(router);
    }
}
