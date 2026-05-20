# Análisis financiero pricing 7 productos — modelo real Lumina

**Fecha**: 2026-05-20
**Sprint**: Análisis Financiero Productos — pricing desde modelo Lumina (no P&C)
**Branch**: `docs/sprint-financial-analysis-products`
**Cross-refs**: PR #134 (ADR-028 mapeo) · PR #135 (ADR-029 viabilidad real) · tracker ADR-030

---

## 1. Premisa

Sprints anteriores establecieron:
- **PR #134/ADR-028:** 100% del USDC entrante se rutea a TWAPBurner (split 85/8/2/5), no hay float ni yield. El modelo real es buyback-and-burn, no P&C.
- **PR #135/ADR-029:** ratio USD burn/redeem = 1.541 (con primas del actuario externo). Modelo viable bajo cualquier precio $0.25-$1.00.

**Pero las primas del análisis Dune del actuario** se calcularon con multiplicador P&C tradicional `1.863 = (1+35%) × (1+15%) × (1+20%)` (loading + expense + profit). **Lumina NO tiene esos costos.** Este sprint re-calcula las primas DESDE CERO usando el modelo económico real.

---

## 2. Inputs fijos (no recalculados)

### 2.1 Los 7 productos (triggers + λ validados con 5y Dune)

| # | Producto | Trigger | Eventos 5y | λ/año |
|---|---|---|---:|---:|
| 1 | FlashBTC-1h | BTC ↓ ≥ 2.5% en 1h | 80 | 16.0 |
| 2 | FlashBTC-24h | BTC ↓ ≥ 6% en 24h | 61 | 12.2 |
| 3 | FlashBTC-48h | BTC drawdown ≥ 10% (rolling 48h) | 89 | 17.8 |
| 4 | FlashETH-1h | ETH ↓ ≥ 4% en 1h | 46 | 9.2 |
| 5 | FlashETH-24h | ETH ↓ ≥ 8.5% en 24h | 53 | 10.6 |
| 6 | FlashETH-48h | ETH drawdown ≥ 14% (rolling 48h) | 73 | 14.6 |
| 7 | RateShockShield | Aave V3 USDC borrow ≥ 12% APY × 168h continuo | 16-24 ext. | 4.8 |

### 2.2 Modelo Lumina (PR #134 + PR #135)

- Split AFD régimen (1,1): **85% burn / 8% buyback / 2% ops / 5% maintenance**
- BondVault: 70M LUMINA pre-fondeado, 35M utilizables (SAFETY_FACTOR_BPS = 5000)
- Maturity: 730 días
- Severity: $1,000 USD face value
- Redemption: `luminaAmount = (usdAmount × 1e36) / oraclePrice`
- Ratio descubierto con primas externas: **1.541** USD burn/redeem

---

## 3. PHASE B — PoR por producto

**Modelo Poisson:** `PoR = 1 − exp(−λ·Δt)` donde Δt = ventana cobertura en años.

| # | Producto | λ/yr | Δt (yr) | λ·Δt | **PoR** |
|---|---|---:|---:|---:|---:|
| 1 | FlashBTC-1h | 16.0 | 1.142e-4 | 0.001826 | **0.182%** |
| 2 | FlashBTC-24h | 12.2 | 2.740e-3 | 0.0334 | **3.288%** |
| 3 | FlashBTC-48h | 17.8 | 5.479e-3 | 0.0975 | **9.290%** |
| 4 | FlashETH-1h | 9.2 | 1.142e-4 | 0.001050 | **0.105%** |
| 5 | FlashETH-24h | 10.6 | 2.740e-3 | 0.0290 | **2.864%** |
| 6 | FlashETH-48h | 14.6 | 5.479e-3 | 0.0800 | **7.690%** |
| 7 | RateShockShield (14d) | 4.8 | 0.0384 | 0.1841 | **16.83%** |

---

## 4. PHASE C — Multiplicador Lumina

### 4.1 ¿Por qué NO usar 1.863 P&C tradicional?

El multiplicador del actuario externo se compone de:
- Safety loading **35%** — para reservas + uncertainty
- Expense ratio **15%** — overhead operacional
- Profit margin **20%** — retorno al capital

