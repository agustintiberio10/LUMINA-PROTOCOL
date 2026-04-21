# Agent 3: ShieldKeeper Analysis

## Overview

ShieldKeeper is a Chainlink Automation-compatible contract that automates policy settlement. It implements `checkUpkeep()` (off-chain, view) and `performUpkeep()` (on-chain, permissionless). The keeper scans active policies via PolicyManager and calls `checkAndSettlePolicy()` on eligible shields.

## Vectors Analyzed

1. **Unauthorized performUpkeep Execution**: Non-Chainlink caller invokes performUpkeep with arbitrary data.
2. **Policy Poisoning / Gas Griefing**: Malicious policy causes revert in performUpkeep, blocking other settlements.
3. **Gas Limit Exhaustion**: Too many policies in a single upkeep exceeds block gas limit.
4. **Stale performData Replay**: Replaying old performData after policies have been settled.
5. **Product ID Spoofing**: Encoding a fake productId in performData to target wrong shield.

## Findings

### F1: Permissionless performUpkeep - BY DESIGN (SAFE)
`performUpkeep` is intentionally permissionless (standard Chainlink Automation pattern). Any caller can invoke it. Safety is guaranteed by:
- `shield.checkAndSettlePolicy()` has its own guards (safety window, finalized check).
- Invalid productId reverts with "Invalid product" (productShield returns address(0)).
- Already-settled policies revert in the shield, caught by try/catch.

### F2: try/catch Prevents Poisoning - SAFE
The critical pattern:
```solidity
try IShieldSettleable(shield).checkAndSettlePolicy(policyIds[i]) {
    emit PolicySettled(...)
} catch (bytes memory reason) {
    emit SettlementFailed(...)
}
```
A poisoned policy that reverts does NOT block other policies in the same batch. The loop continues, and the failure is logged via event for off-chain monitoring.

### F3: MAX_POLICIES_PER_UPKEEP Gas Limit - SAFE
Capped at 10 policies per upkeep. Each `checkAndSettlePolicy` costs ~50-100k gas. Total worst case: ~1M gas, well within block limits (30M on Base L2).

### F4: Stale performData Replay - SAFE
Replaying performData for already-settled policies results in each `checkAndSettlePolicy` reverting with "Not active" or "Not found". The try/catch handles this gracefully - emits SettlementFailed events, no state corruption.

### F5: Emergency Pause - SAFE
Owner can `pause()` the keeper. `checkUpkeep` returns false when paused (Chainlink stops calling). `performUpkeep` reverts with `KeeperPausedError` when paused. This provides emergency shutdown capability.

## Risk Rating

**LOW**

The combination of permissionless design + shield-level guards + try/catch isolation + gas limits creates a robust system. No single-point-of-failure vectors identified.

## Recommendations

1. Add a view function `getSettleableCount(bytes32 productId)` for monitoring dashboards.
2. Consider emitting the gas used per settlement in events for gas optimization tracking.
3. Monitor `SettlementFailed` events - repeated failures on the same policyId may indicate a bug in the shield contract.
