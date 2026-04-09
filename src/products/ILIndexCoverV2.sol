// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "../interfaces/IShield.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {BaseShield} from "./BaseShield.sol";
import {ILMath} from "../libraries/ILMath.sol";

/**
 * @title ILIndexCoverV2
 * @author Lumina Protocol
 * @notice Parametric insurance against Impermanent Loss for AMM LPs.
 *         Standard IL Index (Uniswap V2 formula, 50/50 pools).
 *
 * PRODUCT: ILPROT-001
 * RISK TYPE: VOLATILE
 * TRIGGER: IL% > 2% at expiry (restable deductible — first 2% is subtracted).
 * PAYOUT: PROPORTIONAL — Coverage × max(0, IL% - 2%) × 90%, capped at 11.7% of coverage.
 * RESOLUTION: European-style — ONLY within 48h window after expiry.
 *             No early exercise. Prevents American-option arbitrage.
 * DURATION: 14–90 days. No waiting period (trigger relative to purchase price).
 * ASSET: ETH/USD.
 *
 * IL FORMULA (on-chain via ILMath library):
 *   r = priceAtExpiry / priceAtPurchase
 *   IL = 1 - 2√r / (1 + r)
 *   IL_net = max(0, IL - 0.02)
 *   payout = min(coverage × IL_net × 0.90, coverage × 0.117)
 *
 * ORACLE PROOF FORMAT:
 *   abi.encode(int256 verifiedPrice, bytes32 proofAsset, uint256 verifiedAt, bytes signature)
 *   verifiedPrice = ETH/USD at settlement time. Verified via EIP-712 typed
 *   PriceProof signed by the oracle backend over the latest Chainlink round.
 *   Signature verification is EIP-712 domain-separated
 *   (LuminaOracleV2.verifyPriceProofEIP712).
 *   proofAsset = "ETH" (bound to prevent cross-asset replay)
 *
 * @dev Non-upgradeable. Extends BaseShield. Uses ILMath for sqrt and IL calculation.
 */
