# Standard IL Index Cover — Especificación Técnica y Actuarial Completa

## Protocolo: Lumina Protocol
## Producto: ILPROT-001
## Versión: 1.0
## Chain: Base L2 (8453) | Settlement: USDC
## Modelo: M2M (Machine-to-Machine) — operado exclusivamente por Agentes de IA

**CALIBRATION UPDATE (March 2026):** pBase recalibrated from V1 additive formula values to market-aligned rates for V2 multiplicative Kink Model. Benchmarked against Nexus Mutual, InsurAce, Etherisc. New pBase: 850 bps (8.5%). Original V1 value: 2000 bps.

---

## 1. Definición del Producto

### 1.1 Naturaleza
Seguro paramétrico contra Impermanent Loss significativo para LPs de AMMs (Uniswap V3, Aerodrome, Curve, etc.). A diferencia de los otros productos de Lumina (que son binarios: pagan o no pagan), este producto tiene payout PROPORCIONAL al daño real calculado matemáticamente.

### 1.2 Nombre comercial: "Standard IL Index Cover"
El producto paga sobre la fórmula estándar de IL (Uniswap V2, pools 50/50). No intenta calcular el IL real de posiciones de liquidez concentrada (V3). El comprador entiende que el payout está basado en un índice estándar. Si el comprador tomó más riesgo concentrando liquidez en V3, el payout puede ser menor que su pérdida real.

### 1.3 Activo
ETH/USD (cualquier pool que contenga ETH como uno de los pares). BTC/USD como extensión futura.

### 1.4 Diferencias fundamentales vs otros productos Lumina

| Aspecto | Black Swan Shield | Depeg Shield | IL Index Cover |
|---|---|---|---|
| Payout | Binario (80%) | Binario (85-90%) | PROPORCIONAL al IL |
| Frecuencia claims | ~2% /mes | ~1.5% /mes | ~25-35% /mes |
| Trigger | Caída >30% | Precio < $0.95 | IL > 2% |
| Analogía | Seguro contra huracanes | Seguro contra incendios | Seguro contra abolladuras |

---

## 2. Parámetros del Producto

| Parámetro | Valor |
|---|---|
| Trigger | IL calculado > 2% (equivale a movimiento de precio ±20%) |
| Payout | Proporcional: Coverage × IL% × (1 - deducible) |
| Cap de payout | 15% del coverage × (1 - deducible) = 13.5% del coverage |
| Deducible | 10% |
| Payout factor | 90% |
| Duración | 14 a 90 días (continuo, elige el comprador) |
| P_base | 0.085 (8.5% anualizado) |
| MaxAllocationPerProduct | 20% del Mega Pool (a evaluar en Paso 3) |
| Colateralización | 1:1 estricta |
| Waiting period | No (trigger relativo a precio de compra) |
| Verificación | TWAP 15 min para precio actual |
| Activo | ETH/USD |
| Dirección | Ambas (IL ocurre si ETH sube O baja) |

### 2.1 Sobre el Threshold (IL > 2%)
El IL del 2% equivale a un movimiento de precio de ±20% desde el momento de compra de la póliza. Filtra oscilaciones menores que son ruido operativo normal para cualquier LP en un AMM.

### 2.2 Sobre el Payout Proporcional
A diferencia de BSS y Depeg donde el payout es fijo (binario), acá el payout escala con la severidad del IL:

| Movimiento de ETH (cualquier dirección) | IL% | Payout ($50K coverage) |
|---|---|---|
| ±10% | 0.6% | $0 (IL < 2%) |
| ±15% | 1.0% | $0 (IL < 2%) |
| ±20% | 2.0% | $900 |
| ±25% | 3.0% | $1,350 |
| ±30% | 4.4% | $1,980 |
| ±40% | 3.5% | $1,575 |
| ±50% | 5.7% | $2,565 |
| ±75% | 10.6% | $4,770 |
| ±100% | 5.7% | $2,565 |
| Extremo (>±90%) | >15% | $6,750 (cap) |

### 2.3 Sobre la Fórmula de IL
Se utiliza la fórmula estándar de Impermanent Loss para pools 50/50:

```
priceRatio = precio_actual / precio_al_momento_de_compra
IL% = 2 × sqrt(priceRatio) / (1 + priceRatio) - 1
```

