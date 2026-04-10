// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ILuminaOracle} from "./interfaces/ILuminaOracle.sol";
import {IAaveV3Pool} from "./interfaces/IAaveV3Pool.sol";

contract AltSeasonVesting is Ownable {
    // ═══════ CONSTANTS ═══════
    uint256 public constant ETH_BTC_THRESHOLD = 50e15; // 0.050 in 18 decimals
    int256 public constant ETH_USD_THRESHOLD = 400_000_000_000; // $4,000 in 8 decimals
    uint256 public constant BORROW_RATE_THRESHOLD = 7e25; // 7% APY in RAY (27 decimals)
    uint256 public constant SUSTAINED_DURATION = 7 days;
    uint256 public constant TRANCHE_INTERVAL = 31 days;
    uint256 public constant TOTAL_TRANCHES = 3;

    // ═══════ IMMUTABLES ═══════
    ILuminaOracle public immutable oracle;
    address public immutable aavePool;
    IERC20 public immutable luminaToken;
    address public immutable usdc;

    // ═══════ STATE ═══════
    uint256 public conditionsMetSince;
    bool public altSeasonTriggered;
    uint256 public triggerTimestamp;
    uint256 public tranchesReleased;

    struct Allocation {
        address recipient;
        uint256 totalAmount;
        uint256 released;
    }

    Allocation[] public allocations;

    // ═══════ EVENTS ═══════
    event ConditionsChecked(bool condA, bool condB, bool condC, uint256 metCount, uint256 timestamp);
    event SustainedPeriodStarted(uint256 timestamp);
    event SustainedPeriodReset(uint256 timestamp);
    event AltSeasonTriggered(uint256 timestamp);
    event TrancheReleased(uint256 trancheNumber, uint256 totalReleased);
    event RecipientUpdated(uint256 indexed index, address oldRecipient, address newRecipient);

    constructor(
        address _oracle,
        address _aavePool,
        address _luminaToken,
        address _usdc,
        address[] memory _recipients,
        uint256[] memory _amounts
    ) Ownable(msg.sender) {
        require(_recipients.length == _amounts.length, "Length mismatch");
        require(_recipients.length == 7, "Must have 7 allocations");

        oracle = ILuminaOracle(_oracle);
        aavePool = _aavePool;
        luminaToken = IERC20(_luminaToken);
        usdc = _usdc;

        uint256 total;
        for (uint256 i = 0; i < _recipients.length; i++) {
            require(_recipients[i] != address(0), "Zero recipient");
            require(_amounts[i] > 0, "Zero amount");
            allocations.push(Allocation({recipient: _recipients[i], totalAmount: _amounts[i], released: 0}));
            total += _amounts[i];
        }
        require(total == 65_000_000 * 1e18, "Must be 65M total");
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

    // ═══════ releaseTranche() ═══════

    function releaseTranche() external {
        require(altSeasonTriggered, "Alt season not triggered");
        require(tranchesReleased < TOTAL_TRANCHES, "All tranches released");

        uint256 nextTranche = tranchesReleased;
        uint256 releaseTime = triggerTimestamp + (nextTranche * TRANCHE_INTERVAL);
        require(block.timestamp >= releaseTime, "Too early for this tranche");

        tranchesReleased++;

        for (uint256 i = 0; i < allocations.length; i++) {
            Allocation storage alloc = allocations[i];
            uint256 trancheAmount = alloc.totalAmount / TOTAL_TRANCHES;

            if (nextTranche == TOTAL_TRANCHES - 1) {
                trancheAmount = alloc.totalAmount - alloc.released;
            }

            if (trancheAmount > 0) {
                alloc.released += trancheAmount;
                require(luminaToken.transfer(alloc.recipient, trancheAmount), "Transfer failed");
            }
        }

        emit TrancheReleased(nextTranche + 1, tranchesReleased);
    }

    // ═══════ updateRecipient() ═══════

    function updateRecipient(uint256 index, address newRecipient) external onlyOwner {
        require(index < allocations.length, "Invalid index");
        require(newRecipient != address(0), "Zero address");
        address oldRecipient = allocations[index].recipient;
        allocations[index].recipient = newRecipient;
        emit RecipientUpdated(index, oldRecipient, newRecipient);
    }

    // ═══════ VIEW FUNCTIONS ═══════

    function getConditions() external view returns (bool condA, bool condB, bool condC) {
        return _evaluateConditions();
    }

    function getConditionValues() external view returns (uint256 ethBtcRatio, int256 ethPrice, uint256 borrowRate) {
        int256 _ethPrice = oracle.getLatestPrice(bytes32("ETH"));
        int256 btcPrice = oracle.getLatestPrice(bytes32("BTC"));
        ethBtcRatio = uint256(_ethPrice) * 1e18 / uint256(btcPrice);
        ethPrice = _ethPrice;
        borrowRate = _getAaveBorrowRate();
    }

    function getStatus()
        external
        view
        returns (
            bool triggered,
            uint256 _triggerTimestamp,
            uint256 _tranchesReleased,
            uint256 _conditionsMetSince,
            uint256 nextReleaseAt
        )
    {
        triggered = altSeasonTriggered;
        _triggerTimestamp = triggerTimestamp;
        _tranchesReleased = tranchesReleased;
        _conditionsMetSince = conditionsMetSince;
        if (altSeasonTriggered && tranchesReleased < TOTAL_TRANCHES) {
            nextReleaseAt = triggerTimestamp + (tranchesReleased * TRANCHE_INTERVAL);
        }
    }

    function getAllocation(uint256 index)
        external
        view
        returns (address recipient, uint256 totalAmount, uint256 released)
    {
        Allocation memory alloc = allocations[index];
        return (alloc.recipient, alloc.totalAmount, alloc.released);
    }

    function getAllocationsCount() external view returns (uint256) {
        return allocations.length;
    }

    // ═══════ INTERNAL ═══════

    function _evaluateConditions() internal view returns (bool condA, bool condB, bool condC) {
        // Condition A: ETH/BTC > 0.050
        int256 ethPrice = oracle.getLatestPrice(bytes32("ETH"));
        int256 btcPrice = oracle.getLatestPrice(bytes32("BTC"));
        require(ethPrice > 0 && btcPrice > 0, "Invalid oracle prices");
        uint256 ethBtcRatio = uint256(ethPrice) * 1e18 / uint256(btcPrice);
        condA = ethBtcRatio > ETH_BTC_THRESHOLD;

        // Condition B: ETH > $4,000
        condB = ethPrice > ETH_USD_THRESHOLD;

        // Condition C: Aave V3 USDC borrow rate > 7%
        uint256 borrowRate = _getAaveBorrowRate();
        condC = borrowRate > BORROW_RATE_THRESHOLD;
    }

    function _getAaveBorrowRate() internal view returns (uint256) {
        IAaveV3Pool.ReserveData memory data = IAaveV3Pool(aavePool).getReserveData(usdc);
        return uint256(data.currentVariableBorrowRate);
    }
}