contract ILIndexCoverV2 is BaseShield {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    bytes32 public constant PRODUCT_ID = keccak256("ILPROT-001");
    bytes32 public constant RISK_TYPE = keccak256("VOLATILE");

    uint16 public constant MAX_ALLOCATION_BPS = 2000;    // 20%
    uint32 public constant MIN_DURATION = 14 days;
    uint32 public constant MAX_DURATION = 90 days;
    uint32 public constant WAITING_PERIOD_ = 0;          // No waiting (trigger is relative)
    uint32 public constant SETTLEMENT_WINDOW = 48 hours;

    /// @notice Deductible: 2% restable (200 BPS)
    uint256 public constant DEDUCTIBLE_BPS = 200;

    /// @notice Payout factor: 90% (9000 BPS)
    uint256 public constant PAYOUT_FACTOR_BPS = 9000;

    /// @notice Max payout cap: 11.7% of coverage (coverage × 13% IL_net × 90%)
    /// @dev Stored as BPS of coverage: 1170
    uint256 public constant MAX_PAYOUT_BPS = 1170;

    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_PROOF_AGE = 30 minutes;

    /// @notice Precision for IL calculations (1e18)
    uint256 private constant WAD = 1e18;

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC STORAGE
    // ═══════════════════════════════════════════════════════════

    struct ILData {
        int256 strikePrice;     // ETH/USD at policy issuance (Chainlink 8 decimals)
    }

    mapping(uint256 => ILData) private _ilData;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error InvalidOracleProof();
    error ProofTooOld(uint256 verifiedAt, uint256 currentTime);
    error InvalidPrice(int256 price);

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
    function waitingPeriod() public pure returns (uint32) { return WAITING_PERIOD_; }

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC LOGIC
    // ═══════════════════════════════════════════════════════════

    function _doCreatePolicy(
        uint256 policyId,
        CreatePolicyParams calldata params
    ) internal override {
        // Validate asset is ETH (BTC extension future)
        if (params.asset != "ETH") revert InvalidPrice(0);

        // Get current ETH price from oracle
        int256 currentPrice = IOracle(oracle).getLatestPrice(params.asset);
        if (currentPrice <= 0) revert InvalidPrice(currentPrice);

        _ilData[policyId] = ILData({
            strikePrice: currentPrice
        });
    }

    function _doVerifyAndCalculate(
        uint256 policyId,
        bytes calldata oracleProof
    ) internal view override returns (PayoutResult memory result) {
        ILData storage data = _ilData[policyId];
        CorePolicy storage cp = _policies[policyId];

        // [FIX] Decode oracle proof WITH asset identifier.
        // Previously missing asset binding — cross-asset proof replay was possible.
        (int256 verifiedPrice, bytes32 proofAsset, uint256 verifiedAt, bytes memory signature)
            = abi.decode(oracleProof, (int256, bytes32, uint256, bytes));

        // [V2] Verify EIP-712 typed PriceProof signature (domain-separated)
        if (!_verifyPriceProofEIP712(verifiedPrice, proofAsset, verifiedAt, signature)) {
            revert InvalidOracleProof();
        }

        // Check proof freshness
        if (block.timestamp > verifiedAt + MAX_PROOF_AGE) {
            revert ProofTooOld(verifiedAt, block.timestamp);
        }

        // [FIX] Validate asset is ETH
        if (proofAsset != "ETH") revert InvalidPrice(0);

        // [FIX] For IL (European-style): verifiedAt must be within settlement window
        // (after expiry, before cleanup). The SETTLEMENT status check in
        // _validateStatusForTrigger already handles this, but defense-in-depth.
        if (verifiedAt < cp.expiresAt || verifiedAt > cp.cleanupAt) {
            revert EventAfterExpiry(policyId, verifiedAt, cp.cleanupAt);
        }

        // Validate prices
        if (verifiedPrice <= 0) revert InvalidPrice(verifiedPrice);
        if (data.strikePrice <= 0) revert InvalidPrice(data.strikePrice);

        // Calculate IL using ILMath library
        // priceRatio in WAD = (verifiedPrice * WAD) / strikePrice
        uint256 priceAtExpiry = uint256(verifiedPrice);
        uint256 priceAtPurchase = uint256(data.strikePrice);

        // [FIX C-1] Convert WAD (1e18=100%) to BPS (10000=100%)
        uint256 ilBps = ILMath.calculateIL(priceAtExpiry, priceAtPurchase) * BPS / WAD;

        // Apply restable deductible: IL_net = max(0, IL - 2%)
        if (ilBps <= DEDUCTIBLE_BPS) {
            // IL below deductible — no payout
            result = PayoutResult({
                triggered: false,
                payoutAmount: 0,
                recipient: cp.insuredAgent,
                reason: "IL_BELOW_DEDUCTIBLE"
            });
            return result;
        }

        uint256 ilNetBps = ilBps - DEDUCTIBLE_BPS;

        // Calculate payout: coverage × IL_net × 90%
        // All in BPS: payout = coverageAmount × ilNetBps × PAYOUT_FACTOR_BPS / (BPS × BPS)
        uint256 payout = (cp.coverageAmount * ilNetBps * PAYOUT_FACTOR_BPS) / (BPS * BPS);

        // Cap at maxPayout
        if (payout > cp.maxPayout) {
            payout = cp.maxPayout;
        }

        result = PayoutResult({
            triggered: true,
            payoutAmount: payout,
            recipient: cp.insuredAgent,
            reason: "IMPERMANENT_LOSS"
        });
    }

    function _calculateMaxPayout(
        uint256 coverageAmount,
        CreatePolicyParams calldata /* params */
    ) internal pure override returns (uint256) {
        // Cap: coverage × 13% net IL × 90% = coverage × 11.7%
        return (coverageAmount * MAX_PAYOUT_BPS) / BPS;
    }

    /// @dev IL Index has 48h settlement window after expiry
    function _calculateCleanupAt(uint256 expiresAt) internal pure override returns (uint256) {
        return expiresAt + SETTLEMENT_WINDOW;
    }

    /// @dev IL Index uses settlement window
    function _hasSettlementWindow() internal pure override returns (bool) {
        return true;
    }

    /// @dev IL Index trigger requires SETTLEMENT status (European-style)
    function _validateStatusForTrigger(uint256 policyId, PolicyStatus current) internal view override {
        if (current != PolicyStatus.SETTLEMENT) {
            revert InvalidPolicyStatus(policyId, current, PolicyStatus.SETTLEMENT);
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC VIEWS
    // ═══════════════════════════════════════════════════════════

    function getILData(uint256 policyId) external view returns (ILData memory) {
        if (_policies[policyId].insuredAgent == address(0)) revert PolicyNotFound(policyId);
        return _ilData[policyId];
    }

    /**
     * @notice Preview IL calculation for a given current price against a policy's strike
     * @param policyId The policy to preview
     * @param currentPrice Current ETH price in Chainlink 8 decimals
     * @return ilBps IL in basis points
     * @return ilNetBps IL net of deductible in basis points
     * @return estimatedPayout Estimated payout in USDC (6 decimals)
     */
    function previewIL(
        uint256 policyId,
        uint256 currentPrice
    ) external view returns (uint256 ilBps, uint256 ilNetBps, uint256 estimatedPayout) {
        ILData storage data = _ilData[policyId];
        CorePolicy storage cp = _policies[policyId];
        if (cp.insuredAgent == address(0)) revert PolicyNotFound(policyId);

        // [FIX C-1] Convert WAD to BPS
        ilBps = ILMath.calculateIL(currentPrice, uint256(data.strikePrice)) * BPS / WAD;
        ilNetBps = ilBps > DEDUCTIBLE_BPS ? ilBps - DEDUCTIBLE_BPS : 0;

        if (ilNetBps > 0) {
            estimatedPayout = (cp.coverageAmount * ilNetBps * PAYOUT_FACTOR_BPS) / (BPS * BPS);
            if (estimatedPayout > cp.maxPayout) {
                estimatedPayout = cp.maxPayout;
            }
        }
    }
}
