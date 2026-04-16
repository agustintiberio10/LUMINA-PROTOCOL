// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "../../interfaces/IShield.sol";
import {IOracle} from "../../interfaces/IOracle.sol";
import {BaseShield} from "../../products/BaseShield.sol";

/**
 * @title MicroDepegShield
 * @author Lumina Protocol
 * @notice Parametric insurance: pays 80% if USDT trades below $0.995 during the 7 day window.
 *
 * PRODUCT: MICRODEPEG-001
 * RISK TYPE: STABLE
 * TRIGGER: USDT absolute price < $0.995 (Chainlink 8 decimals: 99_500_000).
 *          Does NOT depend on strike price at issuance — absolute threshold.
 * PAYOUT: Binary — 80% of coverage (20% deductible).
 * DURATION: Fixed 7 days. No waiting period.
 * ASSET: USDT only.
 */
contract MicroDepegShield is BaseShield {
    bytes32 public constant PRODUCT_ID = keccak256("MICRODEPEG-001");
    bytes32 public constant RISK_TYPE = keccak256("STABLE");

    uint16 public constant MAX_ALLOCATION_BPS = 3000; // 30%
    uint32 public constant MIN_DURATION = 604800; // 7 days
    uint32 public constant MAX_DURATION = 604800; // 7 days (fixed)
    uint32 public constant WAITING_PERIOD = 0;

    uint256 public constant DEDUCTIBLE_BPS = 2000; // 20% deductible → 80% max payout
    int256 public constant TRIGGER_PRICE = 99_500_000; // $0.995 in Chainlink 8 decimals
    uint256 private constant BPS = 10_000;

    uint256 public constant MAX_PROOF_AGE = 900; // 15 minutes

    struct DepegData {
        bytes32 asset; // "USDT"
    }

    mapping(uint256 => DepegData) private _depegData;

    error InvalidAsset(bytes32 asset);
    error InvalidOracleProof();
    error ProofTooOld(uint256 verifiedAt, uint256 currentTime);
    error AssetMismatch(bytes32 policyAsset, bytes32 proofAsset);

    constructor(address router_, address oracle_) BaseShield(router_, oracle_) {}

    function productId() external pure returns (bytes32) { return PRODUCT_ID; }
    function riskType() external pure returns (bytes32) { return RISK_TYPE; }
    function maxAllocationBps() external pure returns (uint16) { return MAX_ALLOCATION_BPS; }
    function durationRange() public pure returns (uint32, uint32) { return (MIN_DURATION, MAX_DURATION); }
    function waitingPeriod() public pure returns (uint32) { return WAITING_PERIOD; }

    function _doCreatePolicy(uint256 policyId, CreatePolicyParams calldata params) internal override {
        if (params.asset != "USDT") revert InvalidAsset(params.asset);

        // No strike price calculation — trigger is absolute ($0.995).
        _depegData[policyId] = DepegData({asset: params.asset});
    }

    function _doVerifyAndCalculate(uint256 policyId, bytes calldata oracleProof)
        internal
        view
        override
        returns (PayoutResult memory result)
    {
        DepegData storage data = _depegData[policyId];
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

        // Absolute price trigger: USDT below $0.995
        if (verifiedPrice >= TRIGGER_PRICE) {
            revert TriggerNotMet(policyId, "PRICE_ABOVE_TRIGGER");
        }

        result = PayoutResult({
            triggered: true,
            payoutAmount: cp.maxPayout,
            recipient: cp.insuredAgent,
            reason: "MICRODEPEG_USDT_BELOW_995"
        });
    }

    function _calculateMaxPayout(uint256 coverageAmount, CreatePolicyParams calldata /* params */)
        internal pure override returns (uint256)
    {
        return (coverageAmount * (BPS - DEDUCTIBLE_BPS)) / BPS;
    }

    function getDepegData(uint256 policyId) external view returns (DepegData memory) {
        if (_policies[policyId].insuredAgent == address(0)) revert PolicyNotFound(policyId);
        return _depegData[policyId];
    }
}
