// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILuminaToken is IERC20 {
    function MAX_SUPPLY() external view returns (uint256);
    function totalBurned() external view returns (uint256);
    function burnByRole(address account, uint256 amount) external;
    function BURNER_ROLE() external view returns (bytes32);
}