**En Lumina NO aplican porque:**
- ❌ No hay overhead humano (claim adjustors, underwriting): los smart contracts ejecutan solos.
- ❌ No hay capital cost en sentido tradicional: BondVault está pre-fondeado, no necesita raise.
- ❌ No hay profit margin del protocolo: "profit" se manifiesta como deflación de LUMINA (beneficia holders, no entity).
- ❌ No hay reservas USDC: el 100% de las primas se destruye/distribuye via split AFD.

### 4.2 Costos REALES de Lumina

| Concepto | % Premium | Justificación |
|---|---:|---|
| Ops (smart contract gas, oracle Chainlink, keeper) | 2% | Cobertura via split AFD (2% bucket) |
| Maintenance (audits, dev, infra) | 5% | Cobertura via split AFD (5% bucket) |
| TWAPBurner slippage (max 5% del 85% burn = 4.25% de la prima) | 4.25% | Drag real del swap USDC→LUMINA via DEX |
| λ uncertainty (Dune 5y data, CI band ~10%) | +10% | Safety por error de estimación de frecuencia |
| Correlation risk (FlashBTC + FlashETH disparan juntos) | +5% | Buffer cohort concentration |
| Oracle risk (Chainlink staleness, manipulation) | +5% | Buffer manipulation/lag |

**Costos directos absorbidos por split AFD:** 2% + 5% = 7% del premium (ya descontados).
**Costos a sumar como buffer al pricing:** slippage + λ uncert + correlation + oracle = **24.25%**.

### 4.3 Discount Factor por maturity 2y

Bond ERC-1155 redimible a 730 días. Usuario VALORA el bond a **PV(S) = $1,000 × DF₂ᵧ = $890** (DeFi risk-free 6%, DF² = 0.89), no $1,000 nominal.

### 4.4 Multiplicador Lumina derivado

**Break-even del modelo** (para garantizar deflación neta del protocolo):

```
USD burned (mes 0) > USD redeemed (mes +24, descontado)
0.93 × Premium     > 0.89 × PoR × $1,000
Premium_min        > (0.89 / 0.93) × PoR × $1,000
Premium_min        = 0.957 × PoR × $1,000
```

**Con buffers de safety:**

```
Premium_Lumina = Premium_min × (1 + λ_uncert + correlation + slippage + oracle)
              = 0.957 × (1 + 0.10 + 0.05 + 0.0425 + 0.05)
              = 0.957 × 1.2425
              = 1.189 ≈ 1.20
```

**Multiplicador Lumina = 1.20** (vs P&C 1.863, ratio 1.55× más eficiente).

### 4.5 Sensitivity del multiplicador

| Multiplicador | Ratio USD burn/redeem | Margen safety | Veredicto |
|---:|---:|---|---|
| 0.96 (break-even puro) | 0.89 | 0% — inflacionario por slippage | ❌ no viable |
| 1.075 (mínimo seguro) | 1.000 | apenas break-even | ⚠️ riesgoso |
| **1.20 (recomendado)** | **1.116** | **~16%** | ✅ **óptimo** |
| 1.30 (conservador) | 1.209 | 25% | ✅ válido pero pierde mercado |
| 1.863 (P&C externo) | 1.732 | 78% — overkill | ⚠️ deja revenue en la mesa |

---

## 5. PHASE C bis — Prima Lumina sugerida por producto

**Prima Lumina = PoR × $1,000 × 1.20**

| # | Producto | PoR | Pure Premium | **Prima Lumina** | Prima Actuario Externo | **Diff %** |
|---|---|---:|---:|---:|---:|---:|
| 1 | FlashBTC-1h | 0.182% | $1.82 | **$2.19** | $3.02 | **−27.5%** |
| 2 | FlashBTC-24h | 3.288% | $32.88 | **$39.46** | $54.50 | **−27.6%** |
| 3 | FlashBTC-48h | 9.290% | $92.90 | **$111.48** | $154.00 | **−27.6%** |
| 4 | FlashETH-1h | 0.105% | $1.05 | **$1.26** | $1.74 | **−27.6%** |
| 5 | FlashETH-24h | 2.864% | $28.64 | **$34.37** | $47.49 | **−27.6%** |
| 6 | FlashETH-48h | 7.690% | $76.90 | **$92.28** | $127.50 | **−27.6%** |
| 7 | RateShockShield (14d) | 16.83% | $168.30 | **$201.96** | $278.74 | **−27.5%** |

**Reducción promedio: −27.6% vs actuario externo.** El protocolo puede ofrecer precios significativamente más bajos sin comprometer la deflación neta.

