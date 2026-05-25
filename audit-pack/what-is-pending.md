# What Is Pending — Lumina V5.1

**Última actualización**: 2026-05-18 (Sprint DD)
**Próxima actualización esperada**: cada sprint futuro
**Política**: cuando un item se complete, se mueve a `what-we-tested.md` con fecha de cierre.

Lista de gaps de aseguramiento conocidos al día de hoy. Cada item incluye la razón explícita de por qué aún no se cubrió.

---

## 1. Cobertura Halmos parcial

**Estado**: Solo 4 contratos verificados formalmente (`SolvencyOracle`, `TWAPBurner`, `BondVault`, `PolicyManagerV2`).

**Pendiente verificar formalmente con Halmos**:

- `LuminaTokenV2`
- `ClaimBond`
- `CoverRouterV2`
- `AdaptiveFeeDistributor`
- `BuybackEngine`
- `LuminaBondMarketplace`
- `CapacityOracle`
- `CEXLiquidityReserve`
- `MaintenanceReserve`
- `ShieldKeeper`
- `TreasuryVesting`
- `FounderVesting` (verificación formal, complementaria al Echidna existente)
- `AerodromeAdapter`
- `UniswapV3Adapter`
- 7 shields (`FlashBTCShield1h/24h/48h`, `FlashETHShield1h/24h/48h`, `RateShockShield`)

**Total pendiente**: ~23 contratos.

**Razón**: Halmos tiene timeouts en contratos con loops anidados o storage patterns complejos. Echidna ya cubre estos contratos vía fuzzing (200k runs cada uno para los 7 shields + FV V2). Verificación formal Halmos sobre los 23 restantes es defense-in-depth pero NO bloqueante.

---

## 2. Differential fuzzing

**Estado**: No implementado.

**Razón**: Differential fuzzing requiere una implementación de referencia (segunda implementación del mismo contrato en otro lenguaje o estilo) contra la cual comparar outputs aleatorios. Esto no existe para Lumina y requeriría un esfuerzo de implementación de referencia separada — fuera del scope actual.

---

## 3. Simulación de escenarios de mercado completos

**Estado**: No implementado.

**Pendiente cubrir**:

- Bear market sostenido (-30%+ en BTC/ETH durante 90 días continuos).
- Bull market sostenido (+50% durante 90 días).
- Sideways prolongado (volatilidad < 5% durante 6 meses).
- Black swans tipo COVID-19 (-50% en 7 días + recovery parcial).
- Caídas correlacionadas BTC + ETH + Aave APY spike simultáneo.

**Razón**: Requiere un framework económico de simulación con replay histórico de precios + modelos de behavior de policyholders. Está fuera del scope de unit/integration testing y necesita una herramienta dedicada (ej. agent-based simulation).

---

## 4. Aave V3 integration extrema

**Estado**: Mocks de `IAaveV3Pool` cubren caída + rate spike a nivel happy/sad path. Falta el extremo.

**Pendiente cubrir**:

- Liquidity drain completa de Aave (utilization = 100%).
- Rate spikes >50% APY sostenidos.
- Reserve `paused` mid-policy.
- Reserve `frozen` mid-policy.
- Reserve eliminada del Aave config.
- aToken supply shock.

**Razón**: El mock `IAaveV3PoolReader.ReserveData` actual no replica fielmente la mecánica de interest-rate model + LTV liquidations. Para cubrir esto bien hay que hacer fork tests con el estado replicado de Aave V3 mainnet — pesado para CI.

---

## 5. LBP testing (post-deploy mainnet)

**Estado**: No implementado.

**Pendiente cubrir**:

- Mecánica Balancer/Fjord LBP (price discovery weight curve).
- Sniper detection.
- TWAP rate of consumption.
- Slippage handling al claim.
- Frontrun protection.

**Razón**: El LBP es post-deploy mainnet, no parte de la arquitectura on-chain core. Requiere setup separado contra un LBP factory desplegado.

---

## 6. Multi-DEX routing edge cases

**Estado**: Tests cubren happy path con un solo DEX (Uniswap V3 o Aerodrome). Falta el lado complejo.

**Pendiente cubrir**:

- Liquidez asimétrica entre pools (1 pool con 90% del depth).
- Slippage compounding sobre múltiples hops.
- MEV cross-DEX (arb entre Uni V3 / Aerodrome).
- Fallback cuando un router está paused/halted.

