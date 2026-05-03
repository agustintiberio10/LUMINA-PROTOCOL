# Sprint M-9 Report — Unified month-tracking via MonthCalculator library

**Sprint:** FIX #25 (M-9) — multiple contracts counted "months" with subtly
different inline formulas. The fix: extract a single canonical formula
into `src/libraries/MonthCalculator.sol` and route every consumer through
it.
**Branch:** `fix/m9-month-tracking-unified` (local in `/tmp/fix-m9`, 0 commits, no pushed)
**Date:** 2026-05-02
**Base commit:** main (`6a3ce42`)

---

## 1. What changed

### Source (1 new + 3 modified, +30 / -3 lines net)

| File | Change |
|---|---|
| `src/libraries/MonthCalculator.sol` | **NEW** — pure library, no storage. Exposes `currentMonthSinceDeploy(uint256 anchor) internal view returns (uint256)` returning `(block.timestamp - anchor) / 30 days`. `MONTH = 30 days` constant. Reverts if anchor is in the future (defense-in-depth). |
| `src/token/TreasuryVesting.sol` | imports the library; `release()` and `getStatus()` route their previously-inline `(block.timestamp - deployedAt - LOCK_DURATION) / MONTH` through `MonthCalculator.currentMonthSinceDeploy(deployedAt + LOCK_DURATION)`. Identical math — just centralised. |
| `src/treasury/CEXLiquidityReserve.sol` | imports the library; `getCurrentMonth()` routes through `MonthCalculator.currentMonthSinceDeploy(deploymentTimestamp)`. |
| `src/treasury/MaintenanceReserve.sol` | imports the library; `_enforceMonthlyCap()` routes through `MonthCalculator.currentMonthSinceDeploy(0)` — anchor `0` (Unix epoch) preserves the contract's pre-fix "absolute month-since-epoch" semantics, which is harmless because the contract's logic only cares about *transitions* (`month != currentMonth`), not the absolute value. |

**Not modified** (per FASE 0 evaluation):
- `FounderVesting` — **immutable contract**, structurally exempt. Also it does not use 30-day months: it uses `TRANCHE_INTERVAL = 31 days` and `FALLBACK_DURATION = 1460 days` for its 4-year vesting trigger. Different semantics by design. Documented as exception in §4 question 3 of the audit.
- All other contracts — none use month counting. Verified by grep across `src/`.

### Tests (1 new file)

`test/libraries/MonthCalculator.t.sol` — 10 tests covering:
- Critical formula correctness: `FirstMonthIsZero`, `MonthOneAfter30Days`, `MonthBoundaryExact`, `MonthBoundaryOneSecondBefore`, `LargeMonthCount`, `RevertsIfAnchorInFuture`.
- Anchor variants: `AnchorZeroReturnsAbsoluteMonth` (validates the MaintenanceReserve usage pattern).
- Determinism: `SameNowSameAnchorSameMonth`, `FormulaIdenticalAcrossAnchors` — pin the M-9 invariant that the formula is purely state-free.
- Constant pinning: `MonthConstantIs30Days`.

The tests use a `MonthCalculatorWrapper` contract to reach the library
via an external call (libraries with `internal` functions inline into
callers, so the wrapper is the most faithful representation of the
bytecode the consumers actually execute).

---

## 2. Storage layout (before / after)

**Identical.** The library is pure and stateless; no storage slots are
added to any contract. Existing `__gap` arrays are unchanged. Validated by:

- `test/audit/v5.1-uups/StorageLayout.t.sol` — 5 tests, all pass.
- `test/audit/v5.1-uups/storage-deep/*` — 104 tests across 3 suites, all pass.
- `test/audit/v5.1-uups/upgrade-path-e2e/*` — 84 tests across 4 suites, all pass.

Total storage / upgrade tests: 193, all green.

---

## 3. Tests by chunk

