// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title LuminaTokenV2
/// @notice $LUMINA token — 100M fixed supply, deflationary by design.
/// @dev Distribution V5.0: 70% BondVault | 14% CEX Reserve | 8% Founder | 5% LBP | 3% Treasury
///      No mint function. Supply only decreases via burn.
///
///      Burn paths (post [Fix H-1]):
///      - `burn(amount)`        : holder burns their own balance (ERC20Burnable default).
///      - `burnFrom(acct, amt)` : caller must hold `acct`'s ERC20 allowance for `amt`
///                                (ERC20Burnable default — allowance check restored).
///      TWAPBurner and BondVault burn their OWN balance via `burn()`, so no allowance
///      is needed. BURNER_ROLE is kept as a reserved privilege for future use but is
///      no longer required by `burnFrom` — the standard allowance check is sufficient.
///
///      [Fix H-1] Removed the prior override of `burnFrom` that bypassed the
///      ERC20Burnable allowance check. The previous behavior allowed any
///      BURNER_ROLE holder to burn tokens from any address without consent,
///      which is exploitable if (a) the role is ever granted to a buggy
///      contract, (b) the multisig is compromised and grants the role to an
///      attacker, or (c) the token is upgraded to grant the role to additional
///      callers. The standard ERC20Burnable.burnFrom now applies.
///
///      [L-10] WARNING: Renouncing DEFAULT_ADMIN_ROLE permanently locks
///      BURNER_ROLE management. Only renounce after final TWAPBurner
///      deployment is confirmed stable. (Less critical post H-1: no in-protocol
///      flow currently depends on BURNER_ROLE for `burnFrom`.)
///
///      [V5.1] UUPS upgradeable proxy pattern.
contract LuminaTokenV2 is
    Initializable,
    UUPSUpgradeable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    AccessControlUpgradeable
{
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18;
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address bondVault,
        address cexLiquidityReserve,
        address founderVesting,
        address lbpDeposit,
        address treasuryVesting
    ) public initializer {
        __ERC20_init("Lumina Protocol", "LUMINA");
        __ERC20Burnable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

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

    /// @notice Burns `amount` tokens from `account`, deducting from the caller's
    ///         allowance. Standard ERC20Burnable semantics — caller MUST have
    ///         been pre-approved by `account` for at least `amount` tokens.
    /// @dev    [Fix H-1] The prior override that bypassed `_spendAllowance` and
    ///         gated solely on BURNER_ROLE has been removed. The default
    ///         `ERC20BurnableUpgradeable.burnFrom` is now active, which calls
    ///         `_spendAllowance(account, _msgSender(), amount)` before burning.
    ///         This is intentionally NOT overridden — see contract-level NatSpec.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