**Razón**: Requiere fork tests con liquidez real de mainnet replicada. Echidna no puede modelar esto fácilmente; mock-only tests no detectan oddities del slippage real.

---

## 7. Análisis actuarial de umbrales

**Estado**: Los umbrales de trigger por shield (5% BTC 1h, 10% BTC 24h, 15% BTC 48h, 7% ETH 1h, 12% ETH 24h, 18% ETH 48h, 10% APY RateShock) son los del contrato actual. Falta validación EXTERNA.

**Pendiente cubrir**:

- Validación externa por actuario independiente.
- Backtesting con datos históricos (2019-2026 BTC/ETH minute-level).
- Probabilidad de trigger por shield (frecuencia + severidad).
- Coverage adequacy (premium pricing vs payout probability).

**Razón**: Requiere expertise actuarial específico de risk products parametricos. No es un test de software; es validación de modelo financiero.

---

## 8. Análisis económico de los 3 paths FounderVesting

**Estado**: FounderVesting V2 tiene 3 paths (2-of-3 AltSeason 1d + ETH > $5000 1d + 3y fallback). Falta game theory.

**Pendiente cubrir**:

- Probabilidad relativa de trigger de cada path (PATH 1 vs PATH 2 vs fallback).
- Incentivos founder vs holders en cada escenario.
- Manipulación ETH spike $5,001 sostenida 1d — costo del ataque vs beneficio.
- Escenarios donde PATH 3 (fallback 1095d) sea el path preferente del founder.

**Razón**: Requiere modelo financiero + game theory. No es un test de software.

---

## 9. Oracle assumptions validation

**Estado**: Los parámetros del oracle son hard-coded: `MAX_PROOF_AGE = 900s` (15 min), 3 lecturas separadas 60s para confirmación, fail-silent en staleness. Falta validación de adequacy.

**Pendiente cubrir**:

- ¿`MAX_PROOF_AGE = 900s` es suficiente para volatilidad real del market?
- ¿La heartbeat real de Chainlink BTC/USD en Base (mainnet vs Sepolia) es compatible con 3 lecturas × 60s?
- ¿Fail-silent introduce vector de denial-of-payout vía oracle pause coordinado?
- Análisis del oracle signer single point of failure (multi-sig signer roadmap).

**Razón**: Requiere oracle/MEV expert. Documentado parcialmente en ADR-026 como finding 4 (signer blast radius) y finding 5 (idempotencia de verifyAndCalculate).

---

## 10. Stress testing con flash loans reales

**Estado**: Los 50 stress tests usan mocks de DEX/Aave. Los ataques de flash loan están simulados pero no ejercitados contra fork mainnet.

**Pendiente cubrir**:

- Fork mainnet con Aave V3 + Balancer + Uniswap pools reales.
- Atacante con $100M USDC en flash loan inicia ataque correlated BTC+ETH dump.
- Verificación de profitabilidad del ataque (capital cost + gas vs payout máximo).
- Test que demuestre que el ataque NO es profitable (defensive economics).

**Razón**: Requiere setup de fork mainnet con balances reales + tooling para flash loans en test. Complejo, pero crítico pre-mainnet.

---

## 11. Multi-block sequences extensas en Echidna

**Estado**: `seqLen = 100` en todos los configs (`echidna-fv.yaml`, `echidna-shield-*.yaml`).

**Pendiente cubrir**:

- Sequences `seqLen > 100` para detectar bugs que requieran más calls para manifestarse.
- Especialmente útil para state-machines complejas (FV V2 con 3 paths, policy lifecycle largo).

**Razón**: `seqLen` aumenta multiplicativamente el tiempo de CI. Con `seqLen = 100`, cada shield Echidna corre 1h+ en GitHub Actions. `seqLen = 200` duplicaría el wall time del workflow (de ~1h a ~2h+) que actualmente es 8 jobs paralelos = ~1h. Ir a `seqLen = 500` o `1000` requiere runners dedicados o pre-mainnet sprint sin time budget.

---

## 12. Gas optimization analysis dirigida

**Estado**: `forge snapshot` corre en cada PR (workflow `Gas Snapshot`). No hay análisis dirigido de los paths críticos.

**Pendiente cubrir**:

- Profiling detallado de `releaseTranche()` (FV V2).
- `verifyAndCalculate()` por cada shield, con análisis de hot paths.
- `createPolicy()` + premium routing optimization.
- `redeem()` bond claim path.
- Gas snapshot delta entre upgrades UUPS.

