# What We Tested — Lumina V5.1

**Última actualización**: 2026-05-18 (Sprint DD)
**Última verificación de números**: 2026-05-18 (post Sprint EE-FIX merge a `main`)
**Próxima actualización esperada**: Sprint Deploy / Sprint HH

Documento vivo. Refleja TODO lo que está auditado al día de hoy, con números verificables en CI (PR #130 mergeado a `main`).

---

## 1. Tests unitarios (forge test)

- **Total**: `2996 passing, 0 failed, 24 skipped` (3020 total)
- **Suites**: 189 test suites
- **Tiempo CI**: ~20 min (forge test FULL)
- **Cobertura primaria**: cada contrato bajo `src/` tiene al menos un test file dedicado en `test/`.

### Breakdown por carpeta

| Carpeta | Propósito | Tests |
|---|---|---|
| `test/unit/` | Unit tests directos (incluye `unit/immutables/` y `unit/shields/`) | ~600+ |
| `test/integration/` | Cross-contract + fork tests (`integration/immutables/` y `integration/shields/`) | ~150 |
| `test/audit/` | Tests específicos del audit V5.1 UUPS | ~700 |
| `test/products/` | Tests por shield individual | ~60 |
| `test/core/` | CoverRouterV2, PolicyManagerV2 | ~150 |
| `test/bonds/` | BondVault, ClaimBond | ~80 |
| `test/oracles/` | LuminaOracleV2, CapacityOracle, SolvencyOracle | ~50 |
| `test/token/` | LuminaTokenV2, FounderVesting, TreasuryVesting | ~100 |
| `test/marketplace/` | LuminaBondMarketplace, BuybackEngine | ~80 |
| `test/automation/` | ShieldKeeper | ~40 |
| `test/treasury/` | MaintenanceReserve, CEXLiquidityReserve | ~30 |
| `test/fork/` | Fork mainnet tests | ~50 |
| `test/fuzz/` | Foundry fuzz | ~80 |
| `test/invariant/` + `test/invariants/` | Foundry invariant suites | ~60 |
| `test/handlers/` | Handler contracts para invariant testing | n/a |
| `test/attacks/` | Tests específicos por vector de ataque | ~40 |
| `test/simulation/` | Simulación escenarios | ~30 |
| `test/stress/` | Stress tests (incluye `stress/shields/`) | 50 |
| `test/halmos/` | Symbolic exec entrypoint | 4 contratos |
| `test/economic/`, `test/functional/`, `test/auto-burn/` | Categorías específicas | ~80 |

---

## 2. Echidna fuzz testing

- **Total properties PROVEN**: **74**
- **Total runs**: **13.2M** (200k × cada property)
- **Tiempo CI**: ~1h por contrato (matrix paralelo, 8 jobs concurrentes en GitHub Actions)
- **Workflow**: `.github/workflows/echidna.yml` (matrix de 7 shields + FV V2 standalone job)

### Tabla por contrato

| Contrato | Properties | Runs | Status | Última corrida |
|---|---|---|---|---|
| `FounderVestingV2` | 10 | 200k × 10 = 2M | ✅ PASS | 2026-05-18 |
| `FlashBTCShield1h` | 8 | 200k × 8 = 1.6M | ✅ PASS | 2026-05-18 |
| `FlashBTCShield24h` | 8 | 1.6M | ✅ PASS | 2026-05-18 |
| `FlashBTCShield48h` | 8 | 1.6M | ✅ PASS | 2026-05-18 |
| `FlashETHShield1h` | 8 | 1.6M | ✅ PASS | 2026-05-18 |
| `FlashETHShield24h` | 8 | 1.6M | ✅ PASS | 2026-05-18 |
| `FlashETHShield48h` | 8 | 1.6M | ✅ PASS | 2026-05-18 |
| `RateShockShield` | 8 | 1.6M | ✅ PASS | 2026-05-18 |
| **TOTAL** | **74** | **13.2M** | **74/74 ✅** | |

### Properties cubiertas por shield (las 8 invariantes uniformes)

1. `price_threshold_immutable` — umbral de caída no cambia post-deploy.
2. `window_immutable` — ventana fija (MIN == MAX_DURATION) no cambia.
3. `payout_bounded` — `payout ≤ coverage × (BPS − DEDUCTIBLE) / BPS`.
4. `no_double_trigger_same_policy` — finalización idempotente.
5. `trigger_only_in_window` — trigger solo válido dentro de `[start, expiresAt]`.
6. `oracle_confirmation_required` — proofs firmadas EIP-712 únicamente (RateShock: Aave on-chain).
7. `stale_oracle_fail_silent` — proof >MAX_PROOF_AGE → no trigger.
8. `premium_collected_immutable` — premium pagado no se decrementa.

### Properties de FounderVestingV2 (las 10 invariantes)

1. `total_released_bounded` ≤ 8M LUMINA.
2. `tranches_bounded` ≤ 3.
3. `ghost_matches_contract` — accumulator agnóstico al estado interno.
4. `no_release_before_unlock` — sin tranches si no triggered.
5. `trigger_timestamp_valid`.
6. `conditions_met_since_valid`.
7. `deployed_at_immutable`.
8. `recipient_nonzero`.
9. `override_met_since_valid` (PATH 2).
10. `trigger_implies_history` (PATH 1 ∨ 2 ∨ 3 satisfacha si triggered).

---

## 3. Verificación formal Halmos

- **Contratos cubiertos**: **4**
- **Status**: PASS
- **Tiempo CI**: ~2h (4 jobs sequential dentro del workflow)
- **Workflow**: `.github/workflows/halmos.yml` con jobs por contrato

| Contrato | Properties Halmos | Status |
|---|---|---|
| `SolvencyOracle` | Invariantes de solvencia | ✅ |
| `TWAPBurner` | TWAP integrity + burn invariants | ✅ |
| `BondVault` | Bond accounting + reserve floor | ✅ |
| `PolicyManagerV2` | Policy lifecycle + permission checks | ✅ |

---

## 4. Análisis estático

- **Slither**: corre dentro del workflow `CI` como step (ver `.github/workflows/ci.yml`). Status: ✅ 0 true-positive HIGH (ver ADR-016 Sprint X).
- **Aderyn**: workflow `.github/workflows/aderyn.yml`. Status: ✅ PASS (~10s).
- **Mythril**: workflow `.github/workflows/mythril.yml`. Status: ✅ PASS (~7m).

---

## 5. Tests de integración (fork Sepolia)

- **Total**: **18 tests** E2E + Wiring con `LuminaOracleV2 SET A` real.
- **Address SET A**: `0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194` (canonical desde ADR-024 Sprint Z.2).
- **Secret CI**: `BASE_SEPOLIA_RPC` configurado para que los tests no skipean.

### Por dominio

| Dominio | Tests | Path |
|---|---|---|
| FounderVestingV2 E2E + Wiring | 10 + 8 = 18 | `test/integration/immutables/FounderVestingV2{E2EFlows,Wiring}.t.sol` |
| Shield tests fork (×7 shields × 18 each) | 10 E2E + 8 Wiring = 18 × 7 = 126 | `test/integration/shields/<Shield>{E2EFlows,Wiring}.t.sol` |

> Nota: los 126 fork tests de shields son los que se ejecutan en CI con `BASE_SEPOLIA_RPC` configurado. Sin la env-var skipean gracefully via `requiresFork` modifier.

---

## 6. Stress tests adversariales

- **Total**: **50 escenarios**
- **File**: `test/stress/shields/ShieldStressAttacks.t.sol`
- **Tiempo CI**: ~30s (mocks rápidos)

### Categorías

| Categoría | Tests | Vectores cubiertos |
|---|---|---|
| Económicos | 15 | Flash loans, MEV (sandwich/frontrun/backrun/bundle), whale dump, oracle inflate, ARB, correl 98% |
| Técnicos | 15 | Gas grief, reentry (cross-shield, redeem, trigger, buy), DoS spam/dust, overflow/underflow, frontrun upgrade/pause |
| Timing | 10 | Buy/trigger same block, block.timestamp manipulation, time warp +100y, 1000 policies expire same block |
| Multi-shield | 10 | BTC+ETH crash simultáneo, cross-shield reentry, mass redeem, solvency drain, cascade failure |

---

## 7. CI workflows activos

14 workflows que corren en cada push:

| # | Workflow | Status última corrida | Duración típica |
|---|---|---|---|
| 1 | `CI` (build + test + fmt + gas) | ✅ PASS | 1h 28m |
| 2 | `Aderyn` | ✅ PASS | 9s |
| 3 | `Mythril` | ✅ PASS | 7m 52s |
| 4 | `Coverage` | ✅ PASS | 1h 13m |
| 5 | `Gas Snapshot` | ✅ PASS | 1h 21m |
| 6 | `Halmos` | ✅ PASS | ~2h |
| 7 | `Echidna FV V2` (200k) | ✅ PASS | 1h 7m |
| 8 | `Echidna FlashBTCShield1h` (200k) | ✅ PASS | 1h 11m |
| 9 | `Echidna FlashBTCShield24h` (200k) | ✅ PASS | 1h 7m |
| 10 | `Echidna FlashBTCShield48h` (200k) | ✅ PASS | 1h 7m |
| 11 | `Echidna FlashETHShield1h` (200k) | ✅ PASS | 1h 9m |
| 12 | `Echidna FlashETHShield24h` (200k) | ✅ PASS | 1h 7m |
| 13 | `Echidna FlashETHShield48h` (200k) | ✅ PASS | 1h 10m |
| 14 | `Echidna RateShockShield` (200k) | ✅ PASS | 1h 8m |

---

## 8. ADRs documentando decisiones

Ver `tracking/architectural-decisions.md`. ADRs relevantes auditados:

| ADR | Sprint | Tópico |
|---|---|---|
| 010 | — | SET A canonical, SET B abandoned |
| 011 | — | (reservado) |
| 012 | Sprint T | Deploy script self-revoke bug + fix L476-477 |
| 013 | Sprint V-A | BondVault SET C canonical + setters permanentes |
| 014 | Sprint V-B | Sprint V-B off-chain re-wiring SET B → SET C |
| 015 | Sprint W | Validation SET C upgrade + mainnet runbook |
| 016 | Sprint X | Slither static analysis: 0 true-positive HIGH |
| 017 | Sprint Y | Hardening completo (Mythril + Fuzz 10k + Invariants depth 500 + Coverage CI + Gas baseline) |
| 018 | Sprint Z | Halmos formal verification |
| 019 | Sprint AA | Events closure Fase 2 |
| 020 | Sprint CC | Ponder Indexer Re-postponed to Phase 7 |
| 021-023 | Sprint Z.1 | Immutables hardening (3 inmutables) |
| 024 | Sprint Z.2 | Pre-Redeploy Cleanup (bug L476-477 documentation + 11 addresses blanked) |
| 025 | Sprint FV | FounderVesting V2: PATH 2 Override + adjusted durations + oracle wiring fix |
| 026 | Sprint EE | Shield Testing Exhaustivo + MicroDepeg + FlashBTC4h removed (set final 7 shields) |

---

## 9. Lecciones aplicadas (acumuladas)

### 9.1 Verificación on-chain post-deploy obligatoria

ADRs 025 + 026 incluyen sección de `cast call` assertions que el founder corre post-deploy. Si el valor difiere del esperado, el deploy se ROLLBACK.

### 9.2 Tests E2E con address REAL del oracle SET A

Lecciones previas (Sprint Z.2 forensics): los tests mock-only no detectaron el bug de wiring `FV → CapacityOracle` (vs `LuminaOracleV2` esperado). Sprint FV y EE agregaron `requiresFork` modifier que activa `vm.createSelectFork("base_sepolia")` cuando `BASE_SEPOLIA_RPC` está set, llamando directamente al oracle SET A `0x8cAbC4...D194`.

### 9.3 Auditar deploy scripts integralmente

Sprint Z.2 + FV + EE modificaron `script/deploy/DeployLuminaV5Complete.s.sol` y `DeployLuminaV5Sepolia.s.sol` cada vez que un shield se removió o se cambió un parámetro. Cada modificación de deploy script va acompañada de invariantes `require(...)` en el script (ej. "Deployer must keep DEFAULT_ADMIN_ROLE").

### 9.4 Runbook founder no-técnico

`docs/runbooks/FOUNDER-VESTING-OPERATIONS.md` (Sprint FV) y `docs/runbooks/SHIELDS-OPERATIONS.md` (Sprint EE) explican operaciones críticas (trigger, redeem, emergencias) en español plano. 3 formas independientes de verificar cada acción (BaseScan / Wallet / cast call).

### 9.5 Detección via_ir foot-gun (Sprint EE-FIX)

`foundry.toml` tiene `via_ir = true`. Bajo via_ir, locals como `uint256 t0 = block.timestamp;` se inlinen tras un `vm.warp(...)` y leen el timestamp post-warp. Patrón correcto en tests: leer valores de policy storage via `shield.getPolicyInfo(pid).expiresAt` (struct fields land en memory como uint256 concretos no-plegables) en lugar de capturar `block.timestamp` en local. Documentado en memoria `foundry_via_ir_warp.md`.

---

## Changelog

- **2026-05-18 (Sprint DD)**: documento inicial creado. Refleja el estado al cierre de Sprint EE-FIX (PR #130 mergeado a `main` el 2026-05-18 17:04 UTC).
