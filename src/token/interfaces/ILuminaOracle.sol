// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILuminaOracle {
    function getLatestPrice(bytes32 asset) external view returns (int256);
}