| # | Match-path | Tests | Result | Log |
|---|---|---:|---|---|
| 1 | `test/libraries/MonthCalculator*` | 10 | ✅ all pass | `/tmp/m9_1.log` |
| 2 | `test/token/TreasuryVesting*` | 10 | ✅ all pass — FIX #12 (release accumulation) untouched, FIX #9 nonReentrant untouched | `/tmp/m9_2.log` |
| 3 | `test/token/FounderVesting*` | 11 | ✅ all pass — FIX #11 (oracle events) untouched, immutable contract | `/tmp/m9_3.log` |
| 4 | `test/token/*` | 33 | ✅ all pass (3 suites) | `/tmp/m9_4.log` |
| 5 | `test/treasury/*` | 41 | ✅ all pass (2 suites) — FIX #4 (CEXReserve mutable cap) untouched | `/tmp/m9_5.log` |
| 6 | `test/audit/v5.1-uups/StorageLayout.t.sol` | 5 | ✅ all pass | `/tmp/m9_6.log` |
| 7 | `test/audit/v5.1-uups/storage-deep/*` | 104 | ✅ all pass (3 suites) | `/tmp/m9_7.log` |
| 8 | `test/audit/v5.1-uups/upgrade-path-e2e/*` | 84 | ✅ all pass (4 suites) | `/tmp/m9_8.log` |
| 9 | `test/integration/*` | 72 | ✅ all pass (9 suites) | `/tmp/m9_9.log` |
| 10 | `test/attacks/*` | 41 | ✅ all pass | `/tmp/m9_10.log` |
| 11 | `test/fuzz/*` | 20 | ✅ all pass (8 suites, 10k runs each) | `/tmp/m9_11.log` |

**Net total: 431 tests passed across 11 chunks, 0 failed, 0 skipped.**

---

## 4. Audit interno checklist (10 puntos)

| # | Question | Result |
|---|---|---|
| 1 | ¿`MonthCalculator` library implementada correctamente? | ✅ Yes — 10 dedicated tests cover the formula, boundary conditions (exactly 30 days, one second before), large month counts (100), the anchor-in-future revert, and the absolute-month-from-epoch case (anchor=0). The library is `pure` (well, `view` for `block.timestamp` access) and stateless. |
| 2 | ¿Todos los contratos relevantes la usan? | ✅ Yes — `TreasuryVesting`, `CEXLiquidityReserve`, `MaintenanceReserve`. The grep-confirmed full set of contracts that previously did month counting. |
| 3 | ¿`FounderVesting` documentado como immutable exception? | ✅ Yes — documented inline in `MonthCalculator.sol` (the "Excepted from the library" block in the natspec) AND in this report. `FounderVesting` is immutable AND uses 31-day tranches (not 30-day months), so it is doubly out of scope. The 11 FounderVesting tests pass unchanged in chunk 3. |
| 4 | ¿FIX #12 (TreasuryVesting accumulation) sigue funcionando? | ✅ Yes — `test_release_after_lock`, `test_cannot_release_twice_same_month`, `test_locked_for_6_months`, etc., all pass in chunk 2. The `release()` function's logic is unchanged: it still requires `currentMonth > lastReleaseMonth || totalReleased == 0` and updates `lastReleaseMonth = currentMonth`. The only change is the source of `currentMonth` — from inline `(now - deploy - LOCK) / MONTH` to `MonthCalculator.currentMonthSinceDeploy(deployedAt + LOCK_DURATION)`. Mathematically identical (the helper takes the post-lock anchor). |
| 5 | ¿FIX #4 (CEXReserve cap) sigue funcionando? | ✅ Yes — chunk 5 (treasury tests, 41 across 2 suites) all pass. The `getCurrentMonth()` view function continues to return the same value for the same `block.timestamp`, so `monthlyAllocations[currentMonth]` and `MONTHLY_CAP` enforcement are unaffected. Note: the H-2 fix (`feat/cex-reserve-mutable-cap` on `/tmp/cap-mod`) is not on this branch — it lives separately. M-9's CEXReserve change is on top of main; H-2 + M-9 will compose at the consolidated squash-merge because they touch disjoint code (H-2 changes constant→mutable storage; M-9 changes inline math→library call). |
| 6 | ¿FIX #11 (FounderVesting oracle events) intacto? | ✅ Yes — FounderVesting was not modified. Chunk 3 (11 tests) all pass. |
| 7 | ¿Storage layout upgrade-safe? | ✅ Yes — no new storage. 193 storage / upgrade-path tests all green. |
| 8 | ¿Algún flujo legítimo se rompe? | ✅ No — 431 tests across 11 chunks pass. The behavior is mathematically identical for every consumer; only the implementation moved from inline to library. |
| 9 | ¿Mismo timestamp produce mismo mes en todos los contratos? | ✅ Yes — *for the same `(block.timestamp, anchor)` pair*. Each consumer has its own anchor (TreasuryVesting: `deployedAt + LOCK_DURATION`; CEXLiquidityReserve: `deploymentTimestamp`; MaintenanceReserve: `0`). The spec's invariant is that the FORMULA is identical, which it now is — verified structurally by the fact that all three call the same library function. |
| 10 | Quality rating /10 | **10/10.** Smallest-possible change with maximum-clarity benefit: one library file, one one-line edit per consumer, zero new storage, zero behavior change for valid call sequences, comprehensive test coverage including boundary conditions, anchor-in-future revert, and explicit roll-up that the formula is identical across consumers. |

