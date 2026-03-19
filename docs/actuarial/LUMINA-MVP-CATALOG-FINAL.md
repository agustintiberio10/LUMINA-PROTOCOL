# Lumina Protocol — Catálogo Completo MVP
# Especificación Final del Producto

## Versión: 1.0 — MVP Launch
## Chain: Base L2 (8453) | Settlement: USDC | Vault Asset: USDY (Ondo Finance)
## Modelo: M2M (Machine-to-Machine) — operado exclusivamente por Agentes de IA

**CALIBRATION UPDATE (March 2026):** All pBase values recalibrated from V1 additive formula to market-aligned rates for V2 multiplicative Kink Model. Benchmarked against Nexus Mutual, InsurAce, Etherisc. New values: BSS 650 bps (6.5%, was 2200), DEPEG 250 bps (2.5%, was 2400), IL 850 bps (8.5%, was 2000), EXPLOIT 400 bps (4.0%, was 300). Premium tables in individual specs reflect original V1 calculations and should be recalculated with new pBase values.

---

## 1. Arquitectura General

### 1.1 Smart Contracts (Modular)

```
CoverRouter.sol (entrada única — verifica EIP-712, redirige a vault correcto)
  ↓
VolatileYieldVault.sol (ERC-4626) — ex "High Risk"
StableYieldVault.sol (ERC-4626) — ex "Low Risk"
  ↓
BlackSwanShield.sol (producto 1)
DepegShield.sol (producto 2)
ILIndexCover.sol (producto 3)
ExploitShield.sol (producto 4)
```

Cada producto es un contrato aislado. Se pueden agregar nuevos productos sin tocar contratos existentes. Patrón Diamond (ERC-2535) o Proxy (ERC-1967) para upgradability.

### 1.2 Pricing Engine (Off-chain)

```
Premium = Coverage × P_base × RiskMult × DurationDiscount × M(U) × (Duration_seconds / 31,536,000)

Kink Model:
  U_kink = 0.80
  R_slope1 = 0.5
  R_slope2 = 3.0

  Si U ≤ 0.80: M(U) = 1 + (U / 0.80 × 0.5)
  Si U > 0.80: M(U) = 1 + 0.5 + ((U - 0.80) / 0.20 × 3.0)
  Si U > 0.95: RECHAZAR — no emitir póliza

Quote firmado con EIP-712, deadline de 5 minutos.
```

### 1.3 Colateralización
Estricta 1:1. Cada $1 de coverage = $1 de USDY bloqueado en el vault. Si no hay liquidez, la transacción revierte. Lumina nunca asume deuda ni opera con reserva fraccionaria.

### 1.4 Activo Base: USDY (Ondo Finance)
Los vaults operan en USDY (token respaldado por bonos del Tesoro USA). Genera un yield base pasivo (~3.55% APY actual, variable según tasa de Treasuries). Los agentes hacen swap USDC → USDY externamente antes de interactuar con Lumina.

Toda la lógica interna opera en USD. La conversión a USDY solo ocurre al mover tokens (depósito, bloqueo, payout, retiro).

---

## 2. Los 2 Vaults MVP

### 2.1 Naming (ajustado post-review)

NO se llaman "High Risk" y "Low Risk" porque el vault "Low Risk" tiene un peor escenario (-18%) mayor que el "High Risk" (-16.8%). Los nombres reflejan el PERFIL de yield, no el riesgo absoluto:

| Vault | Nombre comercial | Perfil |
|---|---|---|
| Vault 1 | **Volatile Yield Vault** | Yield variable mes a mes. Claims frecuentes (IL) + riesgo catastrófico raro (BSS). El LP ve su capital fluctuar pero gana más en promedio. |
| Vault 2 | **Stable Yield Vault** | Yield predecible mes a mes. Claims muy raros. Parece una línea recta hasta que pasa un cisne negro (depeg o exploit). |
| Vault 3 | **Medium (Coming Soon)** | Se activa post-MVP cuando se agreguen productos de riesgo medio. |

### 2.2 Volatile Yield Vault (ex High Risk)

