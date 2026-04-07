# LUMINA PROTOCOL -- WHITEPAPER V3

### Seguro Parametrico On-Chain para Agentes de Inteligencia Artificial

**Red:** Base L2 (Chain 8453) | **Liquidacion:** USDC (Circle) | **Yield:** Aave V3

**Version:** 3.0 -- Marzo 2026

**Contacto:** hello@lumina-org.com | **Docs:** https://lumina-org.com

---

## INDICE

1. [Resumen Ejecutivo](#1-resumen-ejecutivo)
2. [Introduccion](#2-introduccion)
3. [Arquitectura del Protocolo](#3-arquitectura-del-protocolo)
4. [Productos de Seguro](#4-productos-de-seguro)
5. [Vaults y Yield](#5-vaults-y-yield)
6. [Oracle y Verificacion](#6-oracle-y-verificacion)
7. [Modelo de Negocio](#7-modelo-de-negocio)
8. [Seguridad](#8-seguridad)
9. [Datos Actuariales](#9-datos-actuariales)
10. [Riesgos](#10-riesgos)
11. [Roadmap](#11-roadmap)
12. [Marco Legal](#12-marco-legal)
13. [Direcciones de Produccion](#13-direcciones-de-produccion)
14. [Grupos de Correlacion](#14-grupos-de-correlacion)
15. [API y Agentes](#15-api-y-agentes)
16. [Conclusion](#16-conclusion)

---

## 1. RESUMEN EJECUTIVO

Lumina Protocol es la primera infraestructura de seguro parametrico descentralizado disenada exclusivamente para agentes de inteligencia artificial que operan en DeFi. El protocolo despliega en Base L2, liquida en USDC real (Circle) y genera yield a traves de Aave V3.

A diferencia del seguro tradicional, que requiere que un humano presente un reclamo, un comite lo revise y semanas de espera para recibir el pago, Lumina utiliza triggers matematicos verificados por oracles. Si la condicion se cumple (por ejemplo, ETH cae un 30%), el pago es instantaneo y automatico. Sin reclamos. Sin disputas. Sin esperar a humanos.

El protocolo ofrece **4 productos de seguro** (Black Swan Shield, Depeg Shield, IL Index Cover, Exploit Shield), **4 vaults de liquidez** (VolatileShort, VolatileLong, StableShort, StableLong) y opera a traves de **13 contratos inteligentes** desplegados en produccion con proxies UUPS upgradeables.

Cada flujo de interaccion comienza de la misma forma: **el humano, a traves de su agente de IA**, instruye la operacion deseada. El agente ejecuta la transaccion on-chain de forma autonoma, interactuando con la API de Lumina y los contratos del protocolo sin intervencion manual.

El modelo de negocio es simple y transparente: una comision del 3% sobre la prima pagada por el asegurado, un 3% sobre el pago de siniestro, y un 3% de performance fee sobre el rendimiento positivo (ganancia) cuando los proveedores de liquidez retiran fondos de los vaults.

---

## 2. INTRODUCCION

### 2.1 El Problema: DeFi sin Proteccion para Agentes Autonomos

La economia agentica crece exponencialmente. Miles de agentes de IA gestionan posiciones DeFi, tesorerías, pools de liquidez y estrategias de yield farming. Sin embargo, estos agentes operan sin ningun tipo de cobertura frente a los riesgos mas criticos del ecosistema: caidas catastroficas del mercado, depegs de stablecoins, impermanent loss severo y exploits de protocolos.

Los protocolos de seguro DeFi existentes fueron disenados para humanos. Requieren interfaces graficas, procesos de votacion comunitaria para validar reclamos y tiempos de resolucion incompatibles con la velocidad a la que operan los agentes autonomos. Lumina resuelve este problema con un enfoque puramente programatico y parametrico.

### 2.2 Comparativa con Protocolos Existentes

| Caracteristica                    | **Nexus Mutual**       | **InsurAce**          | **Ensuro**           | **LUMINA PROTOCOL**          |
|-----------------------------------|------------------------|-----------------------|----------------------|-------------------------------|
| Enfoque principal                 | Seguro para humanos    | Seguro multi-chain    | Seguro parametrico   | **Seguro para agentes de IA** |
| Tipo de seguro                    | Discretional           | Discretional          | Parametrico          | **Parametrico**               |
| Proceso de reclamo                | Votacion comunitaria   | Comite de evaluacion  | Oracle automatico    | **Oracle automatico**         |
| Tiempo de pago                    | Semanas                | Dias                  | Horas                | **Minutos (1 tx)**            |
| Disenado para agentes IA          | No                     | No                    | Parcial              | **Si, exclusivamente**        |
| Yield para LPs                    | Staking NXM            | Farming               | Primas               | **Aave V3 + Primas**         |
| Colateralizacion                  | Pool compartido        | Pool compartido       | Por riesgo           | **1:1 por poliza**            |
| Red                               | Ethereum L1            | Multi-chain           | Polygon              | **Base L2**                   |
| Liquidacion                       | ETH/DAI                | Multi-token           | USDC                 | **USDC (Circle)**             |
| Productos                         | Smart Contract Cover   | Varios                | Clima/Parametrico    | **4 productos DeFi**          |

### 2.3 Como Funciona Lumina

El humano, a traves de su agente de IA, define los parametros de cobertura deseados: activo a cubrir, monto, duracion y producto. El agente consulta la API de Lumina para obtener una cotizacion precisa, incluyendo la prima calculada segun el modelo kink de utilizacion. Una vez aprobada la cotizacion, el agente ejecuta la transaccion on-chain a traves del CoverRouter.

**Flujo simplificado:**

```
Humano → Agente IA → API Lumina → CoverRouter → Shield → PolicyManager → Vault (lock collateral) → USDC transfer
```

El colateral se bloquea 1:1 en el vault correspondiente. Si el trigger se activa durante la vigencia de la poliza, el pago se ejecuta automaticamente. Si la poliza expira sin que el trigger se active, el colateral se libera de vuelta al vault.

---

## 3. ARQUITECTURA DEL PROTOCOLO

### 3.1 Modelo Kink de Utilizacion

El corazon del pricing de Lumina es un modelo de utilizacion no lineal inspirado en los modelos de tasa de interes de Aave y Compound. La prima se calcula con la siguiente formula completa extraida del codigo Solidity:

```
Premium = Coverage x P_base x RiskMult x DurationDiscount x M(U) x (Duration / 365)
```

Donde:

- **Coverage**: monto asegurado en USDC
- **P_base**: tasa base anualizada del producto (ej: 15% para BCS, 20% para EAS, 2.5% para Depeg, 8.5% para IL, 4% para Exploit)
- **RiskMult**: multiplicador de riesgo por activo
- **DurationDiscount**: descuento por duracion larga
- **M(U)**: multiplicador de utilizacion (modelo kink)
- **Duration**: duracion de la poliza en dias

**Modelo Kink -- Multiplicador de Utilizacion M(U):**

El punto de inflexion (kink) se ubica en U_kink = 80%. Por debajo del kink, el multiplicador crece linealmente. Por encima, crece de forma agresiva para desincentivar la sobreutilizacion.

```
Si U <= U_kink (80%):
    M(U) = 1 + (U / U_kink) x 0.5

Si U > U_kink (80%):
    M(U) = 1 + 0.5 + ((U - 0.8) / (1 - 0.8)) x 3.0

U_MAX = 95% → se rechaza la poliza (no se puede comprar cobertura)
```

**Tabla de Multiplicadores por Nivel de Utilizacion:**

| Utilizacion (U) | Multiplicador M(U) | Efecto sobre la Prima         |
|------------------|---------------------|-------------------------------|
| 0%               | 1.00x               | Prima base                    |
| 20%              | 1.13x               | +13% sobre la prima base      |
| 40%              | 1.25x               | +25% sobre la prima base      |
| 60%              | 1.38x               | +38% sobre la prima base      |
| 80%              | 1.50x               | +50% (punto kink)             |
| 85%              | 2.25x               | +125% (zona agresiva)         |
| 90%              | 3.00x               | +200% (zona agresiva)         |
| 95%              | 3.75x               | RECHAZADO (U_MAX alcanzado)   |

Este modelo garantiza que cuando la capacidad del vault esta holgada, las primas son competitivas. A medida que la utilizacion se acerca al 80%, las primas suben gradualmente. Por encima del 80%, el crecimiento es exponencial, protegiendo a los LPs de sobreexposicion.

### 3.2 Flujo de Compra de Poliza

El humano, a traves de su agente de IA, inicia la compra de cobertura. El flujo completo on-chain es:

1. **Humano** instruye a su agente de IA con los parametros deseados
2. **Agente IA** llama a la API de Lumina para obtener cotizacion
3. **API** calcula la prima usando el modelo kink y devuelve los parametros
4. **Agente** aprueba USDC al CoverRouter y ejecuta `purchaseCover()`
5. **CoverRouter** (`0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`) valida parametros y rutea al Shield correcto
6. **Shield** (BCS/EAS/Depeg/IL/Exploit) valida reglas especificas del producto
7. **PolicyManager** (`0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a`) registra la poliza on-chain
8. **Vault** bloquea colateral 1:1 para respaldar la cobertura
9. **USDC** se transfiere del agente al vault (prima) y se cobra el 3% de fee

### 3.3 Flujo del Proveedor de Liquidez (LP)

El humano, a traves de su agente de IA, deposita USDC en uno de los cuatro vaults para ganar yield:

1. **Humano** decide depositar en un vault y lo comunica a su agente
2. **Agente** aprueba USDC y llama a `deposit()` en el vault seleccionado
3. **Vault** recibe el USDC y lo deposita en **Aave V3** (`0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`)
4. El LP recibe **shares soulbound** (no transferibles) proporcionales a su deposito
5. Las shares acumulan yield de dos fuentes: tasa base de Aave V3 (3-5% APY) + primas de seguro
6. Para retirar, el LP inicia un periodo de **cooldown** (30 a 365 dias segun el vault)
7. Tras el cooldown, el LP puede ejecutar `withdraw()` y recibir sus USDC + yield acumulado
8. **Se cobra un 3% de performance fee sobre el rendimiento positivo (ganancia) al retirar**

### 3.4 Tabla de Arquitectura de Contratos

| Contrato                | Tipo           | Proxy  | Dependencias                         | Direccion                                          |
|-------------------------|----------------|--------|--------------------------------------|----------------------------------------------------|
| CoverRouter             | Core           | UUPS   | Todos los Shields, PolicyManager     | `0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`       |
| PolicyManager           | Core           | UUPS   | Vaults, Shields                      | `0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a`       |
| LuminaOracle            | Oracle         | UUPS   | Chainlink feeds, Sequencer           | `0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87`       |
| LuminaPhalaVerifier     | Oracle         | UUPS   | Phala TEE network                    | `0x468b9D2E9043c80467B610bC290b698ae23adb9B`       |
| VolatileShort Vault     | Vault          | UUPS   | Aave V3, USDC                        | `0xbd44547581b92805aAECc40EB2809352b9b2880d`       |
| VolatileLong Vault      | Vault          | UUPS   | Aave V3, USDC                        | `0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904`       |
| StableShort Vault       | Vault          | UUPS   | Aave V3, USDC                        | `0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC`       |
| StableLong Vault        | Vault          | UUPS   | Aave V3, USDC                        | `0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c`       |
| BlackSwanShield (deprecated) | Producto  | UUPS   | Oracle, PolicyManager, VolatileShort | `0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e`       |
| DepegShield             | Producto       | UUPS   | Oracle, PolicyManager, StableShort   | `0x7578816a803d293bbb4dbea0efbed872842679d0`       |
| ILIndexCover            | Producto       | UUPS   | Oracle, PolicyManager, VolatileShort | `0x2ac0d2a9889a8a4143727a0240de3fed4650dd93`       |
| ExploitShield           | Producto       | UUPS   | Oracle, Phala TEE, PolicyManager     | `0x9870830c615d1b9c53dfee4136c4792de395b7a1`       |
| TimelockController      | Governance     | --     | Gnosis Safe                          | `0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a`       |

### 3.5 Colateralizacion Estricta 1:1

Cada poliza emitida en Lumina esta respaldada por colateral bloqueado 1:1 en el vault correspondiente. Esto significa que si un agente compra $50,000 de cobertura BCS o EAS, el vault bloquea exactamente $50,000 en USDC (depositados en Aave V3 como aUSDC) para garantizar el pago en caso de siniestro.

Este modelo elimina el riesgo de subcapitalizacion que afecta a otros protocolos de seguro DeFi que operan con modelos de pool compartido. Si la utilizacion del vault alcanza el 95% (U_MAX), no se aceptan nuevas polizas hasta que se libere capacidad.

---

## 4. PRODUCTOS DE SEGURO

### 4.1 BTC Catastrophe Shield (BCS) y ETH Apocalypse Shield (EAS)

**Descripcion:** El humano, a traves de su agente de IA, puede proteger sus posiciones en BTC y ETH contra caidas catastroficas del mercado. BCS cubre crasheos superiores al 50% en BTC como el vivido durante COVID (marzo 2020); eventos como LUNA (mayo 2022, BTC -42%) o FTX (noviembre 2022, BTC -26%) NO activan BCS porque las caidas de BTC fueron menores al 50%. EAS cubre crasheos superiores al 60% en ETH; solo un evento de esta magnitud ha ocurrido en los ultimos 8 anos (COVID, marzo 2020), cuando ETH cayo de $230 a $80 en 2 dias, y eventos como China (mayo 2021, ETH -56%) o LUNA (junio 2022, ETH -51%) NO activan EAS. Reemplazan al producto legacy Black Swan Shield (BSS, deprecated 2026-04-06).

**Parametros del contrato:**

| Parametro                | BCS — BTC Catastrophe Shield                              | EAS — ETH Apocalypse Shield                              |
|--------------------------|-----------------------------------------------------------|----------------------------------------------------------|
| Producto ID              | `BTCCAT-001`                                              | `ETHAPOC-001`                                            |
| Contrato                 | `0x36e37899D9D89bf367FA66da6e3CebC726Df4ce8`              | `0xA755D134a0b2758E9b397E11E7132a243f672A3D`             |
| Trigger                  | Caida > 50% desde el precio al momento de compra          | Caida > 60% desde el precio al momento de compra         |
| TRIGGER_DROP_BPS         | `5000` (50%)                                              | `6000` (60%)                                             |
| Verificacion             | TWAP 15 minutos o 3 rounds consecutivos de Chainlink      | TWAP 15 minutos o 3 rounds consecutivos de Chainlink     |
| Deducible                | 20%                                                       | 20%                                                      |
| Payout                   | Binario: 80% del coverage                                 | Binario: 80% del coverage                                |
| Duracion                 | 7 a 30 dias                                               | 7 a 30 dias                                              |
| Waiting period           | 1 hora                                                    | 1 hora                                                   |
| Assets cubiertos         | BTC unicamente                                            | ETH unicamente                                           |
| MAX_PROOF_AGE            | 30 minutos                                                | 30 minutos                                               |
| Tasa base                | 15% anualizado (1500 bps)                                 | 20% anualizado (2000 bps)                                |
| Max allocation por vault | 30%                                                       | 25%                                                      |
| Correlation cap          | VOLATILE_CRASH 40% combinado con EAS                      | VOLATILE_CRASH 40% combinado con BCS                     |
| Vault                    | VolatileShort + VolatileLong                              | VolatileShort + VolatileLong                             |

**Producto legacy (deprecated):** Black Swan Shield (BSS, `BLACKSWAN-001`,
`0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e`) — `setProductActive(false)`,
totalPolicies = 0, no acepta nuevas polizas.

**Circuit Breaker:**

El contrato implementa un mecanismo de circuit breaker para proteger al protocolo durante periodos de extrema volatilidad:

- Caida > 5% en 1 hora: la prima se multiplica por 1.5x
- Caida > 10% en 1 hora: se activa HALT -- no se aceptan nuevas polizas

**Ejemplo de pago:**

```
Cobertura: $50,000 en ETH (EAS — ETH Apocalypse Shield)
Precio al comprar: $2,000
Precio trigger: $2,000 x 0.40 = $800   (-60%)
ETH cae a $750 → Trigger activado
Payout bruto: $50,000 x 80% = $40,000
Fee protocolo (3%): $1,200
Payout neto al agente: $38,800
```

### 4.2 Depeg Shield

**Descripcion:** El humano, a traves de su agente de IA, puede proteger sus posiciones en stablecoins contra la perdida del peg. Depeg Shield cubre el escenario en que una stablecoin cae por debajo de $0.95, como ocurrio con USDC durante la crisis de SVB (marzo 2023, llego a $0.87).

**Parametros del contrato:**

| Parametro                | Valor                                                     |
|--------------------------|-----------------------------------------------------------|
| Producto ID              | `DEPEG-STABLE-001`                                        |
| Contrato                 | `0x7578816a803d293bbb4dbea0efbed872842679d0`              |
| Trigger                  | Precio stablecoin < $0.95                                 |
| TRIGGER_PRICE            | `95_000_000` (8 decimales Chainlink)                      |
| Verificacion             | TWAP 30 minutos o 5 rounds consecutivos                   |
| Duracion                 | 14 a 365 dias                                             |
| Waiting period           | 24 horas                                                  |
| Tasa base                | 2.5% anualizado (250 bps)                                 |
| Vault (corto)            | StableShort (`0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC`) |
| Vault (largo)            | StableLong (`0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c`)  |

**Deducibles y Payouts por Stablecoin:**

| Stablecoin | Deducible | Payout       | Payout Neto (post fee 3%) | Notas                         |
|------------|-----------|--------------|---------------------------|-------------------------------|
| DAI        | 12%       | 88% binario  | 85.36% del coverage       | MakerDAO, riesgo moderado     |
| USDT       | 15%       | 85% binario  | 82.45% del coverage       | Tether, riesgo centralizado   |
| USDC       | --        | EXCLUIDO     | --                        | Circular: Lumina liquida en USDC |

USDC esta excluido de la cobertura porque generaria una dependencia circular: si USDC pierde el peg, los pagos de Lumina (que se realizan en USDC) tambien perderian valor.

**Descuento por Duracion:**

| Rango de Duracion  | Factor de Descuento  | Efecto                          |
|--------------------|----------------------|---------------------------------|
| 14 - 90 dias       | 1.00x                | Sin descuento                   |
| 91 - 180 dias      | 0.90x                | 10% descuento en la prima       |
| 181 - 365 dias     | 0.80x                | 20% descuento en la prima       |

Los descuentos por duracion incentivan polizas de largo plazo, lo cual beneficia a los LPs al proporcionar flujos de primas mas predecibles.

### 4.3 IL Index Cover

**Descripcion:** El humano, a traves de su agente de IA, puede proteger sus posiciones de liquidity provider contra el impermanent loss. IL Index Cover utiliza la formula estandar de Uniswap V2 (50/50 pool) para calcular el IL de forma precisa y on-chain, con pago proporcional al IL sufrido.

**Parametros del contrato:**

| Parametro                | Valor                                                     |
|--------------------------|-----------------------------------------------------------|
| Producto ID              | `IL-INDEX-001`                                            |
| Contrato                 | `0x2ac0d2a9889a8a4143727a0240de3fed4650dd93`              |
| Trigger                  | IL > 2% al vencimiento de la poliza                       |
| Estilo                   | European-style (resolucion solo al vencimiento)           |
| Ventana de resolucion    | 48 horas post-vencimiento                                 |
| Deducible                | 2% (restable -- solo se cubre el IL por encima del 2%)    |
| Factor de payout         | 90%                                                       |
| Cap de IL                | 13% (payout maximo = 11.7% del coverage)                  |
| Duracion                 | 14 a 90 dias                                              |
| Vault                    | VolatileShort (`0xbd44547581b92805aAECc40EB2809352b9b2880d`) |

**Formula de Impermanent Loss (extraida de ILMath.sol):**

```solidity
// r = precioExpiry / precioPurchase
// IL = 1 - (2 * sqrt(r)) / (1 + r)

// Calculo del payout:
ilNet = max(0, IL% - 2%)                        // Deducible restable
rawPayout = coverage x ilNet x 0.90              // Factor de payout 90%
maxPayout = coverage x 13% x 0.90               // = 11.7% del coverage
payout = min(rawPayout, maxPayout)
```

El payout es proporcional: cuanto mayor sea el IL neto (despues del deducible), mayor sera el pago, hasta alcanzar el cap del 11.7% del coverage.

**Tabla de Referencia de Impermanent Loss (ILMath.sol):**

| Cambio de Precio | Price Ratio    | IL Bruto | IL Neto (2% ded) | Payout ($50K, 90%) |
|------------------|----------------|----------|-------------------|---------------------|
| +/-10%           | 0.90 / 1.10    | 0.14%    | 0%                | $0                  |
| +/-20%           | 0.80 / 1.20    | 0.56%    | 0%                | $0                  |
| +/-22%           | 0.78 / 1.22    | 0.68%    | 0%                | $0                  |
| +/-25%           | 0.75 / 1.25    | 1.03%    | 0%                | $0                  |
| +/-30%           | 0.70 / 1.30    | 1.57%    | 0%                | $0                  |
| +/-35%           | 0.65 / 1.35    | 2.22%    | 0.22%             | $99                 |
| +/-40%           | 0.60 / 1.40    | 3.02%    | 1.02%             | $459                |
| +/-50%           | 0.50 / 1.50    | 5.72%    | 3.72%             | $1,674              |
| +/-60%           | 0.40 / 1.60    | 9.27%    | 7.27%             | $3,272              |
| +/-75%           | 0.25 / 1.75    | 18.35%   | 13%+ (capped)     | $5,850 (max)        |
| +/-80%           | 0.20 / 1.80    | 22.54%   | 13%+ (capped)     | $5,850 (max)        |

El payout maximo absoluto es **$5,850** por cada **$50,000** de cobertura (11.7% del coverage). El IL es simetrico: una subida del 50% y una caida del 50% producen el mismo IL (5.72%).

### 4.4 Exploit Shield

**Descripcion:** El humano, a traves de su agente de IA, puede proteger sus depositos en protocolos DeFi contra exploits, hacks y vulnerabilidades de smart contracts. Exploit Shield utiliza un sistema de dual trigger para minimizar falsos positivos.

**Parametros del contrato:**

| Parametro                | Valor                                                     |
|--------------------------|-----------------------------------------------------------|
| Producto ID              | `EXPLOIT-SHIELD-001`                                      |
| Contrato                 | `0x9870830c615d1b9c53dfee4136c4792de395b7a1`              |
| Trigger dual             | (1) Token de gobernanza -25% en 24h AND (2) Receipt token -30% por 4h O contrato pausado |
| Verificacion             | Oracle (Chainlink) + Phala TEE                            |
| Deducible                | 10%                                                       |
| Payout                   | Binario: 90% del coverage                                 |
| Cap por wallet           | $50,000                                                   |
| Lifetime cap por wallet  | $150,000                                                  |
| Duracion                 | 90 a 365 dias                                             |
| Waiting period           | 14 dias                                                   |
| Vault                    | StableLong (`0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c`)  |

**Sistema de Dual Trigger:**

El dual trigger requiere que **ambas condiciones** se cumplan simultaneamente:

1. **Trigger primario (Oracle):** El token de gobernanza del protocolo cubierto debe haber caido al menos un 25% en las ultimas 24 horas, verificado por Chainlink.

2. **Trigger secundario (TEE):** Al menos una de estas condiciones: (a) el receipt token del protocolo ha caido un 30% o mas durante al menos 4 horas consecutivas, o (b) el contrato principal del protocolo ha sido pausado.

La verificacion del trigger secundario la realiza el **Phala TEE** (Trusted Execution Environment) en `0x468b9D2E9043c80467B610bC290b698ae23adb9B`, lo que proporciona una capa adicional de seguridad contra manipulacion de oracles.

**Protocolos Cubiertos:**

| Protocolo       | Tier    | Tasa Base | Notas                                   |
|-----------------|---------|-----------|------------------------------------------|
| Compound III    | Tier 1  | Menor     | Auditado extensamente, bajo riesgo       |
| Uniswap V3      | Tier 1  | Menor     | Inmutable, bajo riesgo                   |
| MakerDAO        | Tier 1  | Menor     | Gobernanza robusta                       |
| Curve            | Tier 2  | Mayor     | Complejidad mayor, riesgo moderado       |
| Morpho           | Tier 2  | Mayor     | Protocolo mas nuevo, riesgo moderado     |
| Aave V3          | --      | EXCLUIDO  | Circular: Lumina deposita en Aave V3     |

Aave V3 esta excluido porque Lumina deposita los fondos de los vaults en Aave V3 para generar yield. Cubrir un exploit de Aave V3 crearia una dependencia circular: si Aave V3 es hackeado, los fondos para pagar el siniestro estarian comprometidos.

---

## 5. VAULTS Y YIELD

### 5.1 Los Cuatro Vaults

Lumina opera con cuatro vaults especializados, cada uno con un periodo de cooldown diferente y productos de seguro asignados:

| Vault                | Cooldown | Productos Asignados             | APY Estimado | Direccion                                          |
|----------------------|----------|---------------------------------|--------------|-----------------------------------------------------|
| **VolatileShort**    | 30 dias  | BSS + IL Index Cover            | 12 - 16%     | `0xbd44547581b92805aAECc40EB2809352b9b2880d`       |
| **VolatileLong**     | 90 dias  | IL largo + BSS overflow         | 15 - 19%     | `0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904`       |
| **StableShort**      | 90 dias  | Depeg corto                     | 11 - 15%     | `0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC`       |
| **StableLong**       | 365 dias | Depeg largo + Exploit Shield    | 18 - 27%     | `0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c`       |

Los vaults con cooldowns mas largos ofrecen mayor APY estimado porque asumen mayor riesgo (polizas de mayor duracion, eventos menos frecuentes pero de mayor impacto).

### 5.2 Composicion del Yield

El yield que reciben los LPs proviene de dos fuentes:

1. **Yield base de Aave V3 (3-5% APY):** Los USDC depositados en los vaults se depositan automaticamente en Aave V3 Pool (`0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`), generando yield pasivo en forma de aUSDC (`0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB`).

2. **Primas de seguro:** Cuando un agente compra una poliza, el 97% de la prima (despues del 3% de fee del protocolo) se distribuye al vault correspondiente, incrementando el valor de las shares de los LPs.

### 5.3 Shares Soulbound (No Transferibles)

Las shares de los vaults de Lumina son **soulbound**: no pueden transferirse, venderse ni utilizarse como colateral en otros protocolos. Esta decision de diseno previene:

- La creacion de mercados secundarios de shares que podrian desestabilizar los vaults
- El uso de shares como colateral en protocolos de lending, creando riesgo sistemico
- La fragmentacion de la liquidez entre multiples holders

El LP solo puede interactuar con sus shares a traves de `deposit()` y `withdraw()` (tras el cooldown).

### 5.4 Waterfall de Prioridad

En el improbable caso de que multiples siniestros ocurran simultaneamente y la liquidez de un vault sea insuficiente, se aplica un sistema de waterfall. Los vaults con cooldown mas corto tienen prioridad de pago, ya que sus LPs asumieron el compromiso de menor duracion.

Orden de prioridad: VolatileShort (30d) > StableShort (90d) = VolatileLong (90d) > StableLong (365d).

### 5.5 Productos Futuros

Se han disenado tres productos adicionales para futuras versiones del protocolo:

- **Gas Spike Shield:** Proteccion contra picos extremos de gas que podrian impedir a un agente ejecutar operaciones criticas a tiempo.
- **Slippage Shield:** Cobertura contra slippage excesivo en ejecucion de trades grandes, especialmente relevante para agentes que manejan ordenes de gran tamano.
- **Bridge Shield:** Proteccion contra fallos o exploits en bridges cross-chain, cubriendo fondos en transito entre cadenas.

---

## 6. ORACLE Y VERIFICACION

### 6.1 LuminaOracle

El contrato LuminaOracle (`0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87`) es el componente central de verificacion de datos del protocolo. Opera con un esquema multisig N-of-M que puede expandirse segun las necesidades de descentralizacion.

Actualmente opera en modo 1-of-1 (expandible a N-of-M). El oracle verifica los feeds de Chainlink, implementa un chequeo de sequencer de 1 hora para Base L2, y valida la frescura de los datos antes de aceptarlos como input para triggers.

### 6.2 Tabla de Feeds de Chainlink

| Feed           | Direccion                                          | Staleness    | Productos que lo usan          |
|----------------|-----------------------------------------------------|--------------|--------------------------------|
| ETH/USD        | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70`       | 1,200s (20m) | BSS, IL Index Cover            |
| BTC/USD        | `0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E`       | 1,200s (20m) | BSS                            |
| USDC/USD       | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B`       | 86,400s (24h)| Referencia interna             |
| USDT/USD       | `0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9`       | 86,400s (24h)| Depeg Shield                   |
| DAI/USD        | `0x591e79239a7d679378eC8c847e5038150364C78F`       | 86,400s (24h)| Depeg Shield                   |

Los feeds de assets volatiles (ETH, BTC) tienen un staleness de 20 minutos, mientras que los feeds de stablecoins tienen un staleness de 24 horas, reflejando la menor volatilidad esperada.

### 6.3 Verificacion Multisig: verifyPackedMultisig

El sistema de verificacion de firmas utiliza un esquema de firmas concatenadas ordenadas por address. Cada firmante autorizado produce una firma ECDSA sobre los datos del oracle, y las firmas se concatenan en orden ascendente de address del firmante.

```
Firmas = firma_signer1 ++ firma_signer2 ++ ... ++ firma_signerN
(donde address(signer1) < address(signer2) < ... < address(signerN))
```

La funcion `verifyPackedMultisig` deserializa las firmas, verifica que cada una proviene de un firmante autorizado, que estan en orden correcto (para prevenir duplicados), y que se alcanza el umbral N-of-M requerido.

### 6.4 Phala TEE para Exploit Shield

El contrato LuminaPhalaVerifier (`0x468b9D2E9043c80467B610bC290b698ae23adb9B`) utiliza Phala Network como Trusted Execution Environment para verificar el trigger secundario de Exploit Shield. El TEE ejecuta logica de verificacion en un entorno aislado y tamper-proof, proporcionando una capa de seguridad independiente del oracle principal.

Esto es critico para Exploit Shield porque los exploits pueden involucrar manipulacion de oracles. Al usar un TEE independiente, Lumina garantiza que la verificacion del trigger no puede ser comprometida por el mismo vector de ataque que causo el exploit.

---

## 7. MODELO DE NEGOCIO

### 7.1 Monetizacion

Lumina Protocol genera ingresos a traves de un modelo de comision dual, simple y transparente:

| Evento                        | Fee      | Descripcion                                         |
|-------------------------------|----------|------------------------------------------------------|
| Compra de poliza (premium)    | 3%       | El 3% de la prima va al protocolo, el 97% al vault  |
| Pago de siniestro (payout)    | 3%       | El 3% del payout va al protocolo, el 97% al agente  |
| Retiro de vault (withdrawal)  | **3% performance** | Sobre el rendimiento positivo (ganancia sobre el deposito original) |

### 7.2 Fee Receiver

Todos los fees del protocolo se envian a la direccion:

```
Protocol Fee Receiver: 0x2b4D825417f568231e809E31B9332ED146760337
```

Esta direccion es controlada por el TimelockController con un delay de 48 horas, lo que asegura transparencia y capacidad de auditoria.

### 7.3 Performance Fee en Retiros de Vault

Se cobra un 3% de performance fee unicamente sobre el rendimiento positivo (ganancia) al retirar fondos de los vaults. El fee se calcula sobre la diferencia entre el monto retirado y el cost basis (deposito original). Si no hay ganancia, no se cobra fee alguno.

**Ejemplo:** Un LP deposita $10,000 USDC. Tras acumular yield, retira $10,500 USDC. La ganancia es $500 ($10,500 - $10,000). El performance fee es 3% x $500 = $15. El LP recibe neto $10,485.

Esta estructura alinea los incentivos del protocolo con los de los LPs: Lumina solo cobra cuando el LP efectivamente gana dinero.

### 7.4 Escalabilidad del Modelo

El modelo de negocio de Lumina es inherentemente escalable:

- **Mas LPs** depositan en los vaults, aumentando la capacidad total de cobertura
- **Mas capacidad** permite emitir mas polizas y cubrir mas agentes
- **Mas polizas** generan mas primas, lo que incrementa el yield para los LPs
- **Mayor yield** atrae a mas LPs, cerrando el ciclo virtuoso

Este flywheel se refuerza con cada nuevo participante, creando un efecto de red positivo.

---

## 8. SEGURIDAD

### 8.1 Smart Contracts

Los 13 contratos del protocolo han sido desarrollados con las mejores practicas de seguridad de Solidity:

- **Solidity 0.8.20:** Overflow/underflow checking nativo
- **Patron CEI (Checks-Effects-Interactions):** Todas las funciones criticas siguen este patron
- **SafeERC20:** Todas las transferencias de USDC utilizan la libreria SafeERC20 de OpenZeppelin
- **ReentrancyGuard:** Proteccion contra ataques de reentrancia en todas las funciones que mueven fondos
- **119 tests:** Suite completa de tests unitarios y de integracion

### 8.2 Governance

La gobernanza del protocolo implementa un modelo de seguridad en capas:

- **TimelockController** (`0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a`): Delay de 48 horas para todas las operaciones administrativas. Cualquier cambio en parametros criticos requiere un periodo de espera que permite a los LPs reaccionar.
- **Gnosis Safe 2-of-3** (`0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD`): Las transacciones administrativas requieren la firma de al menos 2 de 3 signatarios autorizados.

### 8.3 API y Backend

La API que conecta a los agentes de IA con los contratos implementa:

- **Rate limiting:** Control de frecuencia de requests para prevenir abuso
- **CORS:** Configuracion estricta de origenes permitidos
- **Helmet:** Headers de seguridad HTTP
- **NonceManager:** Gestion de nonces para prevenir replay attacks y garantizar la secuencialidad de transacciones

### 8.4 Oracle

La seguridad del oracle se basa en tres capas:

- **Multisig:** Verificacion N-of-M de firmas para datos de oracle
- **Chainlink TWAP:** Uso de precios promedio ponderados por tiempo, no precios spot
- **Sequencer check:** Verificacion de que el sequencer de Base L2 ha estado activo durante al menos 1 hora antes de aceptar datos de oracle

### 8.5 Session Approval

Para compras realizadas a traves de relayers, el protocolo requiere **session approval**: el comprador (buyer) debe firmar un consentimiento explicito que autoriza al relayer a ejecutar la compra en su nombre. Esto previene que un relayer compre polizas no autorizadas con fondos del usuario.

### 8.6 Integracion OWS

Lumina integra el estandar OWS (Open Wallet Standard) para facilitar la interaccion segura entre agentes de IA y wallets. Esta integracion permite que los agentes operen con permisos granulares y revocables, sin necesidad de exponer claves privadas.

---

## 9. DATOS ACTUARIALES

### 9.1 Black Swan Shield -- Expected Value para LPs

| Metrica                      | Valor                  |
|------------------------------|------------------------|
| Primas estimadas anuales     | ~$54,000               |
| Siniestros estimados anuales | ~$34,000               |
| Ganancia neta anual          | +$20,000               |
| Margen                       | 38%                    |

El margen del 38% refleja la naturaleza de cola gruesa del riesgo BSS: los eventos de cisne negro son poco frecuentes pero severos. En anos sin eventos, el margen es significativamente mayor. En anos con multiples eventos, el margen puede ser negativo.

### 9.2 Depeg Shield -- Expected Value para LPs

| Metrica                      | Valor                  |
|------------------------------|------------------------|
| Primas estimadas anuales     | ~$85,000               |
| Siniestros estimados anuales | ~$32,000               |
| Ganancia neta anual          | +$52,000               |
| Margen                       | 62%                    |

Depeg Shield presenta el mayor volumen de primas y un margen saludable del 62%. Los eventos de depeg son raros (1-2 veces por decada para stablecoins mayores) pero cuando ocurren son sistemicos.

### 9.3 IL Index Cover -- Expected Value para LPs

| Metrica                      | Valor                  |
|------------------------------|------------------------|
| Primas estimadas anuales     | Calculadas por modelo  |
| Ganancia neta anual          | +$37,000               |
| Margen                       | 60%                    |

El modelo de payout proporcional de IL Index Cover y el deducible del 2% crean un margen favorable. La mayoria de las polizas expiran con IL inferior al 2%, generando primas sin siniestro.

### 9.4 Exploit Shield -- Expected Value para LPs

| Metrica                      | Valor                  |
|------------------------------|------------------------|
| Primas estimadas anuales     | Calculadas por modelo  |
| Ganancia neta anual          | +$2,000                |
| Margen                       | 65%                    |

Exploit Shield tiene el menor volumen absoluto pero el mayor margen porcentual. El dual trigger, el waiting period de 14 dias y el cap de $50,000 por wallet y el lifetime cap de $150,000 por wallet limitan significativamente la exposicion.

### 9.5 Peor Escenario Sistemico

| Metrica                            | Valor                  |
|------------------------------------|------------------------|
| Perdida maxima estimada            | -$438,000              |
| Porcentaje del TVL total ($2M)     | -21.9%                 |
| Tiempo estimado de recuperacion    | 10-12 meses            |

Un escenario sistemico (crash de mercado + depeg + exploit simultaneos) podria generar una perdida del 21.9% del TVL. La recuperacion se proyecta en 10-12 meses a traves de la acumulacion de primas. Este escenario es extremadamente improbable dado los grupos de correlacion independientes entre productos.

---

## 10. RIESGOS

| Riesgo                         | Probabilidad | Impacto  | Mitigacion                                                                          |
|--------------------------------|--------------|----------|--------------------------------------------------------------------------------------|
| Bug en smart contract          | Baja         | Critico  | 119 tests, CEI, ReentrancyGuard, Solidity 0.8.20, proxies UUPS para upgrades         |
| Manipulacion de oracle         | Baja         | Alto     | TWAP (no precio spot), multisig, sequencer check 1h, MAX_PROOF_AGE 30min            |
| Flash loan attack              | Baja         | Alto     | TWAP multiples rounds, colateral 1:1, no dependencia de precios spot                |
| Sequencer de Base L2 offline   | Media        | Medio    | Sequencer check de 1 hora, polizas no expiran durante downtime                      |
| Precio stale en Chainlink      | Media        | Medio    | Staleness checks por feed (1200s volatiles, 86400s stables), rechazo automatico     |
| Subcapitalizacion del vault    | Muy Baja     | Critico  | Colateral 1:1, U_MAX 95%, rechazo automatico de nuevas polizas al alcanzar limite   |
| Exploit de Aave V3             | Muy Baja     | Critico  | Riesgo aceptado; Aave V3 es el protocolo DeFi mas auditado; no se cubre (circular)  |
| Depeg de USDC                  | Muy Baja     | Critico  | Riesgo de denominacion aceptado; no se cubre USDC (circular)                        |
| Caida simultanea multiple      | Muy Baja     | Alto     | Vaults segregados por tipo de riesgo, waterfall de prioridad, grupos de correlacion  |
| Ataque de gobernanza           | Muy Baja     | Critico  | TimelockController 48h + Gnosis Safe 2-of-3, delay permite reaccion de la comunidad |

---

## 11. ROADMAP

### Fase 1 -- Lanzamiento (Actual, Q1 2026)

- 4 productos de seguro operativos: BSS, Depeg, IL Index, Exploit
- 4 vaults de liquidez con yield Aave V3
- Despliegue en Base L2 (Chain 8453)
- 13 contratos en produccion con proxies UUPS
- Oracle con Chainlink feeds y soporte Phala TEE
- API para agentes de IA
- Gobernanza via TimelockController + Gnosis Safe

### Fase 2 -- Expansion de Productos (Q2-Q3 2026)

- **Gas Spike Shield:** Proteccion contra picos extremos de gas
- **Slippage Shield:** Cobertura contra slippage excesivo en trades
- **Bridge Shield:** Proteccion contra fallos de bridges cross-chain
- Nuevos vaults dedicados para productos de Fase 2
- Expansion de protocolos cubiertos en Exploit Shield

### Fase 3 -- Mercado Secundario y Token (Q4 2026 - Q1 2027)

- **Mercado secundario de polizas (NFT marketplace):** Las polizas activas podran tokenizarse como NFTs y venderse en un marketplace dedicado, permitiendo a los agentes transferir coberturas.
- **Token nativo:** Lanzamiento de un token de utilidad y gobernanza para el protocolo, con funciones de staking, votacion y descuentos en primas.

### Fase 4 -- DAO y Multi-Chain (Q2-Q4 2027)

- **DAO governance:** Transicion completa a gobernanza descentralizada por holders del token nativo, reemplazando el modelo Gnosis Safe.
- **Cross-chain:** Expansion a Arbitrum y Optimism, permitiendo cobertura de activos y protocolos en multiples L2s.
- Integracion con protocolos de comunicacion cross-chain para settlement unificado.

---

## 12. MARCO LEGAL

### 12.1 Estructura del Protocolo

Lumina Protocol opera como un protocolo descentralizado desplegado en Base L2 (Chain 8453). Los contratos inteligentes son inmutables en su logica core, con capacidad de upgrade a traves de proxies UUPS controlados por un TimelockController con delay de 48 horas y una Gnosis Safe 2-of-3.

El protocolo no custodia fondos de usuarios. Los depositos de LPs se mantienen en Aave V3, y los pagos de siniestros se ejecutan directamente desde los vaults a las wallets de los agentes. El protocolo solo cobra fees como intermediario.

### 12.2 Naturaleza del Producto

Lumina ofrece productos de proteccion parametrica basados en triggers matematicos verificables on-chain. Los productos de Lumina no constituyen seguros en el sentido regulatorio tradicional: no requieren licencia de aseguradora, no involucran evaluacion subjetiva de reclamos y no dependen de procesos judiciales para la resolucion de disputas.

Los pagos son automaticos, deterministas y verificables por cualquier tercero que inspeccione la blockchain.

### 12.3 Riesgos Regulatorios

El panorama regulatorio de DeFi continua evolucionando. Existen riesgos de que jurisdicciones futuras clasifiquen los productos parametricos on-chain como productos de seguros regulados, lo que podria requerir licencias, cumplimiento normativo adicional o restricciones geograficas.

El equipo monitorea activamente los desarrollos regulatorios en las principales jurisdicciones (EE.UU., UE, Reino Unido, Singapur) y esta preparado para adaptar la estructura del protocolo segun sea necesario.

### 12.4 Disclaimer

ESTE DOCUMENTO ES EXCLUSIVAMENTE INFORMATIVO Y NO CONSTITUYE ASESORAMIENTO FINANCIERO, LEGAL NI DE INVERSION. La participacion en Lumina Protocol, ya sea como comprador de cobertura o como proveedor de liquidez, implica riesgos significativos incluyendo pero no limitados a: perdida total del capital depositado, riesgos de smart contract, riesgos de oracle, riesgo regulatorio y riesgo de mercado.

Los rendimientos estimados (APY) son proyecciones basadas en modelos actuariales y condiciones de mercado historicas. No constituyen garantia de rendimiento futuro. Los participantes deben realizar su propia diligencia debida y consultar con asesores profesionales antes de interactuar con el protocolo.

Lumina Protocol se proporciona "tal cual" (AS-IS) sin garantias de ningun tipo, expresas o implicitas.

---

## 13. DIRECCIONES DE PRODUCCION

**Red:** Base L2 (Chain 8453) | **Fecha de despliegue:** 29 de marzo de 2026

### Governance

| Contrato               | Direccion                                          |
|------------------------|-----------------------------------------------------|
| TimelockController     | `0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a`       |
| Gnosis Safe (2-of-3)   | `0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD`       |

### Core

| Contrato               | Direccion                                          |
|------------------------|-----------------------------------------------------|
| CoverRouter            | `0xd5f8678A0F2149B6342F9014CCe6d743234Ca025`       |
| PolicyManager          | `0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a`       |
| LuminaOracle           | `0x4d1140ac8f8cb9d4fb4f16cae9c9cba13c44bc87`       |
| LuminaPhalaVerifier    | `0x468b9D2E9043c80467B610bC290b698ae23adb9B`       |

### Vaults

| Vault                  | Cooldown  | Direccion                                          |
|------------------------|-----------|-----------------------------------------------------|
| VolatileShort          | 30 dias   | `0xbd44547581b92805aAECc40EB2809352b9b2880d`       |
| VolatileLong           | 90 dias   | `0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904`       |
| StableShort            | 90 dias   | `0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC`       |
| StableLong             | 365 dias  | `0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c`       |

### Shields (Productos)

| Shield                 | Direccion                                          |
|------------------------|-----------------------------------------------------|
| BlackSwanShield (BSS, deprecated) | `0x54CDc21DEDA49841513a6a4A903dc0A0a9e7844e` |
| BTCCatastropheShield (BCS) | `0x36e37899D9D89bf367FA66da6e3CebC726Df4ce8`       |
| ETHApocalypseShield (EAS) | `0xA755D134a0b2758E9b397E11E7132a243f672A3D`        |
| DepegShield            | `0x7578816a803d293bbb4dbea0efbed872842679d0`       |
| ILIndexCover           | `0x2ac0d2a9889a8a4143727a0240de3fed4650dd93`       |
| ExploitShield          | `0x9870830c615d1b9c53dfee4136c4792de395b7a1`       |

### Contratos Externos

| Contrato               | Direccion                                          |
|------------------------|-----------------------------------------------------|
| USDC (Circle)          | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`       |
| Aave V3 Pool           | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5`       |
| aUSDC (Aave)           | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB`       |
| Protocol Fee Receiver  | `0x2b4D825417f568231e809E31B9332ED146760337`       |

### Claves Operativas

| Rol                    | Direccion                                          |
|------------------------|-----------------------------------------------------|
| Deployer / Owner       | `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8`       |
| Oracle Signer          | `0x933b15dd4F42bd2EE2794C1D188882aBCCDa977E`       |
| Relayer                | `0xEdA7774A071a8DDa0c8c98037Cb542A1ee6aC7Eb`       |

### Chainlink Feeds

| Feed                   | Direccion                                          | Staleness     |
|------------------------|-----------------------------------------------------|---------------|
| ETH/USD                | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70`       | 1,200s (20m)  |
| BTC/USD                | `0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E`       | 1,200s (20m)  |
| USDC/USD               | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B`       | 86,400s (24h) |
| USDT/USD               | `0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9`       | 86,400s (24h) |
| DAI/USD                | `0x591e79239a7d679378eC8c847e5038150364C78F`       | 86,400s (24h) |

---

## 14. GRUPOS DE CORRELACION

Los productos de Lumina estan disenados para cubrir riesgos con baja correlacion entre si, limitando la posibilidad de siniestros simultaneos:

| Grupo de Correlacion     | Productos Afectados              | Trigger                                       | Probabilidad Conjunta |
|--------------------------|----------------------------------|------------------------------------------------|------------------------|
| **Crash de ETH/BTC**     | BSS, IL Index Cover              | Caida >30% en activos volatiles                | Media                  |
| **Crisis de stablecoin** | Depeg Shield                     | Depeg de DAI o USDT por debajo de $0.95        | Baja                   |
| **Exploit de protocolo** | Exploit Shield                   | Hack o vulnerabilidad en protocolo cubierto    | Baja                   |
| **Evento sistemico**     | BSS + Depeg + IL + Exploit       | Colapso del ecosistema DeFi completo           | Muy Baja               |

**Analisis de correlacion:**

- **BSS e IL Index Cover** tienen correlacion alta: un crash de mercado activa BSS y simultaneamente genera IL significativo. Por esta razon, ambos comparten el vault VolatileShort.

- **Depeg Shield** tiene correlacion baja con los productos de volatilidad. Un depeg de stablecoin puede ocurrir independientemente de la direccion del mercado (ej: crisis bancaria, riesgo regulatorio de Tether).

- **Exploit Shield** tiene correlacion baja con todos los demas productos. Los hacks de protocolos son eventos idiosincraticos que no dependen de condiciones de mercado.

- **Evento sistemico** (todos los triggers simultaneos) es el escenario de peor caso. La segregacion de vaults por tipo de riesgo y el sistema de waterfall mitigan parcialmente este riesgo. La perdida maxima estimada es de -21.9% del TVL ($438K de $2M).

---

## 15. API Y AGENTES

### 15.1 Descripcion General

El humano, a traves de su agente de IA, interactua con Lumina Protocol a traves de una API REST que expone las funcionalidades core del protocolo. La API permite cotizar, comprar polizas, consultar estado y verificar triggers sin necesidad de interactuar directamente con los contratos.

**Endpoints principales:**

| Endpoint                    | Metodo | Descripcion                                          |
|-----------------------------|--------|-------------------------------------------------------|
| `/quote`                    | POST   | Obtener cotizacion para una poliza                    |
| `/purchase`                 | POST   | Ejecutar compra de poliza via relayer                 |
| `/policy/:id`               | GET    | Consultar estado de una poliza                        |
| `/vault/:name/stats`        | GET    | Obtener estadisticas del vault                        |
| `/vault/:name/deposit`      | POST   | Depositar USDC en un vault                            |
| `/vault/:name/withdraw`     | POST   | Iniciar retiro de un vault                            |
| `/oracle/price/:asset`      | GET    | Consultar precio actual de un activo                  |

### 15.2 Referencia SKILL

La documentacion completa de la API y las instrucciones para configurar agentes se encuentran en el archivo SKILL del protocolo: `docs/SKILL-lumina-v2.md` (Version 2.3, Marzo 2026).

El archivo SKILL contiene:

- Descripcion detallada de cada producto con parametros, ejemplos y tablas de pricing
- Instrucciones paso a paso para que un agente compre cobertura
- Instrucciones para depositar y retirar como LP
- Parametros de cada vault y sus APYs estimados
- Informacion de fees y como planificar coberturas considerando el fee del 3%

### 15.3 Flujo de Setup de un Agente

1. El humano configura su agente con la URL de la API de Lumina y las credenciales de su wallet
2. El agente consulta `/quote` con los parametros deseados (producto, activo, monto, duracion)
3. El agente evalua la cotizacion y decide si procede
4. El agente aprueba USDC al CoverRouter via `approve()`
5. El agente ejecuta `/purchase` o llama directamente a `CoverRouter.purchaseCover()`
6. La poliza queda registrada on-chain en el PolicyManager
7. El agente puede monitorear el estado de su poliza via `/policy/:id`

---

## 16. CONCLUSION

Lumina Protocol representa la primera infraestructura de seguro parametrico disenada exclusivamente para la economia agentica. Al combinar triggers matematicos verificables, oracles descentralizados, colateralizacion estricta 1:1 y yield generado a traves de Aave V3, el protocolo ofrece una solucion completa para los riesgos criticos que enfrentan los agentes de IA en DeFi.

**Fortalezas principales del protocolo:**

- **Parametrico puro:** Sin reclamos subjetivos, sin votaciones, sin esperas. El trigger se activa y el pago es inmediato.
- **Disenado para agentes:** API programatica, session approval para relayers, integracion OWS, documentacion SKILL.
- **Colateral 1:1:** Cada poliza esta respaldada al 100% por USDC real bloqueado en el vault. Sin riesgo de subcapitalizacion.
- **Yield real:** Los LPs ganan yield compuesto de Aave V3 + primas de seguro, con APYs estimados del 11-27%.
- **Seguridad en capas:** Solidity 0.8.20, ReentrancyGuard, CEI, TimelockController 48h, Gnosis Safe 2-of-3, TWAP, sequencer check.
- **Modelo de negocio transparente:** 3% premium + 3% payout. Sin fees ocultos. Performance fee del 3% sobre rendimiento positivo en retiros de vault.

**Vision:**

Lumina aspira a convertirse en la infraestructura de seguro estandar para la economia agentica. A medida que millones de agentes de IA gestionen billones de dolares en activos DeFi, la necesidad de cobertura programatica, instantanea y confiable sera tan fundamental como lo es hoy la infraestructura de lending y trading.

Con el roadmap hacia productos adicionales (Gas Spike, Slippage, Bridge Shield), un marketplace de polizas NFT, token nativo y gobernanza DAO, Lumina se posiciona como el protocolo de referencia en seguro descentralizado para la nueva generacion de participantes autonomos del ecosistema DeFi.

---

*Lumina Protocol -- Seguro parametrico para la economia agentica*

*Base L2 | USDC | Aave V3 | 2026*
