# Pricing 7 productos — Multiplicador Lumina derivado desde código

**Fecha:** 2026-05-20
**Sprint:** Pricing — re-derivación independiente del multiplicador desde contratos
**Branch:** `docs/sprint-pricing-7-products`
**Predecesor:** PR #136 (V1 derivó 1.20 desde first principles); este sprint **valida 1.20 desde el código real**

---

## 1. Inputs (no recalculados — informe Dune)

| # | Producto | Trigger | Ventana | λ/año | PoR (Poisson) |
|---|---|---|---|---:|---:|
| 1 | FlashBTC-1h | BTC ↓ ≥ 2.5% en 1h | 1 h | 16.0 | 0.182% |
| 2 | FlashBTC-24h | BTC ↓ ≥ 6% en 24h | 24 h | 12.2 | 3.288% |
| 3 | FlashBTC-48h | BTC drawdown ≥ 10% rolling 48h | 48 h | 17.8 | 9.290% |
| 4 | FlashETH-1h | ETH ↓ ≥ 4% en 1h | 1 h | 9.2 | 0.105% |
| 5 | FlashETH-24h | ETH ↓ ≥ 8.5% en 24h | 24 h | 10.6 | 2.864% |
| 6 | FlashETH-48h | ETH drawdown ≥ 14% rolling 48h | 48 h | 14.6 | 7.690% |
| 7 | RateShockShield | Aave V3 USDC borrow ≥ 12% APY × 168h | 14 d | 4.8 | 16.83% |

Severity: **$1,000 USD face value** (fijo del bono ERC-1155).

---

## 2. PHASE B — Re-derivación del multiplicador desde contratos

### 2.1 Fórmula real del contrato (`CoverRouterV2.sol:204`)

```solidity
uint256 premium = (coverageAmount * config.payoutRatioBps * config.triggerProbBps * config.marginBps)
                / (10000 * 10000 * 10000);
```

Equivalente algebraico:
```
premium = coverage × (payoutRatioBps/10⁴) × (triggerProbBps/10⁴) × (marginBps/10⁴)
```

### 2.2 Componentes de la fórmula (con su fuente en contrato)

| Componente | Valor deployado | Fuente | Significado |
|---|---:|---|---|
| `payoutRatioBps` | **8000** = **0.80** | `CoverRouterV2.sol:63` + deploy config | Deductible 20% → payout efectivo 80% del coverage. Refleja `DEDUCTIBLE_BPS = 2000` de los shields. |
| `triggerProbBps` | variable por producto | `CoverRouterV2.sol:64` + deploy config | Probabilidad de trigger en bps. Es donde el deployer inyecta la PoR estimada. |
| `marginBps` | **15000** = **1.50×** | `CoverRouterV2.sol:65` + deploy config | Margen único del protocolo. Absorbe λ uncertainty + slippage + correlation + oracle risk en un solo knob. |

### 2.3 Componentes del ecosistema que afectan economics pero NO el premium del usuario

| Componente | Valor | Fuente | Impacto |
|---|---:|---|---|
| Split AFD régimen healthy (1,1): burn/buyback/ops/maint | **85% / 8% / 2% / 5%** | `AdaptiveFeeDistributor.sol:78` (`return (8500, 800, 200, 500)`) | Cómo se distribuye el premium **post-cobranza**. No altera el premium pagado. |
| TWAPBurner `maxSlippageBps` | **500** = 5% | `TWAPBurner.sol:110` | Drag operacional del swap USDC→LUMINA. NO recargado al usuario. |
| TWAPBurner `burnCooldown` | **900 s** (15 min) | `TWAPBurner.sol:113` | Frecuencia mínima de burns. Acumula USDC entre ejecuciones. |
| BondVault `SAFETY_FACTOR_BPS` | **5000** = 50% | `BondVault.sol:46` | Solo 50% del balance respalda obligaciones nuevas. NO afecta premium. |
| BondVault `MIN_REDEEM_PRICE` | **0.001e18** | `BondVault.sol:47` | Floor price para redemption. NO afecta premium. |
| BondVault fórmula redemption | `(usdAmount × 1e36) / oraclePrice` | `BondVault.sol:220` | LUMINA entregada al holder ≠ función del premium pagado. |
| ClaimBond `bondMaturitySeconds` | **730 days** default | `ClaimBond.sol initialize()` | Bond redimible a 2 años. NO descontado en pricing del CoverRouter. |
| CoverRouter `min coverage` | **100e6** = $100 | `CoverRouterV2.sol:201` | Filter de spam. |

