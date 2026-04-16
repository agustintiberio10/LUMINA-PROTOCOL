> **DEPRECATED (2026-04-06):** BlackSwanShield was split into BTCCatastropheShield (BCS) and ETHApocalypseShield (EAS). This document is kept for historical reference. See BCS/EAS specs for current parameters.

# The Black Swan Shield — Especificación Técnica y Actuarial Completa

## Protocolo: Lumina Protocol
## Producto: BLACKSWAN-001 (ex LIQSHIELD-001) — DEPRECATED
## Versión: 3.0 — Post-pivot catastrófico
## Chain: Base L2 (8453) | Settlement: USDC
## Modelo: M2M (Machine-to-Machine) — operado exclusivamente por Agentes de IA

**CALIBRATION UPDATE (March 2026):** pBase recalibrated from V1 additive formula values to market-aligned rates for V2 multiplicative Kink Model. Benchmarked against Nexus Mutual, InsurAce, Etherisc. New pBase: 650 bps (6.5%). Original V1 value: 2200 bps.

---

## 1. Definición del Producto

### 1.1 Naturaleza
Seguro paramétrico catastrófico contra cisnes negros. Protege capital en DeFi contra colapsos sistémicos del mercado (caídas >30% de BTC o ETH). No es protección contra movimientos frecuentes — es seguro contra eventos extremos y raros.

### 1.2 Activo Subyacente
- BTC/USD (Chainlink feed: 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F)
- ETH/USD (Chainlink feed: 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70)

### 1.3 Dirección
Solo LONG (protección contra caída de precio). Short puede agregarse en versión futura.

---

## 2. Parámetros del Producto

| Parámetro | Valor |
|---|---|
| Threshold (trigger) | -30% desde el precio exacto del bloque de emisión de la póliza |
| Duración | 7 a 30 días (continuo, elige el comprador) |
| Deducible | 20% fijo |
| Max Payout | 80% del Coverage Amount |
| P_base (prima base anualizada) | 0.065 (6.5%) |
| Waiting Period | 1 hora (3600 segundos) — anti-front-running; eventos durante el waiting period NO están cubiertos |
| Coverage mínimo | $100 USDC |
| Coverage máximo | Limitado por liquidez disponible del vault |
| MaxAllocationPerProduct | 20% del Mega Pool |
| Colateralización | 1:1 estricta — por cada $1 de coverage se bloquea $1 de USDC del vault |

### 2.1 Sobre el Threshold
El -30% se calcula SIEMPRE desde el precio del activo en el bloque exacto en que se emitió la póliza, NO desde máximos históricos ni desde promedios. Si BTC está en $60,000 al momento de compra, el trigger se activa si BTC llega a $42,000. Si BTC ya había caído 20% durante el día antes de la compra, es irrelevante — el 30% se mide desde el momento de compra.

### 2.2 Sobre la Duración
No hay tiers de duración fijos. El comprador elige cualquier valor entre 7 y 30 días. La fórmula de pricing proratea automáticamente por segundo. A menor duración, menor prima en valor absoluto pero la tasa diaria es similar.

---

## 3. Mecanismo de Trigger: Anti-Flash Crash (TWAP)

### 3.1 Problema que resuelve
Un error de API en un exchange, un flash crash de 2 segundos, o una manipulación puntual podrían activar payouts falsos y drenar el Mega Pool. Una única lectura instantánea de Chainlink por debajo del threshold está PROHIBIDA como trigger.

### 3.2 Mecanismo exigido
El precio debe validarse mediante UNO de estos dos métodos (el que se cumpla primero):

**Método A — TWAP 15 minutos:**
El precio promedio ponderado por tiempo (Time-Weighted Average Price) durante los últimos 15 minutos debe estar por debajo del threshold.

**Método B — 3 roundIds consecutivos de Chainlink:**
Un mínimo de 3 actualizaciones consecutivas de roundId en el feed de Chainlink deben devolver un precio inferior al threshold.

### 3.3 Verificación Multi-Exchange
El precio debe confirmarse caído en al menos 3 exchanges simultáneamente. Chainlink ya agrega datos de Binance, Coinbase, Kraken y otros, pero el backend debe verificar adicionalmente que:
- El feed de Chainlink no esté stale (última actualización < 60 segundos)
- El heartbeat del feed esté activo
- Si un solo exchange muestra la caída pero los demás no, Chainlink no reporta la caída → el trigger no se activa

