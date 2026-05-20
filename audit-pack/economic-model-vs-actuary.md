# Modelo económico real de Lumina V5.2 vs supuestos actuariales externos

**Fecha**: 2026-05-20
**Sprint**: Análisis económico (contraste actuarial)
**Branch**: `docs/sprint-economic-analysis`
**Cross-ref**: tracker ADR-028

---

## 1. Resumen ejecutivo

Recibimos un análisis actuarial externo que aplicó un framework P&C tradicional (Berkshire Hathaway: cobrar primas hoy, mantener "float" USDC, ganar yield sobre el float, pagar siniestros futuros con dilución token). El framework **NO corresponde con lo que los contratos de Lumina V5.2 hacen**.

La lectura on-chain de los 10 contratos del ciclo de vida (CoverRouterV2, PolicyManagerV2, AdaptiveFeeDistributor, TWAPBurner, BuybackEngine, ClaimBond, BondVault, TreasuryVesting, CEXLiquidityReserve, MaintenanceReserve) confirma que Lumina opera un modelo **buyback-and-burn con pasivo nominado en token nativo respaldado por reserva pre-fondeada de 70M LUMINA**. El 100% del USDC entrante por primas se rutea **en la misma tx** a `TWAPBurner.receivePremium()`, donde ~85% se utiliza para market-buy + burn de LUMINA (régimen "healthy" fallback `FALLBACK_BURN_BPS = 8500`), 8% al BuybackEngine, 2% a ops, 5% a maintenance. **No hay float, no hay yield sobre float, no hay capital staked en Aave/Morpho**.

Recomendaciones del actuario derivadas del modelo Berkshire (Solvency Reserve Fund 20%, float-yield 5% APY, "cost of capital zero" como ventaja competitiva) **no aplican**. Recomendaciones independientes del modelo (RateShock window 30d → 14d, M-1 throttle de redemption, concentration limits) **sí aplican** y, en el caso de M-1, son **estructuralmente necesarias** porque `BondVault.redeemBond()` no tiene rate limit on-chain.

---

## 2. Flujo real de USDC (mapeado desde contratos)

### 2.1 Entrada — `CoverRouterV2.purchasePolicy()`

- **Path**: `src/core/CoverRouterV2.sol` L147-225
- **Función**: `purchasePolicy(bytes32 productId, uint256 coverageAmount, bytes32 asset)` (también variante `purchasePolicyFor` para terceros).
- **Cobranza**: `usdc.safeTransferFrom(buyer, address(this), premium)` (L213). Sólo ERC-20 USDC; no acepta `msg.value`.
- **Destino inmediato**: `usdc.forceApprove(twapBurner, premium); twapBurner.receivePremium(premium)` (L217-218).
- **Comentario explícito en NatSpec** (L15): *"100% of premiums go to TWAPBurner for buy & burn"*.

**Consecuencia:** en el mismo bloque que ingresa el premium, el balance neto de USDC en CoverRouterV2 retorna a cero. **No hay acumulación.**

### 2.2 PolicyManagerV2 — bookkeeping only

- **Path**: `src/core/PolicyManagerV2.sol` L186-247
- **NO toca USDC**. Solo registra metadata: `recordPolicy(productId, buyer, coverage, premiumAmount, duration, asset)` y reserva capacidad en BondVault via `bondVault.reserveCapacity(reservedAmount)` (L206).
- `premiumAmount` se almacena en `PolicyRecord.premiumPaid` solo como dato.

### 2.3 AdaptiveFeeDistributor — view-only oracle de splits

- **Path**: `src/core/AdaptiveFeeDistributor.sol` L45-92
- **NO distribuye fondos**. Es un *lookup table* que retorna bps de distribución según `(solvencyLevel, momentumLevel)`.
- Matriz hardcodeada 4×4. Buckets: `(burnBps, buybackBps, opsBps, maintenanceBps)` — **no incluye TreasuryVesting ni CEXLiquidityReserve**.

