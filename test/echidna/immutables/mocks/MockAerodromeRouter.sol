// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAerodromeRouter} from "../../../../src/dex/AerodromeAdapter.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockAerodromeRouter is IAerodromeRouter {
    uint256 public rate = 30;

    function setRate(uint256 r) external {
        rate = r;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 minOut, Route[] calldata routes, address to, uint256)
        external
        returns (uint256[] memory amounts)
    {
        MockERC20(routes[0].from).transfer(address(this), amountIn);
        uint256 out = amountIn * rate;
        require(out >= minOut, "minOut");
        MockERC20(routes[0].to).mint(to, out);
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = out;
    }

    function getAmountsOut(uint256 amountIn, Route[] memory) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn * rate;
    }
}
