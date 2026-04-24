# Fix #27 — Admin-Setter Events Design

Resolves the 5 INFO findings from audit V5.1 #27: admin setters mutating critical configuration without emitting events.

---

## 1. Scope

7 admin setters across 3 contracts:

| # | Contract | Function | Finding |
|---|---|---|---|
| 1 | TWAPBurner | `setAuthorizedSender(address, bool)` | INFO-1 |
| 2 | TWAPBurner | `setReserves(address, address, address)` | INFO-2 |
| 3 | TWAPBurner | `setAdaptiveMode(bool)` | INFO-3 |
| 4 | CoverRouterV2 | `setPolicyManager(address)` | INFO-4 |
| 5 | CoverRouterV2 | `setTwapBurner(address)` | INFO-4 |
| 6 | CoverRouterV2 | `setCapacityOracle(address)` | INFO-4 |
| 7 | PolicyManagerV2 | `setRouter(address)` | INFO-5 |

## 2. Events added

### TWAPBurner

```solidity
event AuthorizedSenderUpdated(address indexed sender, bool authorized);
event ReservesUpdated(
    address indexed buybackReserve,
    address indexed opsReserve,
    address indexed maintenanceReserve
);
event AdaptiveModeUpdated(bool enabled);
```

### CoverRouterV2

```solidity
event PolicyManagerUpdated(address indexed oldPM, address indexed newPM);
event TwapBurnerUpdated(address indexed oldTB, address indexed newTB);
event CapacityOracleUpdated(address indexed oldOracle, address indexed newOracle);
```

### PolicyManagerV2

```solidity
event RouterUpdated(address indexed oldRouter, address indexed newRouter);
```

## 3. Design decisions

### 3.1 old/new pattern for address setters

All 4 address setters (setPolicyManager, setTwapBurner, setCapacityOracle, setRouter) emit **both the old and new value**. Rationale: enables off-chain monitors to verify continuity of config changes without having to index every historical state snapshot. An event log alone is sufficient to reconstruct the full config-change timeline.

### 3.2 setAuthorizedSender — bool-only payload

Mapping setter — captures the key (sender) and the new value (authorized). No old value because the mapping can be queried directly; the event's purpose is to announce the mutation, not to snapshot prior state.

### 3.3 setReserves — triple-indexed event

Single-call that mutates three fields atomically. Event emits all three new addresses; all three are `indexed` for filtering flexibility.

### 3.4 setAdaptiveMode — bool-only payload

Boolean toggle. The event just publishes the new state. Previous state is trivially derivable from the last event of the same type (starts false at deploy).

### 3.5 NO new state variables

Critical: no storage slots added. Each change is strictly:
- Declare event (no storage impact — events are part of contract code, not storage).
- For address setters with old/new: capture `old` in a local `address` variable BEFORE the write, then emit after the write.

Storage layout is byte-for-byte identical pre/post fix.

### 3.6 Behavior unchanged for input validation

Input validation (zero-address rejection, configuration prerequisites for adaptive mode) is preserved exactly as before. The only changes are the `emit` statements and the declarations.

### 3.7 Event ordering (CEI-compatible)

Events are emitted AFTER the storage write, matching standard OZ patterns. This preserves the invariant that if the setter reverts, no event fires — observable by the `*_NonOwner_NoEvent` tests in the test file.

## 4. Upgrade safety

- **Storage layout:** identical (verified via observation — no state variables added).
- **Function selectors:** identical (same signatures).
- **Event selectors:** new (additions only; no existing events renamed or removed).
- **External behavior:** identical except for the new events.

Safe to deploy as a UUPS implementation upgrade on all three proxy contracts.

## 5. Monitoring recommendation

Governance observability stack should subscribe to these 7 new event signatures and:

1. Alert on any event whose `to`/`new` parameter is not in an approved address list.
2. Expose a dashboard tile per contract showing the last 10 config changes with timestamps.
3. For PolicyManager/Router/TwapBurner/CapacityOracle updates, require a human-in-loop acknowledgement within 4 hours of detection (since these reroute critical cross-contract calls).