### 3.4 Volatility Circuit Breaker (Anti-Selección Adversa)
El backend monitorea movimientos de precio recientes para evitar que agentes compren pólizas durante crashes en curso:

```
Si BTC/ETH se movió >5% en la última hora:
  → P_base se multiplica ×1.5 temporalmente (primas 50% más caras)

Si BTC/ETH se movió >10% en la última hora:
  → Se PAUSA la emisión de nuevas pólizas hasta que se estabilice
  → Las pólizas existentes siguen activas normalmente

La verificación se hace contra al menos 3 exchanges vía Chainlink.
```

### 3.5 Impacto actuarial del TWAP + Circuit Breaker
El filtro TWAP reduce la probabilidad efectiva de activación de ~3% a ~1.5-2% por ventana de 30 días, porque:
- Filtra flash crashes de segundos/minutos que se recuperan
- Filtra errores de API de un solo exchange (Chainlink agrega 3+ fuentes)
- Solo pasa si la caída es real, sostenida y multi-exchange

El circuit breaker de volatilidad reduce adicionalmente la selección adversa:
- Los agentes no pueden comprar durante un crash en curso (>10% move → halt)
- Si compran durante volatilidad alta (>5% move), pagan 50% más

Esta combinación es lo que hace el producto actuarialmente viable para los LPs.

---

## 4. Motor de Pricing: AMM de Riesgo (Kink Model)

### 4.1 Fórmula principal

```
Premium_final = Coverage × P_base × M(U) × (Duration_seconds / 31,536,000)
```

Donde:
- Coverage: monto asegurado en USDC
- P_base: 0.065 (6.5% anualizado)
- M(U): multiplicador dinámico basado en utilización del vault
- Duration_seconds: duración de la póliza en segundos
- 31,536,000: segundos en un año

### 4.2 Cálculo de Utilización

```
U = (C_allocated + C_requested) / C_total
```

Donde:
- C_total: USDC total depositado por LPs en el vault
- C_allocated: USDC actualmente bloqueado garantizando pólizas activas
- C_requested: monto de la nueva póliza que se está cotizando

### 4.3 Curva de Multiplicación (Kink Model)

Constantes:
- U_kink = 0.80 (80%)
- R_slope1 = 0.5 (pendiente suave)
- R_slope2 = 3.0 (pendiente agresiva)

```
Si U ≤ U_kink (zona segura):
  M(U) = 1 + (U / U_kink × R_slope1)

Si U > U_kink (zona de estrés):
  M(U) = 1 + R_slope1 + ((U - U_kink) / (1 - U_kink) × R_slope2)
```

### 4.4 Tabla de multiplicadores resultantes

| Utilización | M(U) | Zona |
|---|---|---|
| 0% | 1.00 | Segura |
| 10% | 1.06 | Segura |
| 20% | 1.13 | Segura |
| 30% | 1.19 | Segura |
| 40% | 1.25 | Segura |
| 50% | 1.31 | Segura |
| 60% | 1.38 | Segura |
| 70% | 1.44 | Segura |
| 80% | 1.50 | Límite (kink) |
| 85% | 2.25 | Estrés |
| 90% | 3.00 | Estrés |
| 95% | 3.75 | Estrés crítico |
| >95% | RECHAZADO | Protección de solvencia |

### 4.5 Tabla de primas resultantes (Coverage $50,000)

| Duración | U=20% | U=40% | U=60% | U=80% | U=90% |
|---|---|---|---|---|---|
| 7 días | $70 (0.14%) | $78 (0.16%) | $86 (0.17%) | $93 (0.19%) | $187 (0.37%) |
| 14 días | $140 (0.28%) | $156 (0.31%) | $171 (0.34%) | $187 (0.37%) | $374 (0.75%) |
| 21 días | $210 (0.42%) | $234 (0.47%) | $257 (0.51%) | $280 (0.56%) | $561 (1.12%) |
| 30 días | $301 (0.60%) | $334 (0.67%) | $367 (0.73%) | $401 (0.80%) | $801 (1.60%) |

Rango operativo normal (U=20-60%): **0.14% a 0.73%** del coverage según duración y utilización.

---

## 5. Topología de Liquidez: Mega Pools (Vaults ERC-4626)

### 5.1 Estructura
El Black Swan Shield se aloja en el Mega Pool High Risk (Bóveda 3), junto con otros productos de cola pesada.

