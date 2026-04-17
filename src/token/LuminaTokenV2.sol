// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title LuminaTokenV2
/// @notice $LUMINA token — 100M fixed supply, deflationary by design.
/// @dev Distribution V5.0: 70% BondVault | 14% CEX Reserve | 8% Founder | 5% LBP | 3% Treasury
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
        address cexLiquidityReserve,
        address founderVesting,
        address lbpDeposit,
        address treasuryVesting
    ) ERC20("Lumina Protocol", "LUMINA") {
        // Zero-address checks (5)
        require(bondVault != address(0), "BondVault zero address");
        require(cexLiquidityReserve != address(0), "CEXReserve zero address");
        require(founderVesting != address(0), "FounderVesting zero address");
        require(lbpDeposit != address(0), "LBPDeposit zero address");
        require(treasuryVesting != address(0), "TreasuryVesting zero address");

        // Pairwise duplicate checks (C(5,2) = 10)
        require(bondVault != cexLiquidityReserve, "Duplicate: bondVault/cexReserve");
        require(bondVault != founderVesting, "Duplicate: bondVault/founder");
        require(bondVault != lbpDeposit, "Duplicate: bondVault/lbp");
        require(bondVault != treasuryVesting, "Duplicate: bondVault/treasury");
        require(cexLiquidityReserve != founderVesting, "Duplicate: cexReserve/founder");
        require(cexLiquidityReserve != lbpDeposit, "Duplicate: cexReserve/lbp");
        require(cexLiquidityReserve != treasuryVesting, "Duplicate: cexReserve/treasury");
        require(founderVesting != lbpDeposit, "Duplicate: founder/lbp");
        require(founderVesting != treasuryVesting, "Duplicate: founder/treasury");
        require(lbpDeposit != treasuryVesting, "Duplicate: lbp/treasury");

        // Distribution V5.0
        _mint(bondVault, 70_000_000 * 1e18); // 70% - Bond Reserve
        _mint(cexLiquidityReserve, 14_000_000 * 1e18); // 14% - CEX/DEX Liquidity
        _mint(founderVesting, 8_000_000 * 1e18); // 8% - Founder (AltSeason)
        _mint(lbpDeposit, 5_000_000 * 1e18); // 5% - LBP (Fjord Foundry)
        _mint(treasuryVesting, 3_000_000 * 1e18); // 3% - Treasury

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
