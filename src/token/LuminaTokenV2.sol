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
/// @dev Distribution V5.1: 70% BondVault | 14% CEX Reserve | 8% Founder | 5% LBP | 3% Treasury
///      No mint function. Supply only decreases via burn.
///      BURNER_ROLE allows the TWAPBurner contract to burn tokens.
///
///      [L-10] WARNING: Renouncing DEFAULT_ADMIN_ROLE permanently locks
///      BURNER_ROLE management. If TWAPBurner is ever replaced, the new
///      burner cannot be granted the role. Only renounce after final
///      TWAPBurner deployment is confirmed stable.
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

    /// @notice [Sprint AA] Emitted when BURNER_ROLE consumes tokens from an account.
    event BurnedFromHolder(address indexed burner, address indexed account, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @custom:coverage-exclude L36, L47-L49 OZ pattern (ADR-017 Sprint Y):
    ///         `_disableInitializers()` runs in impl-constructor + `__XInit()` calls
    ///         run via the proxy delegatecall. Neither is credited by forge-coverage
    ///         instrumentation under `--ir-minimum`. Lines are functionally exercised
    ///         every time `ProxyDeployer.deployLuminaTokenV2` runs in tests.
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

    /// @notice Allows BURNER_ROLE to burn tokens from any address (for TWAPBurner)
    /// @param account The address to burn from
    /// @param amount The amount to burn
    /// @dev [F-21 / H-1] By DESIGN this override does NOT consume an ERC-20 allowance: it overrides
    ///      OpenZeppelin's `ERC20Burnable.burnFrom` (which would `_spendAllowance`) to let the
    ///      protocol burner reduce supply without the holder pre-approving each burn. Consequently
    ///      BURNER_ROLE is a CONFISCATION-CAPABLE role: any holder of it can unilaterally destroy
    ///      tokens from ANY account with no allowance and no consent.
    ///
    ///      SECURITY REQUIREMENT: BURNER_ROLE MUST be held ONLY by an audited, immutable/UUPS burner
    ///      contract (e.g. TWAPBurner) operated behind a multisig (Gnosis Safe) and/or timelock.
    ///      It MUST NEVER be granted to an EOA, an upgradeable contract with a mutable burn path, or
    ///      any address that can be socially-engineered. Treat granting BURNER_ROLE with the same
    ///      gravity as granting DEFAULT_ADMIN_ROLE. See ADR on H-1 (burnFrom allowance removal).
    function burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE) {
        _burn(account, amount);
        emit BurnedFromHolder(msg.sender, account, amount);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
