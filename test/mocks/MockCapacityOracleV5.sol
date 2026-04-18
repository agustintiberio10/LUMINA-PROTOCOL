// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockCapacityOracleV5 {
    uint256 public mockPrice;
    bool public revertOnPrice;

    function setPrice(uint256 p) external {
        mockPrice = p;
    }

    function setRevertOnPrice(bool r) external {
        revertOnPrice = r;
    }

    function getLuminaPrice() external view returns (uint256) {
        require(!revertOnPrice, "Mock: price revert");
        return mockPrice;
    }
}