| Parámetro | Valor |
|---|---|
| Productos | Black Swan Shield (20% MaxAlloc) + IL Index Cover (20% MaxAlloc) |
| Max comprometido | 40% del vault |
| Reserva sin asignar | 60% |
| APY estimado (U=40%) | ~9.25% (5.7% primas + 3.55% USDY) |
| APY estimado (U=70%) | ~12.95% (9.4% primas + 3.55% USDY) |
| Peor mes | -16.8% (BSS + IL se activan juntos en crash de ETH) |
| Frecuencia de claims | Alta (IL mensual ~25-35%) + Baja (BSS ~1.5-2%/mes) |
| Recovery de peor caso | ~22 meses de primas |
| Lock periods LP | 31 días / 90 días / 365 días |
| Yield multiplier por lock | 31d = 1.0x / 90d = 1.15x / 365d = 1.35x |

### 2.3 Stable Yield Vault (ex Low Risk)

| Parámetro | Valor |
|---|---|
| Productos | Depeg Shield (20% MaxAlloc) + Exploit Shield (10% MaxAlloc) |
| Max comprometido | 30% del vault |
| Reserva sin asignar | 70% |
| APY estimado (U=40%) | ~9.05% (5.5% primas + 3.55% USDY) |
| APY estimado (U=70%) | ~12.45% (8.9% primas + 3.55% USDY) |
| Peor mes | -18% (Depeg se activa en crisis de stablecoin) |
| Frecuencia de claims | Muy baja (Depeg ~1-1.5%/mes, Exploit ~0.06-0.08%/mes) |
| Recovery de peor caso | ~25 meses de primas |
| Lock periods LP | 90 días / 180 días / 365 días (mínimo más largo — productos de larga duración) |
| Yield multiplier por lock | 90d = 1.0x / 180d = 1.15x / 365d = 1.35x |

### 2.4 Auto-regulación vía Kink Model
Si el 90% de los LPs van al Stable Yield Vault (porque es "más seguro"):
- Stable Yield: U baja → APY baja → menos atractivo
- Volatile Yield: U sube → APY sube → más atractivo
- El mercado se autobalancea sin intervención humana

---

## 3. Los 4 Productos MVP

---

### 3.1 PRODUCTO 1: The Black Swan Shield (BLACKSWAN-001)

**Vault:** Volatile Yield Vault (20% MaxAlloc)

| Parámetro | Valor |
|---|---|
| Naturaleza | Seguro catastrófico contra cisnes negros de BTC/ETH |
| Activos | BTC/USD, ETH/USD (Chainlink feeds) |
| Trigger | Precio cae >30% desde precio del bloque de emisión |
| Verificación | TWAP 15 min O 3 roundIds consecutivos de Chainlink |
| Anti-flash crash | Lectura instantánea única PROHIBIDA |
| Payout | Binario: 80% del coverage |
| Deducible | 20% |
| Duración | 7 a 30 días |
| P_base | 0.065 (6.5% anualizado) |
| Waiting period | Ninguno (trigger relativo a precio de compra) |
| Volatility circuit breaker | >5% move en 1h → P_base ×1.5. >10% → halt. Verificar 3+ exchanges. |
| Renovación | 24h antes de expiración → oferta al agente |

**Resolución:** agente llama triggerPayout() → contrato verifica TWAP on-chain → pago en misma TX.

**Probabilidades:**
- Prob. por 30 días (con TWAP): ~1.5-2%
- Prob. por 7 días: ~0.5-0.8%

**EV del LP (vault $1M, U=40%):**
```
Primas mensuales: ~$4,500
Expected claims: ~$2,800
Neto: +$1,700/mes
Margen: ~38%
```

**Spec completo:** BLACKSWAN-SHIELD-ACTUARIAL-SPEC.md

---

### 3.2 PRODUCTO 2: Stablecoin Depeg Shield (DEPEG-STABLE-001)

**Vault:** Stable Yield Vault (20% MaxAlloc)

