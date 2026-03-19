# Stablecoin Depeg Shield — Especificación Técnica y Actuarial Completa

## Protocolo: Lumina Protocol
## Producto: DEPEG-STABLE-001 (reemplaza DEPEG-USDC-001, DEPEG-USDT-001, DEPEG-DAI-001)
## Versión: 1.0
## Chain: Base L2 (8453) | Settlement: USDC
## Modelo: M2M (Machine-to-Machine) — operado exclusivamente por Agentes de IA

**CALIBRATION UPDATE (March 2026):** pBase recalibrated from V1 additive formula values to market-aligned rates for V2 multiplicative Kink Model. Benchmarked against Nexus Mutual, InsurAce, Etherisc. New pBase: 250 bps (2.5%). Original V1 value: 2400 bps.

---

## 1. Definición del Producto

### 1.1 Naturaleza
Seguro paramétrico contra la pérdida de paridad (depeg) de stablecoins respecto al dólar estadounidense. Producto unificado que cubre USDC, USDT o DAI — el comprador elige cuál al momento de la compra. Cada stablecoin tiene su propio perfil de riesgo reflejado en risk multipliers y deducibles diferenciados.

### 1.2 Activos Cubiertos

| Stablecoin | Chainlink Feed (Base L2) |
|---|---|
| USDC | 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B |
| USDT | 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9 |
| DAI | 0x591e79239a7d679378eC8c847e5038150364C78F |

### 1.3 Diferencia vs Black Swan Shield
El BSS mide caída desde el precio de entrada (variable, relativo). El Depeg Shield mide contra un precio fijo absoluto: $1.00. Si la stablecoin cotiza por debajo de $0.95, es un depeg.

---

## 2. Parámetros del Producto

| Parámetro | Valor |
|---|---|
| Threshold | $0.95 fijo (depeg del 5% contra $1.00) |
| Referencia de precio | Absoluto contra $1.00 — NO relativo al precio de entrada |
| Duración | 14 a 365 días (continuo, elige el comprador) |
| Duration Discount | 1.0x (14-90d), 0.90x (91-180d), 0.80x (181-365d) |
| Waiting Period | 24 horas desde la compra hasta la activación de la cobertura |
| Verificación del trigger | TWAP 30 min O 5 roundIds consecutivos de Chainlink < $0.95 |
| Colateralización | 1:1 estricta — cada $1 de coverage = $1 USDC bloqueado |
| MaxAllocationPerProduct | 25% del Mega Pool |
| Pricing Model | Kink Model (AMM de Riesgo) |
| Coverage mínimo | $100 USDC |
| Coverage máximo | Limitado por liquidez disponible del vault |

### 2.1 Deducible por Stablecoin

| Stablecoin | Deducible | Max Payout | Justificación |
|---|---|---|---|
| USDC | 10% | 90% del coverage | Reservas transparentes, auditadas por Deloitte. Menor riesgo. |
| DAI | 12% | 88% del coverage | Colateralizado por crypto-assets vía MakerDAO. Riesgo de liquidación en cascada. |
| USDT | 15% | 85% del coverage | Reservas históricamente opacas. Mayor riesgo percibido y realizado. |

### 2.2 Sobre el Threshold ($0.95)
El threshold es absoluto: si la stablecoin cotiza por debajo de $0.95 según TWAP de 30 minutos, se activa el payout. No importa si antes estaba en $0.999 o $0.975. El trigger es binario contra $0.95.

Un depeg del 5% filtra todo el ruido operativo (fluctuaciones de $0.998-$1.002), depegs menores por illiquidez temporal, y solo se activa en eventos reales que causan daño material a los holders.

### 2.3 Sobre el Waiting Period (24 horas)
Desde que el comprador adquiere la póliza hasta que la cobertura se activa, hay un período de espera de 24 horas. Durante estas 24 horas, la póliza está emitida pero NO cubre ningún evento.

Justificación: los depegs de stablecoins se desarrollan lento (noticias → rumores → pánico → depeg). Un agente podría monitorear redes sociales y detectar problemas en Circle/Tether/MakerDAO horas antes de que el precio se mueva. El waiting period de 24h elimina esta ventana de selección adversa.

