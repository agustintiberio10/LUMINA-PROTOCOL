# Agent 2: Auto-Settlement Flow Analysis

## Overview

BaseShield introduces `checkAndSettlePolicy()` - a permissionless function allowing anyone to settle expired policies after a 24-hour `SAFETY_WINDOW` post-expiry. The function reads the oracle directly via `_checkTriggerCondition()` to determine if the trigger condition was met, then finalizes the policy as either PAID_OUT or EXPIRED.

## Vectors Analyzed

1. **Double Claim Attack**: Calling `checkAndSettlePolicy` twice on the same policy to extract double payout.
2. **Premature Settlement**: Settling before the safety window to exploit transient price conditions.
3. **Flash Manipulation of Settlement Oracle**: Manipulating oracle at settlement time to trigger false payouts.
4. **Grief Settling**: Maliciously settling policies that would have been triggered with more time.
5. **Reentrancy via _afterFinalize Hook**: Attempting to re-enter during finalization.

## Findings

### F1: Double Claim Protection - SAFE
The `finalized` flag is checked at entry and set atomically before any external calls. Once `cp.finalized = true`, any subsequent call reverts with `InvalidPolicyStatus`. The state change happens before `_afterFinalize`, preventing reentrancy-based double claims.

### F2: Safety Window Enforcement - SAFE
The `SAFETY_WINDOW = 24 hours` is enforced with `block.timestamp < earliest` check and a custom `SafetyWindowNotPassed` error. This cannot be bypassed - block.timestamp is consensus-level.

### F3: Current Price vs Historical Price - KEY CONSIDERATION
`_checkTriggerCondition()` reads the CURRENT oracle price, not the historical price during coverage. This design choice means:
- Flash attacks during coverage that revert by settlement time will NOT trigger false payouts (GOOD).
- The 24h safety window gives time for price feeds to normalize after transient manipulation.
- However, if oracle failure is sustained for >24h, settlement reads the wrong price.

### F4: Status Transition Integrity
The flow: ACTIVE -> finalized=true -> status set -> counters decremented -> _afterFinalize called.
State is fully committed before the hook, preventing manipulation via callback.

### F5: Permissionless Settlement Design
Anyone can settle. This is intentional - it enables Chainlink Automation, bots, and users to settle without relying on a centralized operator. The guards (safety window, finalized check) ensure safety regardless of caller.

## Risk Rating

- **Flash Attack Vector**: LOW (24h window normalizes transient manipulation)
- **Sustained Oracle Failure**: MEDIUM (if oracle reports wrong price for >24h, settlements may be incorrect)
- **Overall**: LOW-MEDIUM

## Recommendations

1. Consider adding a maximum settlement window (e.g., 7 days post-expiry) after which unclaimed policies auto-expire without trigger check.
2. For sustained oracle failure scenarios, the SAFETY_WINDOW could be dynamically extended if oracle staleness is detected.
3. Monitor oracle liveness off-chain and pause ShieldKeeper if oracle is stale >12h.