| Parámetro | Valor |
|---|---|
| Naturaleza | Seguro contra pérdida de paridad de stablecoins |
| Stablecoins | USDC (1.0x), DAI (1.2x), USDT (1.4x) — risk multipliers dinámicos |
| Trigger | Precio < $0.95 (absoluto contra $1.00) |
| Verificación | TWAP 30 min O 5 roundIds consecutivos de Chainlink |
| Payout | Binario |
| Deducible | USDC 10%, DAI 12%, USDT 15% |
| Max Payout | USDC 90%, DAI 88%, USDT 85% |
| Duración | 14 a 365 días |
| Duration Discount | 1.0x (14-90d), 0.90x (91-180d), 0.80x (181-365d) |
| P_base | 0.025 (2.5% anualizado) |
| Waiting period | 24 horas |
| Circuit breaker | >1% debajo de $1 en 1h → prima ×2. >2% → halt. |
| Risk multipliers dinámicos | USDT oscila $0.990-$1.010 → mult sube de 1.4x a 1.8x |
| Renovación | 24h antes de expiración → oferta al agente |

**Lock periods LP:** 90d / 180d / 365d (mínimo 90d porque productos son de larga duración)

**Probabilidades:**
- USDC por 30 días: ~1.0-1.5%
- USDT por 30 días: ~1.5-2.5%
- DAI por 30 días: ~1.5-2.0%

**EV del LP (vault $1M, U=40%, mix USDC/USDT/DAI):**
```
Primas mensuales: ~$7,063
Expected claims: ~$2,703
Neto: +$4,360/mes
Margen: ~62%
```

**Spec completo:** DEPEG-SHIELD-ACTUARIAL-SPEC.md

---

### 3.3 PRODUCTO 3: Standard IL Index Cover (ILPROT-001)

**Vault:** Volatile Yield Vault (20% MaxAlloc)

| Parámetro | Valor |
|---|---|
| Naturaleza | Seguro paramétrico contra IL significativo (índice V2 estándar) |
| Activo | ETH/USD |
| Trigger | IL calculado > 2% |
| Deducible | Restable — payout solo sobre IL que excede 2% |
| Payout | Proporcional: Coverage × max(0, IL - 2%) × 0.90 |
| Cap | Coverage × 13% × 0.90 = 11.7% del coverage |
| Resolución | Solo al vencimiento (estilo opción europea). Ventana 48h post-expiración. |
| Duración | 14 a 90 días |
| P_base | 0.085 (8.5% anualizado) |
| Waiting period | Ninguno (trigger relativo a precio de compra) |
| Circuit breaker | >5% move en 1h → P_base ×1.5. >10% → halt. |
| Dirección | Ambas (IL ocurre si ETH sube O baja) |
| Renovación | 24h antes de expiración → oferta al agente |

**NOTA:** Producto vendido como "Standard IL Index Cover". Paga sobre fórmula V2 (50/50). NO cubre IL real de concentrated liquidity (V3). El comprador entiende que es un índice.

**Fórmula de IL:**
```
priceRatio = priceAtExpiry / priceAtPurchase
IL = 2 × sqrt(priceRatio) / (1 + priceRatio) - 1
IL_neto = max(0, IL - 0.02)
payout = min(coverage × IL_neto × 0.90, coverage × 0.13 × 0.90)
```

**Estrategia óptima del comprador:** Under-insurance táctico. Regla del 50%: prima ≤ 50% de fees proyectados del pool. Sweet spot: ~73% de la posición.

**Probabilidades:**
- 14 días: ~17.5% de activación
- 30 días: ~30%
- 60 días: ~45%
- 90 días: ~62.5%

**EV del LP (vault $1M, U=40%):**
```
Primas mensuales: ~$4,108
Expected claims: ~$1,080 (con deducible restable)
Neto: +$3,028/mes
Margen: ~74%
```

**Spec completo:** ILPROT-ACTUARIAL-SPEC.md

---

### 3.4 PRODUCTO 4: Protocol Exploit Shield (EXPLOIT-001)

**Vault:** Stable Yield Vault (10% MaxAlloc — TOTAL combinado para todas las pólizas Exploit)

