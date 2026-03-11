// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILMath
 * @author Lumina Protocol
 * @notice On-chain Impermanent Loss calculation for the IL Index Cover product.
 *         Computes IL using the standard Uniswap V2 (50/50) formula,
 *         applies the restable deductible (first 2% not covered),
 *         and calculates the payout amount.
 * 
 * 🔴 INMUTABLE — Embedded in ILIndexCover.sol via `using ILMath for uint256`.
 *    If there's a bug in the IL formula, ILIndexCover must be redeployed.
 * 
 * FORMULA (Uniswap V2, constant product x*y=k, 50/50 pool):
 *
 *   priceRatio = priceAtExpiry / priceAtPurchase
 *   IL = 1 - (2 × √priceRatio) / (1 + priceRatio)
 * 
 *   IL is always ≥ 0 (we express it as a positive loss percentage).
 *   IL = 0 when priceRatio = 1 (no price change).
 *   IL is symmetric: a 2x up and a 2x down give the same IL (~5.72%).
 * 
 * PAYOUT:
 *   ilNet = max(0, IL - deductibleWad)          // Restable: first 2% not covered
 *   rawPayout = coverage × ilNet × payoutRate    // payoutRate = 0.90 (90%)
 *   maxPayout = coverage × maxILCap × payoutRate // maxILCap = 0.13 (13%)
 *   payout = min(rawPayout, maxPayout)
 * 
 * EXAMPLE ($50K coverage, ETH goes from $3000 to $2100 = -30%):
 *   priceRatio = 2100/3000 = 0.70
 *   IL = 1 - 2×√0.70 / (1+0.70) = 1 - 2×0.8367 / 1.70 = 1 - 0.9843 = 0.0157 = 1.57%
 *   ilNet = max(0, 1.57% - 2%) = 0%  → No payout (IL below deductible)
 * 
 * EXAMPLE ($50K coverage, ETH goes from $3000 to $1500 = -50%):
 *   priceRatio = 1500/3000 = 0.50
 *   IL = 1 - 2×√0.50 / (1+0.50) = 1 - 2×0.7071 / 1.50 = 1 - 0.9428 = 0.0572 = 5.72%
 *   ilNet = max(0, 5.72% - 2%) = 3.72%
 *   payout = $50,000 × 3.72% × 90% = $1,674
 * 
 * INTERNAL MATH:
 *   All intermediate calculations use WAD (1e18) precision.
 *   Square root uses the Babylonian method (gas-efficient for uint256).
 */