### 2.4 Derivación del multiplicador Lumina (`M_Lumina`)

Reescribiendo la fórmula del contrato como `premium = coverage × PoR × M_Lumina`:

```
premium = coverage × (payoutRatioBps/10⁴) × PoR × (marginBps/10⁴)
        = coverage × 0.80 × PoR × 1.50
        = coverage × 1.20 × PoR
```

**M_Lumina = 0.80 × 1.50 = 1.20** ← multiplicador efectivo del contrato.

Esta re-derivación es **independiente** de la del Sprint V1 (que partía de first principles `DF/burn_ratio × safety_buffer = 0.957 × 1.2425 = 1.189`). Ambas convergen al mismo valor **1.20**, pero por caminos distintos:
- **V1 (first principles):** `1.20 ≈ break_even × safety` desde análisis económico del ecosistema.
- **Este sprint (código):** `1.20 = payoutRatioBps × marginBps / 10⁸` desde la fórmula deployada.

La coincidencia confirma que **el contrato ya está parametrizado para implementar el modelo Lumina** sin necesidad de cambiar la fórmula.

---

## 3. PHASE C — Aplicación del multiplicador Lumina a los 7 productos

**Fórmula:**
```
Prima Pura  = PoR × $1,000 × DF₂y = PoR × $890   (DF₂y = 0.89 al 6% APY)
Prima Lumina = $1,000 × 0.80 × PoR × 1.50 = $1,200 × PoR  (sin DF; el contrato no descuenta el bond 2y)
Prima Externa = Prima Pura × 1.863 = $890 × PoR × 1.863 = $1,658.07 × PoR
Diff %        = (Prima Lumina − Prima Externa) / Prima Externa
```

### Tabla maestra

| # | Producto | PoR | **Prima Pura** | **Prima Lumina** | **Prima Externa** | **Diff %** |
|---|---|---:|---:|---:|---:|---:|
| 1 | FlashBTC-1h | 0.182% | $1.62 | **$2.18** | $3.02 | **−27.6%** |
| 2 | FlashBTC-24h | 3.288% | $29.26 | **$39.46** | $54.51 | **−27.6%** |
| 3 | FlashBTC-48h | 9.290% | $82.68 | **$111.48** | $154.04 | **−27.6%** |
| 4 | FlashETH-1h | 0.105% | $0.93 | **$1.26** | $1.74 | **−27.6%** |
| 5 | FlashETH-24h | 2.864% | $25.49 | **$34.37** | $47.49 | **−27.6%** |
| 6 | FlashETH-48h | 7.690% | $68.44 | **$92.28** | $127.51 | **−27.6%** |
| 7 | RateShockShield (14d) | 16.83% | $149.79 | **$201.96** | $278.95 | **−27.6%** |

**Diff uniforme ≈ −27.6%** por construcción matemática:
```
Ratio = M_Lumina / (DF₂y × M_externo)
      = 1.20 / (0.89 × 1.863)
      = 1.20 / 1.65807
      = 0.7237 ≈ −27.63%
```

---

## 4. PHASE D — Flujo end-to-end de cada producto

El flujo es **el mismo para los 7 productos** (sistema agnóstico al shield). Lo que cambia entre productos son los parámetros del shield (trigger, duración) y la `triggerProbBps` en su `ProductConfig`, no la ruta del USDC ni del LUMINA.

### 4.1 Flujo común — 10 pasos