| Parámetro | Valor |
|---|---|
| Naturaleza | Seguro contra exploits/hacks de protocolos DeFi |
| Protocolos | Aave v3, Compound III, MakerDAO, Uniswap v3, Curve, Morpho |
| Trigger | DUAL: (1) Token governance -25% en 24h AND (2) Receipt token depeg >30% sostenido 4h O contrato pausado |
| Verificación Cond. 1 | TWAP 15 min Chainlink |
| Verificación Cond. 2 | Lectura on-chain del exchange rate del receipt token. Try/catch: si revierte → Condición 2 cumplida. |
| Persistencia anti-flash loan | 4 horas obligatorias para Condición 2 |
| Payout | Binario: 90% del coverage |
| Deducible | 10% |
| Duración | 90 a 365 días (mínimo 90 — waiting de 14d hace pólizas cortas ineficientes) |
| Duration Discount | 1.0x (90d), 0.90x (91-180d), 0.80x (181-365d) |
| P_base Tier 1 | 0.04 (4.0%) — Aave, Compound, Uniswap, MakerDAO |
| P_base Tier 2 | 0.045 (4.5%) Curve / 0.054 (5.4%) Morpho |
| Max Coverage por wallet | $50,000 |
| Waiting period | 14 días |
| Circuit breaker | Token gov -10% → prima ×3. -20% → halt. Receipt token -5% → halt inmediato. |
| Renovación | 24h antes. Gap de 14 días sin cobertura entre pólizas. |
| Tiempo de resolución | ~4-6 horas (vs hasta 35 días Nexus Mutual) |

**Falsos negativos aceptados:** Si ballenas sostienen el token para que no caiga >25%, Lumina no paga. Trade-off por estabilidad del vault.

**Flywheel de escasez:** MaxAlloc 10% = pocas pólizas disponibles → U sube → primas suben → atrae más LPs → TVL crece → capacidad se expande automáticamente.

**Probabilidades:**
- Tier 1 anual: 0.8-1.5%
- Tier 2 anual: 2.0-5.0%

**EV del LP (vault $1M, 2 pólizas Aave $50K, 365 días, U=40%):**
```
Primas anuales: $3,000
Expected claims: $1,035
Neto: +$1,965/año
Margen: ~65%
```

**Spec completo:** EXPLOIT-SHIELD-ACTUARIAL-SPEC-v3.md

---

## 4. Stress Test: El Peor Día del Protocolo

### Escenario: Crisis sistémica (FTX + SVB simultáneo)
```
BTC cae 35% → BSS se activa en Volatile Yield Vault
ETH cae 40% → IL paga alto en Volatile Yield Vault
USDC depegga a $0.87 → Depeg se activa en Stable Yield Vault
Aave no se hackea (pero el mercado entra en pánico)

VOLATILE YIELD VAULT ($1M):
  BSS claims: -$160,000 (16% del vault)
  IL claims: -$8,000 (proporcional, no binario)
  Total: -$168,000 (16.8%)
  Vault queda: $832,000

STABLE YIELD VAULT ($1M):
  Depeg claims: -$180,000 (18% del vault)
  Exploit claims: $0 (no hubo hack)
  Total: -$180,000 (18%)
  Vault queda: $820,000

PROTOCOLO TOTAL ($2M):
  Pérdida: $348,000 (17.4%)
  TVL restante: $1,652,000
  Recovery: ~6-8 meses con primas combinadas de ambos vaults
  Ambos vaults sobreviven.
```

### Escenario: Crisis + Exploit simultáneo (peor caso extremo)
```
Todo lo anterior + Aave es hackeado al mismo tiempo

VOLATILE YIELD VAULT: -$168,000 (sin cambio)
STABLE YIELD VAULT: -$180,000 (Depeg) + -$90,000 (Exploit) = -$270,000 (27%)
Vault queda: $730,000

PROTOCOLO TOTAL: pérdida $438,000 (21.9%)
Recovery: ~10-12 meses
Vault sobrevive pero severamente golpeado.
Probabilidad de este escenario: <0.1% anual (crisis + hack simultáneo)
```

