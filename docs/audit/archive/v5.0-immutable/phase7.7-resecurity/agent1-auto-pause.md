# Agent 1: CoverRouterV2 Auto-Pause Analysis

## Overview

CoverRouterV2 introduces a per-transaction auto-pause mechanism that blocks new policy purchases when the LUMINA token price falls below `MIN_PRICE_FOR_NEW_POLICIES` ($0.005). The check reads the `capacityOracle.getLuminaPrice()` on every `_purchase()` call and reverts if the price is below threshold.

## Vectors Analyzed

1. **Oracle Manipulation (Flash Loan Attack)**: Attacker manipulates oracle to report low price, causing permanent protocol pause.
2. **Stuck State via Stale Oracle**: Oracle fails to update, leaving the protocol in a paused state indefinitely.
3. **Griefing via Oracle Price Suppression**: Sustained manipulation to block legitimate policy purchases.
4. **Race Condition on Recovery**: Protocol does not resume when price recovers above threshold.

## Findings

### F1: Per-Transaction (Stateless) Design - SAFE
The auto-pause is NOT a persistent state variable. It is checked on every transaction by reading the live oracle price. This means:
- Oracle manipulation in block N only affects block N.
- No admin intervention needed to "unpause" - simply restoring the oracle price unblocks purchases.
- No griefing vector that persists beyond the manipulation window.

### F2: No RESET_PRICE Hysteresis Bug
The constant `RESET_PRICE_FOR_NEW_POLICIES` ($0.008) exists but is NOT used in the check logic. The only threshold enforced is `MIN_PRICE_FOR_NEW_POLICIES` ($0.005). The `isProtocolAutoPaused()` view function also uses only the MIN threshold. This is consistent - no hidden hysteresis gap.

### F3: Oracle Address Zero Check
When `capacityOracle` is not set (address(0)), the check is skipped entirely. This prevents a DoS if the oracle is not yet configured. The `setCapacityOracle()` function requires non-zero address.

### F4: View Function Consistency
`isProtocolAutoPaused()` returns the same boolean as the internal check, allowing off-chain monitoring to detect the condition before user transactions fail.

## Risk Rating

**LOW**

The per-transaction design eliminates all sticky-state attack vectors. Flash loan oracle manipulation only affects the attacker's own block. Sustained oracle manipulation would require continuous capital commitment with no protocol-side benefit to the attacker.

## Recommendations

1. Consider adding an event emission when a purchase is blocked by auto-pause (aids monitoring).
2. Document that `RESET_PRICE_FOR_NEW_POLICIES` is reserved for future hysteresis implementation.
3. Ensure the oracle implementation (CapacityOracle) has manipulation resistance (TWAP, multi-source).