```
Hora 0: Agente compra póliza → estado: WAITING
Hora 24: Waiting period termina → estado: ACTIVE (cobertura empieza)
Hora 24+: Si stablecoin < $0.95 TWAP → trigger se activa → payout
```

### 2.4 Sobre las Duraciones Largas
A diferencia del BSS (7-30 días), el Depeg Shield permite pólizas de hasta 365 días. Las stablecoins se mantienen a largo plazo y los depegs son raros pero impredecibles. Duraciones largas reducen fricción de renovación.

Para compensar el riesgo acumulado de duraciones largas, se aplica un Duration Discount que beneficia al comprador (menos costo mensual equivalente) mientras mantiene el EV del LP positivo:

| Rango de duración | Duration Discount | Efecto |
|---|---|---|
| 14 - 90 días | 1.0x (sin descuento) | Precio estándar |
| 91 - 180 días | 0.90x | 10% descuento sobre P_base |
| 181 - 365 días | 0.80x | 20% descuento sobre P_base |

---

## 3. Mecanismo de Trigger

### 3.1 Verificación del Depeg
Una lectura instantánea única está PROHIBIDA. La stablecoin debe confirmarse por debajo de $0.95 de forma sostenida:

**Método A — TWAP 30 minutos:**
El precio promedio ponderado por tiempo durante los últimos 30 minutos debe estar por debajo de $0.95.

**Método B — 5 roundIds consecutivos de Chainlink:**
Un mínimo de 5 actualizaciones consecutivas de roundId en el feed de Chainlink deben devolver un precio inferior a $0.95.

### 3.2 ¿Por qué TWAP de 30 minutos (no 15 como BSS)?
Las stablecoins tienen momentos de illiquidez en exchanges individuales donde el precio puede caer a $0.96-$0.94 por minutos y recuperarse. Los pares de stablecoins tienen menos liquidez que BTC/ETH y son más propensos a wicks de corta duración. Un TWAP de 30 minutos filtra este ruido sin retrasar payouts legítimos (los depegs reales duran horas o días, no minutos).

### 3.3 ¿Por qué 5 roundIds (no 3 como BSS)?
Chainlink actualiza feeds de stablecoins con menor frecuencia que BTC/ETH (cada ~1 hora o cada 0.25% de desvío). 5 roundIds consecutivos representan ~5 horas de lecturas consistentes por debajo del threshold, confirmando que el depeg es real y persistente.

### 3.4 Verificación Multi-Exchange
Chainlink agrega datos de 3+ exchanges. El backend debe verificar que:
- El feed no esté stale (última actualización < 120 segundos para stablecoins)
- El heartbeat del feed esté activo
- Si un solo exchange muestra el depeg pero los demás no, Chainlink no lo reporta → trigger no se activa

---

## 4. Anti-Selección Adversa

### 4.1 Waiting Period (24 horas)
Descrito en sección 2.3. Primera línea de defensa contra agentes que compran al detectar rumores.

### 4.2 Stablecoin-Specific Circuit Breaker
A diferencia del BSS (que usa volatilidad de BTC/ETH), para stablecoins el indicador es la desviación del peg:

```
Si la stablecoin cotiza >1% debajo de $1.00 en la última hora:
  → P_base se multiplica ×2.0 temporalmente (prima se duplica)

Si la stablecoin cotiza >2% debajo de $1.00 en la última hora:
  → Se PAUSA la emisión de nuevas pólizas para esa stablecoin específica
  → Pólizas existentes siguen activas normalmente
  → Se reanuda cuando el precio vuelve a >$0.98 por 1 hora

Verificación vía Chainlink (agrega 3+ exchanges). Feed must not be stale.
```

### 4.3 Risk Multipliers Dinámicos
Los risk multipliers no son fijos. Se ajustan según la estabilidad reciente del peg:

**USDT (base 1.4x):**
| Comportamiento reciente (30 días) | Risk Multiplier |
|---|---|
| Estable ($0.999-$1.001) | 1.4x |
| Oscilación menor ($0.995-$1.005) | 1.6x |
| Oscilación mayor ($0.990-$1.010) | 1.8x |
| Debajo de $0.99 | Circuit breaker activo (×2.0 o halt) |