---

## 5. Grupo de Correlación

| Grupo | Productos afectados | Vault afectado | Prob. conjunta |
|---|---|---|---|
| ETH/BTC crash | BSS + IL | Volatile Yield | ~1.5%/mes |
| Stablecoin crisis | Depeg | Stable Yield | ~1-2%/mes |
| Smart contract exploit | Exploit | Stable Yield | ~0.08%/mes |
| Crisis sistémica total | BSS + IL + Depeg | Ambos vaults | ~0.3%/año |
| ETH sube fuerte (bull) | IL (solo) | Volatile Yield | ~5%/mes |
| Mercado lateral | Ninguno | Ninguno | ~40% del tiempo |

La separación en 2 vaults garantiza que ningún evento activa claims en ambos vaults simultáneamente EXCEPTO una crisis sistémica total (~0.3%/año).

---

## 6. LP: Lock Periods y Yield Multipliers

### Volatile Yield Vault

| Lock | Yield Multiplier | Cobro |
|---|---|---|
| 31 días | 1.0x (base) | Principal + yield al final |
| 90 días | 1.15x | Principal + yield al final |
| 365 días | 1.35x | Principal + yield al final |

### Stable Yield Vault

| Lock | Yield Multiplier | Cobro |
|---|---|---|
| 90 días | 1.0x (base) | Principal + yield al final |
| 180 días | 1.15x | Principal + yield al final |
| 365 días | 1.35x | Principal + yield al final |

Lock duro. No hay retiro anticipado. No hay withdrawal queue para MVP. Si el LP deposita por 365 días, su capital está bloqueado 365 días sin excepción.

### Distribución del yield

```
Capital ponderado del LP = Capital depositado × Yield Multiplier
Participación = Capital ponderado / Suma de todos los capitales ponderados
Yield del LP = Primas totales × Participación
```

El yield se refleja en el precio del share del vault (ERC-4626). Todo se cobra al final del lock period.

---

## 7. Liquidez: Locked vs Free

```
C_total: USDY total depositado por LPs (en USD)
C_allocated: USDY bloqueado garantizando pólizas activas (en USD)
C_free: C_total - C_allocated (disponible para nuevas pólizas)

Cuando se vende póliza:
  C_allocated += coverage_amount
  USDY bloqueado por duración de la póliza

Cuando póliza expira sin claim:
  C_allocated -= coverage_amount
  USDY desbloqueado, vuelve a C_free

Cuando hay claim:
  Payout se transfiere de USDY bloqueado → wallet del agente asegurado
  C_allocated -= coverage_amount

LP retira:
  Solo puede retirar de C_free (nunca de C_allocated)
  Si no hay C_free suficiente y su lock expiró: debe esperar a que pólizas venzan
```

---

## 8. Renovación de Pólizas (flujo universal)

```
24h antes de expiración:
  → Sistema calcula nueva prima con condiciones actuales del vault
  → Lee U actual, aplica Kink Model, genera renewal quote
  → Envía al agente del comprador

Agente decide según reglas preconfiguradas por el humano:
  → Si nueva prima dentro de maxPremiumIncrease → ACEPTA
  → Si excede → intenta fallback (menor duración, menor coverage)
  → Si sigue excediendo → RECHAZA

Resultado:
  → Aceptó → nueva póliza emitida
  → Rechazó → sin cobertura → notifica al humano
```

Cada producto tiene su propio waiting period en renovación. Para Exploit Shield, hay gap de 14 días sin cobertura entre pólizas.

---

## 9. Anti-Selección Adversa (resumen por producto)

| Producto | Waiting Period | Circuit Breaker | Defensa natural |
|---|---|---|---|
| BSS | Ninguno | >5% move 1h → ×1.5, >10% → halt | Trigger relativo a precio de compra |
| Depeg | 24 horas | >1% off-peg → ×2, >2% → halt | TWAP 30 min |
| IL Index | Ninguno | >5% move 1h → ×1.5, >10% → halt | Resolución solo al vencimiento + trigger relativo |
| Exploit | 14 días | Token -10% → ×3, -20% → halt, receipt -5% → halt | Persistencia 4h + max $50K/wallet |

