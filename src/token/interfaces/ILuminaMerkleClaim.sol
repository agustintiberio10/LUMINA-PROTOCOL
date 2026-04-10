// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILuminaMerkleClaim {
    function setMerkleRoot(bytes32 _root) external;
    function claim(uint256 totalAmount, bytes32[] calldata proof) external;
    function claimable(address account, uint256 totalAmount, bytes32[] calldata proof)
        external
        view
        returns (uint256);
    function claimed(address account) external view returns (uint256);
    function merkleRoot() external view returns (bytes32);
    function availableTokens() external view returns (uint256);
}