**DAI (base 1.2x):**
| Comportamiento reciente (30 días) | Risk Multiplier |
|---|---|
| Estable ($0.999-$1.001) | 1.2x |
| Oscilación menor ($0.995-$1.005) | 1.35x |
| Oscilación mayor ($0.990-$1.010) | 1.5x |
| Debajo de $0.99 | Circuit breaker activo |

**USDC (base 1.0x):**
| Comportamiento reciente (30 días) | Risk Multiplier |
|---|---|
| Estable ($0.999-$1.001) | 1.0x |
| Oscilación menor ($0.995-$1.005) | 1.1x |
| Oscilación mayor ($0.990-$1.010) | 1.25x |
| Debajo de $0.99 | Circuit breaker activo |

El backend calcula la desviación estándar del precio en los últimos 30 días y ajusta el multiplier automáticamente. Sin gobernanza humana.

---

## 5. Motor de Pricing

### 5.1 Fórmula Principal

```
Premium = Coverage × P_base × RiskMult × DurationDiscount × M(U) × (Duration_seconds / 31,536,000)
```

Donde:
- Coverage: monto asegurado en USDC
- P_base: 0.025 (2.5% anualizado)
- RiskMult: 1.0 (USDC) | 1.2 (DAI) | 1.4 (USDT) — ajustable dinámicamente
- DurationDiscount: 1.0 (14-90d) | 0.90 (91-180d) | 0.80 (181-365d)
- M(U): multiplicador Kink Model basado en utilización del vault
- Duration_seconds: duración de la póliza en segundos
- 31,536,000: segundos en un año

### 5.2 Kink Model (idéntico al BSS)

```
U = (C_allocated + C_requested) / C_total

Si U ≤ 0.80: M(U) = 1 + (U / 0.80 × 0.5)
Si U > 0.80: M(U) = 1 + 0.5 + ((U - 0.80) / 0.20 × 3.0)
Si U > 0.95: RECHAZAR — no emitir póliza
```

### 5.3 Tablas de Primas

**USDC (P_base=0.025, RiskMult=1.0, Deducible=10%, MaxPayout=90%)**

Coverage $100,000:

| Duración | U=20% (M=1.13) | U=40% (M=1.25) | U=60% (M=1.38) | U=80% (M=1.50) | U=90% (M=2.25) |
|---|---|---|---|---|---|
| 14 días | $520 (0.52%) | $575 (0.58%) | $635 (0.64%) | $691 (0.69%) | $1,036 (1.04%) |
| 30 días | $1,115 (1.12%) | $1,233 (1.23%) | $1,361 (1.36%) | $1,481 (1.48%) | $2,219 (2.22%) |
| 90 días | $3,344 (3.34%) | $3,699 (3.70%) | $4,084 (4.08%) | $4,441 (4.44%) | $6,658 (6.66%) |
| 180 días (×0.90) | $6,019 (6.02%) | $6,658 (6.66%) | $7,351 (7.35%) | $7,994 (7.99%) | $11,984 (11.98%) |
| 365 días (×0.80) | $10,889 (10.89%) | $12,044 (12.04%) | $13,298 (13.30%) | $14,464 (14.46%) | $21,678 (21.68%) |

**DAI (P_base=0.025, RiskMult=1.2, Deducible=12%, MaxPayout=88%)**

Coverage $100,000, selección de duraciones:

| Duración | U=40% | % coverage |
|---|---|---|
| 14 días | $690 | 0.69% |
| 30 días | $1,479 | 1.48% |
| 90 días | $4,438 | 4.44% |
| 180 días (×0.90) | $7,989 | 7.99% |
| 365 días (×0.80) | $14,453 | 14.45% |

**USDT (P_base=0.025, RiskMult=1.4, Deducible=15%, MaxPayout=85%)**

Coverage $100,000, selección de duraciones:

| Duración | U=40% | % coverage |
|---|---|---|
| 14 días | $805 | 0.81% |
| 30 días | $1,726 | 1.73% |
| 90 días | $5,178 | 5.18% |
| 180 días (×0.90) | $9,321 | 9.32% |
| 365 días (×0.80) | $16,862 | 16.86% |

### 5.4 Rangos Operativos