| Régimen (sLevel, mLevel) | burn | buyback | ops | maint |
|---|---:|---:|---:|---:|
| (0, 0) insolvente + momentum bajo | 9500 | 0 | 0 | 500 |
| (1, 1) "healthy" típico | 8500 | 800 | 200 | 500 |
| (3, 3) sobre-solvente + momentum alto | 0 | 9600 | 200 | 200 |

### 2.4 TWAPBurner — el consumidor real del USDC

- **Path**: `src/core/TWAPBurner.sol`
- **Entrada USDC**: `receivePremium(uint256)` L118 (PUSH desde CoverRouterV2), `receiveMarketplaceFee(uint256)` L138 (push desde marketplace).
- **Split efectivo**: TWAPBurner lee bps del AdaptiveFeeDistributor; en fallback usa `FALLBACK_BURN_BPS = 8500` (85%), `FALLBACK_BUYBACK_BPS = 800` (8%), `FALLBACK_OPS_BPS = 200` (2%), `FALLBACK_MAINT_BPS = 500` (5%).
- **Routing burn**: `IDexRouter[]` multi-DEX con selección por mejor quote (`_swapAndBurn` L217-265). NO hardcodea Uniswap V3 — fee tier default 1%.
- **TWAP**: el nombre del contrato es engañoso. La protección TWAP vive en `capacityOracle.getLuminaPrice()` (LuminaOracleV2). El burner solo aplica cooldown `burnCooldown = 900s` entre ejecuciones.
- **Slippage**: `maxSlippageBps = 500` (5% default; bound 50-1000 bps). `minOut = max(DEX_quote × (1-slip), oracle_expected × (1-slip))`; hard `require(minOut > 0)` post-fix M-02.
- **Batching**: V2 auto-burn dispara desde `receivePremium` cuando `purchaseCounter ≥ 50` o `accumulatedUSDCSinceBurn ≥ $500`. Permissionless `executeBurn()` también disponible una vez expirado el cooldown.
- **Burn destination**: `IBurnable(lumina).burn(luminaReceived)` (L258) — usa ERC20Burnable.burn(), no transferencia a 0x0.

### 2.5 ¿Hay acumulación (float)?

**NO en el sentido del actuario.** Hay:
- Una "ventana de pre-burn" entre `receivePremium` y `executeBurn` (max 50 transacciones o $500 acumulado), típicamente sub-horaria. Promedio esperado: $250 USDC parked.
- USDC parked en `MaintenanceReserve` (5% del flow) **es inerte** — `usdc.safeTransfer(recipient, amount)` directo al gastar; `recoverToken` prohíbe rescatar USDC. Solo se va cuando un SPENDER_ROLE lo gasta en infra/audit/marketing.

**Total float estructural máximo:** ~5% del flujo acumulado (MaintenanceReserve) + ventana <1h del 100% pre-burn. **NO es el $1.86M asumido por el actuario** que requiere acumulación de 24 meses.

### 2.6 ¿Hay yield on float (Aave supply)?

**NO.** Grep exhaustivo sobre `aave|morpho|yearn|compound|supply|deposit|stake|yield|erc4626` en los 10 contratos: **0 hits funcionales**. Único match: comentario de "Recover non-LUMINA" en CEXLiquidityReserve.sol L174 (no relacionado con yield).

El yield 5% APY del actuario es **ficticio respecto del código actual**. Habría que agregar un módulo `USDCYieldRouter` que envíe el MaintenanceReserve a Aave supply, pero hoy ese módulo no existe y la cantidad sería mínima (5% de las primas, no el 100%).

---

## 3. Flujo real de LUMINA (bonds)

### 3.1 Emisión de bond al disparar trigger

- **Path**: `src/bonds/ClaimBond.sol` L97 + `src/bonds/BondVault.sol` L181-203
- **Flujo**: `BondVault.issueBond(holder, usdAmount)` → `ClaimBond.mint(holder, epochId, usdAmount)` (`onlyBondVault`).
- **ERC-1155**: sí (`ERC1155Upgradeable + ERC1155SupplyUpgradeable`).
- **Token ID = epoch maturity `YYYYMM`**. 1 token = $1 USD face value.
- **Reserva capacidad on-chain**: PolicyManagerV2 llama `bondVault.reserveCapacity()` en compra de póliza (no en trigger). `SAFETY_FACTOR_BPS = 5000` — sólo 50% del balance LUMINA pre-fondeado puede respaldar bonds nuevos.

