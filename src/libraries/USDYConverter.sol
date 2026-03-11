// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";

/**
 * @title USDYConverter
 * @author Lumina Protocol
 * @notice Conversion library between USD amounts (6 decimals, USDC format)
 *         and USDY tokens (Ondo Finance, accumulating RWA token).
 *
 * USDY BEHAVIOR:
 *   USDY is an accumulating token — its USD value increases over time (~3.55% APY)
 *   as the underlying US Treasury yields accrue. This means:
 *     - 1 USDY ≈ $1.04 today (and rising)
 *     - To pay $100 worth, you need ~96.15 USDY tokens
 *     - To receive $100 worth, you get ~96.15 USDY tokens
 *
 * ORACLE:
 *   USDY/USD price comes from Chainlink via LuminaOracle (8 decimals).
 *   The converter reads the oracle and applies sanity checks:
 *     - Price must be between $0.95 and $1.50 (rejects garbage data)
 *
 * TWO MODES:
 *   - STRICT (for purchases): Reverts if price out of range.
 *   - SAFE (for payouts): Falls back to 1:1 if oracle fails.
 *
 * DECIMALS:
 *   - USD amounts: 6 decimals (USDC standard)
 *   - USDY tokens: 18 decimals (ERC-20 standard)
 *   - Oracle price: 8 decimals (Chainlink standard)
 */
library USDYConverter {

    // ═══════════════════════════════════════════════════════════
    //  CONSTANTS
    // ═══════════════════════════════════════════════════════════

    uint256 internal constant USDY_DECIMALS = 1e18;
    uint256 internal constant USD_DECIMALS = 1e6;
    uint256 internal constant ORACLE_DECIMALS = 1e8;

    uint256 internal constant MIN_USDY_PRICE = 95_000_000;  // $0.95 in 8 decimals
    uint256 internal constant MAX_USDY_PRICE = 150_000_000; // $1.50 in 8 decimals
    uint256 internal constant FALLBACK_PRICE = 100_000_000; // $1.00 in 8 decimals

    // ═══════════════════════════════════════════════════════════
    //  ERRORS
    // ═══════════════════════════════════════════════════════════

    error USDYPriceOutOfRange(uint256 price, uint256 min, uint256 max);
    error USDYFeedNotSet();
    error ZeroAmount();

    // ═══════════════════════════════════════════════════════════
    //  STRICT MODE (for purchases — reverts on any issue)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Convert USD amount to USDY tokens (strict mode)
     * @param usdAmount   Amount in USD (6 decimals)
     * @param oracle      IOracle instance
     * @param usdyAsset   Asset identifier for USDY feed (e.g., "USDY")
     * @return usdyAmount Amount in USDY tokens (18 decimals)
     */
    function usdToUSDYStrict(
        uint256 usdAmount,
        IOracle oracle,
        bytes32 usdyAsset
    ) internal view returns (uint256 usdyAmount) {
        if (usdAmount == 0) revert ZeroAmount();
        if (usdyAsset == bytes32(0)) revert USDYFeedNotSet();

        int256 rawPrice = oracle.getLatestPrice(usdyAsset);
        uint256 price = uint256(rawPrice);

        if (price < MIN_USDY_PRICE || price > MAX_USDY_PRICE) {
            revert USDYPriceOutOfRange(price, MIN_USDY_PRICE, MAX_USDY_PRICE);
        }

        // Ceiling division: protocol rounds UP when charging
        uint256 numerator = usdAmount * 1e20;
        usdyAmount = (numerator + price - 1) / price;
    }

    /**
     * @notice Convert USDY tokens to USD amount (strict mode)
     * @param usdyAmount  Amount in USDY tokens (18 decimals)
     * @param oracle      IOracle instance
     * @param usdyAsset   Asset identifier for USDY feed
     * @return usdAmount  Amount in USD (6 decimals)
     */
    function usdyToUSDStrict(
        uint256 usdyAmount,
        IOracle oracle,
        bytes32 usdyAsset
    ) internal view returns (uint256 usdAmount) {
        if (usdyAmount == 0) revert ZeroAmount();
        if (usdyAsset == bytes32(0)) revert USDYFeedNotSet();

        int256 rawPrice = oracle.getLatestPrice(usdyAsset);
        uint256 price = uint256(rawPrice);

        if (price < MIN_USDY_PRICE || price > MAX_USDY_PRICE) {
            revert USDYPriceOutOfRange(price, MIN_USDY_PRICE, MAX_USDY_PRICE);
        }

        usdAmount = (usdyAmount * price) / 1e20;
    }

    // ═══════════════════════════════════════════════════════════
    //  SAFE MODE (for payouts — fallback to 1:1 if oracle fails)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Convert USD amount to USDY tokens (safe mode with fallback)
     * @param usdAmount   Amount in USD (6 decimals)
     * @param oracle      IOracle instance
     * @param usdyAsset   Asset identifier for USDY feed
     * @return usdyAmount Amount in USDY tokens (18 decimals)
     * @return usedFallback True if fallback price was used
     */
    function usdToUSDYSafe(
        uint256 usdAmount,
        IOracle oracle,
        bytes32 usdyAsset
    ) internal view returns (uint256 usdyAmount, bool usedFallback) {
        if (usdAmount == 0) return (0, false);

        uint256 price = FALLBACK_PRICE;
        usedFallback = true;

        if (usdyAsset != bytes32(0)) {
            try oracle.getLatestPrice(usdyAsset) returns (int256 rawPrice) {
                uint256 p = uint256(rawPrice);
                if (p >= MIN_USDY_PRICE && p <= MAX_USDY_PRICE) {
                    price = p;
                    usedFallback = false;
                }
            } catch {
                // Oracle call failed — use fallback
            }
        }

        usdyAmount = (usdAmount * 1e20) / price;
    }

    // ═══════════════════════════════════════════════════════════
    //  HELPERS
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Calculate how much USDY vault assets are worth in USD
     * @param usdyAmount USDY token balance (18 decimals)
     * @param usdyPrice  Current USDY price (8 decimals)
     * @return usdValue  USD value (6 decimals)
     */
    function usdyValueInUSD(
        uint256 usdyAmount,
        uint256 usdyPrice
    ) internal pure returns (uint256 usdValue) {
        usdValue = (usdyAmount * usdyPrice) / 1e20;
    }

    /**
     * @notice Check if USDY price is within acceptable circuit breaker bounds
     * @param currentPrice  Current USDY price (8 decimals)
     * @param previousPrice USDY price 24h ago (8 decimals)
     * @return safe         True if price change is within bounds
     * @return dropBps      Drop in basis points (0 if no drop)
     */
    function isUSDYPriceSafe(
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