**Comprador (prima como % del coverage, condiciones normales U=20-60%):**
| Stablecoin | 14 días | 30 días | 90 días | 180 días | 365 días |
|---|---|---|---|---|---|
| USDC | 0.52-0.64% | 1.12-1.36% | 3.34-4.08% | 6.02-7.35% | 10.89-13.30% |
| DAI | 0.62-0.77% | 1.34-1.63% | 4.01-4.90% | 7.22-8.82% | 13.07-15.96% |
| USDT | 0.73-0.90% | 1.56-1.90% | 4.68-5.71% | 8.42-10.28% | 15.24-18.61% |

---

## 6. LP: Lock Periods y Yield

### 6.1 Estructura de Lock

| Lock Period | Yield Multiplier | Forma de Cobro |
|---|---|---|
| 90 días | 1.0x (base) | Principal + yield al final de los 90 días |
| 180 días | 1.15x | Principal + yield al final de los 180 días |
| 365 días | 1.35x | Principal + yield al final de los 365 días |

No hay pago mensual de intereses. Todo se cobra al final del período de lock. El yield se refleja en el precio del share del vault ERC-4626.

### 6.2 Distribución de Yield

Las primas de los compradores se acumulan en el vault y se reflejan en el precio del share. Cada LP recibe proporcionalmente a su capital × yield multiplier:

```
Capital ponderado del LP = Capital depositado × Yield Multiplier
Participación = Capital ponderado / Suma de todos los capitales ponderados
Yield del LP = Primas totales × Participación
```

### 6.3 Yield Estimado por Lock (Vault $1M, U=40%, solo producto Depeg)

| Lock | APY estimado |
|---|---|
| 90 días | 4.2% |
| 180 días | 4.8% |
| 365 días | 5.7% |

NOTA: Estos yields son SOLO del producto Depeg Shield. El vault tiene otros productos (BSS, IL Protection, etc.) generando primas adicionales. El yield total del vault es la suma de todos los productos activos, pudiendo alcanzar 15-25% APY combinado.

### 6.4 Restricción de Retiro
Los LPs no pueden retirar antes de que termine su lock period. El USDC en estado C_allocated (bloqueado respaldando pólizas) no es retirable bajo ninguna circunstancia hasta que las pólizas que respalda expiren o se resuelvan.

---

## 7. Análisis Actuarial

### 7.1 Datos Históricos de Depegs

**USDC:**
- Marzo 2023 (SVB): cayó a $0.87. Circle tenía $3.3B en Silicon Valley Bank. Recovery en ~3 días cuando la Fed garantizó depósitos. TWAP 30 min hubiera capturado el evento correctamente (el depeg duró ~72 horas).
- Eventos menores (<$0.99): varias veces por año, recovery en horas. NO cruzan $0.95.
- Depegs severos (<$0.95): 1 en ~5 años.
- Market cap: ~$30B+. Reservas auditadas mensualmente por Deloitte. Regulado como money transmitter.

**USDT:**
- Mayo 2022: cayó a $0.95 durante colapso LUNA/UST. Recovery en ~48h.
- Junio 2023: cayó a $0.985 por FUD sobre reservas. NO cruzó $0.95.
- Nunca cayó por debajo de $0.93 en su historia.
- Market cap: ~$80B+. Reservas históricamente cuestionadas. Auditorías parciales.

**DAI:**
- Marzo 2020 (Black Thursday): cayó a $0.88 cuando ETH se desplomó y liquidó el colateral de MakerDAO. Recovery en ~1 semana.
- DAI es algorítmico/colateralizado. Su peg depende de la salud del sistema MakerDAO y su colateral.
- Market cap: ~$5B.

### 7.2 Probabilidad de Activación (con TWAP 30 min)

| Stablecoin | Prob. por 30 días | Prob. por 90 días | Prob. por 365 días |
|---|---|---|---|
| USDC | ~1.0-1.5% | ~3-4.5% | ~10-15% |
| DAI | ~1.5-2.0% | ~4.5-6% | ~15-20% |
| USDT | ~1.5-2.5% | ~4.5-7.5% | ~15-25% |

El TWAP de 30 minutos filtra depegs breves que se recuperan en <30 minutos, reduciendo la probabilidad efectiva vs lecturas instantáneas.

### 7.3 Expected Value para el LP

**Escenario: Vault $1M, 25% en Depeg ($250K), mix 60% USDC / 25% USDT / 15% DAI, pólizas de 30 días, U=40%**

