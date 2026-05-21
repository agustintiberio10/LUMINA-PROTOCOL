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

## 13. Auditorías profundas T-30b (Slither/Aderyn/Mythril/Halmos + Echidna 200k)

**Estado**: Sprint T-30a entregó código + tests unitarios + Echidna scaffolds (testLimit=1000). Auditorías profundas pendientes:

- Slither / Aderyn / Mythril sobre los nuevos shields + BaseFlashShield + CoverRouterV2 (sequencer) + BondVault (throttle).
- Halmos formal verification sobre BaseFlashShield + BondVault throttle invariants.
- Echidna 200k runs × 48 properties (6 shields × 8 props) — requiere matrix workflow extendido.
- Tests integration completos (cubrir 2 TODOs en `ShieldsE2E.t.sol`: testNoTrigger_PolicyExpires + testBondRedemption_RespectsThrottle).

**Razón**: T-30a alcance ESTRICTO se limita a código + tests scaffolds para que T-30b corra las auditorías sobre código fijado.

---

## Changelog

- **2026-05-20 (Sprint T-30a)**: agregado item 13 (T-30b auditorías profundas + integration TODOs).
- **2026-05-18 (Sprint DD)**: documento inicial creado con 12 items pendientes.