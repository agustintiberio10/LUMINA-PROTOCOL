// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title PremiumMath
 * @author Lumina Protocol
 * @notice On-chain implementation of the Kink Model pricing engine.
 *         Used to VERIFY off-chain quotes, not to calculate them.
 *         The off-chain Pricing API calculates the premium; the Shield verifies
 *         that the premium the agent paid is within acceptable bounds.
 * 
 * 🔴 INMUTABLE — Embedded via `using PremiumMath for uint256` in products.
 *    If there's a bug, every product using it must be redeployed.
 * 
 * FORMULA:
 *   Premium = Coverage × P_base × RiskMult × DurationDiscount × M(U) × (Duration / SECONDS_PER_YEAR)
 * 
 * KINK MODEL — M(U):
 *   U ≤ U_kink (80%): M(U) = 1 + (U / U_kink × R_slope1)
 *   U > U_kink (80%): M(U) = 1 + R_slope1 + ((U - U_kink) / (1 - U_kink) × R_slope2)
 *   U > 95%: REJECT (no policy issued)
 * 
 * INTERNAL MATH:
 *   All intermediate calculations use WAD (1e18) precision to avoid truncation.
 *   Inputs and outputs use the decimals appropriate to their context:
 *     - coverageAmount: 6 decimals (USDC format)
 *     - P_base, riskMult, durationDiscount: basis points (bps, 1e4)
 *     - utilizationBps: basis points
 *     - durationSeconds: raw seconds
 *     - premium output: 6 decimals (USDC format)
 */