```
Primas mensuales:
  USDC ($150K en pólizas): $150K × 0.24 × 1.0 × 1.25 × (1/12) = $3,750
  USDT ($62.5K): $62.5K × 0.24 × 1.4 × 1.25 × (1/12) = $2,188
  DAI ($37.5K): $37.5K × 0.24 × 1.2 × 1.25 × (1/12) = $1,125
  Total primas mensuales: $7,063
  Total primas anuales: $84,756
```

```
Claim scenario — USDC depeg (todas las pólizas USDC se activan):
  Payout: $150K × 90% = $135,000
  Prob anual: ~12%
  Expected: 0.12 × $135K = $16,200

Claim scenario — USDT depeg:
  Payout: $62.5K × 85% = $53,125
  Prob anual: ~20%
  Expected: 0.20 × $53.1K = $10,625

Claim scenario — DAI depeg:
  Payout: $37.5K × 88% = $33,000
  Prob anual: ~17%
  Expected: 0.17 × $33K = $5,610

Total expected annual claims: $32,435
```

```
EV anual = $84,756 - $32,435 = +$52,321
Margen sobre expected claims: ~62%
```

### 7.4 Stress Test

**Peor caso: Crisis sistémica donde USDC Y USDT depeggan simultáneamente (tipo SVB + Tether FUD)**

```
Payout USDC: $135,000
Payout USDT: $53,125
Payout DAI: probablemente también si es crisis sistémica → $33,000
Total: $221,125

Pérdida como % del vault: 22.1%
Si BSS también se activa (BTC -30%): +16% del vault
Total combinado: 38.1% del vault

Probabilidad de este escenario: ~2-3% por año (muy raro)
Meses para recuperar: $221K / $7,063 = ~31 meses de primas de Depeg
(+ primas de otros productos aceleran la recuperación)
```

### 7.5 Correlación con Black Swan Shield

| Evento | BSS se activa? | Depeg se activa? | Correlación |
|---|---|---|---|
| BTC crash -35% (aislado) | Sí | Posiblemente (pánico menor) | Parcial |
| Crisis bancaria (tipo SVB) | No necesariamente | Sí (USDC) | Baja con BSS |
| Hack/exploit de Circle | No | Sí (USDC) | Nula con BSS |
| Hack/exploit de Tether | No | Sí (USDT) | Nula con BSS |
| MakerDAO exploit | No | Sí (DAI) | Nula con BSS |
| Crash general + crisis bancaria | Sí | Sí | ALTA — peor caso |

Pérdida máxima combinada BSS + Depeg en mismo evento: ~38% del vault. Severo pero no terminal.

---

## 8. Resolución y Payout

### 8.1 Flujo

```
1. Evento: stablecoin empieza a depeggar
2. TWAP 30 min confirma precio < $0.95 (o 5 roundIds consecutivos)
3. Un agente de IA llama: triggerPayout(uint256 policyId)
4. El smart contract verifica ON-CHAIN:
   a. La póliza está en estado ACTIVE (pasó el waiting period de 24h)
   b. La póliza no expiró
   c. El TWAP de 30 minutos < $0.95 para la stablecoin de la póliza
   d. O 5 roundIds consecutivos < $0.95
5. Si pasa: transfer USDC (Coverage × MaxPayout%) → wallet del agente asegurado
6. Si falla: transacción revierte
```

### 8.2 Datos de la Póliza (struct Policy)

```solidity
struct Policy {
    uint256 policyId;
    address insuredAgent;
    address stablecoinFeed;       // Chainlink feed de la stablecoin cubierta
    uint8 stablecoinType;         // 0=USDC, 1=DAI, 2=USDT
    uint256 coverageAmount;       // en USDC (6 decimals)
    uint256 premiumPaid;
    uint256 triggerPrice;         // $0.95 (8 decimals Chainlink)
    uint256 startTimestamp;       // bloque de emisión
    uint256 waitingEndTimestamp;  // startTimestamp + 24 horas
    uint256 expirationTimestamp;  // startTimestamp + duration_seconds
    uint256 maxPayout;            // coverage × (1 - deductible)
    uint16 deductibleBps;         // 1000 (USDC), 1200 (DAI), 1500 (USDT)
    bool isActive;
    bool isPaidOut;
}
```

