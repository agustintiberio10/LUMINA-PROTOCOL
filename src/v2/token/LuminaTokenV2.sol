// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title LuminaTokenV2
/// @notice $LUMINA token — 100M fixed supply, deflationary by design.
/// @dev Distribution: 82% BondVault | 5% LBP | 10% Founder | 3% Treasury
///      No mint function. Supply only decreases via burn.
///      BURNER_ROLE allows the TWAPBurner contract to burn tokens.
///
///      [L-10] WARNING: Renouncing DEFAULT_ADMIN_ROLE permanently locks
///      BURNER_ROLE management. If TWAPBurner is ever replaced, the new
///      burner cannot be granted the role. Only renounce after final
///      TWAPBurner deployment is confirmed stable.
contract LuminaTokenV2 is ERC20, ERC20Burnable, AccessControl {
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18;
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor(
        address bondVault,
        address lbpDeposit,
        address founderVesting,
        address treasuryVesting
    ) ERC20("Lumina Protocol", "LUMINA") {
        require(bondVault != address(0), "Zero bondVault");
        require(lbpDeposit != address(0), "Zero lbpDeposit");
        require(founderVesting != address(0), "Zero founderVesting");
        require(treasuryVesting != address(0), "Zero treasuryVesting");

        // [LBL-H1] Prevent accidental distribution collapse if deployer passes
        // the same address twice (e.g. bondVault == treasury would silently
        // combine 82M+3M in one account and break invariant checks elsewhere).
        require(bondVault != lbpDeposit, "Duplicate: bondVault/lbp");
        require(bondVault != founderVesting, "Duplicate: bondVault/founder");
        require(bondVault != treasuryVesting, "Duplicate: bondVault/treasury");
        require(lbpDeposit != founderVesting, "Duplicate: lbp/founder");
        require(lbpDeposit != treasuryVesting, "Duplicate: lbp/treasury");
        require(founderVesting != treasuryVesting, "Duplicate: founder/treasury");

        _mint(bondVault,        82_000_000 * 1e18);  // 82% Bond Reserve
        _mint(lbpDeposit,        5_000_000 * 1e18);  //  5% LBP (Fjord Foundry)
        _mint(founderVesting,   10_000_000 * 1e18);  // 10% Founder (AltSeason)
        _mint(treasuryVesting,   3_000_000 * 1e18);  //  3% Treasury (6m lock)

        assert(totalSupply() == MAX_SUPPLY);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /// @notice Returns total tokens burned (MAX_SUPPLY - current supply)
    function totalBurned() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    /// @notice Allows BURNER_ROLE to burn tokens from any address (for TWAPBurner)
    /// @param account The address to burn from
    /// @param amount The amount to burn
    function burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE) {
        _burn(account, amount);
    }
}