### 3.2 Redención a los `bondMaturitySeconds` (default 730 días)

- **Path**: `src/bonds/BondVault.sol` L210-260 (redención vive en BondVault, no ClaimBond).
- **Función**: `redeemBond(uint256 epochId, uint256 usdAmount)`.
- **Fórmula LUMINA-per-holder**: `luminaAmount = (usdAmount * 1e36) / currentPrice` (L220) donde `currentPrice = _getSafePrice() = priceOracle.getLuminaPrice()` (LuminaOracleV2 con TWAP interno).
- **Floor**: `MIN_REDEEM_PRICE = 0.001e18`. Si `currentPrice < floor` → `require` fail (L217).
- **Fuente del LUMINA**: `lumina.transfer(msg.sender, luminaAmount)` **desde el balance propio de BondVault** (L232).
- **NO hay mint nuevo, NO hay treasury hop, NO hay transferFrom**.
- **Maturity**: `bondMaturitySeconds` es storage (admin-settable), default `730 days`. Bounds: `MIN = 1 minutes`, `MAX = 10 * 365 days`. Sepolia testnet usa ~60s.

### 3.3 Rate limit / throttle / cap por epoch

**NO EXISTE.** `redeemBond` solo aplica:
1. `nonReentrant`
2. `isMatured(epochId)`
3. `balanceOf(msg.sender, epochId) >= usdAmount`
4. `currentPrice >= MIN_REDEEM_PRICE`
5. `lumina.balanceOf(this) >= luminaAmount`

**Un solo holder puede redimir el balance completo de su epoch en una tx, sin cap por bloque, por usuario, ni agregado.** Esta es la observación más importante del análisis: la propuesta M-1 del actuario (redemption throttle) **no es opcional, es estructural**.

### 3.4 BondVault state actual

- **Reserva inicial**: 70M LUMINA (documentado en NatSpec L16; no es constante on-chain — `lumina.balanceOf(this)` runtime).
- **Capacidad útil**: 35M USD-equivalente (`70M × SAFETY_FACTOR_BPS / 1e4 × LUMINA_price`).
- **No pause function**. No `Pausable`, no `whenNotPaused`. GlobalPauseRegistry opera shield-arriba, no en redemption.
- **No mint function**. Sólo `transfer` out y `burnFromReserves` (Double Burn cuando solvency ≥ 150%).
- **Refill**: trivial — `lumina.transfer(bondVault, X)` desde cualquier addr. Sin función dedicada, sin evento.

### 3.5 BuybackEngine (Double Burn)

- **Path**: `src/marketplace/BuybackEngine.sol`
- **Mecanismo distinto de TWAPBurner**: compra ClaimBonds del marketplace P2P con descuento, los quema (mata la obligación USD) y, si solvency ≥ 150% (`MIN_SOLVENCY_FOR_DOUBLE_BURN = 15000`), ADEMÁS quema LUMINA directo de BondVault reserves via `bondVault.burnFromReserves(luminaToBurn)` (L191) → `IBurnable(lumina).burn(amount)` (BondVault L320).
- **USDC source**: balance propio (fondeado por el 8% buyback bucket del TWAPBurner).
- **Amount**: `(faceValueUSD * 1e18) / spotPrice` usando `capacityOracle.getLuminaPrice()` **spot** (L188).
- **LUMINA destination**: burn (nunca re-issued).

---

## 4. Contraste contra supuestos del actuario

