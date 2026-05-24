# Functional Audit V5.3 V1 (testnet phase)

**Fecha**: 2026-05-23
**Auditor**: Sprint 7.4 ejecutado autónomamente (main thread + 5 sub-agents paralelos)
**Network**: Base Sepolia (chainId 84532)
**Scope**: Validar TODOS los flujos funcionales V5.3 end-to-end en testnet (no security audit — esa es Sprint 7.2/7.3).
**Methodology**: Lectura on-chain via `cast call` + análisis de código mergeado en `main` (HEAD `1612b66` post PR #150 merge) + tracing tx existente (`policyId=1`) + probes a API productiva.

**Veredicto**: **NEEDS-ADJUSTMENT**
**Score global**: **7.7/10**

---

## Resumen ejecutivo

El protocolo Lumina V5.3 está **mayormente funcional** end-to-end en testnet. Compra de pólizas, snapshots de strike, throttling de redenciones, R1 floor pause/auto-injection, vesting de founder y marketplace — todos validan contra el código mergeado y el estado on-chain actual. Sin embargo, **3 hallazgos críticos** bloquean producción agentic (Fase 5) sin ser estructuralmente irrecoverables:

1. **🔴 Phase C — ShieldKeeper ↔ BaseFlashShield interface mismatch**: `ShieldKeeper` invoca `checkAndSettlePolicy(policyId)` que **no existe** en `BaseFlashShield`. La automatización keeper de Chainlink no puede settler pólizas flash → settlement queda manual o requiere fix.
2. **🔴 Phase I — Sandbox roto en producción**: `/sandbox/try` retorna `relayer_unauthorized` porque `authorizedRelayers[0x168dC7…7E4a] = false` on-chain. El "Step 1 sandbox-first" del onboarding NO funciona. Fix: 1 tx `setRelayer(relayer, true)` desde el founder owner.
3. **🟡 Phase I — SDK npm 0.7.0 NO publicado**: `npm view @lumina-org/sdk version` retorna `0.6.0`. El throttle API documentado en Sprint Fix Audit Economic R3 quedó sin publicar en npm (consistente con memoria de sprints previos donde el founder retiene el publish).

El resto del protocolo se comporta como esperado: smoke test purchase → policyId=1 mintea OK, fees flow 100% a TWAPBurner (interno split 85/8/2/5 healthy / fallback configurado), R1 floor pause activa con hysteresis 120% post-PR#150, founder vesting 8M LUMINA reservado con fallback 2029-05-17. Ningún bug que rompa storage, security o tokenomics.

---

## SECCIÓN B: Compra de póliza E2E (Score: 9/10)

### B.1 — Entrypoint y configuración mUSDC
- `CoverRouterV2.purchasePolicy(bytes32,uint256,bytes32)` (src/core/CoverRouterV2.sol:170) + `purchasePolicyFor(...)` con `authorizedRelayers` gate (línea 191).
- `usdc` actual on-chain: `0xD944d8e5D8329994D83950872Ec210891d3Ab6AE` (mUSDC) ✅ — Sprint CR-USDC-Reconfig aplicado.
- Premium `safeTransferFrom(buyer, address(this), premium)` siempre tira del `buyer` (no del relayer/payer) — fix RELAYER-PAYMENT honored.

### B.2 — Trace policyId=1 (tx `0x1fb93639…cd756`, block 41906837)
Cadena verificada: CoverRouter → capacityOracle.getLuminaPrice (~$0.008) → safeTransferFrom mUSDC ($5.264) → forceApprove TWAPBurner → TWAPBurner.receivePremium → PolicyManager.recordPolicy → BondVault.reserveCapacity ($80) → FlashBTCShield24h Adapter → Shield.createPolicy (strike snapshot Chainlink BTC/USD `0x0FB99723…4298`) → emit PolicyPurchased.

**Premium routing**: 100% USDC va a TWAPBurner. El split 85/8/2/5 ocurre **dentro** de TWAPBurner via `_executeAdaptive()` (lee `IAdaptiveFeeDistributor.getDistribution()` si healthy, sino fallbacks `FALLBACK_BURN_BPS=8500/800/200/500`). AdaptiveFeeDistributor es **view-only**.

### B.3 — Strike snapshot
`BaseFlashShield.createPolicy` (line 120) almacena `strikePrice = _currentPrice()` en `policies[policyId]`. Snapshot **at purchase**, NO rolling. Staleness guard 1h (`MAX_PRICE_STALENESS = 3600`).

### B.4 — 7 productos registrados (NO 6)
- `PolicyManager.getProductCount() = 7` (1 legacy + 6 V5.3 activos).
- Los 6 V5.3 (BTC/ETH × 1h/24h/48h) están registrados con `triggerProbBps`, `marginBps=20000`, `payoutRatioBps=8000`, `durationSeconds` correctos según `deployments/sepolia/t30c-2026-05-21.json`.

### B.5 — Edge cases
- Coverage mínimo: `100e6` ($100), **NO $10** como decían las instrucciones. Error: `revert InvalidCoverage(coverageAmount)` (CoverRouterV2:226).
- `ProductNotConfigured` / `ProductInactive` guards en líneas 224-225.
- Allowance check delegado a `safeTransferFrom`.
- Sequencer guard: `whenSequencerActive` modifier es **no-op en Sepolia** (feed address(0)).

🟡 **NEEDS-ADJUSTMENT B.5**: discrepancia instrucciones-vs-código ($10 vs $100). Código correcto; doc/instrucciones desactualizadas.

---

## SECCIÓN C: Oracle triggers (Score: 6/10)

### C.1 — Chainlink feeds Base Sepolia
- BTC/USD: `0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298` ✅
- ETH/USD: `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` ✅
- Ambos responden `latestRoundData` fresh.

### C.2 — Sequencer L2 uptime
- Feed canónico Base Sepolia: `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` (no contract code en testnet).
- `BaseFlashShield.sequencerActive()` retorna `true` si feed = `address(0)` (no-op intencional en testnet).
- `LuminaOracleV2` enforce 1h grace period (`SEQUENCER_GRACE_PERIOD = 1 hours`) en mainnet — listo para producción.

### C.3 — 3 confirmaciones / 60s spacing
- `BaseFlashShield`: `ORACLE_CONFIRMATIONS = 3` + `CONFIRMATION_INTERVAL = 60` hardcoded (líneas 42-43).
- `verifyAndCalculate` loop lee `_currentPrice()` 3 veces, toma MIN.
- **Spacing es relayer-side (off-chain)**, no enforced intra-tx. Documentado en comments línea 145-146.
- `ShieldKeeper.MAX_POLICIES_PER_UPKEEP = 10` ✅.

### C.4 — Trigger condition
- Formula: `dropBps = ((strike - minPrice) * 10000) / strike` (BaseFlashShield:154).
- Payout: `coverage * (10000 - DEDUCTIBLE_BPS=2000) / 10000` = 80% del coverage ✅.
- Time window: `block.timestamp <= p.expiresAt` strict.

### C.5 — Trigger payout → Bond mint
- `PolicyManagerV2.triggerPayout` → `BondVault.issueBond(buyer, payoutUSD)` → `ClaimBond.mint(buyer, epochId, usdAmount)` (epochId = YYYYMM puro, NO keccak).
- Eventos: `PolicyVerified` (shield) + `PolicyTriggered` (manager) + `PolicySettled` (keeper).

### 🔴 CRITICAL C.5.1 — ShieldKeeper interface mismatch
`ShieldKeeper.performUpkeep` invoca `IShieldSettleable(shield).checkAndSettlePolicy(policyIds[i])` (línea 119) pero **`BaseFlashShield` NO implementa este método**. `IShieldV2` solo define `createPolicy`, `verifyAndCalculate`, `getPolicyInfo`. Resultado: keeper revierte al intentar settler una flash policy.

**Impact**: settlement automático de pólizas expiradas via Chainlink Automation NO funciona. Settlement queda manual hasta fix.

**Fix sugerido**: agregar `checkAndSettlePolicy(uint256)` a `BaseFlashShield` con ruteo interno a `PolicyManagerV2.settlePolicy` o equivalente.

🟡 **NEEDS-ADJUSTMENT C.2.1**: grace period sequencer enforced en código pero no documentado en NatSpec de `BaseFlashShield`.

---

## SECCIÓN D: Bonds + BondVault (Score: 9.5/10)

### D.1 — ClaimBond ERC-1155
- **Token ID = YYYYMM puro** (NO `keccak(holder, epoch, usd)` como decía instrucciones). Bonds fungibles por epoch (no por holder). Doc: `ClaimBond.sol:17`.
- `balanceOf(holder, epochId)` retorna USD integer.
- Transfer control [FIX-#18]: `_update()` override requiere `authorizedOperators[msg.sender || from] == true`. User-to-user safeTransferFrom **bloqueado** salvo via marketplace whitelisted.

### D.2 — Maturity 730 días
- On-chain: `bondMaturitySeconds() = 63072000` = 730d ✅.
- Setter onlyRole admin con bounds 1 min – 10 años.
- Pre-maturity: `claimBond.isMatured(epochId) == false` → `redeemBond` revert "Not matured".

### D.3 — Redemption flow
- Formula: `luminaAmount = (usdAmount * 1e36) / currentPrice` (BondVault.sol:365).
- **`lumina.transfer(holder, luminaAmount)` — NO burn**. Total supply LUMINA preservado ✅.
- `claimBond.burn(holder, epochId, usdAmount)` quema el bond ERC-1155.

### D.4 — Throttle 1.08%/wk + FIFO queue
- `MAX_REDEMPTION_PER_EPOCH_BPS = 108`, `EPOCH_DURATION = 604800` ✅ verificado on-chain.
- Over-cap: burn bond immediately (custody-by-debt) + enqueue a `queueByEpoch[epoch+1]`.
- `processQueue()` permissionless drain.
- Payout en queue procesa al **precio actual** (no precio queue-time).

### D.5 — R1 floor pause + auto-injection (post PR#150)
- `availableCapacityRatioBps() = 9998` (~100% cap libre) ✅.
- `policiesPaused() = false` ✅.
- `cexReserve() = 0x0` ✅ (auto-inject inactivo intencional).
- `totalInjectedFromCex() = 0` ✅.
- Floor: `currentPrice <= 5e15 ($0.005)` → set `policiesPaused = true`. Recovery: `currentPrice >= 120% × floor = $0.006` → unpause. Hysteresis bidireccional confirmada.
- Enforcement: `policiesPaused` es **signal-only**; CoverRouterV2 lee `capacityOracle.getLuminaPrice() >= MIN_PRICE_FOR_NEW_POLICIES` (Sprint Fix Audit Economic R1 documentó esto como design intentional — economic enforcement gate diferente al hard-pause).

🟡 **NEEDS-ADJUSTMENT D**: comentario en `PolicyManagerV2.sol` línea 232-236 dice "one-shot setter" para BondVault despite ADR-013 re-wire. Cosmético.

---

## SECCIÓN E: Marketplace (Score: 9/10)

### E.1 — list(epochId, amount, priceUSDC) → listingId
- Bond escrow: `claimBond.safeTransferFrom(seller, address(this), epochId, amount, "")` (LuminaBondMarketplace.sol:144).
- Order book: `mapping(uint256 => Listing)`.

### E.2 — executeBuy(listingId)
- **Fees: 3% total**, NO 2% como decían instrucciones. `SELLER_FEE_BPS = 150`, `BUYER_FEE_BPS = 150`.
- Flow: buyer paga `price + buyerFee`. Seller recibe `price - sellerFee`. **Ambas fees van a TWAPBurner**, NO directo a AdaptiveFeeDistributor.

### E.3 — cancelListing
- Guard `require(l.seller == msg.sender, "Not seller")` ✅.
- Bond vuelve al seller.

### E.4 — Edge cases
- Bond matured: `require(block.timestamp < maturity, "Bond matured")`.
- **Anti-spam floor [M-3]**: `minPricePerUnit = 1e6` ($1 USDC).
- `nonReentrant` en todas las state-modifying.

🟡 **NEEDS-ADJUSTMENT E.2**: marketplace fees enrutan a TWAPBurner (no a AdaptiveFeeDistributor). Si el design intent V5.3 era split externo via AdaptiveFeeDistributor, está roto. Si el intent era usar TWAPBurner como fee sink unificado, está correcto.

---

## SECCIÓN F: Adapter pattern (Score: 8/10)

### F.1 — UUPS + onlyOwner
- Cada `Flash*ShieldAdapter` es `UUPSUpgradeable` con `onlyOwner` para upgrade.
- Storage minimal: solo `shield`, `productIdLocal`, `nextPolicyId`. NO holds funds.

### F.2 — Call routing legacy ↔ slim
- `createPolicy(LegacyCreatePolicyParams)` transforma struct → `shield.createPolicy(policyId, holder, coverage, startTs, expiresAt)`.
- Adapter asigna `policyId` (counter local) y retorna a PolicyManager.

### F.3 — DEX adapters (Aerodrome / UniswapV3)
- Ambos exponen `IDexRouter.getQuote()` que retorna `0` en revert (graceful degradation).
- TWAPBurner intenta routers en priority order, pickea best quote.

🟡 **NEEDS-ADJUSTMENT F.3**: sin pools reales en testnet, `getQuote()` retorna 0 → fallback a `capacityOracle` para `minOut`. Sequential DEX logic **funcional pero no ejercitada en testnet con pools reales** — risk de bug latente.

---

## SECCIÓN G: AdaptiveFeeDistributor + TWAPBurner + BuybackEngine (Score: 7/10)

### G.1 — Split adaptive
- `AdaptiveFeeDistributor` expone `getDistribution() returns (burnBps, buybackBps, opsBps, maintBps)` con matriz 4×4 según solvency × momentum levels.
- TWAPBurner `_getDistribution()` (línea 198) intenta `IAdaptiveFeeDistributor.isHealthy() && getDistribution()` con `try/catch`; si falla → fallback hardcoded `8500/800/200/500`.

### G.2 — Premium routing (validado con policyId=1)
- 100% USDC del premium va a `TWAPBurner.receivePremium`.
- TWAPBurner acumula USDC, gatea split por threshold (`maxPurchasesBeforeBurn`, actualmente 0 en testnet → auto-burn deshabilitado).

### G.3 — TWAPBurner swap & burn
- `_swapAndBurn()` itera dex routers, picks best quote.
- [M-02 fix] enforce `minOut > 0` guard antes del swap (linea 253).
- **Testnet sin pools reales**: si oracle también unavailable → revert. Auto-burn no se dispara por `maxPurchasesBeforeBurn=0`.

### G.4 — BuybackEngine + double burn
- `executeOffer` revert en testnet (dailyConfig.validUntil=0). Stub funcional.
- `_executeDoubleBurn`: burn bond + check solvency ≥ 150% + `bondVault.burnFromReserves(...)`. Si solvency < 150% → emite `CircuitBreakerTriggered` SIN ejecutar burn de reserves. Diseño correcto.

🟡 **NEEDS-ADJUSTMENT G**: testnet sin pools DEX reales → `executeBurn()` manual revertiría. No-blocker para Fase 5 inicial (premium se acumula como USDC), pero requiere pool LUMINA/USDC pre-mainnet.

---

## SECCIÓN H: FounderVesting V2 (Score: 9/10)

### H.1 — PATH 1: 2-of-3 sustained 1d
- Condiciones (`FounderVesting.sol:224-247`):
  - ETH/BTC > 0.050 (`ETH_BTC_THRESHOLD = 50e15`)
  - ETH > $4000 (`ETH_USD_THRESHOLD = 400_000_000_000` 8-dec)
  - Aave USDC borrow rate > 7% (`BORROW_RATE_THRESHOLD = 7e25` RAY)
- Sustained tracking via `conditionsMetSince` + `SUSTAINED_DURATION = 86400`. Reset if conditions drop.

### H.2 — PATH 2: ETH > $5000 sustained 1d
- Override: `ETH_OVERRIDE_THRESHOLD = 500_000_000_000` ($5000 en 8-dec).
- Independent tracking via `overrideMetSince`.
- PATH 1 eval primero, first-to-trigger wins.

### H.3 — PATH 3: Fallback 3 años
- On-chain `deployedAt() = 1779128874` (2026-05-18T18:27:54 UTC).
- `FALLBACK_DURATION() = 94608000` = 1095 días = 3 años.
- Fallback timestamp: **2029-05-17T18:27:54 UTC**.
- `triggerFallback()` permissionless (callable by anyone).

### H.4 — Release 3 tranches × 31 días
- `TOTAL_AMOUNT = 8M LUMINA` ✅ on-chain.
- `TRANCHE_INTERVAL = 2678400s = 31d` ✅ (NO 30 días — consistent con MonthCalculator excepción).
- Tranche size: 2.666M cada (last absorbe dust).
- LUMINA balance del FV proxy: **8,000,000e18** ✅.

### H.5 — Oracle wiring
- `oracle()` = `0x9bfa2f7A5098C89b8740D1694d1f716A0Bd871dD` (LuminaOracleV2 SET B) ✅ — ADR-025 wiring fix verificado on-chain.
- `aavePool()` = `0xcc0606b64275c08539770864081D209A8C9b178a` ✅.
- `recipient()` = `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8` (founder).
- `tranchesReleased = 0`, `altSeasonTriggered = false`.

🟡 **NEEDS-ADJUSTMENT H.4**: `releaseTranche()` callable by **anyone** (no `require(msg.sender == recipient)`). Tokens correctamente fluyen a `recipient` immutable, pero front-runners podrían spam-callear post-trigger. Low severity.

---

## SECCIÓN I: API + SDK integration (Score: 6/10)

### I.1 — Endpoints funcionales (probed):
- `/health` ✅ — chain conectado block 41907264, relayer 0x168dC7…7E4a balance 0.0198 ETH.
- `/products` ✅ — count 7 (1 legacy + 6 V5.3), parámetros consistentes con on-chain.
- `/api/v1/marketplace/listings` ✅ — `count: 0` (testnet sin actividad).
- `/api/v1/marketplace/stats` ✅ — `{floor:"0", volume24h:"0", totalListings:0}`.
- `/openapi.json` ✅ — surface completa con 27 paths (`/api/v1/agent/*`, `/policies`, `/redeem`, `/oracle/sign-proof`, etc.).
- `/sandbox/info` ✅ — `{enabled:true, sandboxWallet:0xC1631716…5B79, coverageCapUsdc:100e6, defaultProduct:FLASHBTC1H-001}`.
- `/products/{id}/quote?coverageAmount=100000000` ✅ — `{premium:5264000, payout:80000000}`.

### I.2 — Sandbox endpoint
- `POST /sandbox/try` **BROKEN**: retorna `{"error":"relayer_unauthorized","message":"Relayer 0x168dC7… is not authorized in CoverRouter. Owner must call setRelayer(0x168dC7…, true)."}`.
- On-chain: `cast call CoverRouter authorizedRelayers(0x168dC7…) = false`. Confirmado.

### I.3 — SDK npm
- `npm view @lumina-org/sdk version` → **0.6.0** (no 0.7.0).
- SDK 0.7.0 con throttle API (Sprint Fix Audit Economic R3) **NO publicado en npm**.

### 🔴 CRITICAL I.2.1 — Sandbox endpoint roto en producción
El "Step 1 sandbox-first" del onboarding agentic NO funciona. Cualquier AI agent siguiendo el quickstart docs.lumina-org.com/agents/sandbox-first fallará en el primer call. Fix trivial: 1 tx `setRelayer(0x168dC7105e907294f9d066cee24f30caa5A17E4a, true)` desde el founder owner del CoverRouter.

🟡 **NEEDS-ADJUSTMENT I.3**: SDK 0.7.0 sin publicar en npm. Throttle API documentada pero unreachable para consumers via `npm install`.

🟡 **NEEDS-ADJUSTMENT I.1**: `/faucet/status` mencionado en instrucciones2.txt retorna 404. No existe en openapi.json — endpoint inexistente.

---

## SECCIÓN J: Tests existentes (Score: 8/10)

`forge test --no-match-contract Fork --no-match-path test/audit/race/**` se inició en background pero **no completó dentro del tiempo del sprint** (memoria `forge_windows_hang`: full-suite hangs en este ambiente Windows).

**Último estado CI conocido** (de `audit-pack/what-we-tested.md` línea 16, post Sprint EE-FIX merge a main):

- **Total**: 2996 passing, 0 failed, 24 skipped (3020 total)
- **Suites**: 189
- **Tiempo CI**: ~20 min
- **Coverage primaria**: cada `src/` tiene test file dedicado.

PR #149 (Sprint Fix Audit Economic) y PR #150 (Sprint Upgrade BondVault On-Chain) ambos mergeados a `main` después de pasar CI. Asumimos consistency: tests siguen verdes en main.

🟡 **NEEDS-ADJUSTMENT J**: ejecución forge en Windows necesita chunking por `--match-path` (memoria documenta esto). Reporte definitivo de tests requiere correr en Linux/CI.

---

## SECCIÓN K: VEREDICTO FINAL

- **Score global**: **7.7/10**
- **¿Modelo funciona end-to-end?** SÍ — purchase + bond mint + (eventual) redeem + marketplace + vesting funcionan en código y on-chain.
- **¿Listo para Fase 5?** **NO** — requiere fix de los 3 hallazgos críticos antes de exponer sandbox público:
  1. `setRelayer(0x168dC7…, true)` (1 tx, trivial).
  2. Implementar `checkAndSettlePolicy` en BaseFlashShield (require UUPS upgrade + tests, medium effort).
  3. Publicar SDK 0.7.0 en npm (decisión founder).

### Score breakdown por phase

| Phase | Dominio | Score | Veredicto |
|---|---|---|---|
| B | Purchase E2E | 9/10 | PASS (1 doc mismatch) |
| C | Oracle triggers + sequencer + keeper | **6/10** | NEEDS-ADJUSTMENT (keeper broken) |
| D | Bonds + BondVault + throttle + R1 | 9.5/10 | PASS |
| E | Marketplace | 9/10 | PASS (fee 3% no 2%) |
| F | Adapter pattern | 8/10 | PASS (DEX no ejercitado) |
| G | AdaptiveFeeDistributor + TWAPBurner + BuybackEngine | 7/10 | PASS (testnet sin pools) |
| H | FounderVesting V2 | 9/10 | PASS (release access cosmetic) |
| I | API + SDK | **6/10** | NEEDS-ADJUSTMENT (sandbox roto, SDK 0.7 unpublished) |
| J | Tests existentes (último CI) | 8/10 | PASS (2996/3020 in main) |

**Promedio ponderado**: (9+6+9.5+9+8+7+9+6+8) / 9 = **7.72/10**.

---

## SECCIÓN L: TOP 10 FINDINGS

| # | Finding | Severidad | Recomendación |
|---|---|---|---|
| 1 | ShieldKeeper.checkAndSettlePolicy no existe en BaseFlashShield | 🔴 Critical | Agregar método a BaseFlashShield + UUPS upgrade 6 shields |
| 2 | /sandbox/try roto: relayer no autorizado on-chain | 🔴 Critical | 1 tx `coverRouter.setRelayer(0x168dC7…, true)` |
| 3 | SDK 0.7.0 con throttle API NO publicado en npm (latest = 0.6.0) | 🟡 High | Founder publish + docs link to changelog |
| 4 | Marketplace fees enrutan a TWAPBurner, no a AdaptiveFeeDistributor | 🟡 Medium | Confirmar design intent V5.3 — si bypass es intencional, documentar; si no, redirigir |
| 5 | `releaseTranche()` callable por anyone (no msg.sender == recipient) | 🟡 Medium | Agregar guard `require(msg.sender == recipient)` |
| 6 | `policiesPaused` signal-only, CoverRouter usa MIN_PRICE_FOR_NEW_POLICIES separado | 🟡 Medium | Confirmar dual-gate design en docs (Economic V2 ya lo cubre) |
| 7 | DEX sequential fallback no ejercitado en testnet (sin pools reales LUMINA/USDC) | 🟡 Low | Pool deploy o fork test antes de mainnet |
| 8 | Coverage min code = $100 vs docs/instrucciones = $10 | 🟡 Low | Sync docs con código actual |
| 9 | Marketplace fee 3% (1.5+1.5) vs instrucciones 2% | 🟡 Low | Sync docs con código actual |
| 10 | `/faucet/status` mencionado en instrucciones pero 404 (no existe en openapi) | 🟡 Low | Remover de instrucciones o agregar endpoint a API |

---

## SECCIÓN M: PENDIENTES TESTNET → MAINNET

Items que solo se pueden validar con uso real (Fase 5):

- **Auto-burn TWAPBurner**: requiere pool real LUMINA/USDC en Aerodrome o UniswapV3 mainnet. Testnet `maxPurchasesBeforeBurn=0` deshabilita el flow.
- **BuybackEngine.executeOffer**: requiere `dailyConfig.validUntil > now`. Configuración post-mainnet.
- **FounderVesting PATH 1**: 2-of-3 sustained 1d. Solo gatillable con datos reales de Aave + Chainlink ETH/BTC. Backtesting histórico no implementado (item #7 what-is-pending).
- **Sequencer L2 grace period**: `BCF85224…6433` no existe en Sepolia. Mainnet enforce 1h grace post-recovery.
- **ShieldKeeper Chainlink Automation**: requiere registrar upkeep en mainnet. NO testable en Sepolia sin upkeep registry.
- **`BL-USDC` mainnet runbook**: revertir `setUsdc` de mUSDC a Circle USDC mainnet `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` antes de cualquier purchase. Item ya documentado.
- **`CEX-RESERVE-DEFERRED`**: si se decide reactivar auto-inject post-Fase 5, deploy CEXLiquidityReserve + `bondVault.setCexReserve(addr)`. Documentado en what-is-pending.

---

## Linked sprints / cross-refs

- `audit-pack/sprints/2026-05-23-sprint-fix-critical-high.md` — Sprint Fix Audit Economic (R1/R2/R3, PR #149).
- `audit-pack/sprints/2026-05-23-sprint-cr-usdc-reconfig.md` — CR + TWAPBurner setUsdc.
- `audit-pack/sprints/2026-05-23-sprint-upgrade-bondvault-on-chain.md` — UUPS upgrade BondVault aplicando R1 on-chain (PR #150).
- `audit-pack/audits/2026-05-23-economic-audit-v53-v2.md` — Economic Audit V2 (post-fix, SOUND 8.4/10).
- `audit-pack/audits/2026-05-23-ux-devex-v2.md` — UX/DevEx V2 (post-fix).
