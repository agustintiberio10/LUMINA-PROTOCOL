// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "../interfaces/IShield.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {BaseShield} from "./BaseShield.sol";

/**
 * @title DepegShield
 * @author Lumina Protocol
 * @notice Parametric insurance against stablecoin depegging below $0.95.
 *
 * PRODUCT: DEPEG-STABLE-001
 * RISK TYPE: STABLE
 * TRIGGER: Stablecoin TWAP 30 min < $0.95 (or 5 consecutive Chainlink rounds < $0.95).
 *          Verified via oracle-signed proof.
 * PAYOUT: Binary — (100% - deductible) of coverage.
 *         USDC: 10% deductible → 90% payout
 *         DAI:  12% deductible → 88% payout
 *         USDT: 15% deductible → 85% payout
 * DURATION: 14–365 days.
 * WAITING PERIOD: 24 hours (anti-selection adversa: depegs develop slowly via rumors).
 * STABLECOINS: USDC, DAI, USDT (selected at purchase via params.stablecoin).
 *
 * ORACLE PROOF FORMAT:
 *   abi.encode(int256 verifiedPrice, bytes32 stablecoin, uint256 verifiedAt, bytes signature)
 *
 * @dev Non-upgradeable. Extends BaseShield.
 */
contract DepegShield is BaseShield {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    bytes32 public constant PRODUCT_ID = keccak256("DEPEG-STABLE-001");
    bytes32 public constant RISK_TYPE = keccak256("STABLE");

    uint16 public constant MAX_ALLOCATION_BPS = 2000;    // 20%
    uint32 public constant MIN_DURATION = 14 days;
    uint32 public constant MAX_DURATION = 365 days;
    uint32 public constant WAITING = 1 days;             // 24h waiting period

    /// @notice Trigger price: $0.95 in Chainlink 8-decimal format
    int256 public constant TRIGGER_PRICE = 95_000_000;   // $0.95 × 1e8

    uint256 private constant BPS = 10_000;
    uint256 public constant MAX_PROOF_AGE = 30 minutes;

    // Stablecoin identifiers (bytes32 for gas)
    bytes32 public constant USDC = "USDC";
    bytes32 public constant DAI  = "DAI";
    bytes32 public constant USDT = "USDT";

    // Deductibles per stablecoin (in BPS)
    uint16 public constant USDC_DEDUCTIBLE_BPS = 1000;   // 10%
    uint16 public constant DAI_DEDUCTIBLE_BPS  = 1200;   // 12%
    uint16 public constant USDT_DEDUCTIBLE_BPS = 1500;   // 15%

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC STORAGE
    // ═══════════════════════════════════════════════════════════

    struct DepegData {
        bytes32 stablecoin;     // "USDC", "DAI", or "USDT"
        uint16 deductibleBps;   // 1000, 1200, or 1500
    }

    mapping(uint256 => DepegData) private _depegData;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error InvalidStablecoin(bytes32 stablecoin);
    error InvalidOracleProof();
    error ProofTooOld(uint256 verifiedAt, uint256 currentTime);
    error StablecoinMismatch(bytes32 policyStablecoin, bytes32 proofStablecoin);
    error ExcludedStablecoin(bytes32 stablecoin);

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
    function waitingPeriod() public pure returns (uint32) { return WAITING; }

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC LOGIC
    // ═══════════════════════════════════════════════════════════

    // USDC excluded: settlement token cannot be insured against its own depeg
    address public constant EXCLUDED_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function _doCreatePolicy(
        uint256 policyId,
        CreatePolicyParams calldata params
    ) internal override {
        // USDC excluded: settlement token cannot be insured against its own depeg
        if (params.stablecoin == USDC) revert ExcludedStablecoin(params.stablecoin);

        uint16 deductible = _getDeductible(params.stablecoin);

        _depegData[policyId] = DepegData({
            stablecoin: params.stablecoin,
            deductibleBps: deductible
        });
    }

    function _doVerifyAndCalculate(
        uint256 policyId,
        bytes calldata oracleProof
    ) internal view override returns (PayoutResult memory result) {
        DepegData storage data = _depegData[policyId];
        CorePolicy storage cp = _policies[policyId];

        // Decode oracle proof (off-chain verified TWAP 30 min or 5 consecutive rounds)
        (int256 verifiedPrice, bytes32 proofStablecoin, uint256 verifiedAt, bytes memory signature)
            = abi.decode(oracleProof, (int256, bytes32, uint256, bytes));

        // Verify signature
        bytes32 dataHash = keccak256(abi.encode(verifiedPrice, proofStablecoin, verifiedAt));
        if (!_verifyOracleSignature(dataHash, signature)) revert InvalidOracleProof();

        // Check proof freshness
        if (block.timestamp > verifiedAt + MAX_PROOF_AGE) {
            revert ProofTooOld(verifiedAt, block.timestamp);
        }

        // [FIX] Validate price is positive (defense-in-depth against oracle errors)
        if (verifiedPrice <= 0) revert InvalidOracleProof();

        // [FIX] Event must have occurred during active coverage (after waiting, before expiry).
        // Agent can SUBMIT the TX during grace period, but oracle observation must be in-coverage.
        if (verifiedAt < cp.waitingEndsAt || verifiedAt > cp.expiresAt) {
            revert EventAfterExpiry(policyId, verifiedAt, cp.expiresAt);
        }

        // Check stablecoin matches
        if (proofStablecoin != data.stablecoin) {
            revert StablecoinMismatch(data.stablecoin, proofStablecoin);
        }

        // Check trigger: TWAP price < $0.95
        if (verifiedPrice >= TRIGGER_PRICE) {
            revert TriggerNotMet(policyId, "PRICE_ABOVE_THRESHOLD");
        }

        // Trigger met — binary payout
        result = PayoutResult({
            triggered: true,
            payoutAmount: cp.maxPayout,
            recipient: cp.insuredAgent,
            reason: "STABLECOIN_DEPEG"
        });
    }

    function _calculateMaxPayout(
        uint256 coverageAmount,
        CreatePolicyParams calldata params
    ) internal pure override returns (uint256) {
        uint16 deductible = _getDeductible(params.stablecoin);
        return (coverageAmount * (BPS - deductible)) / BPS;
    }

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════

    function _getDeductible(bytes32 stablecoin) internal pure returns (uint16) {
        if (stablecoin == USDC) return USDC_DEDUCTIBLE_BPS;
        if (stablecoin == DAI)  return DAI_DEDUCTIBLE_BPS;
        if (stablecoin == USDT) return USDT_DEDUCTIBLE_BPS;
        revert InvalidStablecoin(stablecoin);
    }

    // ═══════════════════════════════════════════════════════════
    //  PRODUCT-SPECIFIC VIEWS
    // ═══════════════════════════════════════════════════════════

    function getDepegData(uint256 policyId) external view returns (DepegData memory) {
        if (_policies[policyId].insuredAgent == address(0)) revert PolicyNotFound(policyId);
        return _depegData[policyId];
    }
}