library ILMath {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 internal constant WAD = 1e18;

    /// @notice Default deductible: 2% (first 2% of IL not covered)
    uint256 internal constant DEFAULT_DEDUCTIBLE_WAD = 2e16; // 0.02 in WAD

    /// @notice Default payout rate: 90%
    uint256 internal constant DEFAULT_PAYOUT_RATE_WAD = 9e17; // 0.90 in WAD

    /// @notice Default max IL cap: 13% (payout capped at coverage × 13% × 90% = 11.7%)
    uint256 internal constant DEFAULT_MAX_IL_CAP_WAD = 13e16; // 0.13 in WAD

    /// @notice Price decimals used for price inputs (Chainlink standard: 8)
    uint256 internal constant PRICE_DECIMALS = 1e8;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error ZeroPrice();
    error ZeroCoverage();

    // ═══════════════════════════════════════════════════════════
    //  CORE: IL CALCULATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Calculate Impermanent Loss for a V2 50/50 pool
     * @dev IL = 1 - (2 × √r) / (1 + r) where r = priceAtExpiry / priceAtPurchase
     *      Result is in WAD (1e18 = 100% IL, 572e14 = 5.72% IL)
     *      IL is always ≥ 0 and always < 1 (can't lose more than everything)
     *
     * @param priceAtPurchase Price when policy was bought (8 decimals, Chainlink)
     * @param priceAtExpiry   Price at settlement (8 decimals, Chainlink)
     * @return ilWad          Impermanent Loss as positive value in WAD (0 = no IL)
     */
    function calculateIL(
        uint256 priceAtPurchase,
        uint256 priceAtExpiry
    ) internal pure returns (uint256 ilWad) {
        if (priceAtPurchase == 0) revert ZeroPrice();
        if (priceAtExpiry == 0) revert ZeroPrice();

        // If prices are equal, IL = 0
        if (priceAtPurchase == priceAtExpiry) return 0;

        // r = priceAtExpiry / priceAtPurchase (in WAD)
        uint256 ratioWad = (priceAtExpiry * WAD) / priceAtPurchase;

        // √r in WAD: sqrt(ratioWad × WAD) to maintain WAD precision
        // Because sqrt(a × 1e18) = sqrt(a) × sqrt(1e18) = sqrt(a) × 1e9
        // But we want WAD output, so: sqrt(ratioWad × WAD)
        uint256 sqrtRatioWad = _sqrt(ratioWad * WAD);

        // denominator = 1 + r (in WAD)
        uint256 denominator = WAD + ratioWad;

        // numerator = 2 × √r (in WAD)
        uint256 numerator = 2 * sqrtRatioWad;

        // valueRetained = (2 × √r) / (1 + r) — always ≤ 1.0 in WAD
        uint256 valueRetained = (numerator * WAD) / denominator;

        // IL = 1 - valueRetained
        // valueRetained is always ≤ WAD (the maximum value retained is 100%)
        if (valueRetained >= WAD) {
            return 0; // No IL (shouldn't happen mathematically, but safety check)
        }
        ilWad = WAD - valueRetained;
    }

    /**
     * @notice Calculate IL from raw price ratio (already in WAD)
     * @dev Alternative entry point when ratio is pre-computed
     * @param ratioWad priceAtExpiry / priceAtPurchase in WAD (1e18 = 1.0)
     * @return ilWad IL in WAD
     */
    function calculateILFromRatio(uint256 ratioWad) internal pure returns (uint256 ilWad) {
        if (ratioWad == 0) revert ZeroPrice();
        if (ratioWad == WAD) return 0;

        uint256 sqrtRatioWad = _sqrt(ratioWad * WAD);
        uint256 denominator = WAD + ratioWad;
        uint256 numerator = 2 * sqrtRatioWad;
        uint256 valueRetained = (numerator * WAD) / denominator;

        if (valueRetained >= WAD) return 0;
        ilWad = WAD - valueRetained;
    }

    // ═══════════════════════════════════════════════════════════
    //  CORE: NET IL AFTER DEDUCTIBLE
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Apply restable deductible to IL
     * @dev ilNet = max(0, IL - deductible)
     *      "Restable" means the protocol only pays IL EXCEEDING the deductible,
     *      not the full IL once the deductible is passed.
     * 
     *      Example with 2% deductible:
     *        IL = 1.5% → ilNet = 0% (below deductible, no payout)
     *        IL = 3.0% → ilNet = 1.0% (only the excess above 2%)
     *        IL = 5.7% → ilNet = 3.7%
     *
     * @param ilWad          Gross IL in WAD
     * @param deductibleWad  Deductible in WAD (default: 2e16 = 2%)
     * @return ilNetWad      Net IL after deductible in WAD
     */
    function applyDeductible(
        uint256 ilWad,
        uint256 deductibleWad
    ) internal pure returns (uint256 ilNetWad) {
        if (ilWad <= deductibleWad) return 0;
        ilNetWad = ilWad - deductibleWad;
    }

    // ═══════════════════════════════════════════════════════════
    //  CORE: PAYOUT CALCULATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Calculate the full payout for an IL Index Cover policy
     * @dev Combines IL calculation, deductible, payout rate, and cap.
     *      This is the main function called by ILIndexCover.verifyAndCalculate().
     *
     * @param priceAtPurchase  Price when policy was bought (8 decimals)
     * @param priceAtExpiry    Price at settlement (8 decimals)
     * @param coverageAmount   Coverage in USD (6 decimals)
     * @param deductibleWad    Deductible in WAD (2e16 = 2%)
     * @param payoutRateWad    Payout rate in WAD (9e17 = 90%)
     * @param maxILCapWad      Max IL cap in WAD (13e16 = 13%)
     * @return payoutAmount    Payout in USD (6 decimals)
     * @return ilWad           Gross IL in WAD (for logging/events)
     * @return ilNetWad        Net IL after deductible in WAD
     */
    function calculatePayout(
        uint256 priceAtPurchase,
        uint256 priceAtExpiry,
        uint256 coverageAmount,
        uint256 deductibleWad,
        uint256 payoutRateWad,
        uint256 maxILCapWad
    ) internal pure returns (
        uint256 payoutAmount,
        uint256 ilWad,
        uint256 ilNetWad
    ) {
        if (coverageAmount == 0) revert ZeroCoverage();

        // Step 1: Calculate gross IL
        ilWad = calculateIL(priceAtPurchase, priceAtExpiry);

        // Step 2: Apply restable deductible
        ilNetWad = applyDeductible(ilWad, deductibleWad);

        // Step 3: If ilNet is 0, no payout
        if (ilNetWad == 0) return (0, ilWad, 0);

        // Step 4: Calculate raw payout = coverage × ilNet × payoutRate
        uint256 rawPayout = (coverageAmount * ilNetWad) / WAD;
        rawPayout = (rawPayout * payoutRateWad) / WAD;

        // Step 5: Calculate max payout = coverage × maxILCap × payoutRate
        uint256 maxPayout = (coverageAmount * maxILCapWad) / WAD;
        maxPayout = (maxPayout * payoutRateWad) / WAD;

        // Step 6: Cap payout
        payoutAmount = rawPayout < maxPayout ? rawPayout : maxPayout;
    }

    /**
     * @notice Convenience: calculate payout with default parameters
     * @dev Uses: deductible 2%, payout rate 90%, max IL cap 13%
     */
    function calculatePayoutDefault(
        uint256 priceAtPurchase,
        uint256 priceAtExpiry,
        uint256 coverageAmount
    ) internal pure returns (
        uint256 payoutAmount,
        uint256 ilWad,
        uint256 ilNetWad
    ) {
        return calculatePayout(
            priceAtPurchase,
            priceAtExpiry,
            coverageAmount,
            DEFAULT_DEDUCTIBLE_WAD,
            DEFAULT_PAYOUT_RATE_WAD,
            DEFAULT_MAX_IL_CAP_WAD
        );
    }

    // ═══════════════════════════════════════════════════════════
    //  REFERENCE: IL TABLE (for documentation, not used on-chain)
    // ═══════════════════════════════════════════════════════════

    // Price Change | Price Ratio | IL      | IL Net (2% ded) | Payout ($50K, 90%)
    // -------------|-------------|---------|-----------------|-------------------
    // ±10%         | 0.90 / 1.10 | 0.14%   | 0%              | $0
    // ±20%         | 0.80 / 1.20 | 0.56%   | 0%              | $0
    // ±22%         | 0.78 / 1.22 | 0.68%   | 0%              | $0
    // ±25%         | 0.75 / 1.25 | 1.03%   | 0%              | $0
    // ±30%         | 0.70 / 1.30 | 1.57%   | 0%              | $0
    // ±35%         | 0.65 / 1.35 | 2.22%   | 0.22%           | $99
    // ±40%         | 0.60 / 1.40 | 3.02%   | 1.02%           | $459
    // ±50%         | 0.50 / 1.50 | 5.72%   | 3.72%           | $1,674
    // ±60%         | 0.40 / 1.60 | 9.27%   | 7.27%           | $3,272
    // ±75%         | 0.25 / 1.75 | 18.35%  | 13%+ (capped)   | $5,850 (max)
    // ±80%         | 0.20 / 1.80 | 22.54%  | 13%+ (capped)   | $5,850 (max)

    // ═══════════════════════════════════════════════════════════
    //  INTERNAL: SQUARE ROOT (Babylonian method)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Integer square root using the Babylonian (Newton's) method
     * @dev Gas-efficient for uint256. Accurate to the nearest integer.
     *      For WAD-precision: pass (value × WAD) to get result in √WAD precision.
     * @param x Value to take square root of
     * @return y √x rounded down
     */
    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        if (x <= 3) return 1;

        y = x;
        uint256 z = (x + 1) / 2;

        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
