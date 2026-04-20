# Agent 5: BuybackEngine Without Activation Delay

## Overview

BuybackEngine V5.0 removes the previously planned `ACTIVATION_DELAY` for configuration changes. The owner (multisig with BUYBACK_OPERATOR_ROLE) can call `setDailyBuyback()` immediately and the configuration takes effect in the same transaction. This analysis evaluates whether the removal of the delay introduces exploitable vectors.

## Vectors Analyzed

1. **Rapid Reconfiguration Attack**: Owner reconfigures budget multiple times to bypass daily spending limits.
2. **Flash Configuration + Execute**: Set high budget, execute offer, revert budget in same block.
3. **Budget Exhaustion via Reconfiguration**: Reset `spentToday` by reconfiguring, then spend again.
4. **Solvency Oracle Bypass**: Operator bypasses the 150% solvency circuit breaker via timing.
5. **Price Manipulation + Immediate Buyback**: Manipulate LUMINA price then execute Double Burn at inflated rate.

## Findings

### F1: Reconfiguration Resets spentToday - BY DESIGN (ACCEPTABLE)
Each call to `setDailyBuyback()` creates a fresh `DailyConfig` with `spentToday: 0`. This means:
- Owner CAN reset the daily counter by reconfiguring.
- However, the owner IS the multisig - they already have full authority.
- The budget cap still applies within each configuration period.
- No external actor can trigger a reconfiguration.

### F2: Daily Budget Cap Still Enforced - SAFE
```solidity
require(dailyConfig.spentToday + priceUSDC <= dailyConfig.dailyBudget, "Daily budget exceeded");
```
Within any single configuration, total spending is capped. Even rapid reconfigs cannot spend more than the CURRENT budget in a single `executeOffer` call.

### F3: Solvency Circuit Breaker Independent - SAFE
The 150% solvency check (`MIN_SOLVENCY_FOR_DOUBLE_BURN = 15000`) is checked in `_executeDoubleBurn()` regardless of configuration timing. Even if the operator reconfigures, the solvency oracle check cannot be bypassed.

### F4: Max Price Percent Guard - SAFE
```solidity
require(priceUSDC <= maxAllowedPriceUSDC, "Price exceeds max");
```
The `maxPricePercent` (capped at 95%) prevents buying bonds above face value regardless of configuration timing. This is checked per-transaction.

### F5: 5% Per-TX Burn Cap via Vault - SAFE
The `bondVault.burnFromReserves()` is called with a calculated amount based on face value and spot price. The vault itself enforces burn limits (not in BuybackEngine). The engine cannot unilaterally drain the vault.

### F6: Activation Delay Removal Justification
The delay was originally intended to give token holders notice of buyback changes. Since:
- The operator IS the multisig (same trust as deployer)
- All per-transaction guards remain (budget, price, solvency)
- The buyback benefits token holders (burns LUMINA)
- Delays would prevent rapid response to market opportunities

The removal is justified and does not degrade security.

## Risk Rating

**LOW**

All protective caps (daily budget, max price percent, solvency circuit breaker, vault-level burn limits) remain enforced per-transaction regardless of configuration timing. The BUYBACK_OPERATOR_ROLE is the multisig - same trust level as contract ownership.

## Recommendations

1. Add an event or state variable tracking total historical spend (cumulative, never resets) for auditability.
2. Consider a maximum budget cap constant (e.g., $50,000/day) that cannot be exceeded even by reconfiguration.
3. Monitor `setDailyBuyback` calls - more than 2 per day should trigger an alert.
4. Document in operational runbook that reconfiguration resets the daily counter.
