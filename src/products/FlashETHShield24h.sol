// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "../interfaces/IShield.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {BaseShield} from "./BaseShield.sol";

/**
 * @title FlashETHShield24h
 * @author Lumina Protocol
 * @notice Parametric insurance: pays 80% if ETH drops >12% within 24 hours.
 *
 * PRODUCT: FLASHETH24-001
 * RISK TYPE: VOLATILE
 * TRIGGER: Price drops >12% from the exact price at policy issuance block.
 * PAYOUT: Binary — 80% of coverage (20% deductible).
 * DURATION: Fixed 24h. No waiting period.
 * ASSET: ETH only.
 *
 * @dev [H-1] IMPORTANT: Deploy with router_ = PolicyManagerV2 address (NOT CoverRouterV2).
 *      BaseShield.onlyRouter restricts createPolicy() to the router address.
 *      In V2, PolicyManagerV2 is the caller of createPolicy(), not CoverRouterV2.
 */
contract FlashETHShield24h is BaseShield {
    bytes32 public constant PRODUCT_ID = keccak256("FLASHETH24-001");
    bytes32 public constant RISK_TYPE = keccak256("VOLATILE");

    uint16 public constant MAX_ALLOCATION_BPS = 3000; // 30%
    uint32 public constant MIN_DURATION = 86400; // 1h
    uint32 public constant MAX_DURATION = 86400; // 1h (fixed)
    uint32 public constant WAITING_PERIOD = 0;

    uint256 public constant DEDUCTIBLE_BPS = 2000; // 20% deductible → 80% max payout
    uint256 public constant TRIGGER_DROP_BPS = 1200; // 12% drop
    uint256 private constant BPS = 10_000;

    uint256 public constant MAX_PROOF_AGE = 900; // 15 minutes

    struct BSSData {
        bytes32 asset; // "ETH"
        int256 strikePrice;
        int256 triggerPrice; // strikePrice × (100 - 7) / 100
    }

    mapping(uint256 => BSSData) private _bssData;

    error InvalidAsset(bytes32 asset);
    error InvalidOracleProof();
    error ProofTooOld(uint256 verifiedAt, uint256 currentTime);
    error AssetMismatch(bytes32 policyAsset, bytes32 proofAsset);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address router_, address oracle_) public initializer {
        __BaseShield_init(router_, oracle_);
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
        if (params.asset != "ETH") revert InvalidAsset(params.asset);

        int256 currentPrice = IOracle(oracle).getLatestPrice(params.asset);
        if (currentPrice <= 0) revert InvalidOracleProof();

        // Trigger: strikePrice × (100 - 12) / 100
        int256 trigger = (currentPrice * int256(BPS - TRIGGER_DROP_BPS)) / int256(BPS);

        _bssData[policyId] = BSSData({asset: params.asset, strikePrice: currentPrice, triggerPrice: trigger});
    }

    function _doVerifyAndCalculate(uint256 policyId, bytes calldata oracleProof)
        internal
        view
        override
        returns (PayoutResult memory result)
    {
        BSSData storage data = _bssData[policyId];
        CorePolicy storage cp = _policies[policyId];

        (int256 verifiedPrice, bytes32 proofAsset, uint256 verifiedAt, bytes memory signature) =
            abi.decode(oracleProof, (int256, bytes32, uint256, bytes));

        if (!_verifyPriceProofEIP712(verifiedPrice, proofAsset, verifiedAt, signature)) {
            revert InvalidOracleProof();
        }

        if (block.timestamp > verifiedAt + MAX_PROOF_AGE) {
            revert ProofTooOld(verifiedAt, block.timestamp);
        }

        if (verifiedPrice <= 0) revert InvalidOracleProof();

        if (verifiedAt < cp.waitingEndsAt || verifiedAt > cp.expiresAt) {
            revert EventAfterExpiry(policyId, verifiedAt, cp.expiresAt);
        }

        if (proofAsset != data.asset) revert AssetMismatch(data.asset, proofAsset);

        if (verifiedPrice >= data.triggerPrice) {
            revert TriggerNotMet(policyId, "PRICE_ABOVE_TRIGGER");
        }

        result = PayoutResult({
            triggered: true, payoutAmount: cp.maxPayout, recipient: cp.insuredAgent, reason: "FLASHETH24_DROP12"
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
        BSSData storage data = _bssData[policyId];
        int256 currentPrice = IOracle(oracle).getLatestPrice(data.asset);
        return currentPrice > 0 && currentPrice <= data.triggerPrice;
    }

    function getBSSData(uint256 policyId) external view returns (BSSData memory) {
        if (_policies[policyId].insuredAgent == address(0)) revert PolicyNotFound(policyId);
        return _bssData[policyId];
    }

    uint256[50] private __gap_shield;
}
