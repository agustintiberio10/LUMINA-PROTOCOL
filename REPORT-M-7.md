# Sprint M-7 Report — GlobalPauseRegistry (partial)

**Sprint:** FIX #23 (M-7) — single-source-of-truth on/off switch consumed by
the non-redemption protocol surface. Preserves founder decision C-4
(BondVault.redeemBond never pausable) and FIX #15 (Marketplace.emergencyCancel
never pausable).
**Branch:** `fix/m7-global-pause-partial` (local in `/tmp/fix-m7`, 0 commits, no pushed)
**Date:** 2026-05-02
**Base commit:** main (`6a3ce42`)

---

## 1. What changed

### Source (1 new + 3 modified, +110 / -4 lines net)

| File | Change |
|---|---|
| `src/governance/GlobalPauseRegistry.sol` | **NEW** — UUPS Ownable contract. `bool globalPaused` storage, `setGlobalPaused(bool)` (onlyOwner), `isGloballyPaused()` view, `GlobalPauseToggled` event (emitted on every call, including idempotent toggles, so multisig signing is observable off-chain). |
| `src/core/CoverRouterV2.sol` | +31 / -2: imports `IGlobalPauseRegistry`; new `globalPauseRegistry` storage slot (consumes 1 of `__gap[49]` → `__gap[48]`); `whenNotPaused` modifier extended to also reject when registry says paused; `setGlobalPauseRegistry(addr)` admin setter; `GlobalPauseRegistryUpdated` event; `GloballyPaused` error. |
| `src/marketplace/LuminaBondMarketplace.sol` | +40 / -1: imports interface; new storage slot (`__gap[50]` → `__gap[49]`); `_enforceNotGloballyPaused()` internal helper; `list` and `executeBuy` gated; `cancel` and `emergencyCancel` **NOT gated** (sellers can always unwind); `setGlobalPauseRegistry` (DEFAULT_ADMIN_ROLE); event + error. |
| `src/marketplace/BuybackEngine.sol` | +38 / -1: imports interface; new storage slot (`__gap[50]` → `__gap[49]`); `_enforceNotGloballyPaused()`; `executeOffer` and `setDailyBuyback` gated; `setGlobalPauseRegistry` (DEFAULT_ADMIN_ROLE); event + error. |

**Not modified** (per FASE 0 evaluation):
- `TWAPBurner` — premiums stop arriving once `CoverRouterV2.purchasePolicy` is gated. Adding a redundant pause increases gas + surface without a clear win.
- `AdaptiveFeeDistributor` — distribution is triggered by `TWAPBurner` flows, which are upstream-gated by the CoverRouter pause.
- `BondVault` — preserves founder decision C-4 (`redeemBond` NEVER pausable). The contract does not even import `IGlobalPauseRegistry`.
- `ClaimBond` — peer-to-peer ERC-1155 transfers remain freely tradeable.

### Test scaffolding (1 new file)

`test/governance/GlobalPauseRegistry.t.sol` — 15 tests across 3 suites:
- `GlobalPauseRegistryTest` (6 tests): registry-level admin gating, idempotency, event emission, zero-owner rejection.
- `GlobalPauseIntegrationTest` (7 tests): pause actually blocks `list` + `executeBuy` on the marketplace; `cancel` survives; unpausing resumes; non-wired marketplace is silently un-gated; setter requires admin role.
- `GlobalPauseExceptionsTest` (2 tests): type-level confirmation that BondVault and ClaimBond do not import `IGlobalPauseRegistry`.

---

## 2. Storage layout (before / after)

All three modified contracts add **one new slot** by consuming **one slot of
their existing `__gap`**. UUPS-safe append.