---

## 6. PHASE D — Revenue e impacto por producto

### 6.1 Volúmenes estimados (con fundamento)

| Producto | Vol/mes | Fundamento |
|---|---:|---|
| FlashBTC-1h | 300 | Low ticket impulse ($2.19), frecuencia evento 16/yr atrae intra-day traders |
| FlashBTC-24h | 800 | Sweet spot precio $40, cobertura útil holders + day traders |
| FlashBTC-48h | 600 | High ticket $111, swing traders + protección fines de semana |
| FlashETH-1h | 400 | Similar BTC-1h, comunidad ETH activa |
| FlashETH-24h | 700 | Similar BTC-24h |
| FlashETH-48h | 500 | Menor que BTC-48h porque trigger más estricto (14%) |
| RateShockShield (14d) | 150 | Niche Aave borrowers, prima alta $202, frecuencia evento 4.8/yr |
| **TOTAL** | **3,450** | |

### 6.2 Revenue mensual

| Producto | Vol | Prima Lumina | **Revenue/mes** |
|---|---:|---:|---:|
| FlashBTC-1h | 300 | $2.19 | $657 |
| FlashBTC-24h | 800 | $39.46 | $31,568 |
| FlashBTC-48h | 600 | $111.48 | **$66,888** |
| FlashETH-1h | 400 | $1.26 | $504 |
| FlashETH-24h | 700 | $34.37 | $24,059 |
| FlashETH-48h | 500 | $92.28 | $46,140 |
| RateShockShield (14d) | 150 | $201.96 | $30,294 |
| **TOTAL** | **3,450** | — | **$200,110** |

Anualizado: **$2.40M/año** (vs $3.32M/año con primas externas).

### 6.3 LUMINA quemado por producto (93% del premium destinado a destruir)

**LUMINA burned = Revenue × 0.93 / precio LUMINA**

| Producto | Revenue/mes | **@ $0.25** | **@ $0.50** | **@ $1.00** |
|---|---:|---:|---:|---:|
| FlashBTC-1h | $657 | 2,444 | 1,222 | 611 |
| FlashBTC-24h | $31,568 | 117,432 | 58,716 | 29,358 |
| FlashBTC-48h | $66,888 | 248,824 | 124,412 | 62,206 |
| FlashETH-1h | $504 | 1,876 | 938 | 469 |
| FlashETH-24h | $24,059 | 89,499 | 44,750 | 22,375 |
| FlashETH-48h | $46,140 | 171,640 | 85,820 | 42,910 |
| RateShockShield (14d) | $30,294 | 112,694 | 56,347 | 28,173 |
| **TOTAL** | $200,110 | **744,409** | **372,205** | **186,102** |

### 6.4 Bonds emitidos y LUMINA outflow vault (a t+730)

`E[bonds]/mes = Volumen × PoR` · `face = bonds × $1,000` · `LUMINA out = face / precio`

| Producto | E[bonds/mes] | E[face/mes] | **LUMINA out @ $0.50** |
|---|---:|---:|---:|
| FlashBTC-1h | 0.547 | $547 | 1,094 |
| FlashBTC-24h | 26.304 | $26,304 | 52,608 |
| FlashBTC-48h | 55.740 | $55,740 | 111,480 |
| FlashETH-1h | 0.420 | $420 | 840 |
| FlashETH-24h | 20.048 | $20,048 | 40,096 |
| FlashETH-48h | 38.450 | $38,450 | 76,900 |
| RateShockShield (14d) | 25.245 | $25,245 | 50,490 |
| **TOTAL** | **166.754** | **$166,754** | **333,508** |

### 6.5 Balance neto por producto @ $0.50 (deflación vs inflación)

| Producto | Quemado/mes | Outflow vault/mes | **Balance neto** | Deflacionario? |
|---|---:|---:|---:|:---:|
| FlashBTC-1h | 1,222 | 1,094 | **+128** | ⚠️ marginal |
| FlashBTC-24h | 58,716 | 52,608 | **+6,108** | ✅ |
| FlashBTC-48h | 124,412 | 111,480 | **+12,932** | ✅✅ |
| FlashETH-1h | 938 | 840 | **+98** | ⚠️ marginal |
| FlashETH-24h | 44,750 | 40,096 | **+4,654** | ✅ |
| FlashETH-48h | 85,820 | 76,900 | **+8,920** | ✅✅ |
| RateShockShield (14d) | 56,347 | 50,490 | **+5,857** | ✅ |
| **TOTAL** | 372,205 | 333,508 | **+38,697** | **✅ Neto deflacionario** |

