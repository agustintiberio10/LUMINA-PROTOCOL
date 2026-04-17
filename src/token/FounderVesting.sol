// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FounderVesting
/// @notice 10M LUMINA locked until AltSeason conditions or 4-year fallback.
/// @dev Conditions (2-of-3 sustained 7 days):
///      A: ETH/BTC > 0.050
///      B: ETH > $4,000
///      C: Aave V3 USDC borrow rate > 7% APY
///      Release: 3 tranches every 31 days after trigger.
///      Fallback: 1460 days from deploy if conditions never trigger.

interface ILuminaOracleReader {
    function getLatestPrice(bytes32 asset) external view returns (int256);
}

interface IAaveV3PoolReader {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }
    function getReserveData(address asset) external view returns (ReserveData memory);
}

contract FounderVesting is Ownable {
    // ═══════ CONSTANTS ═══════
    uint256 public constant ETH_BTC_THRESHOLD = 50e15; // 0.050 in 18 decimals
    int256 public constant ETH_USD_THRESHOLD = 400_000_000_000; // $4,000 in 8 decimals
    uint256 public constant BORROW_RATE_THRESHOLD = 7e25; // 7% APY in RAY (27 decimals)
    uint256 public constant SUSTAINED_DURATION = 7 days;
    uint256 public constant TRANCHE_INTERVAL = 31 days;
    uint256 public constant TOTAL_TRANCHES = 3;
    uint256 public constant FALLBACK_DURATION = 1460 days; // 4 years
    uint256 public constant TOTAL_AMOUNT = 8_000_000 * 1e18; // 10M LUMINA
    uint256 public constant TRANCHE_AMOUNT = TOTAL_AMOUNT / TOTAL_TRANCHES; // ~3.333M per tranche

    // ═══════ IMMUTABLES ═══════
    ILuminaOracleReader public immutable oracle;
    address public immutable aavePool;
    IERC20 public immutable luminaToken;
    address public immutable usdc;
    uint256 public immutable deployedAt;

    // ═══════ STATE ═══════
    address public recipient;
    uint256 public conditionsMetSince;
    bool public altSeasonTriggered;
    uint256 public triggerTimestamp;
    uint256 public tranchesReleased;
    uint256 public totalReleased;

    // ═══════ EVENTS ═══════
    event ConditionsChecked(bool condA, bool condB, bool condC, uint256 metCount, uint256 timestamp);
    event SustainedPeriodStarted(uint256 timestamp);
    event SustainedPeriodReset(uint256 timestamp);
    event AltSeasonTriggered(uint256 timestamp);
    event TrancheReleased(uint256 trancheNumber, uint256 amount, address recipient);
    event RecipientUpdated(address oldRecipient, address newRecipient);
    event FallbackTriggered(uint256 timestamp);

    constructor(address _oracle, address _aavePool, address _luminaToken, address _usdc, address _recipient)
        Ownable(msg.sender)
    {
        require(_oracle != address(0), "Zero oracle");
        require(_aavePool != address(0), "Zero aavePool");
        require(_luminaToken != address(0), "Zero token");
        require(_usdc != address(0), "Zero usdc");
        require(_recipient != address(0), "Zero recipient");

        oracle = ILuminaOracleReader(_oracle);
        aavePool = _aavePool;
        luminaToken = IERC20(_luminaToken);
        usdc = _usdc;
        recipient = _recipient;
        deployedAt = block.timestamp;
    }

    // ═══════ CORE: checkAltSeason() ═══════
    function checkAltSeason() external {
        require(!altSeasonTriggered, "Already triggered");

        (bool condA, bool condB, bool condC) = _evaluateConditions();
        uint256 metCount = (condA ? 1 : 0) + (condB ? 1 : 0) + (condC ? 1 : 0);

        emit ConditionsChecked(condA, condB, condC, metCount, block.timestamp);

        if (metCount >= 2) {
            if (conditionsMetSince == 0) {
                conditionsMetSince = block.timestamp;
                emit SustainedPeriodStarted(block.timestamp);
            } else if (block.timestamp - conditionsMetSince >= SUSTAINED_DURATION) {
                altSeasonTriggered = true;
                triggerTimestamp = block.timestamp;
                emit AltSeasonTriggered(block.timestamp);
            }
        } else {
            if (conditionsMetSince != 0) {
                emit SustainedPeriodReset(block.timestamp);
            }
            conditionsMetSince = 0;
        }
    }

    // ═══════ triggerFallback() ═══════
    function triggerFallback() external {
        require(!altSeasonTriggered, "Already triggered");
        require(block.timestamp >= deployedAt + FALLBACK_DURATION, "Fallback not reached");

        altSeasonTriggered = true;
        triggerTimestamp = block.timestamp;
        emit FallbackTriggered(block.timestamp);
    }

    // ═══════ releaseTranche() ═══════
    function releaseTranche() external {
        require(altSeasonTriggered, "Not triggered");
        require(tranchesReleased < TOTAL_TRANCHES, "All tranches released");

        uint256 nextTranche = tranchesReleased;
        uint256 releaseTime = triggerTimestamp + (nextTranche * TRANCHE_INTERVAL);
        require(block.timestamp >= releaseTime, "Too early");

        tranchesReleased++;

        // Last tranche gets the remainder to avoid rounding dust
        uint256 amount = (nextTranche == TOTAL_TRANCHES - 1) ? TOTAL_AMOUNT - totalReleased : TRANCHE_AMOUNT;

        totalReleased += amount;
        require(luminaToken.transfer(recipient, amount), "Transfer failed");

        emit TrancheReleased(tranchesReleased, amount, recipient);
    }

    // ═══════ updateRecipient() ═══════
    function updateRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Zero address");
        address old = recipient;
        recipient = newRecipient;
        emit RecipientUpdated(old, newRecipient);
    }

    // ═══════ VIEW FUNCTIONS ═══════
    function getConditions() external view returns (bool condA, bool condB, bool condC) {
        return _evaluateConditions();
    }

    function getStatus()
        external
        view
        returns (
            bool triggered,
            uint256 _triggerTimestamp,
            uint256 _tranchesReleased,
            uint256 _totalReleased,
            uint256 _conditionsMetSince,
            uint256 nextReleaseAt,
            uint256 fallbackAt
        )
    {
        triggered = altSeasonTriggered;
        _triggerTimestamp = triggerTimestamp;
        _tranchesReleased = tranchesReleased;
        _totalReleased = totalReleased;
        _conditionsMetSince = conditionsMetSince;
        fallbackAt = deployedAt + FALLBACK_DURATION;
        if (altSeasonTriggered && tranchesReleased < TOTAL_TRANCHES) {
            nextReleaseAt = triggerTimestamp + (tranchesReleased * TRANCHE_INTERVAL);
        }
    }

    // ═══════ INTERNAL ═══════
    function _evaluateConditions() internal view returns (bool condA, bool condB, bool condC) {
        try oracle.getLatestPrice(bytes32("ETH")) returns (int256 ethPrice) {
            try oracle.getLatestPrice(bytes32("BTC")) returns (int256 btcPrice) {
                if (ethPrice > 0 && btcPrice > 0) {
                    uint256 ethBtcRatio = uint256(ethPrice) * 1e18 / uint256(btcPrice);
                    condA = ethBtcRatio > ETH_BTC_THRESHOLD;
                    condB = ethPrice > ETH_USD_THRESHOLD;
                }
            } catch {}
        } catch {}

        try IAaveV3PoolReader(aavePool).getReserveData(usdc) returns (IAaveV3PoolReader.ReserveData memory data) {
            condC = uint256(data.currentVariableBorrowRate) > BORROW_RATE_THRESHOLD;
        } catch {}
    }
}