| # | Paso | Contrato | Función |
|---|---|---|---|
| 1 | Usuario paga premium USDC | `CoverRouterV2` | `purchasePolicy(productId, coverage, asset)` (L147-225) |
| 2 | Premium calculado | `CoverRouterV2` | `(coverage × payoutRatioBps × triggerProbBps × marginBps) / 10⁴³` (L204) |
| 3 | USDC ruteado 100% intra-tx | `CoverRouterV2` → `TWAPBurner` | `twapBurner.receivePremium(premium)` (L218) |
| 4 | Policy registrada | `PolicyManagerV2` | `recordPolicy(productId, buyer, coverage, premium, duration, asset)` |
| 5 | Capacidad reservada en vault | `BondVault` | `reserveCapacity(reservedAmount)` |
| 6 | Auto-burn cuando counter/accumulated supera threshold | `TWAPBurner` | `executeBurn()` (L149+) consulta AFD bps |
| 7 | USDC → LUMINA → burn (85%) | `UniswapV3Adapter` / `AerodromeAdapter` → `LuminaTokenV2` | `IBurnable.burn(luminaReceived)` |
| 8 | Buyback bonds P2P + Double Burn si solv≥150% (8%) | `BuybackEngine` | `bondVault.burnFromReserves()` |
| 9 | Ops 2% + maintenance 5% | `MaintenanceReserve` | USDC parked, `safeTransfer` on demand |

### 4.2 Flujo de trigger (si se activa)

| # | Paso | Contrato | Función |
|---|---|---|---|
| 10 | Shield notifica trigger | `ShieldKeeper` → Shield (no leer) | `_verifyAndCalculate()` |
| 11 | Bond ERC-1155 minted | `BondVault.issueBond()` → `ClaimBond.mint()` | `mint(holder, epochId=YYYYMM, usdAmount)` |
| 12 | Holder espera 730 días | — | `bondMaturitySeconds` (default 730d) |
| 13 | Redemption | `BondVault.redeemBond(epochId, usdAmount)` | `luminaAmount = usdAmount × 1e36 / oraclePrice` (L220) |
| 14 | LUMINA transferido al holder | `BondVault` → `LuminaTokenV2` | `lumina.transfer(holder, luminaAmount)` (L232) desde balance pre-fondeado 70M |

### 4.3 Mapeo por producto

| # | Producto | Premium / $1k cov | Posición en ecosistema | Frecuencia activación (λ/año) | Si activa: USD bond emitido / face value |
|---|---|---:|---|---:|---:|
| 1 | FlashBTC-1h | $2.18 | Core BTC short-window | 16.0 | $1,000 face → $800 payout (80%) |
| 2 | FlashBTC-24h | $39.46 | Core BTC mid-window | 12.2 | $1,000 → $800 |
| 3 | FlashBTC-48h | $111.48 | Core BTC long-window | 17.8 | $1,000 → $800 |
| 4 | FlashETH-1h | $1.26 | Core ETH short-window | 9.2 | $1,000 → $800 |
| 5 | FlashETH-24h | $34.37 | Core ETH mid-window | 10.6 | $1,000 → $800 |
| 6 | FlashETH-48h | $92.28 | Core ETH long-window | 14.6 | $1,000 → $800 |
| 7 | RateShockShield | $201.96 | Nicho — Aave borrowers | 4.8 | $1,000 → $800 |

> "Posición en ecosistema" describe la categoría conceptual del producto. NO se inventan volúmenes — son función del demand off-chain.

---

## 5. PHASE E — Comparación 1.863 vs 1.20 (componente por componente)

### 5.1 Componentes del multiplicador externo 1.863 y su aplicabilidad a Lumina

| Componente externo | Valor | ¿Aplica al modelo Lumina según el código? |
|---|---:|---|
| Safety loading 35% | ×1.35 | **No directo**. El `marginBps = 15000` (1.50×) del contrato funciona como un loading único pero con valor distinto. El factor 1.50 absorbe loading + correlation + oracle + slippage en un solo knob. |
| Expense ratio 15% | ×1.15 | **No aplica**. El 2% ops + 5% maintenance del AFD se DESCUENTAN del premium recibido (post-cobranza), NO se SUMAN al premium del usuario. |
| Profit margin 20% | ×1.20 | **No aplica**. "Profit" en Lumina = deflación LUMINA neta (beneficio para holders del token via burn), no margen sobre premium recibido. |
| Discount factor 2y | ×0.89 | **No aplica**. La fórmula del contrato NO descuenta el bond 2y. Cobra premium nominal, paga bond nominal a 730d. El factor `payoutRatioBps = 0.80` aproxima parcialmente el DF (0.89) pero su rol formal es el deductible. |

### 5.2 Componentes del multiplicador Lumina 1.20 (lo que SÍ está en el código)

