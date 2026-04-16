// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAavePool} from "../interfaces/IAavePool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockAavePool is IAavePool {
    MockERC20 public aToken;
    bool public simulateFailure;

    constructor(address _aToken) {
        aToken = MockERC20(_aToken);
    }

    function setSimulateFailure(bool _fail) external {
        simulateFailure = _fail;
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        if (simulateFailure) revert("Aave: no liquidity");
        uint256 actual = amount == type(uint256).max ? aToken.balanceOf(msg.sender) : amount;
        aToken.burn(msg.sender, actual);
        IERC20(asset).transfer(to, actual);
        return actual;
    }
}
