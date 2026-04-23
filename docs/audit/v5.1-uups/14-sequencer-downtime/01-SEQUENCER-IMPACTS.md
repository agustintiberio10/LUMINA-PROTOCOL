# Audit V5.1 #14 — Sequencer Downtime: Inventory of Impacts

**Target:** LUMINA Protocol V5.1 (UUPS upgradeable) on Base L2
**Scope:** Behavior during centralized-sequencer downtime
**Date:** 2026-04-23

---

## 1. Context — Base L2 sequencer

Base L2 (Coinbase) runs a single centralized sequencer. When it is down:

- Transactions are not included in new blocks
- Chainlink price feeds cannot post updates → oracles become stale
- Users cannot buy policies, trigger claims, redeem bonds, execute burns
- Time-based state (cleanup windows, cooldowns, maturities) still ticks forward in calendar time

Chainlink publishes a dedicated **Sequencer Uptime Feed** (Base mainnet:
`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`) exposing:

- `answer`: `0` = up, `1` = down
- `startedAt`: Unix timestamp of last status change

## 2. Current V5.1 integration surface

Grepping `src/` for `Sequencer` yields **exactly two** hits:

| File | Line | Role |
|---|---|---|
| `src/interfaces/IOracle.sol` | 32 | `function getSequencerDowntime(uint256 sinceTimestamp) external view returns (uint256)` — interface declaration only |
| `src/products/BaseShield.sol` | 376 | Call site inside `_validateStatusForTrigger` that extends the cleanup window by the reported downtime |

### 2.1 BaseShield cleanup-window extension (the only code path)

```solidity
function _validateStatusForTrigger(uint256 policyId, PolicyStatus current) internal view virtual {
    if (current != PolicyStatus.ACTIVE && current != PolicyStatus.EXPIRED) {
        revert InvalidPolicyStatus(policyId, current, PolicyStatus.ACTIVE);
    }
    CorePolicy storage cp = _policies[policyId];
    uint256 downtime = IOracle(oracle).getSequencerDowntime(cp.expiresAt);
    uint256 adjustedCleanupAt = cp.cleanupAt + downtime;
    if (block.timestamp >= adjustedCleanupAt) {
        revert InvalidPolicyStatus(policyId, PolicyStatus.EXPIRED, PolicyStatus.ACTIVE);
    }
}
```

**Effect:** A policy that would normally go un-triggerable at
`cleanupAt = expiresAt + 24h` remains triggerable until
`cleanupAt + downtime` — so users can't lose a valid trigger just because
the sequencer ate part of their cleanup grace period.

This is inherited (no overrides) by every Shield product:
`FlashBTCShield1h/4h/24h/48h`, `FlashETHShield1h/24h/48h`, `MicroDepegShield`,
`RateShockShield`.

### 2.2 Concrete Oracle implementation — NOT in src/

`IOracle.getSequencerDowntime` has **no production implementation** in `src/`.
The only implementation lives in the archived V1 oracle at
`archive/v1-deprecated/oracles/LuminaOracle.sol`, which uses Chainlink's
`AggregatorV3Interface` on the Sequencer Uptime Feed with a
`MIN_DOWNTIME_EXTENSION = 2 hours` grace period.

Test suites use mock oracles (`MockChainlinkOracle`, `MockSequencerOracle`, etc.)
that either return `0` (default, safe) or a configurable value. The V5.1 deployment
must wire up a concrete oracle contract that implements this function against the
real Chainlink feed before mainnet.

## 3. Coverage matrix — who else gates on sequencer?

| Contract | Sequencer-aware? | Notes |
|---|---|---|
| `BaseShield` | ✅ **YES** — cleanup-window extension | `_validateStatusForTrigger` |
| `FlashBTCShield1h/4h/24h/48h` | ✅ Inherited | No overrides |
| `FlashETHShield1h/24h/48h` | ✅ Inherited | No overrides |
| `MicroDepegShield` | ✅ Inherited | No overrides |
| `RateShockShield` | ✅ Inherited | No overrides |
| `CoverRouterV2` | ❌ No | Purchase path ignores sequencer status |
| `PolicyManagerV2` | ❌ No | No sequencer logic |
| `BondVault` | ❌ No | Redemption not gated |
| `TWAPBurner` | ❌ No | `executeBurn` not gated |
| `Marketplace` / `MarketplaceV2` | ❌ No | List/buy not gated |
| `CapacityOracle` | ❌ No | LUMINA-price only |
| `SolvencyOracle` | ❌ No | Quadrant tracker |
| `FounderVesting*` | ❌ No | No sequencer logic |

### 3.1 Is the "no-gate" behavior a problem?

No — and the design is intentional:

- **"If my tx is mined, the sequencer is up"** — the L2 invariant means that
  any function called on-chain implicitly proves the sequencer is processing
  transactions. An explicit `revert "sequencer down"` inside a function that
  just got called is incoherent (the sequencer clearly isn't down).
- The only state that keeps advancing without any new transactions is the
  **on-chain clock relative to stored deadlines** (cleanup windows, cooldowns,
  maturities). Of those, only the cleanup window has a "use-it-or-lose-it"
  trigger semantic where unfair lock-out is possible. BondVault maturities and
  TWAPBurner cooldowns don't expire — they just wait.
- Stale Chainlink price data during a downtime → handled by existing
  chainlink-failure paths (see audit #11).

**Therefore:** the only place sequencer awareness is load-bearing is exactly
where it is today — the trigger-validation cleanup-window extension.

## 4. Failure modes exercised by tests

1. Baseline (no downtime): status check reverts at `cleanupAt`.
2. Small downtime (60s, 1h): extension covers the gap; status check passes.
3. Extension boundary: `cleanupAt + downtime + 1s` reverts.
4. Large downtime (24h): extension applies proportionally.
5. Downtime mutated mid-call: re-read on every call (view semantics).
6. Downtime = 0: no extension, identical to baseline.
7. Overflow (`type(uint256).max`): reverts via Solidity checked math.
8. Coverage across all 8 shield implementations.
9. `createPolicy` / `getPolicyInfo`: explicitly NOT gated, verified by test.
10. Finalized policies (`markPaidOut`): not re-triggerable regardless of downtime.

## 5. Finding categories

- **INFORMATIONAL**: V5.1 ships no concrete `IOracle.getSequencerDowntime`
  implementation in `src/` — production deployment must add one before mainnet.
- **DESIGN NOTE**: Only the cleanup window is sequencer-aware. By the
  "if-mined-then-up" invariant, this is correct and sufficient.
- **NO REGRESSIONS**: All existing mock-based tests keep working.