**Razón**: Optimización requiere refactor del contract → cada cambio invalida los Echidna corpus + Halmos proofs + requiere re-auditar. Trade-off costo / beneficio.

---

## ~~13. Auditorías profundas T-30b~~ — CERRADO 2026-05-21

**Resolved**: Sprint T-30b (PR #139 draft sobre commit `705ca08`, 20/20 CI workflows verde):

- ✅ Aderyn + Mythril sobre código nuevo: 0 High/Critical findings.
- ✅ Halmos: 5 invariants nuevos PROVEN sobre arithmetic mirrors (throttle, drop math, window, payout, no-double-pay).
- ✅ Echidna 200k × 48 properties (6 shields × 8 props) = 9.6M iterations PROVEN.
- ✅ Interface bridge resuelto via adapter pattern (`src/shields/FlashShieldAdapter.sol`) — PolicyManagerV2 unchanged.
- ⚠️ Slither no en CI explícito (deferred): ADR-016 baseline Sprint X autoritativo.
- ⚠️ FlashShieldAdapter sin tests dedicados aún — pendiente Sprint T-30c integration + production wire.

Ver detalles en `what-we-tested.md` sección 13.

---

## ~~14. Adapter integration tests pendientes (Sprint T-30c)~~ — CERRADO 2026-05-21

**Resolved**: Sprint T-30c (PR #140 LP draft):

- ✅ `test/shields/FlashShieldAdapter.t.sol`: 16 unit tests dedicados, ≥95% coverage del adapter (initialize / createPolicy / verifyAndCalculate / getPolicyInfo / UUPS / sequencer inherited / router guard).
- ✅ `test/integration/ShieldsE2E.t.sol`: 2 integration tests nuevos (`testPurchasePolicy_Through_CoverRouter_Full`, `testTrigger_EmitsBond_Full`) ejercitando `CoverRouterV2 → PolicyManagerV2 → FlashShieldAdapter → BaseFlashShield`.
- ✅ Deploy fresco a Base Sepolia: 6 shields + 6 adapter UUPS proxies (18 contratos verificados BaseScan).
- ✅ 6 productos registrados en PolicyManagerV2 (canonical adapter por productId).
- ✅ 6 productos configurados en CoverRouterV2 con margin 20000.
- ✅ E2E reads on-chain consistentes (cuádruple cross-check PM ↔ Adapter ↔ Shield ↔ Asset).

Ver detalles en `what-we-tested.md` sección 14.

---

## ~~15. Tail de productShield mappings (Sprint T-30c)~~ — CERRADO 2026-05-22

**Resolved**: Sprint Cleanup (PR #141 LP draft) — UUPS upgrade del proxy `PolicyManagerV2` agregó `removeProduct(bytes32)` + `removeProductBatch(bytes32[])` con swap-and-pop. 6 productIds limpiados on-chain via 12 txs (remove + register × 6); array final tiene 7 entries únicos (6 flash + 1 RateShock). API `/products` y PM `productIds[]` ambos retornan count 7. Nueva impl `0xdE41D414eD191A1090546078DF8e120c196Be22F` verified BaseScan.

Ver detalles en `what-we-tested.md` sección 15.

---

## 16. Retry semantics sobre `cast send` (ops)

**Estado**: Durante Phase G/H del Sprint T-30c, 3 de 6 `cast send` calls (en cada round) requirieron retry. Comportamiento intermitente — probablemente nonce-race o RPC público bajo carga.

**Pendiente** (ops side):
- Wrappear deploy + register + configure en un único `forge script` con `vm.broadcast` para nonce-tracking determinista en mainnet.
- O alternativa: shell wrapper con `cast nonce` explícito y retry-with-backoff.

**Razón**: Mitigado con verificación on-chain final en T-30c. Para mainnet conviene endurecer.

---

## ~~27. USDC mock prerequisite (Fase 5)~~ — CERRADO 2026-05-23

**Resolved**: Sprint USDC Mock — la faucet existente `POST /api/v1/faucet/claim` (Sprint L) fue migrada de `usdc.transfer` (que requería pre-fundeo del relayer con USDC, live `/faucet/status` mostraba `enabled:false`) a `mockUsdc.mint` contra `0xD944d8e5D8329994D83950872Ec210891d3Ab6AE` (MockUSDC permissionless mintable, verificada vía `cast call --from <random>` que no revierte). 10,000 mUSDC + 0.05 ETH por claim, mismo rate-limit Sprint L (24h cooldown wallet+IP, 50/día global, global lock HIGH-1).

PRs: `lumina-api#39` + `v0-lumina-landing-page#(sub-agent)` + `docs#(sub-agent)` + `LP#(este)`.

Ver detalles en `what-we-tested.md` sección 19.

---

## ~~28. CoverRouter USDC config no alineada con la mUSDC faucet~~ — CERRADO 2026-05-23

**Resolved**: Sprint CR USDC Reconfig (Opción A elegida) — ver [`audit-pack/sprints/2026-05-23-sprint-cr-usdc-reconfig.md`](./sprints/2026-05-23-sprint-cr-usdc-reconfig.md) y `what-we-tested.md` sección 20. UUPS upgrade de `CoverRouterV2` + `TWAPBurner` agregó `setUsdc(address) onlyOwner`. Ambos contratos ahora apuntan a `mUSDC` (`0xD944d8e5D8329994D83950872Ec210891d3Ab6AE`). Smoke test exitoso con `policyId=1`. 4 txs on-chain (2 `upgradeTo` + 2 `setUsdc`).

**Pre-mainnet blocker creado:** `BL-USDC` — ver sección Mainnet Blockers abajo.

---

## Sprint Shields UUPS Redeploy (2026-05-24) — resuelto on-chain (PR #156, merged)

- **Red-team F-01 (flash-shield barrier-option)** → **RESUELTO ON-CHAIN**: 6 shields nuevos UUPS desplegados con multi-block confirmation (3 obs espaciadas, distinto bloque + round más nuevo) + `MIN_DWELL_PERIOD` 5min + `checkAndSettlePolicy onlyKeeperOrRelayer`. PolicyManager cut over (mismos productIds). Verificado on-chain + smoke e2e. PR LP#156, addresses `deployments/sepolia/V5.4-shields-uups-2026-05-24.json`.
- **N-02 (adapters sin `setShield`)** → **RESUELTO**: re-deploy completo de shields + adapters nuevos (en vez de re-pointing). Los nuevos shields son UUPS-upgradeable, así que futuros cambios de lógica de shield ya NO requieren re-deploy (se upgradean).
- **Pendiente menor**: verificación BaseScan de los 12 nuevos (founder), deactivate/cleanup de los productShield viejos orphaned, compile de la test-suite completa en CI Linux (via_ir OOMea local; src + deploy compilan limpios).

## Sprint Fix 7.2 — Red Team findings status (2026-05-24, PR #155)

Los 39 findings del Red Team Audit V1 están **resueltos en código** (branch `feat/fix-red-team-complete`, suite `test/redteam-fixes/`). Detalle por finding en [`audit-pack/audits/2026-05-24-red-team-audit-v53-v2.md`](./audits/2026-05-24-red-team-audit-v53-v2.md).

**Cerrados (código + test):** F-01 a F-16, F-18 a F-31 + N-01 (bug nuevo: processQueue skip-every-other, arreglado). INFO-1..8 documentados. **Los fixes de shields (F-01/F-03/F-05/F-06/F-08) se desplegaron on-chain vía PR #156** (UUPS); PR #155 conserva los fixes NO-shield (F-02/F-04/F-07/F-09/F-10/F-11/F-12/F-13/F-14/F-15/F-16/F-18/F-19 + N-01).

**Pendiente (NO defectos de fix — founder/ops):**
- **Deploy/upgrade on-chain de los contratos NO-shield** (BondVault, CoverRouter, PolicyManager, TWAPBurner, BuybackEngine, CapacityOracle, MaintenanceReserve, Marketplace) + `FounderVestingV2`. Scaffold: `script/deploy/UpgradeAll-FixRedTeam.s.sol`. Post-deploy: `BondVault.setAuthorizedCaller(ClaimBond,true)`, `MaintenanceReserve.setMonthlyCap(...)`.
- **F-17 governance** → ver `BL-MULTISIG` abajo.
- ~~**Barrido legacy amplio** (audit/fuzz/functional/integration/stress/unit) sin migrar exhaustivamente~~ — **CERRADO 2026-05-25** (Sprint Migrate Legacy Tests): toda la suite no-Fork migrada y VERDE (~1,900 tests, 0 fails). Ver `audit-pack/sprints/2026-05-25-sprint-migrate-legacy-tests.md`. PR `feat/migrate-legacy-tests`.
- Mythril/Aderyn/Echidna 200k diferidos a CI Linux.

---

## Mainnet Blockers

Items que NO bloquean testnet pero **deben** resolverse antes del primer deploy de mainnet. Estos no son gaps de auditoría sino state on-chain o configuración que se cambió para uso testnet.

### BL-MULTISIG — Governance single-EOA (Red Team F-17)

**Estado**: Abierto (decisión founder: Safe + TimelockController post-Fase 7).

Todos los `owner`/`DEFAULT_ADMIN_ROLE` resuelven a una EOA founder. El poder de UUPS upgrade = control total de fondos sin timelock/warning window. **Pre-mainnet**: migrar a Gnosis Safe + `TimelockController` (24-48h), adoptar `Ownable2Step`, renunciar poderes `_deployer` residuales. Tracked como design tradeoff aceptado para testnet.

### BL-USDC — CoverRouterV2 + TWAPBurner apuntan a MockUSDC en Sepolia

**Estado**: Abierto (deliberadamente, para Sepolia).

**Detalle**: durante Sprint CR-USDC-Reconfig (2026-05-23) se agregó `setUsdc(address)` onlyOwner a `CoverRouterV2` y `TWAPBurner`, y ambos proxies se repointaron a `MockUSDC` (`0xD944d8e5D8329994D83950872Ec210891d3Ab6AE`) para desbloquear el flujo faucet → buy policy. Los setters quedan en la codebase con NatSpec `[Sprint CR-USDC-Reconfig]`.

**Acción mainnet runbook**:
1. Después de `forge script DeployLuminaV5Mainnet.s.sol --broadcast`, **antes** de cualquier `purchasePolicy` en mainnet:
   - `cast send <CoverRouterV2 proxy> "setUsdc(address)" 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (Base mainnet Circle USDC).
   - `cast send <TWAPBurner proxy> "setUsdc(address)" 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.
2. Verificar `usdc()` en ambos proxies devuelve la address mainnet de Circle.
3. (Opcional, defensa adicional) renounceOwnership o Gnosis Safe transfer una vez confirmado.

**Por qué se mantienen los setters en código**: por simetría con los otros admin setters del contrato (`setPolicyManager`, `setTwapBurner`, `setCapacityOracle`) — el owner ya puede modificar dependencias críticas; un setter más del mismo nivel de riesgo no degrada el threat model. Si se prefiere remover post-mainnet, alternativa es un UUPS upgrade de cleanup que elimine los setters.

---

### CEX-RESERVE-DEFERRED — CEXLiquidityReserve V5.1+ deploy diferido

**Estado**: Abierto (deliberadamente, post-Fase 5 o descartado).

**Detalle**: el Sprint Upgrade BondVault On-Chain (2026-05-23) aplicó R1
on-chain (PR #149) pero **no** desplegó una `CEXLiquidityReserve` fresca ni
invocó `bondVault.setCexReserve(<address>)`. Resultado: la rama
**auto-injection** del `BondVault._checkAndInject` (10% del balance de la
reserva CEX → BondVault si `availableCapacityRatioBps < 5000`) queda
INACTIVA en Sepolia — gate `cexReserve != address(0)` salta. La rama
**LUMINA floor pause** (independiente del CEX reserve) sí queda activa.

**Acción mainnet runbook** (opcional, sólo si se decide reactivar
auto-injection):

1. `forge script DeployCEXLiquidityReserve.s.sol --broadcast` o equivalente.
2. Fundear con LUMINA del treasury (porcentaje a decidir según tokenomics).
3. `cast send <BondVault proxy> "setCexReserve(address)" <reserveAddress>` —
   gateado por `DEFAULT_ADMIN_ROLE`. No requiere otro UUPS upgrade del
   BondVault — el código R1 ya está on-chain.

**Por qué se difiere**: el ROI testnet de redeployar la reserva CEX +
mover LUMINA no justifica el cost; el floor pause + hysteresis cubre el
caso de protección crítica (LUMINA < $0.005). Auto-injection es nice-to-have
para suavizar drawdowns de capacidad, no protección estructural.

---

## ~~20. Docs Mintlify desactualizado (audit UX/DevEx 2026-05-22)~~ — CERRADO 2026-05-22

**Resolved**: Sprint Docs Mintlify Integral (org-lumina/docs PR draft). 14 áreas alineadas a V5.3 en una sola pasada con 3 sub-agents paralelos + main thread:

- Homepage (`index.mdx`) + Quickstart (`quickstart.mdx`) reescritas con tabla de 6 productos, sandbox-first Step 1, install `@^0.6.0`.
- Navigation (`docs.json`) expone 3 páginas nuevas: `concepts/adapters`, `concepts/bondvault-throttle`, `agents/sandbox-first`.
- 10 Core Concepts pages updated (8 existentes + 2 new) — sub-agent.
- 7 For AI agents pages updated (6 + 1 new) — sub-agent.
- 5 SDK reference pages aligned al v0.6.0 + migration guide v0.5.x→v0.6.0 — sub-agent.
- Contracts reference (deployed.mdx + architecture.mdx) con V5.3 adapter + shield maps + BaseScan links + audit-fix map updated.
- Global purge `prob/probabilidad/PoR` en surface user-facing.
- Cleanup retired products (FlashBTC4h/MicroDepeg/RateShock) — RateShock referenciado sólo como paused.

Ver detalles en `what-we-tested.md` sección 17.

---

### ~~FA-V1-C1 — ShieldKeeper.checkAndSettlePolicy no implementado~~ — CERRADO 2026-05-23

**Resolved**: Sprint Fix 7.4 CRITICAL — ver [`audit-pack/sprints/2026-05-23-sprint-fix-7-4-critical.md`](./sprints/2026-05-23-sprint-fix-7-4-critical.md). El método se agregó al `FlashShieldAdapter` (los slim shields no son upgradeables — solo los adapters son UUPS). 13 txs on-chain: 1 deploy de nueva impl (`0xc92F034442B918C0392bcc357D995D7e0439Bad8`) + 6 `upgradeToAndCall` + 6 `setPolicyManager(0x546C07…cDd8)`. 11/11 tests PASS. Verificación on-chain: los 6 adapters revertan `checkAndSettlePolicy(999)` con `POLICY_NOT_FOUND` (selector presente + policyManager seteado + delegación a shield OK). ShieldKeeper automation ahora funcional.

---

### ~~FA-V1-C2 — Sandbox roto (relayer no autorizado)~~ — CERRADO 2026-05-23 (parcial)

**Resolved on-chain**: `coverRouter.setRelayer(0x168dC7105e907294f9d066cee24f30caa5A17E4a, true)` ejecutado en tx `0x1d91e3d22d6fcc11b909d374572940cc61bc5b94be8b2e33b36f55e31c135cec` (block 41908739). Verificación post-block: `authorizedRelayers(0x168dC7…) = true`. El smoke test `/sandbox/try` ya NO retorna `relayer_unauthorized` — el gate del relayer está OK. Sprint detalle en [`audit-pack/sprints/2026-05-23-sprint-fix-7-4-critical.md`](./sprints/2026-05-23-sprint-fix-7-4-critical.md).

**Follow-up abierto**: `FA-V1-C2-FOLLOWUP` (ver abajo).

---

### FA-V1-C2-FOLLOWUP — sandboxWallet sin allowance al CoverRouter

**Estado**: Abierto, severidad HIGH.

**Detalle**: post-`setRelayer`, `/sandbox/try` retorna `internal_error` en lugar de respuesta exitosa. Root cause: `allowance(sandboxWallet=0xC1631716e3EE5EB8092927680a1c9A49C8D55B79, coverRouter=0xcdB70B40e6a3DEac3189185d947A0e458518F566) = 0`. SandboxWallet tiene 999.36 mUSDC + 0.015 ETH, pero nunca aprobó al CoverRouter para tirar el premium.

**Fix (founder action — privkey del sandboxWallet está API-side)**:

```bash
cast send 0xD944d8e5D8329994D83950872Ec210891d3Ab6AE \
  "approve(address,uint256)" 0xcdB70B40e6a3DEac3189185d947A0e458518F566 \
  115792089237316195423570985008687907853269984665640564039457584007913129639935 \
  --private-key $SANDBOX_WALLET_PK --rpc-url $BASE_SEPOLIA_RPC
```

(Approve MAX_UINT256 — gas one-shot.) Re-test `/sandbox/try` esperando respuesta exitosa con `policyId`.

---

### FA-V1-I3 — SDK 0.7.0 listo para publish (founder action pending)

**Estado**: Abierto pero ready, severidad HIGH (validado en Sprint Fix 7.4 CRITICAL).

**Detalle validado**: `@lumina-org/sdk` `0.7.0` mergeado a `main` del repo `lumina-sdk` (commit `612de98`, PR `sdk#15` merged). Build clean (`tsc` sin diagnostics), tests `71 passing / 0 failing / 1 skipped`, throttle API (R3) presente en `src/bonds/throttle.ts` (`BondQueue`, `getRedemptionStatus`, `ThrottleInfo`, constants), exports OK en `dist/index.d.ts`. `package.json` publish manifest válido (`name`, `version`, `main`, `types`, `files`, `publishConfig.access: public`, `prepublishOnly` re-runs build+test).

**Action pending (founder, fuera de scope on-chain)**:

```bash
cd /c/tmp/lumina-sdk
git checkout main && git pull   # ensure at 612de98 (PR sdk#15 merge)
npm ci
npm publish --access public
# Si 2FA habilitado: agregar --otp=<6-digit-code>
```

Opcional post-publish: `git tag v0.7.0 && git push origin v0.7.0`.

---

## Changelog

- **2026-05-25 (Sprint Fix 7.3 Manual Review Complete + V2)**: resueltos los 28 findings del Manual Review V1. **22 fixed en código** (2 HIGH MR-H01/MR-H02 + 6 MEDIUM + 8 LOW + 6 INFO), todos con test bug-before/no-after en `test/manual-review-fixes/` (compilan + pasan a `runs=1`). **Nuevo bug confirmado durante el fix: MR-L10 upgradeado LOW→HIGH** — doble-decremento de `totalCommittedUSD` en `processQueue` (borraba el committed de otros holders → sobreestimaba `availableCapacityUSD`); FIXED (decrementa sólo `queued` en pay-time). Dispositions: **MR-M05** design tradeoff (FounderVesting V2 no se despliega en testnet; mainnet Fase 6 deploy fresco con `migrateFrom`/freeze), MR-L02/L03/L08/L09 doc/verify, INFO-7/8 cosmético/positivo. Audit V2 = **9.3/10 SOUND** (V1 8.0). Report `audit-pack/audits/2026-05-25-manual-review-v53-v2.md`. PR `feat/fix-manual-review-complete` (draft). **Pendiente founder**: broadcast on-chain de `UpgradeAll-FixManualReview.s.sol` (no ejecutado — regla "no broadcast sin dry-run 100% limpio" + build OOM en Windows), verificar router SwapRouter02 (MR-L09), Echidna 200k en CI Linux, `BL-MULTISIG`.
- **2026-05-23 (Sprint Fix 7.4 CRITICAL)**: cerrados `FA-V1-C1` (UUPS upgrade 6 FlashShieldAdapter agregando `checkAndSettlePolicy(uint256)` + `setPolicyManager`; new impl `0xc92F034442B918C0392bcc357D995D7e0439Bad8`; 13 tx on-chain; 11/11 tests PASS) y `FA-V1-C2` parcial (`coverRouter.setRelayer(0x168dC7…, true)` ejecutado, tx `0x1d91e3d2…cec`). Abierto `FA-V1-C2-FOLLOWUP` (sandboxWallet sin allowance — founder API-side). Validado `FA-V1-I3` (SDK 0.7.0 ready, founder pending `npm publish`). Sprint detalle en `audit-pack/sprints/2026-05-23-sprint-fix-7-4-critical.md`.
- **2026-05-23 (Sprint 7.4 Functional Audit V5.3 V1)**: ejecutado audit funcional testnet — veredicto NEEDS-ADJUSTMENT, score 7.7/10. Report archivado en `audit-pack/audits/2026-05-23-functional-audit-v53-v1.md`. 3 críticos nuevos: `FA-V1-C1` (ShieldKeeper interface), `FA-V1-C2` (sandbox relayer no autorizado), `FA-V1-I3` (SDK 0.7.0 unpublished). Sección 22 nueva en `what-we-tested.md`.
- **2026-05-23 (Sprint Upgrade BondVault On-Chain)**: R1 (PR #149) aplicado on-chain vía UUPS upgrade del BondVault proxy `0x193acBc1EdC5E565a4aBE96941C7E7AeF637B6EC` → nueva impl `0x6BBDE25a235DC07c0145A8a1A1d570E4f7ABdFaA` (tx `0xa395c8b6…03a477`). Storage layout compatible (slots 12/13 ocupados de `__gap`, gap 46→43). Selectors R1 (`policiesPaused`, `cexReserve`, `totalInjectedFromCex`, `availableCapacityRatioBps`) responden. Floor pause + hysteresis **ACTIVOS**; CEX auto-injection **INACTIVO** por decisión founder (`cexReserve = 0x0`, no se desplegó CEXLiquidityReserve fresca). Smoke test e2e post-upgrade exitoso (`policyId=1` minted en CoverRouter, BondVault.reserveCapacity ejecutó normalmente). Nuevo item **CEX-RESERVE-DEFERRED** en Mainnet Blockers. Sprint archivado en `audit-pack/sprints/2026-05-23-sprint-upgrade-bondvault-on-chain.md`.
- **2026-05-23 (Sprint Fix Audit Economic Complete)**: cerrados R1 (CEX auto-injection + LUMINA floor pause con hysteresis), R2 (BondVault.redeem semantics verified, no bug) y R3 (SDK v0.7.0 throttle + docs Mintlify) del Audit Economic V1. Re-auditoría Economic V2 produce score 8.4/10 (vs V1 6.4) y verdict **SOUND** — ver `audit-pack/audits/2026-05-23-economic-audit-v53-v2.md`. Residuales documentados en el reporte V2 (no items nuevos abiertos aquí: `policiesPaused` no enforced en CoverRouterV2 [LOW, fuera de scope post BL-USDC], Halmos `_checkAndInject` deferido [item #1 ya existente], actuarial validation [item #7 ya existente]).
- **2026-05-23 (Sprint CR-USDC-Reconfig)**: UUPS upgrades en `CoverRouterV2` + `TWAPBurner` agregando `setUsdc(address)` onlyOwner; ambos proxies repointados a MockUSDC en Sepolia para cerrar gap arquitectural Sprint USDC Mock. Smoke e2e on-chain `policyId=1` con premium pulled de mUSDC. Nuevo item **BL-USDC** en sección Mainnet Blockers con runbook revert a Circle USDC mainnet. Sección 20 nueva en `what-we-tested.md`.
- **2026-05-23 (Sprint USDC Mock — Fase 5 prerequisite)**: item #27 CERRADO (faucet migrado a `mint` sobre MockUSDC permissionless). Item #28 nuevo (CoverRouter USDC config no alineada con mUSDC — contract-side follow-up).

- **2026-05-22 (Sprint Docs Mintlify Integral)**: item 20 CERRADO (docs Mintlify desactualizado del audit UX/DevEx). Sección 17 nueva en `what-we-tested.md`.
- **2026-05-23 (Sprint Recovery)**: item #28 (CR USDC config) CERRADO — Sprint CR USDC Reconfig (Opción A, setter + UUPS upgrade) archivado en `audit-pack/sprints/2026-05-23-sprint-cr-usdc-reconfig.md`. Pre-mainnet blocker `BL-USDC` documentado para mainnet re-config a Circle USDC canonical.
- **2026-05-22 (Sprint Fix Critical+High, post-audit UX/DevEx)**: items #18 (Tokenomics V2 deferred) y #19 (USDC mock prerequisite Phase 5) remain abiertos. SDK 0.6.0 publicado en npm (cierra issue #1 del audit UX/DevEx). llms.txt mergeado (cierra issue #2). PRs sdk #13 + docs #15 merged.
- **2026-05-21 (Sprint T-30c)**: item 14 CERRADO (adapter unit tests + integration TODOs + deploy + verify + register + configure + E2E reads). Items 15 (tail de productShield mappings) y 16 (retry semantics ops) nuevos pero no bloqueantes.
- **2026-05-21 (Sprint T-30b)**: item 13 CERRADO (auditorías profundas completadas: 48 Echidna × 200k PROVEN, 5 Halmos PROVEN, SAST clean, adapter pattern resuelve interface bridge). Item 14 nuevo (adapter integration tests para T-30c).
- **2026-05-20 (Sprint T-30a)**: agregado item 13 (T-30b auditorías profundas + integration TODOs).
- **2026-05-18 (Sprint DD)**: documento inicial creado con 12 items pendientes.