---

## 10. Contratos a Desarrollar

| Contrato | Función | Prioridad |
|---|---|---|
| CoverRouter.sol | Entrada única. Verificación EIP-712 de quotes. Redirige a vault correcto. | Crítico |
| VolatileYieldVault.sol (ERC-4626) | Vault 1. Depósitos LP, shares, bloqueo de fondos, lock periods. | Crítico |
| StableYieldVault.sol (ERC-4626) | Vault 2. Igual estructura, distintos productos. | Crítico |
| PolicyManager.sol | Asigna liquidez de vaults a pólizas. MaxAllocation. Contabilidad. | Crítico |
| BlackSwanShield.sol | Verificación TWAP BTC/ETH. Payout binario 80%. | Crítico |
| DepegShield.sol | Verificación TWAP stablecoins. Payout binario 85-90%. | Crítico |
| ILIndexCover.sol | Cálculo IL on-chain. Payout proporcional restable. Resolución al vencimiento. | Crítico |
| ExploitShield.sol | Trigger dual. Try/catch para contratos pausados. Persistencia 4h. | Crítico |
| PricingOracle.sol | Lee Chainlink feeds. Calcula TWAP. Verifica firmas EIP-712. | Crítico |

### Backend (off-chain)

| Componente | Función |
|---|---|
| Pricing API (Node.js) | /quote, /purchase, /renew. Kink Model. EIP-712 signer. |
| Volatility Monitor | Lee Chainlink cada hora. Calcula vol. Activa circuit breakers. |
| Renewal Engine | 24h antes de expiración, genera quotes y los envía a agentes. |
| Exploit Persistence Monitor | Lee exchange rates de receipt tokens cada hora. Certifica persistencia 4h. |
| USDY Price Monitor | Lee precio USDY/USD. Conversiones USD ↔ USDY. Sanity checks. |

---

## 11. Orden de Implementación

```
FASE 1 — Smart Contracts (sin esto nada funciona)
  1. Vaults ERC-4626 × 2 (con lock periods y yield multipliers)
  2. PolicyManager (asignación + MaxAllocation + contabilidad)
  3. CoverRouter (EIP-712 verification)
  4. BlackSwanShield (TWAP + payout)
  5. DepegShield (TWAP + payout + deducibles diferenciados)
  6. ILIndexCover (cálculo IL + deducible restable + resolución al vencimiento)
  7. ExploitShield (trigger dual + try/catch + persistencia)
  8. Deploy en Base testnet → test → audit → mainnet

FASE 2 — Backend
  9. Pricing engine con Kink Model leyendo vaults on-chain
  10. Volatility circuit breakers
  11. Renewal engine
  12. Exploit persistence monitor
  13. USDY price monitor
  14. API endpoints: /vaults, /quote, /purchase, /renew, /policy

FASE 3 — Frontend y Docs
  15. Landing page actualizada (BLACKSWAN + Depeg + IL + Exploit)
  16. Pricing info section (no calculadora — precios dinámicos)
  17. GitHub docs actualizados
  18. SDK para agentes (TypeScript/Python)
  19. Dashboard para humanos (post-MVP)
```

---

## 12. Specs Individuales (archivos de referencia)

| Producto | Archivo |
|---|---|
| Black Swan Shield | BLACKSWAN-SHIELD-ACTUARIAL-SPEC.md |
| Stablecoin Depeg Shield | DEPEG-SHIELD-ACTUARIAL-SPEC.md |
| Standard IL Index Cover | ILPROT-ACTUARIAL-SPEC.md (v2.0) |
| Protocol Exploit Shield | EXPLOIT-SHIELD-ACTUARIAL-SPEC-v3.md |
| Catálogo completo | Este documento |
| Pricing Engine | Documento_sin_título.docx (Kink Model spec) |
| USDY Integration | Pendiente de spec formal |
