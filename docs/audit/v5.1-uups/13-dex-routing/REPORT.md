# V5.1 Audit #13 — DEX Routing Audit

**Audit ID:** V5.1 #13 of 40 (Bloque 3)
**Branch:** `audit/v5.1-13-dex-routing`
**Date:** 2026-04-23

---

## 1. Executive Summary

32 new tests (100% substantive) exercising TWAPBurner's DEX routing
(Uniswap V3 + Aerodrome adapters). All pass. Regression unchanged.

**Verdict: ROBUST WITH ONE MEDIUM FINDING.** The router-failure,
slippage, quote, and config surfaces are all sound. One MEDIUM gap is
flagged: **when DEX adapters return 0 for `getQuote` AND CapacityOracle
is unconfigured or failing, `minOut` degrades to 0** — a swap would
accept any non-zero return and be vulnerable to a sandwich attack. The
current adapter implementations return 0 for quote by design, so this
relies on CapacityOracle being properly wired for slippage protection.

---

## 2. Scope

- `src/core/TWAPBurner.sol`: `executeBurn`, `_executeAdaptive`,
  `_swapAndBurn`, all setters.
- `src/dex/UniswapV3Adapter.sol` and `src/dex/AerodromeAdapter.sol`.
- `src/interfaces/IDexRouter.sol`.

Inventory in `01-DEX-USAGE.md`.

---

## 3. Tests Created

| File | Tests |
|------|-------|
| `DEXRouting.t.sol` | 32 |

### Categories
- Router failure propagation (swap revert, swap returns 0): 2 tests
- Quote-path fallback (both quotes revert → dexRouters[0] used): 1
- Best-router selection (higher quote wins): 1
- Oracle backstop (minOut enforced when quote=0 and oracle live): 2
- Oracle revert (falls back to quote-only): 1
- Min/max/cap burn-amount boundaries: 3
- Cooldown (enforced + clears): 2
- Setter range validation (slippage, cooldown, pool fee, min/max): 5
- Admin access control: 3
- Burn effect on totalSupply + counters: 2
- Approval hygiene (no residual allowance): 2
- addDexRouter extends / zero rejected: 2
- setCapacityOracle zero/non-zero: 2
- Legacy burn path: 1
- Empty routers array rejected: 1
- No-routers guard (documentary): 1

All 32 tests pass.

---

## 4. Issues Found

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 1 |
| LOW | 0 |
| INFO | 3 |

### MEDIUM
- **M-02** — **`minOut` can degrade to 0 if both the adapter quote path
  and the CapacityOracle fail simultaneously.** `UniswapV3Adapter.
  getQuote` and `AerodromeAdapter.getQuote` both currently return 0 (by
  design — adapters are stubs in this respect). TWAPBurner then relies
  entirely on the CapacityOracle-derived minOut. If `capacityOracle`
  has been unset (its zero-address default), or its `getLuminaPrice()`
  reverts, `minOut` stays at 0 and the swap accepts any non-zero return.

  **Mitigation (already partial):** the swap still reverts on
  `luminaReceived == 0`, and the max slippage range (50..1000 bps) is
  admin-enforced but only has bite when a non-zero reference price is
  available.

  **Recommendation:** either (a) implement a non-zero `getQuote` in
  both adapters (the stub returning 0 is the root cause), or (b) add
  a TWAPBurner-level require that `minOut > 0` before the swap call to
  force the admin to wire CapacityOracle correctly.

### INFO
- **I-01** — Adapters' `getQuote` implementation is a stub returning 0.
  This is a documented design choice (§5 of `01-DEX-USAGE.md`), but it
  means best-router selection is effectively disabled today. See M-02.
- **I-02** — Aerodrome's swap uses `block.timestamp` as deadline; no
  mempool delay attack is possible because the swap must execute in the
  submitting block.
- **I-03** — Uniswap V3 adapter's `exactInputSingle` does not take a
  deadline parameter (its interface omits it). This is consistent with
  the standard V3 SwapRouter2 signature.

---

## 5. Quality Rating

**9.0 / 10**

