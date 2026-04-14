// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IExpirable {
    function getExpiresAt(uint256 tokenId) external view returns (uint256);
}
