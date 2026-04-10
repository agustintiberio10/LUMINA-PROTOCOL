// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILuminaPriceOracle {
    function getPrice() external view returns (uint256);
    function usdToLumina(uint256 usdAmount) external view returns (uint256);
    function luminaToUsd(uint256 luminaAmount) external view returns (uint256);
}