library PremiumMath {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    /// @notice Internal precision for intermediate math (avoids truncation)
    uint256 internal constant WAD = 1e18;

    /// @notice Seconds in a year (365 days, no leap year adjustment)
    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    /// @notice Kink point: 80% utilization (in WAD)
    uint256 internal constant U_KINK = 8000; // 80.00% in bps

    /// @notice Slope below kink (in WAD): 0.5
    uint256 internal constant R_SLOPE1_WAD = 5e17; // 0.5 × 1e18

    /// @notice Slope above kink (in WAD): 3.0
    uint256 internal constant R_SLOPE2_WAD = 3e18; // 3.0 × 1e18

    /// @notice Maximum utilization: 95% — above this, reject policy
    uint256 internal constant U_MAX = 9500; // 95.00% in bps

    /// @notice Basis points denominator
    uint256 internal constant BPS = 10_000;

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    /// @notice Utilization exceeds 95% — no policy can be issued
    error UtilizationAboveMax(uint256 utilizationBps);

    /// @notice Duration is zero or exceeds max
    error InvalidDuration(uint256 durationSeconds);

    /// @notice Coverage amount is zero
    error ZeroCoverage();

    /// @notice P_base is zero
    error ZeroPBase();

    // ═══════════════════════════════════════════════════════════
    //  CORE: MULTIPLIER M(U) — THE KINK MODEL
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Calculate the utilization multiplier M(U) using the Kink Model
     * @dev Returns M(U) in WAD precision (1e18 = multiplier of 1.0x)
     *
     *  Example values:
     *    U = 0%:   M = 1.000 (1e18)
     *    U = 20%:  M = 1.125 (1.125e18)
     *    U = 40%:  M = 1.250 (1.25e18)
     *    U = 60%:  M = 1.375 (1.375e18)
     *    U = 80%:  M = 1.500 (1.5e18)  ← kink point
     *    U = 85%:  M = 2.250 (2.25e18) ← steep jump
     *    U = 90%:  M = 3.000 (3.0e18)
     *    U = 95%:  M = 3.750 (3.75e18) ← max before reject
     *    U > 95%:  REVERT
     *
     * @param utilizationBps Current utilization in basis points (0-10000)
     * @return multiplierWad M(U) in WAD (1e18 = 1.0x)
     */
    function calculateMultiplier(uint256 utilizationBps) internal pure returns (uint256 multiplierWad) {
        if (utilizationBps > U_MAX) revert UtilizationAboveMax(utilizationBps);

        // Base multiplier: 1.0 in WAD
        multiplierWad = WAD;

        if (utilizationBps == 0) {
            return multiplierWad; // M(0) = 1.0
        }

        if (utilizationBps <= U_KINK) {
            // Below kink: M(U) = 1 + (U / U_kink × R_slope1)
            // In WAD: 1e18 + (U_bps × 1e18 / U_KINK_bps × R_slope1 / 1e18)
            uint256 ratio = (utilizationBps * WAD) / U_KINK; // U / U_kink in WAD
            uint256 slopeContribution = (ratio * R_SLOPE1_WAD) / WAD;
            multiplierWad = WAD + slopeContribution;
        } else {
            // Above kink: M(U) = 1 + R_slope1 + ((U - U_kink) / (1 - U_kink) × R_slope2)
            uint256 excessBps = utilizationBps - U_KINK;
            uint256 remainingBps = BPS - U_KINK; // 10000 - 8000 = 2000

            uint256 excessRatio = (excessBps * WAD) / remainingBps;
            uint256 steepContribution = (excessRatio * R_SLOPE2_WAD) / WAD;

            multiplierWad = WAD + R_SLOPE1_WAD + steepContribution;
        }
    }

    // ═══════════════════════════════════════════════════════════
    //  CORE: PREMIUM CALCULATION
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Calculate the expected premium for a policy
     * @dev Used by Shields to VERIFY that the premium paid by the agent
     *      matches the expected value (within acceptable tolerance).
     *
     * @param coverageAmount  Coverage in USD (6 decimals, e.g. 50000e6 = $50,000)
     * @param pBaseBps        P_base in basis points (e.g. 2200 = 22% for BSS, 300 = 3% for Exploit)
     * @param riskMultBps     Risk multiplier in bps (10000 = 1.0x, 14000 = 1.4x for USDT Depeg)
     * @param durationDiscountBps  Duration discount in bps (10000 = 1.0x, 9000 = 0.9x, 8000 = 0.8x)
     * @param utilizationBps  Current vault utilization in bps (0-9500)
     * @param durationSeconds Policy duration in seconds
     * @return premiumAmount  Expected premium in USD (6 decimals)
     */
    function calculatePremium(
        uint256 coverageAmount,
        uint256 pBaseBps,
        uint256 riskMultBps,
        uint256 durationDiscountBps,
        uint256 utilizationBps,
        uint256 durationSeconds
    ) internal pure returns (uint256 premiumAmount) {
        if (coverageAmount == 0) revert ZeroCoverage();
        if (pBaseBps == 0) revert ZeroPBase();
        if (durationSeconds == 0) revert InvalidDuration(durationSeconds);

        // Step 1: Get M(U) in WAD
        uint256 mWad = calculateMultiplier(utilizationBps);

        // Step 2: Calculate premium in WAD precision to avoid truncation
        //
        // premium = coverage × (P_base / 10000) × (riskMult / 10000) × (durDiscount / 10000)
        //           × M(U) × (duration / SECONDS_PER_YEAR)
        //
        // Rearranged to minimize intermediate overflow:
        // premium = coverage × P_base × riskMult × durDiscount × M(U) × duration
        //           / (10000 × 10000 × 10000 × WAD × SECONDS_PER_YEAR)
        //
        // We compute step by step in WAD to keep precision:

        // coverage × P_base (scale: 6 dec × bps)
        uint256 step1 = coverageAmount * pBaseBps;

        // × riskMult / BPS (normalize one bps layer)
        uint256 step2 = (step1 * riskMultBps) / BPS;

        // × durationDiscount / BPS (normalize another bps layer)
        uint256 step3 = (step2 * durationDiscountBps) / BPS;

        // × M(U) / WAD (apply kink multiplier)
        uint256 step4 = (step3 * mWad) / WAD;

        // × durationSeconds / SECONDS_PER_YEAR (annualize)
        uint256 step5 = (step4 * durationSeconds) / SECONDS_PER_YEAR;

        // ÷ BPS (normalize the P_base bps — we had 3 bps layers, normalized 2, this is the 3rd)
        // [FIX] Ceiling division: protocol always rounds UP when charging premiums.
        // Lumina never undercharges. Agent pays at most 1 microUSD more than exact.
        premiumAmount = (step5 + BPS - 1) / BPS;
    }

    // ═══════════════════════════════════════════════════════════
    //  VERIFICATION: Is the paid premium within tolerance?
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Verify that a premium paid by an agent is within acceptable bounds
     * @dev The off-chain quote may use slightly different precision than on-chain.
     *      We allow a ±1% tolerance (100 bps) to account for:
     *        - Rounding differences between JS and Solidity
     *        - Utilization changes between quote and purchase (up to 5 min deadline)
     *        - USDC price fluctuation during the deadline window
     *
     * @param premiumPaid     Premium the agent actually paid (6 decimals)
     * @param expectedPremium Premium calculated on-chain (6 decimals)
     * @param toleranceBps    Acceptable deviation in bps (e.g. 100 = 1%)
     * @return valid          True if premiumPaid is within tolerance of expected
     */
    function verifyPremium(
        uint256 premiumPaid,
        uint256 expectedPremium,
        uint256 toleranceBps
    ) internal pure returns (bool valid) {
        if (expectedPremium == 0) return premiumPaid == 0;

        uint256 tolerance = (expectedPremium * toleranceBps) / BPS;
        uint256 lowerBound = expectedPremium > tolerance ? expectedPremium - tolerance : 0;
        uint256 upperBound = expectedPremium + tolerance;

        valid = premiumPaid >= lowerBound && premiumPaid <= upperBound;
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Calculate utilization in basis points
     * @dev U = (allocated + requested) / total × 10000
     *      [CRITICAL FIX] If vault is empty (totalAssets=0) and request > 0,
     *      returns type(uint256).max to force rejection. Prevents issuing policies
     *      in an unfunded vault at the cheapest possible premium.
     *
     * @param allocatedAssets Currently allocated to policies
     * @param requestedAmount New coverage being requested
     * @param totalAssets     Total vault assets
     * @return bps            Utilization in basis points (0-10000, or max for empty vault)
     */
    function calculateUtilization(
        uint256 allocatedAssets,
        uint256 requestedAmount,
        uint256 totalAssets
    ) internal pure returns (uint256 bps) {
        if (totalAssets == 0) {
            // Empty vault: any request > 0 = infinite utilization (reject)
            // Zero request on empty vault = 0% utilization (no harm)
            return requestedAmount > 0 ? type(uint256).max : 0;
        }
        bps = ((allocatedAssets + requestedAmount) * BPS) / totalAssets;
    }

    /**
     * @notice Check if a new policy would push utilization above the max (95%)
     * @param allocatedAssets Currently allocated
     * @param requestedAmount New coverage requested
     * @param totalAssets     Total vault assets
     * @return allowed        True if utilization after allocation would be ≤ 95%
     */
    function isUtilizationAllowed(
        uint256 allocatedAssets,
        uint256 requestedAmount,
        uint256 totalAssets
    ) internal pure returns (bool allowed) {
        uint256 newUtilization = calculateUtilization(allocatedAssets, requestedAmount, totalAssets);
        allowed = newUtilization <= U_MAX;
    }
}