| # | Supuesto | Realidad on-chain | ¿Coincide? |
|---|---|---|:---:|
| A | Float USDC $1.86M acumulado mes 24 | 100% del USDC entrante se rutea a TWAPBurner mismo bloque; ventana de pre-burn <1h (max 50 tx o $500). Único USDC parked = 5% MaintenanceReserve, inerte. Float estructural ≈ $0. | ❌ |
| B | Yield +5% APY en Aave sobre float | Cero referencias a Aave/Morpho/yield en los 10 contratos. MaintenanceReserve USDC no se stakea — espera transferencia manual del SPENDER_ROLE. | ❌ |
| C | Cost of capital efectivo 0% | El concepto "float-as-equity" no aplica. El "costo" real de Lumina es el **balance entre LUMINA quemada (deflación)** y **LUMINA distribuida a holders de bonds maduros (sell-pressure)**. No es 0%, es una variable dinámica. | ❌ (framework equivocado) |
| D | Loss ratio target 53.7% | La "siniestralidad" en Lumina no es USDC pagado; es LUMINA entregado desde BondVault. El loss ratio relevante es `LUMINA_redeemed / LUMINA_burned` (medido por tx hash, no USD). | ❌ (métrica errónea) |
| E | Combined ratio cash 62% | No hay cash flow operativo en el sentido P&C — 95% del USDC entrante se destruye en buyback+burn dentro del cooldown 900s. La métrica "Combined Ratio cash" no aplica. | ❌ |
| F | Inflación token 6% en cisne negro | **NO HAY MINT en redemption** — es asignación desde 70M pre-fondeado en BondVault. El supply circulante no cambia por una redención; sólo cambia la distribución entre holders. El efecto en precio sí es real, pero por sell-pressure, no inflación. La cantidad relevante es `outflow_LUMINA / circulating_supply`, no `mint_rate`. | ⚠️ (mecánica diferente, efecto similar) |
| G | Mitigación M-2: burn 80% primas | Real: **~85% en régimen "healthy"** (`FALLBACK_BURN_BPS = 8500`), variable 0-95% según `(solvencyLevel, momentumLevel)`. El estimado del actuario es razonable y cercano al real. | ✅ |
| H | Bonds redimibles a $1 face en LUMINA equiv | Confirmado: `luminaAmount = usdAmount * 1e36 / oraclePrice`, floor `MIN_REDEEM_PRICE = 0.001e18`. Pero **SIN throttle/cap on-chain**. | ⚠️ (cálculo correcto, ausencia de throttle es riesgo) |

**Score: 5/8 supuestos falsos, 1/8 parcialmente correcto, 2/8 confirmados.**

---

## 5. Modelo económico CORRECTO de Lumina

### 5.1 Ingresos
- Primas USDC entrantes: variable según volumen × prima por producto.

### 5.2 Distribución automática (sin acumulación, intra-tx + auto-burn batched)

| Bucket | % default (régimen 1,1) | Función | Resultado |
|---|---:|---|---|
| TWAPBurner → DEX swap → burn LUMINA | 85% | `IBurnable(lumina).burn()` | **Supply LUMINA ↓** |
| BuybackEngine (compra+burn ClaimBonds + Double Burn LUMINA si solv≥150%) | 8% | `bondVault.burnFromReserves()` | **Outstanding face value ↓, BondVault ↓** |
| Ops (operations, oracle fees) | 2% | `IBurnable(lumina).burn()` o transfer a ops addr | Sin acumulación significativa |
| MaintenanceReserve (audits, infra, marketing, legal) | 5% | `usdc.safeTransfer` on demand | USDC parked, eventually spent |
| **Total = 100%** | | | |

### 5.3 Egresos (token side)
- Bonds entregados desde BondVault (70M pre-fondeado, `SAFETY_FACTOR_BPS = 5000` → 35M utilizables).
- NO hay minteo nuevo.
- LUMINA transferida holder = `usdAmount × 1e36 / oraclePrice`.
- **NO hay throttle, NO hay rate limit, NO hay epoch cap on-chain.**

### 5.4 Métricas relevantes para Lumina (no insurance tradicional)

| Métrica | Significado | Cómo computar |
|---|---|---|
| **Quema neta LUMINA / mes** | Tokens destruidos vía TWAPBurner + Double Burn | `sum(IBurnable.burn events)` |
| **Outstanding bond face value (USD)** | Pasivo nominal vivo | `sum(ClaimBond.totalSupply per epoch >= maturity_min)` |
| **BondVault remaining balance** | Reserva disponible para próximas redenciones | `lumina.balanceOf(bondVault)` |
| **Solvency ratio** | `bondVault_balance × oracle_price / outstanding_face_USD` | dinámico runtime |
| **Net deflation rate** | `(burned − redeemed) / circulating_supply` por período | series histórica |