Esta fórmula es precisa para Uniswap V2 y pools de rango completo. Para Uniswap V3 (concentrated liquidity), el IL real puede ser significativamente mayor. El producto cubre el IL estándar (índice), no el IL real de posiciones concentradas.

### 2.4 Sobre el Cap del 15%
El payout máximo es 15% del coverage × 90% = 13.5% del coverage. Esto equivale a un IL de ~17%, que requiere un movimiento de precio extremo (>±90%). El cap protege al vault contra payouts desproporcionados.

---

## 3. Mecanismo de Trigger

### 3.1 Verificación
El precio actual de ETH/USD se obtiene via TWAP de 15 minutos de Chainlink. Se compara contra el precio registrado al momento de emisión de la póliza.

```
priceAtPurchase: registrado en el bloque de emisión
priceCurrent: TWAP 15 min de Chainlink ETH/USD

priceRatio = priceCurrent / priceAtPurchase
IL = 2 × sqrt(priceRatio) / (1 + priceRatio) - 1

Si IL > 0.02:
  payout = min(coverage × IL × 0.90, coverage × 0.15 × 0.90)
Si IL ≤ 0.02:
  payout = 0
```

### 3.2 Dirección
El IL ocurre en AMBAS direcciones. Si ETH sube 50% o baja 50%, el IL es idéntico (~5.7%). El trigger evalúa la magnitud del movimiento, no la dirección.

### 3.3 ¿Por qué no hay waiting period?
Porque el IL se mide desde el precio de compra de la póliza. Si ETH ya se movió 10% antes de la compra, el agente necesita que se mueva ±20% ADICIONAL desde su precio de entrada para que IL supere 2%. No hay ventaja de timing.

### 3.4 Momento de activación
El comprador puede llamar a triggerPayout() en CUALQUIER momento durante la vigencia de la póliza cuando el IL supere 2%. No necesita esperar a que expire.

NOTA IMPORTANTE: Una vez ejecutado el payout, la póliza se cierra. El comprador no puede cobrar múltiples veces por la misma póliza. Si ETH sigue moviéndose después del cobro, necesita comprar una nueva póliza.

---

## 4. Anti-Selección Adversa

### 4.1 Circuit Breaker por Volatilidad
```
Si ETH se movió >5% en la última hora:
  → P_base × 1.5 temporalmente (prima 50% más cara)

Si ETH se movió >10% en la última hora:
  → HALT emisión de nuevas pólizas

Verificación vía Chainlink (agrega 3+ exchanges).
```

### 4.2 Defensa natural del producto
El trigger es relativo al precio de COMPRA de la póliza. Un agente que compra durante un movimiento necesita que el precio se mueva ±20% ADICIONAL desde su punto de entrada. No hay forma de explotar el timing.

---

## 5. Motor de Pricing

### 5.1 Fórmula Principal
```
Premium = Coverage × P_base × M(U) × (Duration_seconds / 31,536,000)

P_base = 0.085 (8.5% anualizado)
M(U) = Kink Model estándar
```

### 5.2 Tablas de Primas (Coverage $50,000)

| Duración | U=20% (M=1.13) | U=40% (M=1.25) | U=60% (M=1.38) | U=80% (M=1.50) | U=90% (M=2.25) |
|---|---|---|---|---|---|
| 14 días | $541 (1.08%) | $599 (1.20%) | $661 (1.32%) | $719 (1.44%) | $1,079 (2.16%) |
| 30 días | $1,160 (2.32%) | $1,284 (2.57%) | $1,418 (2.84%) | $1,542 (3.08%) | $2,314 (4.63%) |
| 60 días | $2,321 (4.64%) | $2,568 (5.14%) | $2,836 (5.67%) | $3,084 (6.17%) | $4,627 (9.25%) |
| 90 días | $3,481 (6.96%) | $3,852 (7.70%) | $4,254 (8.51%) | $4,627 (9.25%) | $6,941 (13.88%) |

### 5.3 Rango Operativo Normal (U=20-60%)
- 14 días: 1.08% - 1.32%
- 30 días: 2.32% - 2.84%
- 60 días: 4.64% - 5.67%
- 90 días: 6.96% - 8.51%

---

## 6. Estrategia Óptima del Comprador (Under-Insurance Táctico)

### 6.1 El Problema
Si un agente asegura el 100% de su posición LP, la prima se come todo el rendimiento del pool. El sweet spot es asegurar ~50-60% del nocional.

