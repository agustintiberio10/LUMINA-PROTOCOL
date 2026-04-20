// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "../interfaces/IShield.sol";
import {BaseShield} from "./BaseShield.sol";

/**
 * @title RateShockShield
 * @author Lumina Protocol
 * @notice Parametric insurance: pays 80% if Aave V3 USDC variable borrow rate exceeds 10% APY
 *         during the 7 day window.
 *
 * PRODUCT: RATESHOCK-001
 * RISK TYPE: RATE
 * TRIGGER: Aave V3 `getReserveData(USDC).currentVariableBorrowRate` > 10% APY (RAY, 27 decimals).
 *          Verified ON-CHAIN — no oracle proof required. Aave rates are first-class on-chain data.
 * PAYOUT: Binary — 80% of coverage (20% deductible).
 * DURATION: Fixed 7 days. No waiting period.
 * ASSET: USDC (for reference only; does not read Chainlink).
 *
 * @dev [H-1] IMPORTANT: Deploy with router_ = PolicyManagerV2 address (NOT CoverRouterV2).
 *      BaseShield.onlyRouter restricts createPolicy() to the router address.
 *      In V2, PolicyManagerV2 is the caller of createPolicy(), not CoverRouterV2.
 */

interface IAaveV3Pool {
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

contract RateShockShield is BaseShield {
    bytes32 public constant PRODUCT_ID = keccak256("RATESHOCK-001");
    bytes32 public constant RISK_TYPE = keccak256("RATE");

    uint16 public constant MAX_ALLOCATION_BPS = 3000; // 30%
    uint32 public constant MIN_DURATION = 604800; // 7 days
    uint32 public constant MAX_DURATION = 604800; // 7 days (fixed)
    uint32 public constant WAITING_PERIOD = 0;

    uint256 public constant DEDUCTIBLE_BPS = 2000; // 20% deductible → 80% max payout
    uint256 public constant TRIGGER_RATE = 10e25; // 10% APY in RAY (27 decimals)
    uint256 private constant BPS = 10_000;

    /// @notice Aave V3 Pool (Base mainnet) — set at construction
    IAaveV3Pool public immutable aavePool;
    /// @notice USDC reserve asset on Base
    address public immutable usdc;

    struct RateShockData {
        bytes32 asset; // "USDC" (reference)
        uint256 policyStart; // timestamp of issuance — trigger must fire during coverage window
    }

    mapping(uint256 => RateShockData) private _rateData;

    error InvalidAsset(bytes32 asset);
    error RateBelowTrigger(uint256 currentRate);

    constructor(address router_, address oracle_, address _aavePool, address _usdc) BaseShield(router_, oracle_) {
        require(_aavePool != address(0), "Zero aavePool");
        require(_usdc != address(0), "Zero usdc");
        aavePool = IAaveV3Pool(_aavePool);
        usdc = _usdc;
    }

    function productId() external pure returns (bytes32) {
        return PRODUCT_ID;
    }

    function riskType() external pure returns (bytes32) {
        return RISK_TYPE;
    }

    function maxAllocationBps() external pure returns (uint16) {
        return MAX_ALLOCATION_BPS;
    }

    function durationRange() public pure returns (uint32, uint32) {
        return (MIN_DURATION, MAX_DURATION);
    }

    function waitingPeriod() public pure returns (uint32) {
        return WAITING_PERIOD;
    }

    function _doCreatePolicy(uint256 policyId, CreatePolicyParams calldata params) internal override {
        if (params.asset != "USDC") revert InvalidAsset(params.asset);

        // No price reading. Just store policy start timestamp.
        _rateData[policyId] = RateShockData({asset: params.asset, policyStart: block.timestamp});
    }

    function _doVerifyAndCalculate(
        uint256 policyId,
        bytes calldata /* oracleProof */
    )
        internal
        view
        override
        returns (PayoutResult memory result)
    {
        CorePolicy storage cp = _policies[policyId];

        // Policy must be inside its active coverage window.
        if (block.timestamp < cp.waitingEndsAt || block.timestamp > cp.expiresAt) {
            revert EventAfterExpiry(policyId, block.timestamp, cp.expiresAt);
        }

        // Read Aave V3 reserve data directly on-chain (no oracle proof needed).
        IAaveV3Pool.ReserveData memory reserve = aavePool.getReserveData(usdc);
        uint256 currentRate = uint256(reserve.currentVariableBorrowRate);

        if (currentRate <= TRIGGER_RATE) {
            revert RateBelowTrigger(currentRate);
        }

        result = PayoutResult({
            triggered: true,
            payoutAmount: cp.maxPayout,
            recipient: cp.insuredAgent,
            reason: "RATESHOCK_AAVE_USDC_ABOVE_10"
        });
    }

    function _calculateMaxPayout(
        uint256 coverageAmount,
        CreatePolicyParams calldata /* params */
    )
        internal
        pure
        override
        returns (uint256)
    {
        return (coverageAmount * (BPS - DEDUCTIBLE_BPS)) / BPS;
    }

    function _checkTriggerCondition(uint256 policyId) internal view override returns (bool) {
        // Suppress unused variable warning — RateShock doesn't need policy-specific data
        policyId;
        // Read Aave V3 reserve data directly on-chain
        IAaveV3Pool.ReserveData memory reserve = aavePool.getReserveData(usdc);
        uint256 currentRate = uint256(reserve.currentVariableBorrowRate);
        return currentRate > TRIGGER_RATE;
    }

    function getRateShockData(uint256 policyId) external view returns (RateShockData memory) {
        if (_policies[policyId].insuredAgent == address(0)) revert PolicyNotFound(policyId);
        return _rateData[policyId];
    }

    /// @notice Current Aave V3 USDC variable borrow rate (RAY, 27 decimals). Informational.
    function currentBorrowRate() external view returns (uint256) {
        return uint256(aavePool.getReserveData(usdc).currentVariableBorrowRate);
    }
}
