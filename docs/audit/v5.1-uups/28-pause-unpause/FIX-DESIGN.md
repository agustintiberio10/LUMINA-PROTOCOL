# Fix #28 — Pause Hysteresis + Keeper Event Design

Resolves the 2 INFO findings from audit V5.1 #28.

---

## 1. INFO-6 — ShieldKeeper.pause() event

### Status after checking main branch

Upon re-inspection of current `main`, `src/automation/ShieldKeeper.sol` already declares `event KeeperPaused(address indexed by)` at line 46 and emits it from `pause()` at line 69. **The event was present in main** — the audit #28 finding was based on an outdated grep of a branched older version.

### Verification added

This fix adds explicit tests (`test_Fix_ShieldKeeper_PauseEmitsKeeperPausedEvent`, `test_Fix_ShieldKeeper_PauseUnpauseCycle_BothEmit`) to confirm:

1. `pause()` emits `KeeperPaused(msg.sender)`.
2. `unpause()` emits `KeeperUnpaused(msg.sender)`.
3. Multi-cycle pause/unpause emits exactly 1 event per call.

No source change for ShieldKeeper required. INFO-6 is validated as resolved.

---

## 2. INFO-7 — CoverRouterV2 auto-pause hysteresis

### Problem

`RESET_PRICE_FOR_NEW_POLICIES = 8e15` (`$0.008`) was declared as a constant but never referenced. The circuit breaker used only `MIN_PRICE_FOR_NEW_POLICIES = 5e15` (`$0.005`) for its check. Consequence: the protocol flaps between paused/unpaused for small oscillations around `$0.005`.

### EVM constraint

A naive "set flag then revert" pattern doesn't work — the EVM rolls back state mutations on `revert`. Setting `autoPausedOnce = true` inside `_purchase` just before a revert means the flag never persists.

### Design — split sync from purchase

The fix introduces two state transitions:

1. **`syncCircuitBreaker()`** (new external fn, permissionless) — reads current price, updates the `autoPausedOnce` flag, emits events. **Never reverts.** Keepers, users, or any caller can invoke it to commit the flag change in a successful tx.

2. **`_purchase()`** — reads the flag; if true, uses `RESET_PRICE` as the threshold (`$0.008`); if false, uses `MIN_PRICE` (`$0.005`). Reverts if current price is below the applicable threshold. **Does not mutate the flag.**

This split is the only way to make hysteresis actually work in EVM: state mutation must happen on a tx that doesn't revert.

### Storage layout

New state variable `bool public autoPausedOnce` added at the end of existing sequential storage (after `productList`, before `__gap`). The gap is reduced from `__gap[50]` to `__gap[49]` to keep the total contract slot count unchanged.

```solidity
// ... existing fields ...
mapping(bytes32 => ProductConfig) public products;
bytes32[] public productList;

/// @notice [Fix audit #28 INFO-7] Sticky auto-pause flag for hysteresis.
bool public autoPausedOnce;

// Storage gap for future upgrades
uint256[49] private __gap;  // reduced from 50
```

**UUPS upgrade safety:**
- All pre-existing sequential slots (usdc, policyManager, twapBurner, capacityOracle, paused, authorizedRelayers, products, productList) keep their exact indices.
- `autoPausedOnce` lands at what was previously `__gap[0]` — default value 0 maps cleanly to `false` which is the correct "not paused" initial state.
- `__gap` shrinks by exactly 1 slot; total storage footprint unchanged.

### Hysteresis behavior

```
Initial:         flag=false, price=$0.10        → healthy, threshold=MIN
Price drops:     flag=false, price=$0.004       → purchase REVERTS (price<MIN)
                 keeper calls syncCircuitBreaker() → flag=true, emit AutoPauseActivated
Price recovers:  flag=true,  price=$0.006       → purchase REVERTS (price<RESET)
                 keeper calls sync               → no change, still paused
Price crosses:   flag=true,  price=$0.008       → purchase passes check
                 keeper calls sync               → flag=false, emit AutoPauseDeactivated
Price dips:      flag=false, price=$0.006       → purchase passes check (price>=MIN)
                 keeper calls sync               → no change, still healthy
Price crashes:   flag=false, price=$0.004       → purchase REVERTS
                 keeper calls sync               → flag=true, re-activates
```

**Flap gap:** `RESET - MIN = 8e15 - 5e15 = 3e15` = `$0.003` = 60% of the floor. Price must move > 60% of the floor to flip the state — adequate anti-flap margin.

### Events

```solidity
event AutoPauseActivated(uint256 priceWei);
event AutoPauseDeactivated(uint256 priceWei);
```

Emitted from `syncCircuitBreaker()` only (since that's the only place the flag changes). Governance monitors can subscribe to these to track circuit-breaker state transitions.

### Non-goal: sync from within _purchase

We considered calling `syncCircuitBreaker()` from `_purchase` before the revert, but:
1. The state change is rolled back along with the revert — no net effect.
2. Even if we refactored to sync-then-check, we'd have to inform every call site, and the mutation-on-reverting-tx problem remains.
3. Keeper-driven sync is the industry-standard pattern for circuit breakers with hysteresis.

### Views updated

`isProtocolAutoPaused()` now reflects hysteresis-based threshold:

```solidity
function isProtocolAutoPaused() external view returns (bool) {
    if (address(capacityOracle) == address(0)) return false;
    uint256 threshold = autoPausedOnce ? RESET_PRICE_FOR_NEW_POLICIES : MIN_PRICE_FOR_NEW_POLICIES;
    return capacityOracle.getLuminaPrice() < threshold;
}
```

### Interaction with admin pause

- Admin `setPaused(true)` takes precedence over auto-pause (the `whenNotPaused` modifier fires first, reverting with `ContractPaused` selector rather than the auto-pause message).
- Admin `setPaused(false)` only clears the manual flag; the `autoPausedOnce` flag is untouched. A price-based recovery still requires `syncCircuitBreaker()`.

### Monitoring recommendation

Deploy a keeper that calls `syncCircuitBreaker()` every block or every N seconds. This ensures the flag reflects current price without relying on user txs.

---

## 3. Summary of changes

| Contract | Change |
|---|---|
| `ShieldKeeper` | No change (already emits `KeeperPaused`); tests added |
| `CoverRouterV2` | +1 storage slot (`autoPausedOnce`), +2 events, +1 public fn (`syncCircuitBreaker`), modified `_purchase` threshold check, modified `isProtocolAutoPaused` view, `__gap` 50→49 |

## 4. Upgrade checklist for production

1. Build new CoverRouterV2 implementation.
2. Run `forge inspect CoverRouterV2 storageLayout` pre/post — confirm only `autoPausedOnce` added at slot 8 and `__gap` reduced by 1.
3. Queue `upgradeToAndCall(newImpl, "")` via multisig + 48h timelock.
4. Deploy a keeper that calls `syncCircuitBreaker()` continuously.
5. Monitor for `AutoPauseActivated` / `AutoPauseDeactivated` events.
