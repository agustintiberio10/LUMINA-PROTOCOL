// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";

/**
 * @title USDCConverter
 * @author Lumina Protocol
 * @notice Conversion library between USD amounts (6 decimals, USDC format)
 *         and USDC tokens (Circle, native stablecoin on Base).
 *
 * USDC BEHAVIOR:
 *   USDC is a standard stablecoin pegged 1:1 to USD. It does NOT accumulate
 *   value like yield-bearing tokens. 1 USDC = $1.00 always.
 *   When deposited into Lumina vaults, yield is earned via Aave V3 aTokens,
 *   not via USDC price appreciation.
 *
 * ORACLE:
 *   USDC/USD price comes from Chainlink via LuminaOracle (8 decimals).
 *   The converter reads the oracle and applies sanity checks:
 *     - Price must be between $0.95 and $1.50 (rejects garbage data)
 *
 * TWO MODES:
 *   - STRICT (for purchases): Reverts if price out of range.
 *   - SAFE (for payouts): Falls back to 1:1 if oracle fails.
 *
 * DECIMALS:
 *   - USD amounts: 6 decimals (USDC standard)
 *   - USDC tokens: 6 decimals (Circle USDC on Base)
 *   - Oracle price: 8 decimals (Chainlink standard)
 */
library USDCConverter {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 internal constant USDC_DECIMALS = 1e6;
    uint256 internal constant USD_DECIMALS = 1e6;
    uint256 internal constant ORACLE_DECIMALS = 1e8;

    uint256 internal constant MIN_USDC_PRICE = 95_000_000;  // $0.95 in 8 decimals
    uint256 internal constant MAX_USDC_PRICE = 150_000_000; // $1.50 in 8 decimals
    uint256 internal constant FALLBACK_PRICE = 100_000_000; // $1.00 in 8 decimals

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error USDCPriceOutOfRange(uint256 price, uint256 min, uint256 max);
    error USDCFeedNotSet();
    error ZeroAmount();
    error NegativeOraclePrice();

    // ═══════════════════════════════════════════════════════════
    //  STRICT MODE (for purchases — reverts on any issue)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Convert USD amount to USDC tokens (strict mode)
     * @param usdAmount   Amount in USD (6 decimals)
     * @param oracle      IOracle instance
     * @param usdcAsset   Asset identifier for USDC feed (e.g., "USDC")
     * @return usdcAmount Amount in USDC tokens (6 decimals)
     */
    function usdToUSDCStrict(
        uint256 usdAmount,
        IOracle oracle,
        bytes32 usdcAsset
    ) internal view returns (uint256 usdcAmount) {
        if (usdAmount == 0) revert ZeroAmount();
        if (usdcAsset == bytes32(0)) revert USDCFeedNotSet();

        int256 rawPrice = oracle.getLatestPrice(usdcAsset);
        require(rawPrice > 0, "Negative oracle price"); // [H-3]
        uint256 price = uint256(rawPrice);

        if (price < MIN_USDC_PRICE || price > MAX_USDC_PRICE) {
            revert USDCPriceOutOfRange(price, MIN_USDC_PRICE, MAX_USDC_PRICE);
        }

        // Ceiling division: protocol rounds UP when charging
        // USD(6 dec) * ORACLE_DECIMALS(1e8) / price(8 dec) = USDC(6 dec)
        uint256 numerator = usdAmount * ORACLE_DECIMALS;
        usdcAmount = (numerator + price - 1) / price;
    }

    /**
     * @notice Convert USDC tokens to USD amount (strict mode)
     * @param usdcAmount  Amount in USDC tokens (6 decimals)
     * @param oracle      IOracle instance
     * @param usdcAsset   Asset identifier for USDC feed
     * @return usdAmount  Amount in USD (6 decimals)
     */
    function usdcToUSDStrict(
        uint256 usdcAmount,
        IOracle oracle,
        bytes32 usdcAsset
    ) internal view returns (uint256 usdAmount) {
        if (usdcAmount == 0) revert ZeroAmount();
        if (usdcAsset == bytes32(0)) revert USDCFeedNotSet();

        int256 rawPrice = oracle.getLatestPrice(usdcAsset);
        require(rawPrice > 0, "Negative oracle price"); // [H-3]
        uint256 price = uint256(rawPrice);

        if (price < MIN_USDC_PRICE || price > MAX_USDC_PRICE) {
            revert USDCPriceOutOfRange(price, MIN_USDC_PRICE, MAX_USDC_PRICE);
        }

        usdAmount = (usdcAmount * price) / ORACLE_DECIMALS;
    }

    // ═══════════════════════════════════════════════════════════
    //  SAFE MODE (for payouts — fallback to 1:1 if oracle fails)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Convert USD amount to USDC tokens (safe mode with fallback)
     * @param usdAmount   Amount in USD (6 decimals)
     * @param oracle      IOracle instance
     * @param usdcAsset   Asset identifier for USDC feed
     * @return usdcAmount Amount in USDC tokens (6 decimals)
     * @return usedFallback True if fallback price was used
     */
    function usdToUSDCSafe(
        uint256 usdAmount,
        IOracle oracle,
        bytes32 usdcAsset
    ) internal view returns (uint256 usdcAmount, bool usedFallback) {
        if (usdAmount == 0) return (0, false);

        uint256 price = FALLBACK_PRICE;
        usedFallback = true;

        if (usdcAsset != bytes32(0)) {
            try oracle.getLatestPrice(usdcAsset) returns (int256 rawPrice) {
                // [H-3] Negative price → use fallback instead of unsafe cast
                if (rawPrice > 0) {
                    uint256 p = uint256(rawPrice);
                    if (p >= MIN_USDC_PRICE && p <= MAX_USDC_PRICE) {
                        price = p;
                        usedFallback = false;
                    }
                }
            } catch {
                // Oracle call failed — use fallback
            }
        }

        usdcAmount = (usdAmount * ORACLE_DECIMALS) / price;
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Calculate how much USDC vault assets are worth in USD
     * @param usdcAmount USDC token balance (6 decimals)
     * @param usdcPrice  Current USDC price (8 decimals)
     * @return usdValue  USD value (6 decimals)
     */
    function usdcValueInUSD(
        uint256 usdcAmount,
        uint256 usdcPrice
    ) internal pure returns (uint256 usdValue) {
        usdValue = (usdcAmount * usdcPrice) / ORACLE_DECIMALS;
    }

    /**
     * @notice Check if USDC price is within acceptable circuit breaker bounds
     * @param currentPrice  Current USDC price (8 decimals)
     * @param previousPrice USDC price 24h ago (8 decimals)
     * @return safe         True if price change is within bounds
     * @return dropBps      Drop in basis points (0 if no drop)
     */
    function isUSDCPriceSafe(
        uint256 currentPrice,
        uint256 previousPrice
    ) internal pure returns (bool safe, uint256 dropBps) {
        if (previousPrice == 0) return (false, 0);

        if (currentPrice > previousPrice) {
            uint256 spikeBps = ((currentPrice - previousPrice) * 10_000) / previousPrice;
            if (spikeBps > 100) return (false, 0);
            return (true, 0);
        }

        if (currentPrice < previousPrice) {
            dropBps = ((previousPrice - currentPrice) * 10_000) / previousPrice;
            safe = dropBps <= 100;
            return (safe, dropBps);
        }

        return (true, 0);
    }
}
