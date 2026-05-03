// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IShield} from "../interfaces/IShield.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {BaseShield} from "./BaseShield.sol";

/**
 * @title FlashBTCShield1h
 * @author Lumina Protocol
 * @notice Parametric insurance: pays 80% if BTC drops >5% within 1 hour.
 *
 * PRODUCT: FLASHBTC1H-001
 * RISK TYPE: VOLATILE
 * TRIGGER: Price drops >5% from the exact price at policy issuance block.
 * PAYOUT: Binary — 80% of coverage (20% deductible).
 * DURATION: Fixed 1h. No waiting period.
 * ASSET: BTC only.
 *
 * @dev [H-1] IMPORTANT: Deploy with router_ = PolicyManagerV2 address (NOT CoverRouterV2).
 *      BaseShield.onlyRouter restricts createPolicy() to the router address.
 *      In V2, PolicyManagerV2 is the caller of createPolicy(), not CoverRouterV2.
 */
contract FlashBTCShield1h is BaseShield {
    bytes32 public constant PRODUCT_ID = keccak256("FLASHBTC1H-001");
    bytes32 public constant RISK_TYPE = keccak256("VOLATILE");

    uint16 public constant MAX_ALLOCATION_BPS = 3000; // 30%
    uint32 public constant MIN_DURATION = 3600; // 1h
    uint32 public constant MAX_DURATION = 3600; // 1h (fixed)
    uint32 public constant WAITING_PERIOD = 0;

    uint256 public constant DEDUCTIBLE_BPS = 2000; // 20% deductible → 80% max payout
    uint256 public constant TRIGGER_DROP_BPS = 500; // 5% drop
    uint256 private constant BPS = 10_000;

    uint256 public constant MAX_PROOF_AGE = 86400; // [Fix M-8] 24 hours (was 900 = 15 min). Replay protection comes from policy-finalization state, not proof-age — extending the window absorbs keeper-bot delays + Base congestion without weakening security.

    // [M-01 fix] Per-asset sanity bounds (Chainlink 8-dec). Out-of-range prices
    // from oracle or signed proof revert with PriceOutOfSanityBounds.
    uint256 public constant MIN_PRICE = 10_000 * 1e8; // $10,000
    uint256 public constant MAX_PRICE = 1_000_000 * 1e8; // $1,000,000

    struct BSSData {
        bytes32 asset; // "BTC"
        int256 strikePrice;
        int256 triggerPrice; // strikePrice × (100 - 5) / 100
    }

    mapping(uint256 => BSSData) private _bssData;

    error InvalidAsset(bytes32 asset);
    error InvalidOracleProof();
    error ProofTooOld(uint256 verifiedAt, uint256 currentTime);
    error AssetMismatch(bytes32 policyAsset, bytes32 proofAsset);
    error PriceOutOfSanityBounds(uint256 price, uint256 min, uint256 max);

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
        if (params.asset != "BTC") revert InvalidAsset(params.asset);

        int256 currentPrice = IOracle(oracle).getLatestPrice(params.asset);
        if (currentPrice <= 0) revert InvalidOracleProof();
        _validatePriceBounds(currentPrice);

        // Trigger: strikePrice × (100 - 5) / 100 = strikePrice × 95 / 100
        int256 trigger = (currentPrice * int256(BPS - TRIGGER_DROP_BPS)) / int256(BPS);

        _bssData[policyId] = BSSData({asset: params.asset, strikePrice: currentPrice, triggerPrice: trigger});
    }

    /// @dev [M-01 fix] Enforce per-asset price sanity bounds.
    function _validatePriceBounds(int256 price) private pure {
        uint256 p = uint256(price);
        if (p < MIN_PRICE || p > MAX_PRICE) {
            revert PriceOutOfSanityBounds(p, MIN_PRICE, MAX_PRICE);
        }
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
        _validatePriceBounds(verifiedPrice);

        if (verifiedAt < cp.waitingEndsAt || verifiedAt > cp.expiresAt) {
            revert EventAfterExpiry(policyId, verifiedAt, cp.expiresAt);
        }

        if (proofAsset != data.asset) revert AssetMismatch(data.asset, proofAsset);

        if (verifiedPrice >= data.triggerPrice) {
            revert TriggerNotMet(policyId, "PRICE_ABOVE_TRIGGER");
        }

        result = PayoutResult({
            triggered: true, payoutAmount: cp.maxPayout, recipient: cp.insuredAgent, reason: "FLASHBTC1H_DROP5"
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
        // Read current price from oracle (Chainlink via LuminaOracle)
        int256 currentPrice = IOracle(oracle).getLatestPrice(data.asset);
        // Check if current price is at or below the trigger price set at policy creation
        return currentPrice > 0 && currentPrice <= data.triggerPrice;
    }

    function getBSSData(uint256 policyId) external view returns (BSSData memory) {
        if (_policies[policyId].insuredAgent == address(0)) revert PolicyNotFound(policyId);
        return _bssData[policyId];
    }

    /// @inheritdoc BaseShield
    /// @dev [Audit fix H-13] FlashBTC reads the BTC/USD Chainlink feed;
    ///      signal that to BaseShield so a BTC feed outage extends the
    ///      trigger window proportionally and an honest claimant does
    ///      not lose payout because the feed went stale at trigger time.
    function _chainlinkGraceAsset() internal pure override returns (bytes32) {
        return bytes32("BTC");
    }

    uint256[50] private __gap_shield;
}