**Sostenibilidad confirmada: +38,697 LUMINA destruidos netos por mes = +464,364/año = 0.46% supply destrucción anual sobre 100M.**

---

## 7. PHASE E — Rankings

### E.1 Ranking por Revenue mensual

| # | Producto | Revenue/mes | % del total |
|---|---|---:|---:|
| 1 | FlashBTC-48h | $66,888 | 33.4% |
| 2 | FlashETH-48h | $46,140 | 23.1% |
| 3 | FlashBTC-24h | $31,568 | 15.8% |
| 4 | RateShockShield (14d) | $30,294 | 15.1% |
| 5 | FlashETH-24h | $24,059 | 12.0% |
| 6 | FlashBTC-1h | $657 | 0.3% |
| 7 | FlashETH-1h | $504 | 0.3% |

Los productos 48h son el **56% del revenue total**.

### E.2 Ranking por quema neta LUMINA (deflacionario)

| # | Producto | Neto LUMINA/mes |
|---|---|---:|
| 1 | FlashBTC-48h | +12,932 |
| 2 | FlashETH-48h | +8,920 |
| 3 | FlashBTC-24h | +6,108 |
| 4 | RateShockShield (14d) | +5,857 |
| 5 | FlashETH-24h | +4,654 |
| 6 | FlashBTC-1h | +128 |
| 7 | FlashETH-1h | +98 |

### E.3 Ranking por riesgo (face emitido/mes)

| # | Producto | Face emitido/mes |
|---|---|---:|
| 1 | FlashBTC-48h | $55,740 |
| 2 | FlashETH-48h | $38,450 |
| 3 | FlashBTC-24h | $26,304 |
| 4 | RateShockShield (14d) | $25,245 |
| 5 | FlashETH-24h | $20,048 |
| 6 | FlashBTC-1h | $547 |
| 7 | FlashETH-1h | $420 |

### E.4 Viabilidad económica integral

**Criterios:** (a) Quema mensual > outflow vault, (b) Volumen razonable, (c) Prima/face < 25%.

| Producto | (a) Burn > Outflow? | (b) Vol razonable? | (c) Prima/face | Veredicto integral |
|---|:---:|:---:|---:|:---:|
| FlashBTC-1h | ✅ marginal | ✅ | 0.22% | ✅ marginal |
| FlashBTC-24h | ✅ | ✅ | 3.95% | ✅✅ |
| FlashBTC-48h | ✅ | ✅ | 11.15% | ✅✅✅ |
| FlashETH-1h | ✅ marginal | ✅ | 0.13% | ✅ marginal |
| FlashETH-24h | ✅ | ✅ | 3.44% | ✅✅ |
| FlashETH-48h | ✅ | ✅ | 9.23% | ✅✅✅ |
| RateShockShield (14d) | ✅ | ⚠️ niche | 20.20% | ✅✅ |

---

## 8. PHASE F — Recomendaciones por producto

| # | Producto | Veredicto | Razón |
|---|---|:---:|---|
| 1 | FlashBTC-1h | ⚠️ **Re-precio** | Revenue $657/mes — mantener como anchor de catálogo, no revenue driver. Prima ajustada $2.19 OK. |
| 2 | FlashBTC-24h | ✅ **Mantener** | Sweet spot. $31k/mes revenue, +6k/mes neto deflación. |
| 3 | FlashBTC-48h | ✅ **Mantener** | Producto estrella ($67k/mes, 33% del revenue total). Driver principal. |
| 4 | FlashETH-1h | ⚠️ **Re-precio** | Similar a FlashBTC-1h. Catálogo, no driver. |
| 5 | FlashETH-24h | ✅ **Mantener** | Sólido revenue $24k/mes. |
| 6 | FlashETH-48h | ✅ **Mantener** | Segundo revenue driver ($46k/mes). |
| 7 | RateShockShield (14d) | ✅ **Mantener (con re-spec 14d)** | El re-spec 30d→14d ya identificado en Sprint V1 sigue válido. Sin re-spec, PoR sube a 32.6% y prima a $390+ (PoR/face = 39%, no vendible). |

**Ningún producto se descontinúa.** Todos los 7 son viables bajo modelo Lumina con multiplicador 1.20.

