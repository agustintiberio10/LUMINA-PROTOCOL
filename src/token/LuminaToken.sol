// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract LuminaToken is ERC20, ERC20Burnable, AccessControl {
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18;
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor(
        address treasury,
        address exitEngineReserve,
        address exchangeReserve,
        address altSeasonVesting
    ) ERC20("Lumina Protocol", "LUMINA") {
        require(treasury != address(0), "Zero treasury");
        require(exitEngineReserve != address(0), "Zero exitEngine");
        require(exchangeReserve != address(0), "Zero exchange");
        require(altSeasonVesting != address(0), "Zero vesting");

        _mint(treasury, 10_000_000 * 1e18);
        _mint(exitEngineReserve, 15_000_000 * 1e18);
        _mint(exchangeReserve, 10_000_000 * 1e18);
        _mint(altSeasonVesting, 65_000_000 * 1e18);

        assert(totalSupply() == MAX_SUPPLY);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function totalBurned() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    function burnByRole(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(account, amount);
    }
}
