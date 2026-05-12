// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {
    ERC1155HolderUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC1155/utils/ERC1155HolderUpgradeable.sol";

interface IBuybackClaimBond {
    function getFaceValue(uint256 epochId) external view returns (uint256);
    function burnByHolder(address account, uint256 epochId, uint256 amount) external;
}

interface IBuybackBondVault {
    function decreaseObligations(uint256 amount) external;
    function burnFromReserves(uint256 amount) external;
}

interface IBuybackSolvencyOracle {
    function getSolvencyRatio() external view returns (uint256);
}

interface IBuybackCapacityOracle {
    function getLuminaPrice() external view returns (uint256);
}

interface IBuybackMarketplace {
    function executeBuy(uint256 listingId) external;
    function getListing(uint256 listingId)
        external
        view
        returns (address seller, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active);

    // [M-03 fix] Needed so executeOffer approves priceUSDC + buyerFee.
    function BUYER_FEE_BPS() external view returns (uint256);
    function BPS_DENOMINATOR() external view returns (uint256);
}

/// @title BuybackEngine
/// @notice Buys ClaimBonds from marketplace + executes Double Burn.
/// @dev [V5.1] UUPS upgradeable proxy pattern.
contract BuybackEngine is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC1155HolderUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant BUYBACK_OPERATOR_ROLE = keccak256("BUYBACK_OPERATOR_ROLE");

    IBuybackClaimBond public claimBond;
    IBuybackBondVault public bondVault;
    IBuybackSolvencyOracle public solvencyOracle;
    IBuybackCapacityOracle public capacityOracle;
    IBuybackMarketplace public marketplace;
    IERC20 public usdc;

    uint256 public constant MIN_SOLVENCY_FOR_DOUBLE_BURN = 15000; // 150%

    struct DailyConfig {
        uint256 dailyBudget;
        uint256 maxPricePercent;
        uint256 validUntil;
        uint256 spentToday;
    }

    DailyConfig public dailyConfig;

    event DailyBuybackConfigured(uint256 budget, uint256 maxPercent, uint256 durationHours);
    event OfferExecuted(uint256 indexed listingId, uint256 epochId, uint256 amount, uint256 priceUSDC);
    event DoubleBurnExecuted(uint256 epochId, uint256 obligationsReduced, uint256 luminaBurned);
    event CircuitBreakerTriggered(uint256 currentSolvency, uint256 threshold);
    /// @notice [LOW-2 fix] Emitted on successful non-core token rescue.
    event TokenRecovered(address indexed token, uint256 amount, address indexed to);

    // ═══════ ERRORS (rescue) ═══════
    error CoreTokenProtected(address token);
    error ZeroAddressNotAllowed();
    error RecoverAmountZero();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _claimBond,
        address _bondVault,
        address _solvencyOracle,
        address _capacityOracle,
        address _marketplace,
        address _usdc,
        address _multisigOwner
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __ERC1155Holder_init();
        __UUPSUpgradeable_init();

        require(_claimBond != address(0) && _bondVault != address(0) && _solvencyOracle != address(0), "Zero addr core");
        require(
            _capacityOracle != address(0) && _marketplace != address(0) && _usdc != address(0)
                && _multisigOwner != address(0),
            "Zero addr ext"
        );

        claimBond = IBuybackClaimBond(_claimBond);
        bondVault = IBuybackBondVault(_bondVault);
        solvencyOracle = IBuybackSolvencyOracle(_solvencyOracle);
        capacityOracle = IBuybackCapacityOracle(_capacityOracle);
        marketplace = IBuybackMarketplace(_marketplace);
        usdc = IERC20(_usdc);

        _grantRole(DEFAULT_ADMIN_ROLE, _multisigOwner);
        _grantRole(BUYBACK_OPERATOR_ROLE, _multisigOwner);
    }

    function setDailyBuyback(uint256 _budget, uint256 _maxPricePercent, uint256 _durationHours)
        external
        onlyRole(BUYBACK_OPERATOR_ROLE)
    {
        require(_budget > 0, "Budget zero");
        require(_maxPricePercent > 0 && _maxPricePercent <= 95, "Max percent 1-95");
        require(_durationHours > 0 && _durationHours <= 72, "Duration 1-72 hours");

        dailyConfig = DailyConfig({
            dailyBudget: _budget,
            maxPricePercent: _maxPricePercent,
            validUntil: block.timestamp + (_durationHours * 1 hours),
            spentToday: 0
        });

        emit DailyBuybackConfigured(_budget, _maxPricePercent, _durationHours);
    }

    function executeOffer(uint256 listingId) external nonReentrant {
        require(block.timestamp <= dailyConfig.validUntil, "Daily offer expired");

        // [Sprint X.1] `seller` is intentionally unused: non-existent listings
        // return the default Listing struct where `active=false`, so the
        // require below is the canonical existence check. `seller` validation
        // would be redundant.
        // slither-disable-next-line unused-return
        (, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active) = marketplace.getListing(listingId);
        require(active, "Listing not active");
        require(amount > 0, "Amount zero");

        uint256 faceValueUSD = claimBond.getFaceValue(epochId) * amount;
        uint256 maxAllowedPriceUSDC = (faceValueUSD * dailyConfig.maxPricePercent) / (100 * 1e12);
        require(priceUSDC <= maxAllowedPriceUSDC, "Price exceeds max");

        // [M-03 fix] Marketplace.executeBuy pulls priceUSDC + buyerFee from
        // this engine. Approve the total AND count the total against the
        // daily budget — anything less reverts at the marketplace transfer.
        uint256 buyerFee = (priceUSDC * marketplace.BUYER_FEE_BPS()) / marketplace.BPS_DENOMINATOR();
        uint256 totalRequired = priceUSDC + buyerFee;
        require(dailyConfig.spentToday + totalRequired <= dailyConfig.dailyBudget, "Daily budget exceeded");

        // CEI: update state before external call.
        dailyConfig.spentToday += totalRequired;

        usdc.forceApprove(address(marketplace), totalRequired);
        marketplace.executeBuy(listingId);
        // Defensive reset — should already be zero after the marketplace
        // drained the approval, but keep it explicit.
        usdc.forceApprove(address(marketplace), 0);

        _executeDoubleBurn(epochId, amount, faceValueUSD);
        emit OfferExecuted(listingId, epochId, amount, priceUSDC);
    }

    function _executeDoubleBurn(uint256 epochId, uint256 amount, uint256 faceValueUSD) internal {
        claimBond.burnByHolder(address(this), epochId, amount);
        bondVault.decreaseObligations(faceValueUSD);

        uint256 currentSolvency = solvencyOracle.getSolvencyRatio();
        if (currentSolvency >= MIN_SOLVENCY_FOR_DOUBLE_BURN) {
            uint256 spotPrice = capacityOracle.getLuminaPrice();
            if (spotPrice > 0) {
                uint256 luminaToBurn = (faceValueUSD * 1e18) / spotPrice;
                bondVault.burnFromReserves(luminaToBurn);
                emit DoubleBurnExecuted(epochId, faceValueUSD, luminaToBurn);
                return;
            }
        }

        emit CircuitBreakerTriggered(currentSolvency, MIN_SOLVENCY_FOR_DOUBLE_BURN);
        emit DoubleBurnExecuted(epochId, faceValueUSD, 0);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable, ERC1155HolderUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ═══════ RESCUE (LOW-2 fix, audit #26) ═══════

    /// @notice Recover non-core ERC-20 tokens sent here by mistake.
    /// @dev    USDC (budget) and ClaimBond are protected.
    function recoverToken(address token, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (_isCoreToken(token)) revert CoreTokenProtected(token);

        IERC20(token).safeTransfer(to, amount);
        emit TokenRecovered(token, amount, to);
    }

    /// @notice Recover non-core ERC-1155 tokens sent here by mistake.
    function recoverERC1155(address token, uint256 id, uint256 amount, address to)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (token == address(0)) revert ZeroAddressNotAllowed();
        if (to == address(0)) revert ZeroAddressNotAllowed();
        if (amount == 0) revert RecoverAmountZero();
        if (_isCoreToken(token)) revert CoreTokenProtected(token);

        IERC1155(token).safeTransferFrom(address(this), to, id, amount, "");
        emit TokenRecovered(token, amount, to);
    }

    function _isCoreToken(address token) private view returns (bool) {
        return token == address(usdc) || token == address(claimBond);
    }

    // Storage gap for future upgrades
    uint256[50] private __gap;
}