---

## 9. Comparación maestra: Prima Lumina vs Prima Actuario Externo

| # | Producto | Prima Externo (1.863) | **Prima Lumina (1.20)** | Ahorro al usuario | Revenue Externo | Revenue Lumina | Burn Externo @ $0.50 | Burn Lumina @ $0.50 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | FlashBTC-1h | $3.02 | $2.19 | −$0.83 | $906 | $657 | 1,685 | 1,222 |
| 2 | FlashBTC-24h | $54.50 | $39.46 | −$15.04 | $43,600 | $31,568 | 81,096 | 58,716 |
| 3 | FlashBTC-48h | $154.00 | $111.48 | −$42.52 | $92,400 | $66,888 | 171,864 | 124,412 |
| 4 | FlashETH-1h | $1.74 | $1.26 | −$0.48 | $696 | $504 | 1,295 | 938 |
| 5 | FlashETH-24h | $47.49 | $34.37 | −$13.12 | $33,243 | $24,059 | 61,832 | 44,750 |
| 6 | FlashETH-48h | $127.50 | $92.28 | −$35.22 | $63,750 | $46,140 | 118,575 | 85,820 |
| 7 | RateShockShield (14d) | $278.74 | $201.96 | −$76.78 | $41,811 | $30,294 | 77,768 | 56,347 |
| **TOTAL** | — | — | — | — | **$276,406** | **$200,110** | **514,114** | **372,205** |

**Trade-off del re-pricing Lumina vs externo:**
- ✅ Precios al usuario **−27.6%** → más competitivo, atrae volumen (elasticidad demanda)
- ✅ Sigue siendo deflacionario neto (+38,697 LUMINA/mes vs +180,606 con externo)
- ⚠️ Revenue/mes baja 27.6% → menos burn absoluto
- ⚠️ Margen safety vs cisne negro pasa de 78% (externo) a 16% (Lumina) — menor cushion para escenarios extremos

**Recomendación final:** ofrecer **Prima Lumina 1.20 como pricing público**, con la opción de subir el multiplicador a 1.30 (margen safety 25%) si la demanda es elástica baja (volumen no responde al descuento). Decidir post-launch tracking elasticity.

---

## 10. Próximo paso recomendado

1. **Implementar M-1 throttle + auto-refill BondVault** (P0 de sprints V1/V2, no opcional).
2. **Configurar multiplicador 1.20 base en API pricing layer** (no en `PolicyManagerV2` hard-coded, dado que el contrato actual usa pricing dinámico vía AFD). El API debe servir primas según fórmula `prima = PoR × $1,000 × 1.20 × utilization_adjustment(U)`.
3. **A/B test pricing 1.20 vs 1.30** post-launch en mainnet beta para medir elasticidad.
4. **Tracking dashboard**: emisión bonds/mes, balance vault, ratio burn/redeem realizado vs proyectado.

---

## Apéndice — Tabla maestra para PR description

| # | Producto | PoR | Prima Lumina | Prima Externo | Diff % | Revenue/mes | Burn @ $0.50 | Outflow @ $0.50 | Neto | Veredicto |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|:---:|
| 1 | FlashBTC-1h | 0.182% | $2.19 | $3.02 | −27.5% | $657 | 1,222 | 1,094 | +128 | ⚠️ Re-precio |
| 2 | FlashBTC-24h | 3.288% | $39.46 | $54.50 | −27.6% | $31,568 | 58,716 | 52,608 | +6,108 | ✅ Mantener |
| 3 | FlashBTC-48h | 9.290% | $111.48 | $154.00 | −27.6% | $66,888 | 124,412 | 111,480 | +12,932 | ✅ Mantener |
| 4 | FlashETH-1h | 0.105% | $1.26 | $1.74 | −27.6% | $504 | 938 | 840 | +98 | ⚠️ Re-precio |
| 5 | FlashETH-24h | 2.864% | $34.37 | $47.49 | −27.6% | $24,059 | 44,750 | 40,096 | +4,654 | ✅ Mantener |
| 6 | FlashETH-48h | 7.690% | $92.28 | $127.50 | −27.6% | $46,140 | 85,820 | 76,900 | +8,920 | ✅ Mantener |
| 7 | RateShockShield (14d) | 16.83% | $201.96 | $278.74 | −27.5% | $30,294 | 56,347 | 50,490 | +5,857 | ✅ Mantener (14d) |