### 5.2 MaxAllocationPerProduct
Máximo 20% del vault puede estar comprometido en pólizas del Black Swan Shield.

```
Vault: $1,000,000
Max BSS: $200,000
Pólizas activas posibles: 4 × $50K, o 2 × $100K, o 1 × $200K, etc.
```

### 5.3 Modelo de colateralización
Estricto 1:1. Fully collateralized. Nunca se emite una póliza sin el respaldo bloqueado.

```
Por cada $1 de Coverage → $1 de USDC bloqueado en el vault
Si C_requested > (C_total - C_allocated) → transacción revierte
Si U post-emisión > 95% → transacción revierte
El protocolo NUNCA asume deuda ni opera con reserva fraccionaria
```

### 5.4 Restricción de retiro para LPs
Los LPs no pueden retirar USDC que esté en estado C_allocated. Solo pueden retirar liquidez ociosa (C_total - C_allocated).

---

## 6. Análisis Actuarial

### 6.1 Probabilidad histórica de activación

Eventos donde BTC o ETH cayó >30% en ≤30 días (2020-2025):
- Marzo 2020 (COVID): -55% en 7 días
- Mayo 2021 (China ban): -53% en 12 días
- Junio 2022 (LUNA/3AC): -45% en 10 días
- Noviembre 2022 (FTX): -30% en 8 días

4 eventos en ~5 años = ~0.8 eventos/año.

IMPORTANTE: estos son medidos desde máximos previos. El Black Swan Shield mide desde el precio de COMPRA de la póliza, lo que puede reducir o aumentar la probabilidad dependiendo de cuándo se compra.

### 6.2 Probabilidad ajustada por TWAP

Sin TWAP (lectura instantánea): ~3% por ventana de 30 días
Con TWAP 15 minutos: ~1.5-2% por ventana de 30 días

El TWAP filtra flash crashes que se recuperan en <15 minutos, reduciendo la frecuencia efectiva aproximadamente a la mitad.

Para 7 días: ~0.5-0.8% de probabilidad con TWAP
Para 14 días: ~1.0-1.2% de probabilidad con TWAP
Para 30 días: ~1.5-2.0% de probabilidad con TWAP

### 6.3 Expected Value para el LP

Escenario: Vault $1M, 20% en BSS ($200K), 4 pólizas de $50K, duración 30 días, U=40%

```
Primas mensuales BSS: 4 × $334 = $1,336
Primas anuales BSS: $1,336 × 12 = $16,027

Si claim (todas las pólizas se activan — evento correlacionado):
  Payout total: 4 × ($50K × 80%) = $160,000
  Pérdida como % del vault: 16%

Probabilidad de al menos 1 claim/año: ~18-24% (basado en 1.5-2% mensual)
Expected annual claims: 0.21 × $160,000 = $33,600

EV anual BSS solo = $16,027 - $33,600 = -$17,573

NOTA: Con pBase=650 bps, BSS solo no es rentable para LPs a U=40%.
La viabilidad del vault depende de:
  1. Múltiples productos (BSS + IL Protection + Exploit Shield) compartiendo el vault
  2. Yield de Aave V3 (~3-6% APY sobre totalAssets)
  3. Utilización agregada elevada por la combinación de productos
  4. A U=90% (M=3.0), BSS solo genera EV positivo: $38,466 - $33,600 = +$4,866
```

### 6.4 Stress test — año catastrófico (2 eventos)

```
Primas anuales BSS: $16,027
Claims: 2 × $160,000 = $320,000
Neto BSS: -$303,973

Probabilidad de 2+ eventos/año: ~3-5%
```

En un año con 2 cisnes negros, el vault pierde 32% de su capital solo por BSS. El MaxAllocationPerProduct del 20% limita la pérdida máxima por un solo evento a 16%. Las primas BSS a pBase=650 no cubren ni un evento. La viabilidad del vault en stress depende del yield combinado de todos los productos y Aave V3.

### 6.5 Break-even para el LP

```
Meses de primas BSS para recuperar 1 claim: $160,000 / $1,336 = ~120 meses
Con probabilidad mensual de claim de ~2%: esperanza de 50 meses entre claims

NOTA: Con BSS solo a pBase=650, el break-even por primas excede la esperanza entre claims.
El vault se sostiene por la combinación de:
  - Primas de todos los productos (BSS + IL + Exploit + Depeg)
  - Yield de Aave V3 sobre totalAssets (~3-6% APY)
  - El Kink Model incentiva utilización alta donde las primas son multiplicadas
```