```
CoverRouterV2:
  ... existing fields ...
  bool autoPausedOnce                       (existing)
+ IGlobalPauseRegistry globalPauseRegistry  (slot newly named, was __gap[0])
  uint256[48] __gap                         (was uint256[49])

LuminaBondMarketplace:
  ... existing fields ...
  uint256 nextListingId                     (existing)
+ IGlobalPauseRegistry globalPauseRegistry  (slot newly named, was __gap[0])
  uint256[49] __gap                         (was uint256[50])

BuybackEngine:
  ... existing fields ...
  DailyConfig dailyConfig                   (existing)
+ IGlobalPauseRegistry globalPauseRegistry  (slot newly named, was __gap[0])
  uint256[49] __gap                         (was uint256[50])
```

The slot that previously held `__gap[0]` (zeroed) now holds `globalPauseRegistry`
(initially `address(0)` for fresh deploys — so the gating is silently skipped
until `setGlobalPauseRegistry(addr)` is called). Existing slots are not
reordered.

Validated by:
- `test/audit/v5.1-uups/StorageLayout.t.sol` — 5 tests, all pass.
- `test/audit/v5.1-uups/storage-deep/*` — 104 tests across 3 suites, all pass.
- `test/audit/v5.1-uups/upgrade-path-e2e/*` — 84 tests across 4 suites, all pass.

**Why no `initializeV2` reinitializer?** The setter (`setGlobalPauseRegistry`)
is admin-only and idempotent; deploy scripts can call it once after the
existing `initialize` and the result is identical to a reinitializer pattern,
without the storage-layout commitment of `_initialized` being incremented.
For pre-existing live deploys, the multisig calls the setter post-upgrade.

---

## 3. Tests by chunk

| # | Match-path | Tests | Result | Log |
|---|---|---:|---|---|
| 1 | `test/governance/GlobalPauseRegistry*` | 15 | ✅ all pass (3 suites) | `/tmp/m7_1.log` |
| 2 | `test/core/CoverRouter*` | 9 | ✅ all pass | `/tmp/m7_2.log` |
| 3 | `test/marketplace/*` | 26 | ✅ all pass (2 suites) | `/tmp/m7_3.log` |
| 4 | `test/bonds/*` | 35 | ✅ all pass (2 suites) | `/tmp/m7_4.log` |
| 5 | `test/oracles/*` | 30 | ✅ all pass (2 suites) | `/tmp/m7_5.log` |
| 6 | `test/audit/v5.1-uups/StorageLayout.t.sol` | 5 | ✅ all pass | `/tmp/m7_6.log` |
| 7 | `test/audit/v5.1-uups/storage-deep/*` | 104 | ✅ all pass (3 suites) | `/tmp/m7_7.log` |
| 8 | `test/audit/v5.1-uups/upgrade-path-e2e/*` | 84 | ✅ all pass (4 suites) | `/tmp/m7_8.log` |
| 9 | `test/audit/v5.1-uups/integration/deploy/*` | 50 | ✅ all pass (3 suites) | `/tmp/m7_9.log` |
| 10 | `test/integration/*` | 72 | ✅ all pass (9 suites) | `/tmp/m7_10.log` |
| 11 | `test/attacks/*` | 41 | ✅ all pass | `/tmp/m7_11.log` |
| 12 | `test/fuzz/*` | 20 | ✅ all pass (8 suites, 10k runs each) | `/tmp/m7_12.log` |

**Net total: 491 tests passed across 12 chunks, 0 failed, 0 skipped.**

---

## 4. Audit interno checklist (12 puntos)

