// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

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
}

/// @title BuybackEngine
/// @notice Buys ClaimBonds from marketplace + executes Double Burn.
contract BuybackEngine is AccessControl, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    bytes32 public constant BUYBACK_OPERATOR_ROLE = keccak256("BUYBACK_OPERATOR_ROLE");

    IBuybackClaimBond public immutable claimBond;
    IBuybackBondVault public immutable bondVault;
    IBuybackSolvencyOracle public immutable solvencyOracle;
    IBuybackCapacityOracle public immutable capacityOracle;
    IBuybackMarketplace public immutable marketplace;
    IERC20 public immutable usdc;
    uint256 public immutable deploymentTimestamp;

    uint256 public constant ACTIVATION_DELAY = 365 days;
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

    constructor(
        address _claimBond,
        address _bondVault,
        address _solvencyOracle,
        address _capacityOracle,
        address _marketplace,
        address _usdc,
        address _multisigOwner
    ) {
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
        deploymentTimestamp = block.timestamp;

        _grantRole(DEFAULT_ADMIN_ROLE, _multisigOwner);
        _grantRole(BUYBACK_OPERATOR_ROLE, _multisigOwner);
    }

    function setDailyBuyback(uint256 _budget, uint256 _maxPricePercent, uint256 _durationHours)
        external
        onlyRole(BUYBACK_OPERATOR_ROLE)
    {
        require(_isActivated(), "Not yet activated");
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
        require(_isActivated(), "Not yet activated");
        require(block.timestamp <= dailyConfig.validUntil, "Daily offer expired");

        (, uint256 epochId, uint256 amount, uint256 priceUSDC, bool active) = marketplace.getListing(listingId);
        require(active, "Listing not active");
        require(amount > 0, "Amount zero");

        uint256 faceValueUSD = claimBond.getFaceValue(epochId) * amount;
        uint256 maxAllowedPriceUSDC = (faceValueUSD * dailyConfig.maxPricePercent) / (100 * 1e12);
        require(priceUSDC <= maxAllowedPriceUSDC, "Price exceeds max");
        require(dailyConfig.spentToday + priceUSDC <= dailyConfig.dailyBudget, "Daily budget exceeded");

        usdc.forceApprove(address(marketplace), priceUSDC);
        marketplace.executeBuy(listingId);
        dailyConfig.spentToday += priceUSDC;

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

    function _isActivated() internal view returns (bool) {
        return block.timestamp >= deploymentTimestamp + ACTIVATION_DELAY;
    }

    function isActivated() external view returns (bool) {
        return _isActivated();
    }

    function timeUntilActivation() external view returns (uint256) {
        if (_isActivated()) return 0;
        return (deploymentTimestamp + ACTIVATION_DELAY) - block.timestamp;
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControl, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