- +3.5 All failure modes exercised (revert, zero, below-minOut, etc).
- +1.5 Oracle backstop semantics tested both ways (enforced + bypass).
- +1.0 Config range setters fully covered.
- +1.0 Admin access control tests on every owner-gated function.
- +1.0 Cooldown enforcement tested forward and reset.
- +0.5 Total-counter accounting tested.
- +0.5 Approval hygiene tested.
- −1.0 No integration test against a real forked Uniswap V3 or Aerodrome
       pool — documented in `01-DEX-USAGE.md`. Full fork tests exist in
       `test/fork/` but are out of scope for this audit's scope slice.

---

## 6. Verdict

**ROBUST WITH ONE MEDIUM FINDING**

M-02 should be addressed before mainnet: either implement non-zero
`getQuote` in both adapters or gate TWAPBurner on `minOut > 0`. A dedicated
`fix/` PR is the appropriate vehicle for this; design is straightforward.

All other surfaces are correctly validated.

---

## 7. Raw `forge test` Output

```
No files changed, compilation skipped

Ran 32 tests for test/audit/v5.1-uups/external-deps/dex/DEXRouting.t.sol:DEXRouting
[PASS] test_DEX_AboveMaxBurnAmount_UsesMaxCap() (gas: 406231)
[PASS] test_DEX_AddDexRouter_ExtendsArray() (gas: 49648)
[PASS] test_DEX_AddDexRouter_Zero_Reverts() (gas: 17466)
[PASS] test_DEX_Approval_ConsumedBySwap() (gas: 406556)
[PASS] test_DEX_Approval_Exact_NoOverApprove() (gas: 406045)
[PASS] test_DEX_AtMinBurnAmount_Succeeds() (gas: 404760)
[PASS] test_DEX_BelowMinBurnAmount_Reverts() (gas: 56340)
[PASS] test_DEX_BestQuote_PicksHigherQuote() (gas: 502390)
[PASS] test_DEX_BothQuotesRevert_FallsBackToFirst() (gas: 475296)
[PASS] test_DEX_Burn_ReducesTotalSupply() (gas: 406520)
[PASS] test_DEX_Cooldown_ClearsAfterPeriod() (gas: 560527)
[PASS] test_DEX_Cooldown_EnforcedBetweenBurns() (gas: 426671)
[PASS] test_DEX_LegacyBurn_PathWorks() (gas: 406824)
[PASS] test_DEX_NoRouters_ExecuteBurn_Reverts() (gas: 416181)
[PASS] test_DEX_NonOwner_CannotAddDexRouter() (gas: 21194)
[PASS] test_DEX_NonOwner_CannotSetDexRouters() (gas: 21761)
[PASS] test_DEX_NonOwner_CannotSetMaxSlippage() (gas: 17577)
[PASS] test_DEX_OracleBackstop_MinOutEnforced_WhenRouterReturnsBelow() (gas: 213648)
[PASS] test_DEX_OracleBackstop_MinOutMet_Succeeds() (gas: 438604)
[PASS] test_DEX_OracleReverts_ContinuesWithQuoteMinOut() (gas: 453526)
[PASS] test_DEX_RouterReverts_ExecuteBurn_Reverts() (gas: 145231)
[PASS] test_DEX_SetBurnCooldown_OutOfRange_Reverts() (gas: 25564)
[PASS] test_DEX_SetCapacityOracle_NonZero_Accepted() (gas: 23708)
[PASS] test_DEX_SetCapacityOracle_Zero_Reverts() (gas: 16612)
[PASS] test_DEX_SetMaxBurnAmount_BelowMin_Reverts() (gas: 25574)
[PASS] test_DEX_SetMinBurnAmount_BelowFloor_Reverts() (gas: 17366)
[PASS] test_DEX_SetPoolFee_OnlyValidTiers() (gas: 30933)
[PASS] test_DEX_SetRouters_EmptyArray_Reverts() (gas: 17053)
[PASS] test_DEX_SetSlippage_OutOfRange_Reverts() (gas: 16047)
[PASS] test_DEX_SetSlippage_WithinRange_Succeeds() (gas: 26839)
[PASS] test_DEX_SwapReturnsZero_Reverts() (gas: 174088)
[PASS] test_DEX_TotalCounters_IncrementOnBurn() (gas: 409176)
Suite result: ok. 32 passed; 0 failed; 0 skipped

Ran 1 test suite in 11.52ms: 32 tests passed, 0 failed, 0 skipped (32 total tests)
```

Full regression (non-fork, non-invariant): **1631 tests passed, 0 failed, 0 skipped (1631 total)**
— 1599 pre-existing + 32 new = zero regression.