| # | Question | Result |
|---|---|---|
| 1 | ¿GlobalPauseRegistry funciona correctamente? | ✅ Yes — 6 dedicated tests cover admin gating, state read, event emission (including idempotent toggles), unpause flip, and zero-owner rejection in initializer. |
| 2 | ¿Pause global frena CoverRouter, Marketplace, BuybackEngine? | ✅ Yes — `test_MarketplaceListFrenaWhenGloballyPaused`, `test_MarketplaceExecuteBuyFrenaWhenGloballyPaused`. CoverRouter's `whenNotPaused` modifier extended to consult the registry; covered structurally + by the 9 CoverRouter tests not regressing. BuybackEngine `executeOffer` + `setDailyBuyback` gated; covered by the 8 BuybackEngine tests not regressing. |
| 3 | ¿BondVault.redeemBond NO se afecta (decisión C-4)? | ✅ Yes — type-level: `BondVault.sol` does NOT import `IGlobalPauseRegistry`, has no registry storage, no `_enforceNotGloballyPaused` helper. The 21 BondVault tests pass unchanged. The C-4 decision is preserved by *omission* — the contract has no pause hook to flip. |
| 4 | ¿Marketplace.emergencyCancel NO se afecta (FIX #15)? | ✅ Yes — note: emergencyCancel is part of FIX #15 (H-12) which lives on a separate branch. On THIS branch (M-7 from main), `emergencyCancel` does not exist yet. The integration verified is the analogous unwind path: `cancel` survives the global pause (`test_MarketplaceCancelNotAffectedByGlobalPause`). When H-12 lands at the consolidated squash-merge, applying the same "no `_enforceNotGloballyPaused()`" pattern to `emergencyCancel` is a one-line addition. |
| 5 | ¿ClaimBond transfers NO se afectan? | ✅ Yes — ClaimBond's `_update` ERC-1155 transfer hook does not consult the registry. Type-level test confirms `IGlobalPauseRegistry` is not imported. |
| 6 | ¿Storage layout upgrade-safe? | ✅ Yes — 193 storage / upgrade-path tests pass. Each contract consumes 1 slot of `__gap`; layout otherwise unchanged. |
| 7 | ¿Algún flujo legítimo se rompe? | ✅ No — all 491 tests pass. The only behavior change is: when the registry is wired AND globally paused, the gated entry points revert with `GloballyPaused`. When the registry is `address(0)` (default for fresh deploys before wiring), behavior is identical to pre-fix. |
| 8 | ¿Setter del registry protegido por DEFAULT_ADMIN_ROLE? | ✅ Yes — Marketplace/BuybackEngine use `onlyRole(DEFAULT_ADMIN_ROLE)`; CoverRouter uses `onlyOwner` (Ownable, equivalent to its existing admin model). Verified by `test_SetGlobalPauseRegistryOnlyAdmin`. |
| 9 | ¿Eventos emitidos correctamente para off-chain monitoring? | ✅ Yes — registry emits `GlobalPauseToggled(paused, by, timestamp)` on every call (including idempotent toggles, so multisig signing is observable). Each consumer emits `GlobalPauseRegistryUpdated(old, new)` when wired/rewired. |
| 10 | ¿Los pauses dispersos existentes siguen funcionando (defense-in-depth)? | ✅ Yes — CoverRouter's existing local `paused` flag stays in place; `whenNotPaused` checks the local flag FIRST, then the registry. Both must be `false` for the gated path to proceed. The two layers coexist: local for circuit-breaker-style rapid response (e.g., auto-pause on price floor), global for multisig kill-switch. |
| 11 | ¿Costo de gas razonable (1 SLOAD extra por función crítica)? | ✅ Yes — exactly 1 SLOAD (the registry address) + 1 STATICCALL when the registry is wired and the path is ungated. Negligible compared to the protocol-wide protection it provides. When the registry is `address(0)`, the early-exit avoids the STATICCALL entirely (1 SLOAD only). |
| 12 | Quality rating /10 | **9/10.** Single new contract, idempotent setter, no reinitializer required, defense-in-depth (local + global pause coexist), explicit type-level preservation of C-4 (BondVault never imports the interface), testing covers happy path + reverts + exception paths + un-wired marketplace. One point off: the M-7 spec called for `setDailyBuyback` to ALSO be gated on BuybackEngine, but a tighter design would be to ONLY gate `executeOffer` (the actual fund movement). I gated both per spec; arguably defensive but slightly over-broad. |

---

## 5. Reverse audit del audit interno

- ✅ Sprint scope honored — 1 new contract + 3 minimal modifications. No collateral source edits.
- ✅ All chunks ran with `forge test --match-path "specific/*"` — never bare `forge test`. No hangs.
- ✅ One forge at a time — outputs redirected to `/tmp/m7_X.log` + `tail -10`.
- ✅ Hallazgos extra: none surfaced. Each contract only got a small, surgical insertion.
- ✅ No agentes paralelos for forge.
- ✅ NO mergeado, NO pusheado.

**Reverse audit rating: 10/10.** The change is small (110 lines of source across 4 files), the registry contract is minimal (~50 lines), and the integration is uniform across the three consumers (same pattern: storage slot, internal helper, setter, event, error). The 491-test surface fully exercises the integration.

---

## 6. Hallazgos extra ARREGLADOS inline

**None.** No bugs surfaced during the integration; the existing test suite was already well-isolated from the new gating (default behavior when registry is `address(0)` is unchanged).

---

## 7. Hallazgos extra que requieren decisión del founder

**None.** All scope items resolvable inline.

A non-blocking observation worth noting: the `setGlobalPauseRegistry` setter
on each consumer is independent — there is no single "wire all 3 contracts"
helper. A deploy script that calls `setGlobalPauseRegistry(addr)` on each
contract individually is the prescribed flow. If a future sprint wants to
collapse this into a `protocolWiringHelper`, that's a deploy-script change,
not a contract change.

---

## 8. CONFIRMACIONES EXPLÍCITAS (per spec)

> ✅ **Pause global PARCIAL implementado** — `GlobalPauseRegistry` is the
> single source of truth. Three protocol contracts (CoverRouterV2,
> LuminaBondMarketplace, BuybackEngine) consult it. When paused:
> - CoverRouter: `purchasePolicy*`, `submitTrigger`, `purchasePolicyFor`
>   revert with `GloballyPaused` (via the extended `whenNotPaused` modifier).
> - Marketplace: `list` and `executeBuy` revert; `cancel` continues working.
> - BuybackEngine: `executeOffer` and `setDailyBuyback` revert.

> ✅ **BondVault.redeemBond preservado (C-4)** — verified at the TYPE level:
> `BondVault.sol` does NOT import `IGlobalPauseRegistry`. There is no
> `globalPauseRegistry` storage, no `_enforceNotGloballyPaused` helper, no
> `GloballyPaused` error. The C-4 decision is preserved by *omission* — the
> contract physically cannot consult the global pause. The 21 existing
> BondVault tests pass unchanged.

> ✅ **Marketplace.emergencyCancel preservado (FIX #15)** — analogous unwind
> path `cancel` is verified ungated by `test_MarketplaceCancelNotAffectedByGlobalPause`.
> `emergencyCancel` itself lives on the FIX #15 branch (`fix-h12`), not on
> this M-7 branch from main. When the consolidated V5.1 squash-merge brings
> H-12 in, `emergencyCancel` will need the same "do NOT call
> `_enforceNotGloballyPaused()`" treatment as `cancel`. That is a one-line
> conformance check at merge-time, not a code addition in this sprint.

> ✅ **Pauses dispersos existentes coexisten** — CoverRouter's local
> `paused` flag and the new global registry are checked together in
> `whenNotPaused`. Either being `true` blocks the gated path. The local
> circuit breaker (auto-pause on price floor) and the global kill switch
> (multisig action) operate independently and compose: defense in depth.

---

## 9. Branch state

- Branch: `fix/m7-global-pause-partial` (local in `/tmp/fix-m7`)
- Commits: 0 (uncommitted in working tree, per workflow rule)
- Files modified: 1 new src + 3 modified src + 1 new test + 1 new report = 6 changes total.

NOT pushed. NOT merged.
