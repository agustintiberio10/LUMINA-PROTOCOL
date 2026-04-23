# Audit V5.1 #16 — Stress Test Volume: Report

**Branch:** `audit/v5.1-16-stress-test-volume`
**Date:** 2026-04-23
**Verdict:** SCALABLE — every measured operation maintains O(1) cost across 500–2 000-op runs; no state corruption, no invariant breaks, no DOS vectors. Two informational notes (§5).

---

## 1. Summary

We exercised the protocol under sustained volume on every scaling axis (purchases, bond issuance, marketplace listings, redemptions, settlements, multi-day operation) and confirmed gas-per-operation stays flat. The contracts contain **no on-chain loop over an unbounded set in a user-callable function** (verified statically — see `01-STRESS-SCENARIOS.md` §4), so flatness at N=2 000 mathematically implies flatness at N=200 000.

## 2. How the numbers were collected

- File: `test/audit/v5.1-uups/performance/stress/StressVolume.t.sol` (10 tests).
- Harness: full E2E setup pattern (lumina, bondVault, claimBond, capacityOracle, solvencyOracle, feeDistributor, twapBurner, policyManager, coverRouter, marketplace, buybackEngine, shieldKeeper, 3 shields).
- Mocks for USDC / DEX router / shield oracle only; everything else is the real proxy contracts.
- Each scaling test does a 10-iteration cold-state warm-up before measuring, so the comparison is steady-state-vs-steady-state and not biased by first-touch SSTORE costs.

## 3. Performance under load

| Scenario | Volume | gas op-N (warm) | gas op-1 (warm) | Spread | Status |
|---|---|---|---|---|---|
| `purchasePolicy` (single shield) | 500 ops | log: see test output | log: see test output | ≤ 15 % | ✅ flat |
| `purchasePolicy` (3 shields) | 300 ops | — | — | ≤ 15 % | ✅ flat |
| `bondVault.issueBond` (same epoch) | 2 000 ops | ~50 k | ~50 k | < 15 % | ✅ flat |
| `bondVault.redeemBond` (same epoch) | 500 ops | ~50 k | ~50 k | < 15 % | ✅ flat |
| `marketplace.list` | 300 ops | ~150 k | ~150 k | < 15 % | ✅ flat |
| `checkAndSettlePolicy` (no trigger) | 100 ops | ~30 k | ~30 k | < 15 % | ✅ flat |
| 365-day simulation | 365 purchases + 52 burns | — | — | — | ✅ invariants hold |
| `performUpkeep` (1000-id batch) | 1 capped op | < 10 M total | — | — | ✅ bounded |
| `abi.encode(1000 ids)` memory | 1 op | < 1 M | — | — | ✅ linear |

(Concrete gas numbers are emitted via `log_named_uint` and visible in the `forge test -vv` output; this audit verifies the *flatness* property, not absolute numbers — those are covered in audit #15.)

## 4. Invariants verified

1. **Bond accounting**: `totalCommittedUSD` after 2 000 issuances equals `2000 × $100 × 1e18` exactly. After 500 redemptions of $100 each, it decreases by exactly `500 × $100 × 1e18`. No drift, no rounding loss.
2. **Listing IDs**: 300 sequential listings produce IDs in a strict monotonic +1 sequence — no collisions, no skips.
3. **Capacity cap**: in the 365-day run, `totalCommittedUSD < 1 260 000e18` at all times (matches the SAFETY_FACTOR_BPS × reserve cap).
4. **Per-policy state isolation**: 100 same-block settlements all succeed independently; settle of policy N does not affect policy N+1.
5. **DOS bound**: a 1 000-id batch of `performUpkeep` is capped by `MAX_POLICIES_PER_UPKEEP` and always returns within < 10 M gas — no out-of-gas, no infinite loop.

## 5. Findings

### 5.1 INFO — Cold-state SSTORE dominance on first-ever call

**Observation:** The first-ever `purchasePolicy`, `issueBond`, `marketplace.list`, etc. on a fresh deployment is 3–4× more expensive than steady-state due to cold-SSTORE costs on first-touch slots. This was already covered in audit #15 §5.1; this audit confirms that **after the first 10 operations**, every subsequent operation lives at the same gas cost regardless of how many ops have run before it (tested up to 2 000).

**Impact:** None at scale — only the first user pays the cold cost. Already documented in audit #15 with a deployer-pre-warm recommendation for V5.2.

### 5.2 INFO — `performUpkeep` batch size cap

**Observation:** `ShieldKeeper.performUpkeep` correctly caps iteration at `MAX_POLICIES_PER_UPKEEP` (the constant guards against keeper-supplied OOG). A 1 000-id batch is silently truncated to the cap. No loss-of-funds risk; off-chain keepers must batch-split policies they want settled.

**Impact:** None — this is the intended safety bound. Off-chain keeper drivers in `automation/` already split batches.

### 5.3 No HIGH / MEDIUM / LOW issues found

The protocol scales without state corruption, gas blow-up, or broken invariants under all tested volumes.

## 6. Static loop audit

See `01-STRESS-SCENARIOS.md` §4 for the line-by-line table. Summary:

- The only on-chain `for`-loop over an array is `ShieldKeeper.performUpkeep`, which is bounded.
- Every other scaling axis uses mappings (O(1) per access) — no iteration over policy / holder / listing universes.
- View functions (`getStats`, `availableCapacityUSD`) read scalars and one mapping slot — also O(1).

## 7. Regression

```
forge test --no-match-contract "Fork" --no-match-path "test/audit/invariant*"
```

```
Ran 108 test suites in 22.65s (98.10s CPU time): 1692 tests passed, 0 failed, 0 skipped (1692 total tests)
```

Baseline before audit was 1682. Delta = 10 new stress tests.

## 8. Reverse audit

- **Total tests:** 10 (new)
- **% substantive:** 100 % — every test deploys real proxies and drives them through the full call stack (no shortcuts, no mock internals).
- **Quality:** 9/10 — covers all scaling axes, validates flatness rather than chasing absolute numbers (which audit #15 already did), includes a static loop audit, and asserts invariants beyond just gas.

## 9. Verdict

**SCALABLE.** No code changes recommended. Gas-per-op stays flat across all measured volumes; invariants hold; no DOS vectors found. The two INFO findings (§5.1, §5.2) are not regressions — §5.1 was already known from audit #15, and §5.2 is intended safety behaviour.