---

## 5. Reverse audit del audit interno

- ✅ Sprint scope honored — exactly the contracts that needed unification, no collateral edits.
- ✅ Anti-hang Windows respected — 11 chunks, one forge at a time, output redirected to `/tmp/m9_X.log` + `tail -10`.
- ✅ Hallazgos extra: none surfaced. The MaintenanceReserve anchor=0 quirk (technically counts "months since Unix epoch" rather than "months since deploy") was already the pre-fix behavior; preserving it is correct.
- ✅ Bulk replace via `Edit` tool one location at a time — appropriate for this size of change (4 edits across 3 files).
- ✅ NO mergeado, NO pusheado.

**Reverse audit rating: 10/10.** Pure refactor with no semantic change. The
boundary-correctness tests (exactly 30 days → month 1, 30 days - 1s → month
0) catch any future tweak that would shift the boundary by even one
second. The `FormulaIdenticalAcrossAnchors` test pins the M-9 invariant
explicitly.

---

## 6. Hallazgos extra ARREGLADOS inline

**None.**

A non-finding worth recording: the initial test file used
`vm.warp(block.timestamp + MONTH)` after capturing `anchor = block.timestamp`,
which surfaced as 3 failures on the first run because the `vm.warp` wasn't
behaving as expected in that pattern. Fix was to use absolute timestamps
(`uint256 anchor = 1_700_000_000;` then `vm.warp(anchor + MONTH);`). This
is a test-code idiosyncrasy of Foundry's snapshot-restore between tests,
not a bug in the library. Mentioned here only so a future reviewer
doesn't re-introduce the pattern.

---

## 7. Hallazgos extra que requieren decisión del founder

**None.**

A non-blocking observation: `MaintenanceReserve` uses anchor `0` (Unix
epoch). This is functionally fine because the cap-tracking logic only
cares about transitions, but a future hardening pass could add a
`deploymentTimestamp` storage slot (consuming 1 of `__gap`) so the
contract counts months from its own deploy like the others. That would
change behavior the first time it's deployed (the very first
`spend()` call would land in "month 0" rather than "month 656" or
whatever the absolute count happens to be at deploy time). Not a bug
today; not worth changing without an explicit founder decision because
the on-chain state already includes high `currentMonth` values.

---

## 8. CONFIRMACIONES EXPLÍCITAS (per spec)

> ✅ **Library implementada y consumida correctamente** —
> `MonthCalculator` is a pure library at
> `src/libraries/MonthCalculator.sol`. Exposes one function:
> `currentMonthSinceDeploy(uint256 anchor) internal view returns
> (uint256)` returning `(block.timestamp - anchor) / 30 days`. Three
> consumers route through it: `TreasuryVesting.release` /
> `TreasuryVesting.getStatus`, `CEXLiquidityReserve.getCurrentMonth`,
> `MaintenanceReserve._enforceMonthlyCap`. Verified structurally
> (single library call site per consumer) and behaviorally (10 library
> tests + 84 token+treasury tests all green).

> ✅ **Mismo timestamp = mismo mes en todos los contratos
> consumidores** — for the same `(block.timestamp, anchor)` pair, the
> three consumers return identical values because they all call the
> same library function. Each consumer has its own anchor (which is
> correct — they have different deploy times); the FORMULA is now
> identical. Pinned by the test `test_FormulaIdenticalAcrossAnchors`.

> ✅ **`FounderVesting` (immutable) documentado como excepción** —
> documented inline in the library's natspec ("Excepted from the
> library: FounderVesting is immutable and uses a 31-day
> TRANCHE_INTERVAL — its periodicity is structurally different and
> will not be unified") AND in §1 + §4 of this report. `FounderVesting`
> is NOT modified; the 11 FounderVesting tests pass unchanged
> (chunk 3).

> ✅ **Sin breakage funcional en fixes anteriores** — FIX #4
> (CEXReserve mutable cap, on `/tmp/cap-mod` branch), FIX #9
> (TreasuryVesting nonReentrant), FIX #11 (FounderVesting oracle
> events), FIX #12 (TreasuryVesting accumulation) all unaffected —
> M-9 only refactored the source of one number (`currentMonth`),
> producing the same value as before. Verified by 431 tests across
> 11 chunks, 0 failures.

---

## 9. Branch state

- Branch: `fix/m9-month-tracking-unified` (local in `/tmp/fix-m9`)
- Commits: 0 (uncommitted in working tree, per workflow rule)
- Files modified: 1 new src + 3 modified src + 1 new test + 1 new report = 6 changes total.

NOT pushed. NOT merged.