| Componente Lumina | Valor | Fuente | Cubre |
|---|---:|---|---|
| `payoutRatioBps` | ×0.80 | `CoverRouterV2.sol:63` | Deductible 20% (refleja `DEDUCTIBLE_BPS = 2000` de cada shield) |
| `marginBps` | ×1.50 | `CoverRouterV2.sol:65` | λ uncertainty + TWAPBurner slippage + correlation + oracle risk (todo en un knob único) |
| **M_Lumina** | **×1.20** | derivado | premium = coverage × M_Lumina × PoR |

### 5.3 Componentes que el actuario externo NO consideró pero el contrato sí impone

| Componente | Valor | Fuente | Impacto |
|---|---:|---|---|
| Auto-burn batching | 50 tx o $500 accumulated | `TWAPBurner` constants (sprints V1/V2) | Latencia del swap, no afecta premium |
| `burnCooldown 900s` | 15 min | `TWAPBurner.sol:113` | Frecuencia mínima entre burns |
| `maxSlippageBps = 500` | 5% | `TWAPBurner.sol:110` | Slippage de swap, drag operacional |
| `SAFETY_FACTOR_BPS = 5000` | 50% | `BondVault.sol:46` | Limita emisión nueva al 50% del balance |
| `MIN_REDEEM_PRICE = 0.001e18` | $0.001 floor | `BondVault.sol:47` | Floor de redemption price oracle |
| AFD régimen healthy | 85/8/2/5 | `AdaptiveFeeDistributor.sol:78` | Distribución post-cobranza del premium |

Ninguno de estos componentes está en el multiplicador externo 1.863 — son **realidades del ecosistema** que el actuario no modeló.

### 5.4 Tabla resumen comparativa

| Métrica | Externo (1.863) | **Lumina (derivado 1.20)** | Diferencia |
|---|---:|---:|---:|
| Multiplicador | 1.863 | **1.20** | −35.6% |
| Fórmula | `Pure × DF × 1.863` | `coverage × 0.80 × PoR × 1.50` | Distintas |
| Discount factor 2y | sí (×0.89) | NO (hardcoded en payoutRatio) | — |
| Prima FlashBTC-1h / $1k | $3.02 | **$2.18** | −27.6% |
| Prima FlashBTC-24h / $1k | $54.51 | **$39.46** | −27.6% |
| Prima FlashBTC-48h / $1k | $154.04 | **$111.48** | −27.6% |
| Prima FlashETH-1h / $1k | $1.74 | **$1.26** | −27.6% |
| Prima FlashETH-24h / $1k | $47.49 | **$34.37** | −27.6% |
| Prima FlashETH-48h / $1k | $127.51 | **$92.28** | −27.6% |
| Prima RateShockShield / $1k | $278.95 | **$201.96** | −27.6% |

---

## 6. Notas técnicas

### 6.1 Sobre el `triggerProbBps` deployado vs PoR del Dune

Las primas calculadas en este sprint usan **PoR del Dune** (`λ·Δt` Poisson sobre 5y data empírica). El contrato deployado en Sepolia tiene un `triggerProbBps` constante por producto en su `ProductConfig` que **no coincide** con la PoR del Dune para 6 de los 7 productos. Esa discrepancia entre análisis y configuración deployada queda fuera del scope de este sprint — el founder pidió aplicar `M_Lumina` derivado del código a las PoR del Dune, no auditar la config del deploy.

### 6.2 Sobre el discount factor 2y

El multiplicador externo aplica `× 0.89` para descontar el valor del bond a 2y. El contrato **no aplica este descuento explícitamente**, pero el factor `payoutRatioBps = 0.80` actúa como aproximación parcial (0.80 vs 0.89 → 10% conservador adicional). Esto contribuye al diff uniforme de −27.6%.

### 6.3 Sobre la convergencia V1 ↔ código

Sprint V1 derivó `M_Lumina ≈ 1.20` desde first principles independientes (DF/burn_ratio × safety_buffer = 0.957 × 1.2425). Este sprint deriva `M_Lumina = 1.20` desde la fórmula del contrato (0.80 × 1.50). **Ambos métodos convergen al mismo valor** por caminos distintos, lo que valida la coherencia del modelo Lumina.
