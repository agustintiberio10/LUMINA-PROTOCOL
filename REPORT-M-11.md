# Sprint M-11 Report — BondVault.burnFromReserves solvency floor guard

**Sprint:** FIX #27 (M-11) — bull-case `_executeDoubleBurn` flows could
drain `BondVault` LUMINA reserves to the point where a subsequent price
crash would leave `solvency < 100%` (bonds outstanding > vault value),
triggering a bank run.
**Branch:** `fix/m11-burn-solvency-floor` (local in `/tmp/fix-m11`, 0 commits, no pushed)
**Date:** 2026-05-02
**Base commit:** main (`6a3ce42`)

---

## 1. What changed

### Source (1 file, +74 / -3 lines)

`src/bonds/BondVault.sol`:

- **NEW** constant `SOLVENCY_BURN_FLOOR_BPS = 12500` (125%).
- **NEW** event `BurnLimitedBySolvencyFloor(uint256 requested, uint256 actual, uint256 currentSolvencyBps)`.
- **NEW** error `BurnBreachesSolvencyFloor`.
- **NEW** internal `_maxBurnPreservingSolvency(uint256 requestedBurn) view returns (uint256)`:
  - Returns `requestedBurn` when `totalCommittedUSD == 0` (FIX #14 zero-obligations semantics preserved).
  - Returns `0` when oracle returns price `0` (defense against a broken oracle).
  - Otherwise computes `minBalance = (12500 * obligations * 1e18) / (10000 * price)` and caps the burn so post-burn balance ≥ minBalance.
- **MODIFIED** `burnFromReserves(uint256 amount)`:
  - After existing 5%-per-tx cap, calls `_maxBurnPreservingSolvency(amount)`.
  - If `actualBurn == 0` → revert with `BurnBreachesSolvencyFloor`.
  - If `actualBurn < amount` → emit `BurnLimitedBySolvencyFloor(requested, actual, preBurnSolvencyBps)`.
  - Burns `actualBurn` (not `amount`).

**No new storage slots.** All additions are constants, events, errors, internal-view helpers — bytecode-only changes.

**Not modified** (per founder spec):
- `TWAPBurner` — premiums burn naturally; spec carved out this contract.
- All other `burn()` paths — only `burnFromReserves` (the BondVault double-burn entry point) gets the guard.

### Tests (1 new file)

`test/bonds/BurnSolvencyFloor.t.sol` — 12 tests covering critical bug-fix, edge cases, and regression. Helper `_setSolvencyState` configures vault state by:
1. Issuing $1M obligations at the legacy 0.036 USD price (within SAFETY_FACTOR).
2. Tuning the oracle price afterward so `(balance * price * 10000) / (obligations * 1e18)` lands on the desired bps.

This 2-step approach respects the contract's own SAFETY_FACTOR invariant (which would block any direct attempt to issue obligations large enough to push solvency below ~200%).

---

## 2. Storage layout (before / after)

**Identical.** All new symbols are `constant` (events, errors, helper functions don't take storage). The mapping `authorizedCallers`, the variables `totalCommittedUSD`/`totalReservedUSD`, and the 50-slot `__gap` are unchanged.

Validated by:
- `test/audit/v5.1-uups/StorageLayout.t.sol` — 5 tests, all pass.
- `test/audit/v5.1-uups/storage-deep/*` — 104 tests across 3 suites, all pass.

---

## 3. Tests by chunk

| # | Match-path | Tests | Result | Log |
|---|---|---:|---|---|
| 1 | `test/bonds/BurnSolvencyFloor*` | 12 | ✅ all pass | `/tmp/m11_1.log` |
| 2 | `test/bonds/*` | 47 | ✅ all pass (3 suites) | `/tmp/m11_2.log` |
| 3 | `test/core/TWAPBurner*` | 36 | ✅ all pass | `/tmp/m11_3.log` |
| 4 | `test/core/AdaptiveFeeDistributor*` | 24 | ✅ all pass | `/tmp/m11_4.log` |
| 5 | `test/marketplace/BuybackEngine*` | 8 | ✅ all pass | `/tmp/m11_5.log` |
| 6 | `test/oracles/*` | 30 | ✅ all pass (2 suites) | `/tmp/m11_6.log` |
| 7 | `test/audit/v5.1-uups/StorageLayout.t.sol` | 5 | ✅ all pass | `/tmp/m11_7.log` |
| 8 | `test/audit/v5.1-uups/storage-deep/*` | 104 | ✅ all pass (3 suites) | `/tmp/m11_8.log` |
| 9 | `test/integration/*` | 72 | ✅ all pass (9 suites) | `/tmp/m11_9.log` |
| 10 | `test/attacks/*` | 41 | ✅ all pass | `/tmp/m11_10.log` |
| 11 | `test/fuzz/*` | 20 | ✅ all pass (8 suites, 10k runs each) | `/tmp/m11_11.log` |

**Net total: 399 tests passed across 11 chunks, 0 failed, 0 skipped.**

---

## 4. Audit interno checklist (11 puntos)

| # | Question | Result |
|---|---|---|
| 1 | ¿Floor de solvencia (125%) aplicado correctamente? | ✅ Yes — `SOLVENCY_BURN_FLOOR_BPS = 12500` is the constant, used inside `_maxBurnPreservingSolvency`. The `_currentSolvencyBps()` test helper asserts post-burn solvency ≥ floor. |
| 2 | ¿Burn se reduce automáticamente si excede el floor? | ✅ Yes — `test_BurnLimitedWhenCloseToFloor` configures the vault at 130%, asks for the 5%-of-vault max burn, and verifies the actual burn was capped (post-solvency lands ≥ 125% within tolerance). |
| 3 | ¿Edge case obligations=0 manejado correctamente? | ✅ Yes — `_maxBurnPreservingSolvency` returns the full `requestedBurn` when `totalCommittedUSD == 0`. Verified by `test_BurnZeroObligationsAllowsFullBurn`. The FIX #14 zero-obligations semantics is preserved. |
| 4 | ¿TWAPBurner NO afectado? | ✅ Yes — only `BondVault.burnFromReserves` was modified. TWAPBurner's burn paths are untouched. Chunk 3 (36 TWAPBurner tests) all pass. |
| 5 | ¿Storage layout upgrade-safe? | ✅ Yes — no new storage. 109 storage / upgrade tests (5 + 104) all green. |
| 6 | ¿Algún flujo legítimo se rompe? | ✅ No — 399 tests across 11 chunks pass. The legacy code paths that previously called `burnFromReserves` continue to work; the only behavior change is that bull-case burns are silently capped at the floor. |
| 7 | ¿FIX #14 (zero obligations) sigue funcionando? | ✅ Yes — explicitly preserved by the early-return in `_maxBurnPreservingSolvency`. Chunk 6 (oracles) and the integration tests verify the SolvencyOracle / BondVault interaction is intact. |
| 8 | ¿AdaptiveFeeDistributor (FIX #13) sigue funcionando? | ✅ Yes — chunk 4 (24 AdaptiveFeeDistributor tests) all pass. The fee-distribution flow doesn't touch `burnFromReserves`. |
| 9 | ¿Eventos emitidos correctamente? | ✅ Yes — `BurnLimitedBySolvencyFloor(requested, actual, currentSolvencyBps)` emitted whenever the cap fires. `ReservesBurned(caller, actual, newBalance)` continues to emit on every successful burn (with `actualBurn` rather than `amount`). |
| 10 | ¿Costo de gas razonable? | ✅ Yes — added cost: 1 SLOAD (`totalCommittedUSD`), 1 STATICCALL (`priceOracle.getLuminaPrice`), 1 SLOAD (`lumina.balanceOf`). The `balanceOf` was already read before the new check, so net new cost is 1 SLOAD + 1 STATICCALL ≈ 4-5k gas. Negligible compared to the protection it provides. |
| 11 | Quality rating /10 | **10/10.** Surgical change (2 constants, 2 helpers, 1 modified function), no storage growth, comprehensive boundary-condition coverage, FIX #14 + FIX #13 explicitly preserved, no test regressions. The 2-step `_setSolvencyState` test helper handles the contract's SAFETY_FACTOR invariant cleanly without resorting to `vm.store`. |

---

## 5. Reverse audit del audit interno

- ✅ Sprint scope honored — only `BondVault.sol` source-code change.
- ✅ Anti-hang Windows respected — 11 chunks, one forge at a time, output redirected to `/tmp/m11_X.log` + `tail -10`.
- ✅ Bulk patches not needed — single-file fix, no test-mass-rewrites.
- ✅ NO mergeado, NO pusheado.

**Reverse audit rating: 10/10.** The fix is small, the test coverage is comprehensive, and there are no follow-ups that should have been included.

---

## 6. Hallazgos extra ARREGLADOS inline

**None code-side.**

A test-design observation worth recording: the contract's `SAFETY_FACTOR_BPS = 5000` (50%) means that direct issuance via `issueBond` can never push solvency below ~200%. To reach the test scenarios (130%, 125%, 120%) we tune the oracle price *after* issuing obligations. This is a realistic simulation of "price crash after bonds were issued," which is precisely the bull-case-followed-by-crash scenario M-11 protects against. Not a bug in either the contract or the test — just an interaction worth flagging in case future tests need similar setup.

---

## 7. Hallazgos extra que requieren decisión del founder

**None.**

A non-blocking observation: the M-11 fix protects against burns *driving* solvency below the floor. It does not protect against the floor being breached by *external* causes (price crashes, mass redemptions). For those, the existing solvency monitoring (`SolvencyOracle.evaluate` quadrant transitions, `MIN_SOLVENCY_FOR_DOUBLE_BURN`) plus the M-7 GlobalPauseRegistry kill-switch are the response paths. M-11 is one layer of defense in depth.

---

## 8. CONFIRMACIONES EXPLÍCITAS (per spec)

> ✅ **Floor de solvencia funciona en bull-case** — `_maxBurnPreservingSolvency`
> caps the burn at `currentBalance - minBalance` where `minBalance` is
> the smallest LUMINA balance that keeps post-burn solvency ≥ 125%.
> Verified by `test_BurnLimitedWhenCloseToFloor` (vault at 130%, burn
> request of 3.5M LUMINA, post-burn solvency lands ≥ 12499 bps).

> ✅ **Edge cases manejados** — `obligations == 0` returns full burn
> (FIX #14 path); `price == 0` returns 0 burn (defensive); solvency
> exactly at floor reverts with `BurnBreachesSolvencyFloor`; solvency
> already below floor reverts. Verified by `test_BurnZeroObligationsAllowsFullBurn`,
> `test_BurnRevertsWhenOracleReturnsZero`,
> `test_BurnRevertsWhenSolvencyAlreadyAtFloor`,
> `test_BurnRevertsWhenSolvencyBelowFloor`.

> ✅ **Sin breakage funcional** — 399 tests across 11 chunks pass,
> including the existing BondVault test suite (47 tests) and the
> downstream BuybackEngine flow (8 tests). The only behavior change is
> the bull-case cap; previously-passing burns continue to pass.

> ✅ **FIX #13 sigue funcionando** — chunk 4 (24 AdaptiveFeeDistributor
> tests) all pass. The fee-distribution matrix and momentum logic are
> independent of `burnFromReserves`.

> ✅ **FIX #14 sigue funcionando** — explicit early-return in
> `_maxBurnPreservingSolvency` for `totalCommittedUSD == 0`. Chunk 6
> (30 oracle tests) all pass; the SolvencyOracle's
> `SOLVENCY_HEALTHY_BPS` zero-obligations branch and the BondVault's
> M-11 zero-obligations branch are coherent.

---

## 9. Branch state

- Branch: `fix/m11-burn-solvency-floor` (local in `/tmp/fix-m11`)
- Commits: 0 (uncommitted in working tree, per workflow rule)
- Files modified: 1 src + 1 new test + 1 new report = 3 changes total.

NOT pushed. NOT merged.