### 6.2 La Regla del 50%
La prima no debe superar el 50% de los fees proyectados del pool.

```
Pool fees mensuales: positionSize × monthlyAPY
Max prima: poolFees × 50%
Coverage óptimo: maxPrima / (P_base × M(U) × timeFraction)
```

### 6.3 Ejemplo: $100K en pool, 3% mensual, póliza 30 días, U=40%

```
Pool fees: $100K × 3% = $3,000/mes
Max prima (50%): $1,500
Premium rate per dollar: 0.25 × 1.25 × (30/365) = 0.02568
Coverage óptimo: $1,500 / 0.02568 = $58,400 (58.4% de la posición)
```

### 6.4 Escenarios con coverage óptimo ($58,400, prima $1,500)

| Escenario | ETH mueve | IL real ($100K) | Seguro paga | Neto con seguro | Neto sin seguro |
|---|---|---|---|---|---|
| Tranquilo | ±10% | $600 | $0 | +$900 | +$2,400 |
| Volátil | ±30% | $4,400 | $2,311 | -$589 | -$1,400 |
| Crash | ±50% | $5,700 | $2,996 | -$1,204 | -$2,700 |
| Extremo | ±75% | $10,600 | $5,571 | -$4,529 | -$7,600 |

El seguro no mejora el retorno promedio (EV). Reduce las pérdidas en meses malos. Es un seguro real: en promedio pagás más de lo que cobrás, pero cuando viene el golpe, sobrevivís.

### 6.5 Hedging Engine
Lumina provee un módulo TypeScript (`LuminaILHedgingStrategy`) para que los agentes calculen automáticamente el coverage óptimo. El engine:
- Recibe posición, APY del pool, y consulta la API de Lumina
- Aplica la regla del 50%
- Evalúa 3 duraciones (14, 30, 60 días)
- Retorna la mejor combinación + payload JSON para la compra
- Puede decidir SKIP si el seguro no es cost-effective

---

## 7. LP: Perfil de Riesgo

### 7.1 Frecuencia de Claims
Este producto tiene la frecuencia de claims más alta del catálogo:

| Duración | Prob. de activación | Claims esperados /mes (4 pólizas) |
|---|---|---|
| 14 días | ~17.5% | ~1.4 claims |
| 30 días | ~30% | ~1.2 claims |
| 60 días | ~45% | ~0.9 claims |
| 90 días | ~62.5% | ~0.7 claims |

### 7.2 EV del LP

Vault $1M, 20% en ILPROT ($200K), 4 pólizas de $50K, 30 días, U=40%

```
Primas mensuales: 4 × $1,284 = $5,136
Expected claims mensuales: ~1.2 pólizas × $1,700 promedio = $2,040
Neto mensual esperado: +$3,096
EV anual: +$37,152
Margen sobre expected claims: ~60%
```

### 7.3 Variabilidad del Yield
A diferencia de BSS y Depeg donde el yield mensual es predecible (primas fijas, claims raros), con IL el yield varía significativamente:

```
Mes tranquilo (ETH ±10%): neto ~+$5,136 (sin claims)
Mes normal (ETH ±20%): neto ~+$3,096 (algunos claims)
Mes volátil (ETH ±35%): neto ~+$1,000 (muchos claims)
Mes bull/bear fuerte (ETH ±50%): neto ~-$500 (casi todos cobran)
```

El LP debe entender que tendrá meses negativos con regularidad. El EV anual es positivo pero la varianza mensual es alta.

### 7.4 Peor Escenario
Bull o bear market sostenido donde ETH se mueve >30% cada mes durante 3+ meses:

```
Mes 1: primas $5,136, claims $4,500 → neto +$636
Mes 2: primas $5,136, claims $5,000 → neto +$136
Mes 3: primas $5,136, claims $5,500 → neto -$364
Total 3 meses: +$408 (apenas positivo)
```

Difícil pero no terminal. El LP no pierde principal (a diferencia de BSS donde un claim destruye el 16% del vault). Los claims de IL son pequeños y frecuentes.

---

## 8. Correlación con Otros Productos

| Evento | BSS | Depeg | IL |
|---|---|---|---|
| ETH cae 35% | ✅ Paga 80% | Posiblemente | ✅ IL ~5% |
| ETH sube 50% | ❌ | ❌ | ✅ IL ~5.7% |
| USDC depeg | ❌ | ✅ | ✅ Si pool tiene USDC |
| Mercado lateral ±5% | ❌ | ❌ | ❌ IL <0.5% |
| Bull market sostenido | ❌ | ❌ | ✅ Claims frecuentes |