---

## 7. Perspectiva del Comprador

### 7.1 Costo de cobertura

| Capital a cubrir | Duración | Prima (U=40%) | Costo mensual si renueva | % mensual |
|---|---|---|---|---|
| $25,000 | 7 días | $39 | $167 | 0.67% |
| $25,000 | 30 días | $167 | $167 | 0.67% |
| $50,000 | 7 días | $78 | $334 | 0.67% |
| $50,000 | 30 días | $334 | $334 | 0.67% |
| $100,000 | 7 días | $156 | $668 | 0.67% |
| $100,000 | 30 días | $668 | $668 | 0.67% |
| $500,000 | 30 días | $3,339 | $3,339 | 0.67% |

### 7.2 Value proposition

```
Sin seguro: BTC cae 30% → pierde parte o todo del capital (dependiendo del apalancamiento)
Con seguro: BTC cae 30% → cobra 80% del coverage amount. Sobrevive y se reposiciona.

Costo: ~0.67% mensual del capital cubierto (a U=40%)
Alternativa: no hay producto equivalente en DeFi que cubra cisnes negros con liquidación automática
```

---

## 8. Resolución y Payout

### 8.1 Flujo de resolución

```
1. Evento de mercado: BTC/ETH cae significativamente
2. Un agente de IA llama: triggerPayout(uint256 policyId)
3. El smart contract verifica ON-CHAIN:
   a. La póliza está activa (no expirada)
   b. El TWAP de 15 minutos de Chainlink está por debajo del strikePrice × 0.70
   c. O alternativamente: 3 roundIds consecutivos de Chainlink muestran precio < strikePrice × 0.70
4. Si la verificación pasa:
   → Transfer de USDC (Coverage × 80%) directo al wallet del agente asegurado
   → En la misma transacción
   → Sin timelock, sin espera, sin reclamo manual
5. Si la verificación falla:
   → Transacción revierte
```

### 8.2 Datos almacenados en la póliza (struct Policy)

```solidity
struct Policy {
    uint256 policyId;
    address insuredAgent;          // wallet del agente asegurado
    address asset;                 // dirección del feed de Chainlink (BTC o ETH)
    uint256 coverageAmount;        // en USDC (6 decimals)
    uint256 premiumPaid;           // prima pagada en USDC
    uint256 strikePrice;           // precio del activo al momento de emisión (8 decimals Chainlink)
    uint256 triggerPrice;          // strikePrice × 0.70 (threshold -30%)
    uint256 startTimestamp;        // bloque de emisión
    uint256 expirationTimestamp;   // startTimestamp + duration_seconds
    uint256 maxPayout;             // coverageAmount × 0.80 (deducible 20%)
    bool isActive;                 // true hasta que expire o se pague
    bool isPaidOut;                // true si se ejecutó el payout
}
```

---

## 9. Renovación Automática

### 9.1 Flujo

```
SEGUNDO 0: Póliza expira
SEGUNDO 1: Sistema calcula nueva prima con condiciones actuales del vault
           → Lee U actual, aplica Kink Model, genera quote
SEGUNDO 2: Presenta al agente del comprador:
           "Póliza expiró. Nueva oferta: $X por Y días. Aceptar / Rechazar / Modificar"
SEGUNDO 3: Agente decide según reglas preconfiguradas por el humano:
           → Si nueva prima dentro de maxPremiumIncrease → ACEPTA
           → Si excede → intenta con fallback_duration (ej: 14 días en vez de 30)
           → Si sigue excediendo → RECHAZA
SEGUNDO 4: Resultado:
           → Aceptó → nueva póliza emitida instantáneamente
           → Rechazó → sin cobertura → notifica al humano
```

### 9.2 Ventana de renovación
24 horas antes de la expiración, el sistema genera el renewal quote y lo envía al agente. Esto da tiempo al agente para evaluar y al humano para intervenir si es necesario. Si el agente no responde en 24h, la póliza expira sin renovación.

### 9.3 Configuración del agente (definida por el humano)