---

## 6. Re-cálculo de viabilidad con modelo correcto

Si en mes 24 se completa el ramp del actuario (3,450 pólizas/mes × $80 promedio) → $276k USDC/mes entrantes, **el 100% se destruye** en buyback+burn (mod batching, mod buyback bucket que también burnea):

- LUMINA burned/mes (régimen healthy): $276k × 93% ≈ $257k USD-equivalente quemado (85% directo TWAPBurner + 8% via BuybackEngine).
- Si LUMINA price = $0.50 → 514k tokens quemados/mes.
- Anualizado: ~**6.2M LUMINA quemados/año** = **6.2% supply** (sobre 100M total) o **8.9% sobre circulating** (asumiendo ~70M circulating).

Bond face value emitido en mes 24 (suponiendo loss ratio empírico 6-9% PoR ponderado producto-mix):
- Pólizas × premium × PoR ≈ 3,450 × $80 × 0.08 = ~**$22k USD face emitido/mes**.
- A los 24 meses de operación: bonds maduran $22k × 24 = **$528k face redimible**.
- A $0.50 LUMINA price → **~1.06M LUMINA outflow desde BondVault**.

**Balance net**: 6.2M burned/yr − 1.06M outflow ≈ **+5.1M net deflation/yr en steady state**.

Conclusión: el modelo es **estructuralmente deflacionario** si el ramp del actuario se materializa y el régimen `FALLBACK_BURN_BPS = 8500` se mantiene. La "viabilidad" del actuario es directionalmente correcta pero por razones equivocadas.

---

## 7. Riesgos reales (no los del actuario)

1. **AUSENCIA DE THROTTLE EN BondVault.redeemBond**. En mes 24, si un cohort masivo (ej. evento FlashETH-48h con concentración alta) madura simultáneamente, un sólo bot puede redimir el balance completo de su epoch en una tx. Sin protección `RANGE BETWEEN` por época o usuario. **Esto es lo único que el actuario propuso correctamente (M-1) sin saberlo**.

2. **Sensibilidad al oracle**. La fórmula de redemption usa `priceOracle.getLuminaPrice()` (LuminaOracleV2, TWAP interno). Si el oracle es manipulable (e.g. low liquidity en DEXs base de TWAP), una redención puede sacar más LUMINA del esperado. Mitigación parcial: `MIN_REDEEM_PRICE = 0.001e18` floor; pero no hay ceiling.

3. **Refill BondVault depende de actores externos**. No hay función dedicada de refill — anyone puede transferir LUMINA al vault, pero no hay incentivo on-chain para hacerlo. Si BondVault se agota en mes N, las redenciones siguientes fallarán con `lumina.balanceOf(this) < luminaAmount`. Tendría que haber un mecanismo automático (% del burn redirigido a refill cuando vault < threshold).

4. **Dependencia del régimen AdaptiveFeeDistributor**. El 85% burn fallback se activa cuando el oracle de momentum/solvency falla. En operación normal, el régimen actual depende del oracle. Si el oracle es manipulable a régimen (3,3) → 0% burn, 96% buyback, el deflation rate cae a cero. Esto es un vector de ataque económico no obvio.

5. **MaintenanceReserve inerte**. 5% del USDC entrante se acumula sin yield. A volumen $276k/mes × 5% = $13.8k/mes parked. En 24 meses son **$331k de capital ocioso**. Costo de oportunidad ≈ $16.5k/año en yield perdido (5% APY benchmark). No es catastrófico pero es un detalle de eficiencia que el actuario sí señaló (parcialmente correcto en este punto).

---

## 8. Recomendaciones del actuario que SÍ aplican