Peor caso combinado con BSS (ETH crash -35%):
- BSS: 20% del vault = $200K en claims
- IL: ~$10K en claims (proporcional, mucho menor)
- Total: ~21% del vault

La correlación con BSS existe pero el impacto de IL es menor porque los payouts son proporcionales, no binarios.

---

## 9. Resolución y Payout

### 9.1 Flujo
```
1. Precio de ETH se mueve significativamente
2. Agente calcula IL basado en precio actual vs precio de compra
3. Si IL > 2%: agente llama triggerPayout(uint256 policyId)
4. Smart contract verifica on-chain:
   a. Póliza activa y no expirada
   b. Calcula IL usando TWAP 15 min vs strikePrice
   c. IL > 2%
5. Calcula payout: min(coverage × IL × 0.90, coverage × 0.15 × 0.90)
6. Transfiere USDC al agente asegurado
7. Póliza se cierra (un solo cobro por póliza)
```

### 9.2 Datos de la Póliza

```solidity
struct Policy {
    uint256 policyId;
    address insuredAgent;
    uint256 coverageAmount;       // en USDC (6 decimals)
    uint256 premiumPaid;
    uint256 strikePrice;          // precio ETH/USD al momento de emisión (8 decimals)
    uint256 startTimestamp;
    uint256 expirationTimestamp;
    uint256 maxPayout;            // coverage × 0.15 × 0.90 (cap)
    uint16 deductibleBps;         // 1000 (10%)
    uint16 triggerILBps;          // 200 (2% IL mínimo)
    bool isActive;
    bool isPaidOut;
}
```

---

## 10. Renovación

Mismo flujo que BSS y Depeg:
```
24h antes de expiración → sistema genera renewal quote → agente decide
```

Particularidad: al renovar, el nuevo strikePrice es el precio de ETH al momento de la renovación. Si ETH subió 30% durante la póliza anterior, la nueva póliza toma el nuevo precio como base. El agente NO arrastra el IL acumulado a la nueva póliza.

---

## 11. Riesgos y Mitigaciones

| Riesgo | Mitigación |
|---|---|
| Claims frecuentes erosionan yield del LP | Margen del 60% sobre expected claims. P_base calibrado a 0.25. |
| Bull market sostenido genera claims constantes | El LP entiende la volatilidad del yield. EV anual sigue positivo. |
| Fórmula V2 subestima IL real en V3 | Producto vendido explícitamente como "Standard IL Index". No cubre riesgo de concentrated liquidity. |
| Correlación con BSS en crash | Impacto de IL es proporcional (pequeño vs BSS binario). Máximo combinado ~21% del vault. |
| Agente cobra IL y luego el precio vuelve | Póliza se cierra al cobrar. Un cobro por póliza. |
| Flash crash genera IL momentáneo | TWAP 15 min filtra. |
| Agente compra durante volatilidad | Circuit breaker: >5% en 1h → prima ×1.5, >10% → halt. |

---

## 12. Métricas de Monitoreo

| Métrica | Target | Alarma |
|---|---|---|
| Utilización del vault (U) | 30-60% | >80% |
| Ratio claims/pólizas mensual | 25-35% | >50% |
| Payout promedio por claim | 3-5% del coverage | >8% |
| EV acumulado del LP | Positivo | Negativo por >2 meses consecutivos |
| Volatilidad de ETH 30d | 40-60% | >80% (considerar pausa) |
| Prima promedio como % coverage | 2-3% (30d) | <1.5% o >5% |
| MaxAllocation utilizado | <80% del cap | >90% |

---

## 13. Hedging Engine (módulo para agentes)

Lumina provee `LuminaILHedgingStrategy` (TypeScript) como SDK para agentes compradores. El módulo:

- Input: tamaño de posición, APY del pool, asset
- Consulta API de Lumina para P_base y M(U) actuales
- Calcula coverage óptimo (regla del 50%: prima ≤ 50% de fees proyectados)
- Evalúa duraciones de 14, 30 y 60 días
- Output: decisión BUY/SKIP + payload JSON para compra
- Incluye proyección de net yield con y sin seguro

El sweet spot típico: cubrir ~58% de la posición, prima = 50% de los fees del pool.
