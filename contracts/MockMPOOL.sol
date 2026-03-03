// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockMPOOL
 * @notice Mock MPOOL token for testing. 18 decimals, public mint.
 */
contract MockMPOOL is ERC20 {
    constructor() ERC20("MutualPool Token", "MPOOL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