### 8.1 ✅ RateShockShield window 30d → 14d
Matemática pura sobre frecuencia λ = 4.8 evt/año. PoR cae de 32.6% → 16.8%. Prima Pura ajustable a ~$150 (vs $290 actual). Sigue siendo válida — independiente del modelo Berkshire vs token-burn.

### 8.2 ✅ Mecanismo M-1 (redemption throttle) — **ESTRUCTURALMENTE NECESARIO**
El actuario lo propuso como mitigación de inflación; la realidad es que es necesario por la **ausencia total de throttle en `BondVault.redeemBond`**. Implementación sugerida:

```solidity
uint256 public constant MAX_REDEMPTION_PER_EPOCH_BPS = 50; // 0.5% supply por semana
mapping(uint256 weekId => uint256 redeemed) public weeklyRedemption;
```

Esto introduce un cap semanal sobre el outflow LUMINA, spread payouts. Costo: usuarios esperan hasta N semanas post-maturity. Mitigado por el secondary marketplace P2P de bonos existente en V5.1.

### 8.3 ✅ Concentration limits sobre nuevas pólizas
Tope diario de pólizas FlashETH-48h y FlashBTC-48h ≤ 3% del outstanding LUMINA face value, para evitar cohort masivo. Implementable en CoverRouterV2 antes de `recordPolicy`.

### 8.4 ✅ Burn ratio ~85% (confirmado)
El estimado del actuario (80%) está cerca del real (`FALLBACK_BURN_BPS = 8500`). Mantener el actual.

---

## 9. Recomendaciones del actuario que NO aplican

### 9.1 ❌ Yield on float
No hay float estructural sobre el cual ganar yield. El 100% del USDC se destruye en burn dentro del cooldown 900s.

### 9.2 ❌ Stake USDC en Aave V3 supply
**Excepción parcial**: el 5% MaintenanceReserve podría considerar yield router (cuantía pequeña, ~$331k máx en 24 meses). Pero no era el modelo masivo del actuario.

### 9.3 ❌ Solvency Reserve Fund (20% del profit margin)
El "profit margin" del actuario asume P&C accounting con primas guardadas. En Lumina no hay primas guardadas — ya están burnadas. El SRF no tiene de dónde fondearse en este modelo.

### 9.4 ❌ Combined Ratio framework cash
Métrica P&C tradicional. En Lumina no aplica: no hay claims pagados en cash, todo es swap+burn+bond+token.

### 9.5 ❌ Loss Ratio 53.7% como target
La métrica relevante es **net deflation rate** = `burn_rate − redemption_rate`, no `losses/premiums`.

### 9.6 ⚠️ "Cost of Capital cero" como ventaja competitiva
El framework está equivocado. La ventaja real de Lumina vs P&C tradicional es **doble**: (a) el premium se destruye inmediatamente (deflación pre-pago), (b) el pasivo está nominado en token nativo respaldado por reserva pre-fondeada (no fiat). Nadie del lado tradicional puede replicar (a) porque cobra fiat y los pasivos son fiat.

---

## 10. Conclusión

El análisis actuarial externo, aplicando framework P&C tradicional Berkshire Hathaway a Lumina V5.2, produjo conclusiones direccionalmente correctas (modelo viable, deflacionario, requiere throttle) pero por **razones estructuralmente equivocadas** (asume float USDC + yield Aave). El modelo real de Lumina es un **buyback-and-burn protocol con pasivo respaldado por 70M LUMINA pre-fondeados en BondVault**, no una insurance con float invertido.

**Acción inmediata recomendada:**
1. Implementar throttle M-1 en BondVault (no es opcional — es gap estructural).
2. Re-pricing RateShockShield a ventana 14d.
3. Concentration limits en CoverRouterV2.
4. Considerar (deferred) un USDCYieldRouter para MaintenanceReserve.

**Acción no recomendada:**
1. NO implementar SolvencyReserveFund USDC 20% — no tiene de dónde fondearse.
2. NO presentar el modelo Lumina como "Berkshire on-chain" externamente — la analogía es engañosa y debilita la posición real (deflación pre-pago única en su categoría).

Próximo sprint propuesto: implementación de M-1 throttle (Sprint Análisis Implementación).
