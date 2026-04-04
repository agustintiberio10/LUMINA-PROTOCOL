// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "../interfaces/IShield.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {BaseShield} from "./BaseShield.sol";

/**
 * @title BlackSwanShield
 * @author Lumina Protocol
 * @notice Catastrophic parametric insurance against >30% crash in BTC or ETH.
 *
 * PRODUCT: BLACKSWAN-001
 * RISK TYPE: VOLATILE
 * TRIGGER: Price drops >30% from the exact price at policy issuance block.
 *          Verified via oracle-signed TWAP proof (15 min or 3 consecutive Chainlink rounds).
 * PAYOUT: Binary — 80% of coverage (20% deductible).
 * DURATION: 7–30 days. No waiting period.
 * ASSET: ETH or BTC (selected at purchase via params.asset).
 *
 * ORACLE PROOF FORMAT:
 *   abi.encode(int256 verifiedPrice, bytes32 asset, uint256 verifiedAt, bytes signature)
 *   The off-chain oracle performs TWAP/3-round verification, signs the result.
 *   On-chain: verify signature, check verifiedPrice < triggerPrice.
 *
 * @dev Non-upgradeable. Extends BaseShield for shared policy management.
 */
contract BlackSwanShield is BaseShield {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    bytes32 public constant PRODUCT_ID = keccak256("BLACKSWAN-001");
    bytes32 public constant RISK_TYPE = keccak256("VOLATILE");

    uint16 public constant MAX_ALLOCATION_BPS = 2000;   // 20%
    uint32 public constant MIN_DURATION = 7 days;
    uint32 public constant MAX_DURATION = 30 days;
    // [FIX C-3] 1h waiting period. On Base L2 (2s blocks), this is ~1800 blocks.
    // Sufficient for technical front-running prevention. Macro speculation handled by oracle.
    uint32 public constant WAITING_PERIOD = 1 hours;

    uint256 public constant DEDUCTIBLE_BPS = 2000;       // 20% deductible → 80% max payout
    uint256 public constant TRIGGER_DROP_BPS = 3000;      // 30% drop
    uint256 private constant BPS = 10_000;

    /// @notice Max age of oracle proof (prevents stale proofs)
    uint256 public constant MAX_PROOF_AGE = 30 minutes;

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC STORAGE
    // ═══════════════════════════════════════════════════════════

    struct BSSData {
        bytes32 asset;          // "ETH" or "BTC"
        int256 strikePrice;     // Price at issuance (Chainlink 8 decimals)
        int256 triggerPrice;    // strikePrice × 70 / 100
    }

    mapping(uint256 => BSSData) private _bssData;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error InvalidAsset(bytes32 asset);
    error InvalidOracleProof();
    error ProofTooOld(uint256 verifiedAt, uint256 currentTime);
    error AssetMismatch(bytes32 policyAsset, bytes32 proofAsset);

    // ═══════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════

    constructor(
        address router_,
        address oracle_
    ) BaseShield(router_, oracle_) {}

    // ═══════════════════════════════════════════════════════════
    //  METADATA (IShield)
    // ═══════════════════════════════════════════════════════════

    function productId() external pure returns (bytes32) { return PRODUCT_ID; }
    function riskType() external pure returns (bytes32) { return RISK_TYPE; }
    function maxAllocationBps() external pure returns (uint16) { return MAX_ALLOCATION_BPS; }
    function durationRange() public pure returns (uint32, uint32) { return (MIN_DURATION, MAX_DURATION); }
    function waitingPeriod() public pure returns (uint32) { return WAITING_PERIOD; }

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC LOGIC (BaseShield overrides)
    // ═══════════════════════════════════════════════════════════

    function _doCreatePolicy(
        uint256 policyId,
        CreatePolicyParams calldata params
    ) internal override {
        // Validate asset is ETH or BTC
        if (params.asset != "ETH" && params.asset != "BTC") {
            revert InvalidAsset(params.asset);
        }

        // Get current price from oracle
        int256 currentPrice = IOracle(oracle).getLatestPrice(params.asset);
        if (currentPrice <= 0) revert InvalidOracleProof();

        // Calculate trigger price: strikePrice × (1 - 0.30) = strikePrice × 70 / 100
        int256 trigger = (currentPrice * 70) / 100;

        _bssData[policyId] = BSSData({
            asset: params.asset,
            strikePrice: currentPrice,
            triggerPrice: trigger
        });
    }

    function _doVerifyAndCalculate(
        uint256 policyId,
        bytes calldata oracleProof
    ) internal view override returns (PayoutResult memory result) {
        BSSData storage data = _bssData[policyId];
        CorePolicy storage cp = _policies[policyId];

        // Decode oracle proof
        (int256 verifiedPrice, bytes32 proofAsset, uint256 verifiedAt, bytes memory signature)
            = abi.decode(oracleProof, (int256, bytes32, uint256, bytes));

        // Verify signature
        bytes32 dataHash = keccak256(abi.encode(verifiedPrice, proofAsset, verifiedAt));
        if (!_verifyOracleSignature(dataHash, signature)) revert InvalidOracleProof();

        // Check proof freshness
        if (block.timestamp > verifiedAt + MAX_PROOF_AGE) {
            revert ProofTooOld(verifiedAt, block.timestamp);
        }

        // [FIX] Validate price is positive (defense-in-depth against oracle errors)
        if (verifiedPrice <= 0) revert InvalidOracleProof();

        // [FIX M-1] Event must have occurred during ACTIVE coverage period.
        // Uses waitingEndsAt (not startTimestamp) to enforce the 1h waiting period.
        // Events during waiting period are NOT covered — prevents front-running.
        if (verifiedAt < cp.waitingEndsAt || verifiedAt > cp.expiresAt) {
            revert EventAfterExpiry(policyId, verifiedAt, cp.expiresAt);
        }

        // Check asset matches
        if (proofAsset != data.asset) revert AssetMismatch(data.asset, proofAsset);

        // Check trigger: verified TWAP price must be below triggerPrice
        if (verifiedPrice >= data.triggerPrice) {
            revert TriggerNotMet(policyId, "PRICE_ABOVE_TRIGGER");
        }

        // Trigger met — binary payout at 80% of coverage
        result = PayoutResult({
            triggered: true,
            payoutAmount: cp.maxPayout,
            recipient: cp.insuredAgent,
            reason: "BLACKSWAN_CRASH"
        });
    }

    function _calculateMaxPayout(
        uint256 coverageAmount,
        CreatePolicyParams calldata /* params */
    ) internal pure override returns (uint256) {
        // 80% of coverage (20% deductible)
        return (coverageAmount * (BPS - DEDUCTIBLE_BPS)) / BPS;
    }

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC VIEWS
    // ═══════════════════════════════════════════════════════════

    function getBSSData(uint256 policyId) external view returns (BSSData memory) {
        if (_policies[policyId].insuredAgent == address(0)) revert PolicyNotFound(policyId);
        return _bssData[policyId];
    }
}