---

## 9. Renovación

### 9.1 Flujo
Idéntico al BSS:

```
24 horas antes de expiración:
  → Sistema calcula nueva prima con condiciones actuales
  → Lee U actual del vault, risk multiplier dinámico de la stablecoin, aplica Kink Model
  → Genera renewal quote
  → Envía al agente del comprador

Agente decide según reglas preconfiguradas por el humano:
  → Acepta → nueva póliza emitida (con nuevo waiting period de 24h)
  → Rechaza → sin cobertura → notifica al humano

NOTA: La nueva póliza tiene un nuevo waiting period de 24h.
Esto significa que hay un gap de cobertura de ~24h entre pólizas en cada renovación.
El agente y el humano son notificados de este gap.
```

### 9.2 Configuración del Agente

```json
{
  "autoRenewal": true,
  "maxPremiumIncrease": 0.30,
  "preferredDuration": 90,
  "fallbackDuration": 30,
  "minCoverage": 50000,
  "stablecoin": "USDC",
  "notifications": {
    "on_renewal": "always",
    "on_price_change_above": 0.10,
    "on_rejection": "immediate",
    "on_coverage_gap": "immediate"
  }
}
```

---

## 10. Riesgos y Mitigaciones

| Riesgo | Mitigación |
|---|---|
| Flash depeg falso (illiquidez temporal) | TWAP 30 min + 5 roundIds consecutivos — filtra wicks de minutos |
| Error de un solo exchange | Chainlink agrega 3+ exchanges. Feed freshness < 120s. |
| Selección adversa (compra al ver rumores) | Waiting period 24h + circuit breaker (>1% off-peg → ×2, >2% → halt) |
| Risk multiplier desactualizado | Multipliers dinámicos ajustados por desviación del peg en últimos 30 días |
| Vault drenado por depeg correlacionado | MaxAllocationPerProduct 25%. Pérdida máxima: 22.5% del vault |
| Contagio BSS + Depeg simultáneo | Pérdida combinada máxima ~38% del vault. Severo pero no terminal |
| LP retira antes del evento | Lock periods obligatorios (90/180/365 días). Capital bloqueado no es retirable. |
| Póliza emitida sin respaldo | Imposible — colateralización 1:1, revierte si no hay liquidez |
| Quote viejo con condiciones diferentes | Deadline de 5 min en firma EIP-712 |
| Utilización >95% | Transacción revierte — protección hard-coded |
| Contagio inter-stablecoin (USDT depeg causa USDC depeg) | MaxAllocation limita exposición por producto. Diversificación forzada. |

---

## 11. Comparación con Alternativas

| | Depeg Shield | Nexus Mutual (depeg) | Comprar la stablecoin directamente | Short stablecoin en DEX |
|---|---|---|---|---|
| Threshold | $0.95 fijo | Varía por cover | N/A | Flexible |
| Duración | 14-365 días | 30-365 días | Indefinido | Indefinido |
| Prima | 0.52-16.86% | 2.6% anual | N/A | Funding rate variable |
| Payout | Automático on-chain (1 TX) | Requiere claim + votación | N/A | Requiere gestión manual |
| Waiting period | 24h | 72h típico | N/A | N/A |
| Settlement | USDC instantáneo | ETH (con delay) | N/A | Variable |
| Operador | Agente de IA M2M | Humano | Humano | Humano o bot |
| Cobertura 3 stablecoins | Sí (USDC/USDT/DAI) | Separadas | N/A | Por par |

---

## 12. Métricas de Monitoreo

| Métrica | Target | Alarma |
|---|---|---|
| Utilización del vault (U) | 30-60% | >80% |
| Desviación del peg (cada stablecoin) | <0.5% | >1% |
| Risk multiplier actual (USDT) | 1.4x | >1.6x |
| Ratio claims / pólizas | <3% mensual | >5% mensual |
| EV acumulado del LP | Positivo | Negativo por >3 meses |
| Waiting period violations | 0 | Cualquiera |
| Prima promedio como % coverage | 1-3% (30d) | <0.5% o >5% |
| MaxAllocation utilizado | <80% del cap | >90% |
| Feed freshness (Chainlink) | <120s | >300s |