```json
{
  "autoRenewal": true,
  "maxPremiumIncrease": 0.30,
  "preferredDuration": 30,
  "fallbackDuration": 14,
  "minCoverage": 25000,
  "notifications": {
    "on_renewal": "always",
    "on_price_change_above": 0.10,
    "on_rejection": "immediate"
  }
}
```

---

## 10. Contratos Inteligentes Requeridos

| Contrato | Función |
|---|---|
| BlackSwanShield.sol | Emisión de pólizas, verificación TWAP/3-rounds on-chain, ejecución de payouts |
| LuminaVault.sol (ERC-4626) × 3 | Mega Pools por nivel de riesgo. Depósitos de LPs, shares, bloqueo de fondos |
| CoverRouter.sol | Verificación EIP-712 de quotes firmados off-chain. No calcula precios. |
| PolicyManager.sol | Asignación de liquidez de vaults a pólizas, MaxAllocationPerProduct |

Los contratos existentes (MutualLumina, DisputeResolver, AutoResolver) se mantienen para los productos P2P legacy.

---

## 11. Arquitectura Off-chain

### 11.1 Pricing API (Node.js)
- Endpoint /quote: recibe product_id, coverage_amount, duration
- Lee estado del vault via RPC (C_total, C_allocated)
- Calcula U, M(U), Premium_final
- Firma EIP-712 con Oracle Key
- Retorna quote con deadline de 5 minutos

### 11.2 Volatilidad Monitor
- Lee precio de Chainlink cada hora
- Calcula volatilidad realizada 7 días
- Si vol > 80%: alerta al sistema
- Si vol > 100%: puede pausar emisión de nuevas pólizas (decisión del protocolo)

### 11.3 Renewal Engine
- 24h antes de expiración: genera renewal quote
- Lo envía al agente del comprador
- Procesa respuesta (aceptar/rechazar/modificar)
- Emite nueva póliza o notifica

---

## 12. Riesgos y Mitigaciones

| Riesgo | Mitigación |
|---|---|
| Flash crash falso activa payout | TWAP 15 min o 3 roundIds consecutivos — imposible con wick de segundos |
| Error de un solo exchange | Chainlink agrega 3+ exchanges — un solo exchange no mueve el feed. Backend verifica feed freshness. |
| Selección adversa (compra durante crash) | Volatility circuit breaker: >5% move en 1h → prima ×1.5, >10% → halt emisión |
| Vault drenado por evento correlacionado | MaxAllocationPerProduct 20% — pérdida máxima 16% del vault por evento |
| LP retira antes del claim | USDC bloqueado no es retirable. Solo liquidez ociosa. |
| Póliza emitida sin respaldo | Imposible — colateralización 1:1, revierte si no hay liquidez |
| Quote viejo usado en condiciones diferentes | Deadline de 5 min en firma EIP-712 — expira automáticamente |
| Utilización >95% | Transacción revierte — protección hard-coded |
| Manipulación de oráculo Chainlink | Riesgo sistémico de todo DeFi — fuera del alcance del producto |

---

## 13. Comparación con Alternativas

| | Black Swan Shield | Put Options (Deribit) | Perps Hedging | Nexus Mutual |
|---|---|---|---|---|
| Threshold | -30% fijo | Flexible (any strike) | No tiene threshold | Varía |
| Duración | 7-30 días | Fijo (expiry dates) | Indefinido | 30-365 días |
| Prima | ~0.14-1.60% por período | Variable (volatility surface) | Funding rate | 2.6%/año |
| Payout | Automático on-chain | Requiere ejercicio | Manual | Requiere claim + votación |
| Cobertura | BTC/ETH crashes | Cualquier activo listado | Cualquier perp | Smart contract exploits |
| Liquidación | N/A | Riesgo de margin call | Riesgo de liquidación | N/A |
| Operador | Agente de IA M2M | Humano o bot | Humano o bot | Humano |
| Settlement | USDC instantáneo | USDC/BTC | Variable | ETH (con delay) |

---

## 14. Métricas Clave para Monitoreo

| Métrica | Target | Alarma |
|---|---|---|
| Utilización del vault (U) | 30-60% | >80% |
| Ratio de claims / pólizas emitidas | <3% mensual | >5% mensual |
| EV acumulado del LP | Positivo | Negativo por >3 meses |
| Tiempo promedio de renovación | <1 hora | >12 horas |
| Prima promedio como % coverage | 0.5-1.0% | <0.3% o >2% |
| MaxAllocation utilizado | <80% del cap | >90% del cap |
