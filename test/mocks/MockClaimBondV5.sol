// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract MockClaimBondV5 is ERC1155 {
    mapping(uint256 => uint256) public maturityDate;
    uint256 public constant FACE_VALUE = 1e18;

    constructor() ERC1155("https://mock.lumina/") {}

    function setMaturityDate(uint256 epochId, uint256 timestamp) external {
        maturityDate[epochId] = timestamp;
    }

    function mint(address to, uint256 epochId, uint256 amount) external {
        _mint(to, epochId, amount, "");
    }

    function burnByHolder(address account, uint256 epochId, uint256 amount) external {
        require(msg.sender == account || isApprovedForAll(account, msg.sender), "Not authorized");
        _burn(account, epochId, amount);
    }

    function getFaceValue(uint256) external pure returns (uint256) {
        return FACE_VALUE;
    }
}
