# Agent 4: Multi-DEX Routing Analysis

## Overview

TWAPBurner V5.0 introduces multi-DEX routing via an array of `IDexRouter` adapters (UniswapV3Adapter, AerodromeAdapter). The `_swapAndBurn()` function queries all configured routers for quotes, selects the best one, applies slippage protection (both quote-based and oracle-based), then executes the swap and burns the received LUMINA.

## Vectors Analyzed

1. **Malicious Adapter Injection**: Attacker-controlled adapter returns inflated quotes to win selection, then delivers less tokens.
2. **Quote Manipulation Across Adapters**: One adapter's quote manipulated to route through a less liquid pool.
3. **Reentrancy via Adapter swap()**: Adapter calls back into TWAPBurner during swap execution.
4. **Adapter Approval Exploit**: Lingering approvals on adapters after swap.
5. **Oracle Bypass for Slippage**: Oracle not set, allowing quote-only slippage (lower protection).

## Findings

### F1: Adapter Trust Model - OWNER-CONTROLLED (SAFE)
Adapters are set exclusively by the owner (Gnosis Safe multisig). A malicious adapter requires a compromised owner key - same trust model as the previous single-router design. No escalation of privilege.
- `setDexRouters()`: replaces all routers (onlyOwner)
- `addDexRouter()`: appends new router (onlyOwner)
- No permissionless adapter registration exists.

### F2: Dual Slippage Protection - SAFE
Two layers of slippage protection:
1. **Quote-based**: `minOut = bestQuote * (10000 - maxSlippageBps) / 10000`
2. **Oracle-based**: `oracleMin = expectedOut * (10000 - maxSlippageBps) / 10000`
The HIGHER of the two is used as minAmountOut. This means a manipulated quote cannot lower the oracle floor, and a stale oracle cannot lower the quote floor.

### F3: forceApprove + Per-Call Pattern - SAFE
```solidity
usdc.forceApprove(address(bestRouter), usdcAmount);
```
Uses `forceApprove` (handles USDC non-standard approve). Approval is set to exact amount needed, not unlimited. After swap, the router has consumed the approval. No lingering allowance risk.

### F4: Reentrancy Protection - SAFE
`executeBurn()` is protected by `nonReentrant` modifier (OpenZeppelin ReentrancyGuard). Even if a malicious adapter attempts to call back into `executeBurn()`, the guard reverts.

### F5: getQuote Failure Handling - SAFE
The try/catch around `dexRouters[i].getQuote()` means a failing adapter does not block other adapters from being queried. If all adapters fail, `bestQuote = 0`, and `minOut = 0` (unless oracle provides a floor). The oracle check then provides the safety net.

### F6: Zero-Quote Edge Case
If ALL adapters return 0 or revert AND no oracle is set, `minOut = 0`. The swap proceeds with no slippage protection. This is acceptable only in test/bootstrap scenarios. In production, `capacityOracle` should always be set.

## Risk Rating

**LOW**

Same trust model as before (owner-controlled routers). The dual slippage protection is strictly stronger than single-source. Reentrancy is blocked by OpenZeppelin guard.

## Recommendations

1. Enforce `capacityOracle != address(0)` for production deployment (add a require in setAdaptiveMode or a dedicated production-lock).
2. Consider adding a minimum adapter count check (at least 2 for redundancy).
3. Add an event when an adapter's getQuote reverts, for monitoring adapter health.
4. Consider a maximum adapter count (e.g., 5) to bound gas in the quote-selection loop.
