# LUMINA PROTOCOL — TOKEN + MARKETPLACE + EXIT ENGINE (V2)
## Documento de Diseño — Versión Corregida para Análisis

---

## CONTEXTO

Lumina Protocol es un protocolo de seguros paramétricos DeFi para agentes de IA desplegado en Base L2 (chain 8453). Settlement en USDC. 5 productos de seguro activos. 4 vaults para LPs. API REST para agentes de IA. Relayer automático.

El protocolo está en mainnet y operativo. Este documento diseña el ecosistema económico: token nativo $LUMINA, marketplace secundario de PolicyNFTs y VaultShareNFTs, y Exit Engine para salida anticipada de LPs.

**Principio fundamental:** El marketplace es un layer SOBRE el protocolo de seguros. Si el marketplace se cae, los seguros siguen funcionando. Los dos mercados se auto-regulan simultáneamente pero nunca se bloquean mutuamente.

---

## PARTE 1 — TOKEN $LUMINA

### 1.1 — Especificaciones base

```
Nombre:     Lumina Protocol
Símbolo:    LUMINA
Decimales:  18
Blockchain: Base L2 (chain 8453)
Estándar:   ERC-20 (OpenZeppelin)
Max Supply: 100,000,000 LUMINA (100 millones) — CAP FIJO, INMUTABLE
```

### 1.2 — Distribución

```
MAX SUPPLY: 100,000,000 LUMINA

| Categoría                              | %   | Tokens      | Liberación                    |
|----------------------------------------|-----|-------------|-------------------------------|
| Venta pública (incluye preventas)      | 30% | 30,000,000  | BLOQUEADO hasta alt season *  |
| Team allocation                        | 15% | 15,000,000  | BLOQUEADO hasta alt season *  |
| Tesorería                              | 10% | 10,000,000  | LIBRE desde día 1 **         |
| Ecosistema, grants, marketing, advisors| 25% | 25,000,000  | BLOQUEADO hasta alt season *  |
| Reserva Exit Engine                    | 10% | 10,000,000  | LIBRE desde día 1 ***        |
| Desarrolladores técnicos               | 5%  | 5,000,000   | BLOQUEADO hasta alt season *  |
| Libre disponibilidad                   | 5%  | 5,000,000   | BLOQUEADO hasta alt season *  |

NO hay airdrop.

* BLOQUEADO: estos tokens existen en el contrato pero NO se pueden 
  transferir hasta que el oráculo confirme paramátricamente que estamos 
  en alt season. Una vez confirmado, se liberan en 3 pagos iguales 
  cada 3 meses (mes 0, mes 3, mes 6).

** TESORERÍA (10%): liberada desde el día 1 para que el protocolo pueda 
   operar el Exit Engine (comprar vaults), proveer liquidez inicial al 
   pool LUMINA/USDC, y cubrir costos operativos.

*** RESERVA EXIT ENGINE (10%): liberada desde el día 1, controlada por 
    el contrato ExitEngine. Se usa exclusivamente para pagar LPs que 
    activan el Exit Engine. No se puede usar para otro propósito.
```

### 1.3 — Oráculo de Alt Season (Release Oracle)

Los tokens bloqueados (80% del supply) solo se liberan cuando el oráculo confirma paramátricamente que estamos en una alt season. Esto protege a los holders de dumping en mercado bajista.

**Indicador 1 — ETH/BTC Ratio:**
```
ETH/BTC > 0.050  →  condición 1 ACTIVA
ETH/BTC < 0.040  →  condición 1 NO ACTIVA

Fuente: Chainlink ETH/BTC feed (si existe en Base) o cálculo 
        ETH/USD ÷ BTC/USD usando los feeds existentes en LuminaOracleV2.

Lógica on-chain:
  int256 ethPrice = oracleV2.getLatestPrice("ETH");  // 8 decimals
  int256 btcPrice = oracleV2.getLatestPrice("BTC");  // 8 decimals
  uint256 ethBtcRatio = uint256(ethPrice) * 1e18 / uint256(btcPrice);
  // ethBtcRatio > 0.050e18 → condición 1 activa

Hoy (abril 2026): ETH ~$2,200 / BTC ~$71,000 = 0.031 → NO activa
```

**Indicador 2 — BTC Dominance:**
```
BTC dominance < 50% Y en tendencia bajista → condición 2 ACTIVA
BTC dominance > 55%                        → condición 2 NO ACTIVA

DESAFÍO: BTC dominance no es un dato on-chain nativo. Opciones:
  A) Chainlink custom feed (si existe)
  B) El oráculo de Lumina lo postea (firmado por oracleKey, verificable)
  C) Proxy on-chain: Total crypto market cap no está disponible en Chainlink,
     pero podemos usar un proxy simplificado:
     - Si ETH/BTC > 0.050 → es casi seguro que BTC dom < 50%
     - Históricamente, ETH/BTC > 0.050 y BTC dom > 55% NUNCA coexistieron

RECOMENDACIÓN: Usar solo ETH/BTC como trigger primario (100% on-chain via 
Chainlink), y BTC dominance como confirmador off-chain posteado por el 
oráculo. AMBAS condiciones deben cumplirse para liberar.

Si solo queremos 100% trustless: usar ETH/BTC > 0.050 como único trigger.
```

**Verificación histórica de los indicadores:**

| Ciclo | ETH/BTC pico | BTC dom mínimo | ¿Alt season? | ¿Indicadores correctos? |
|-------|-------------|----------------|--------------|------------------------|
| 2017 | 0.155 (Jun) | 33% (Ene 2018) | Sí | ✅ Ambos triggearían |
| 2021 | 0.082 (May) | 39% (May 2021) | Sí | ✅ Ambos triggearían |
| 2024-25 | 0.056 (brief) | 48% (brief) | Parcial | ✅ Triggearía brevemente |
| Hoy 2026 | 0.031 | 63% | No | ✅ No triggearía |

**Mecanismo de liberación:**
```solidity
contract AltSeasonVesting {
    // Condiciones paramátricas
    uint256 public constant ETH_BTC_THRESHOLD = 50e15;    // 0.050 en 18 decimals
    uint256 public constant BTC_DOM_THRESHOLD = 5000;      // 50.00% en BPS
    uint256 public constant SUSTAINED_DURATION = 7 days;   // Debe mantenerse 7 días

    // Estado
    uint256 public altSeasonConfirmedAt;  // Timestamp cuando se confirmó
    bool public altSeasonTriggered;       // true = liberación iniciada
    uint256 public releasesCompleted;     // 0, 1, 2, o 3

    // Verificar condiciones
    function checkAltSeason() external {
        uint256 ethBtcRatio = _getEthBtcRatio();
        uint256 btcDominance = _getBtcDominance();

        if (ethBtcRatio > ETH_BTC_THRESHOLD && btcDominance < BTC_DOM_THRESHOLD) {
            if (altSeasonStartedAt == 0) {
                altSeasonStartedAt = block.timestamp;
            } else if (block.timestamp - altSeasonStartedAt >= SUSTAINED_DURATION) {
                altSeasonTriggered = true;
                altSeasonConfirmedAt = block.timestamp;
            }
        } else {
            altSeasonStartedAt = 0;  // Reset if conditions no longer met
        }
    }

    // Liberar tokens (1/3 cada 3 meses después de trigger)
    function release(uint256 tranche) external {
        require(altSeasonTriggered, "Alt season not confirmed");
        require(tranche < 3, "Only 3 tranches");
        require(block.timestamp >= altSeasonConfirmedAt + (tranche * 90 days), "Too early");
        require(!trancheReleased[tranche], "Already released");

        trancheReleased[tranche] = true;
        releasesCompleted++;

        // Transfer 1/3 of each allocation to their respective recipients
        _releaseTrancheToAll();
    }
}
```

### 1.4 — Análisis: ¿10% de tesorería alcanza para operar?

```
Tesorería libre desde día 1: 10,000,000 LUMINA

Usos de la tesorería:
1. Liquidez inicial del pool LUMINA/USDC en Uniswap V3
2. Comprar vaults via Exit Engine (cuando el admin decida)
3. Costos operativos (gas, infraestructura)

¿Alcanza para el Exit Engine?
- Reserva Exit Engine: 10,000,000 LUMINA (separada de tesorería)
- Si LUMINA = $1.00, la reserva cubre $10M en compras de vaults (con descuento)
- Si LUMINA = $0.50, cubre $5M
- Si LUMINA = $0.10, cubre $1M

Riesgo: si el precio de LUMINA baja mucho, la reserva compra menos vaults.
Pero: si LUMINA baja, también hay menos incentivo para que LPs usen el Exit 
Engine (reciben menos). Es auto-regulante.

¿Y si la reserva se agota?
- El admin puede transferir tokens de tesorería (10%) a la reserva
- Total disponible desde día 1: 10% reserva + 10% tesorería = 20M LUMINA
- Si todo se agota, el Exit Engine se pausa hasta que los burns del 
  marketplace + recompras reabastezcan la tesorería
- EL PROTOCOLO DE SEGUROS SIGUE FUNCIONANDO. Los LPs solo pierden la 
  opción de salida anticipada, no su capital.

CONCLUSIÓN: 20% libre desde día 1 (20M LUMINA) es suficiente para la 
operación inicial. Si el protocolo crece, el 80% restante se libera en 
alt season y da más runway.
```

### 1.5 — Mecanismo deflacionario

```
El token tiene MAX SUPPLY fijo de 100M. No se puede mintear más allá de ese cap.
No existe función mint() post-genesis. NADIE puede crear tokens nuevos. Nunca.

Fuentes de burn PERMANENTE:
1. Exit Engine: cuando recupera USDC → compra LUMINA del DEX → burn
2. Marketplace fees: 2% de cada transacción → buy & burn
3. Access NFT: $10 USD en LUMINA quemados para entrar al marketplace
4. (Futuro) Protocol revenue: parte del 3% fee de seguros → buy & burn

Cada LUMINA quemado reduce el supply PARA SIEMPRE.
El supply solo puede bajar, nunca subir.
En 5 años, el circulating supply podría ser 80M, 70M, 60M...
Nunca será más de 100M.
```

### 1.6 — Fijación de precio

```
Estándar Tier 1: Uniswap V3 TWAP on-chain.

Mismo approach que usan:
- Frax Finance (FRAX/USDC TWAP)
- Liquity (LQTY price via Uniswap)
- Reflexer (RAI redemption rate)
- Euler Finance (EUL governance pricing)

Implementación:
- Pool LUMINA/USDC en Uniswap V3 en Base
- TWAP de 30 minutos como price feed (anti-manipulación)
- OracleLibrary.consult(pool, 1800) → tick promedio → precio
- El contrato LuminaPriceOracle lee directamente del pool

Precio inicial: determinado por el market maker contratado para el launch.
Post-launch: el mercado lo define (Uniswap TWAP es la fuente de verdad).
```

### 1.7 — Roles del token

```
MINTER_ROLE:     NADIE. No existe mint() post-genesis.
                 Todo se mintea una sola vez en el constructor del deploy.
                 Después del deploy, la función mint() no existe en el ABI.

BURNER_ROLE:     ExitEngine + Marketplace + AccessNFT
                 (pueden quemar tokens que reciben o que los users aprobaron)

ADMIN_ROLE:      TimelockController
                 (solo puede asignar/revocar BURNER_ROLE)

OWNER:           TimelockController

El admin NO puede:
- Mintear LUMINA (la función no existe)
- Mover tokens de otros
- Pausar el token
- Blacklistear wallets
```

---

## PARTE 2 — NFTs

### 2.1 — Access NFT (Entrada al Marketplace)

```
Contrato:    LuminaAccessNFT.sol (ERC-721)
Precio:      $10 USD equivalente en LUMINA (recalculado via TWAP)
Pago:        LUMINA se QUEMA (100% deflacionario)
Tipo:        Soulbound (intransferible) — 1 por wallet
Función:     Gate de acceso al marketplace. Sin AccessNFT no podés comprar ni vender.

Por qué $10 y no $300:
- $300 es barrera demasiado alta para wallets individuales
- $10 filtra bots de spam (un bot que crea 1000 wallets gasta $10K)
- A escala, 100,000 access NFTs = 1,000,000 LUMINA quemados (~$1M deflación)
- El fee real del marketplace (3% por tx) es donde se genera valor, no en el acceso

Admin puede: cambiar el precio en USD
```

### 2.2 — Policy NFT (Pólizas como NFTs)

```
Contrato:    PolicyNFT.sol (ERC-721)
Se mintea:   Automáticamente cuando alguien compra una póliza
Visual:      🛡️ ESCUDO con el logo del producto
             - BCS: escudo azul con símbolo BTC
             - EAS: escudo morado con símbolo ETH
             - DEPEG: escudo verde con símbolo $
             - IL: escudo naranja con gráfico de curva
             - EXPLOIT: escudo rojo con símbolo de lock

Metadata on-chain:
  - productId, coverageAmount, premiumPaid, strikePrice
  - expiresAt, waitingEndsAt, status, vault, asset

Transferible: SÍ — al transferir, el nuevo dueño cobra si se triggerea
```

### 2.3 — Vault Share NFT (Posiciones LP como NFTs)

```
Contrato:    VaultShareNFT.sol (ERC-721)
Se mintea:   Cuando un LP wrappea su posición
Visual:      🪙 MONEDA con el nombre del vault
             - VolatileShort: moneda dorada con "VS"
             - VolatileLong: moneda dorada con "VL"
             - StableShort: moneda plateada con "SS"
             - StableLong: moneda plateada con "SL"

Metadata on-chain:
  - vault address, shares amount, depositedAt, depositedUSDC
  - NAV actual (dinámico, se calcula en tiempo real)

Transferible: SÍ — al transferir, el nuevo dueño puede retirar
Funciones: wrap(), unwrap(), getNAV()
```

---

## PARTE 3 — MARKETPLACE

### 3.1 — UX de marketplace (nivel OpenSea/Blur)

Dos interfaces: web para humanos + API para agentes de IA.

```
PANTALLA PRINCIPAL:

┌─────────────────────────────────────────────────────────────────┐
│  LUMINA MARKETPLACE                        🪙 12,500 LUMINA    │
│                                            🔗 0x1234...5678    │
│                                                                 │
│  [🛡️ Policies]  [🪙 Vault Positions]  [My Items]  [Activity]  │
│                                                                 │
│  ┌─ FILTROS ─────────────────────────────────────────────────┐ │
│  │ Producto: [All ▾] [🛡️BCS] [🛡️EAS] [🛡️DEPEG] [🛡️IL] [🛡️EXP]│
│  │ Precio: [$0 ──●────── $100K]                              │ │
│  │ Expira en: [>1d] [>7d] [>30d]                             │ │
│  │ Ordenar: [Precio ↑] [Precio ↓] [Expira pronto] [Nuevo]  │ │
│  └───────────────────────────────────────────────────────────┘ │
│                                                                 │
│  ┌──────────────────┐ ┌──────────────────┐ ┌────────────────┐ │
│  │  🛡️ BCS #427     │ │  🛡️ EAS #89      │ │ 🛡️ DEPEG #201 │ │
│  │  ┌────────────┐  │ │  ┌────────────┐  │ │ ┌────────────┐ │ │
│  │  │   🛡️ BTC   │  │ │  │   🛡️ ETH   │  │ │ │   🛡️ $     │ │ │
│  │  │  ESCUDO    │  │ │  │  ESCUDO    │  │ │ │  ESCUDO    │ │ │
│  │  │  AZUL      │  │ │  │  MORADO    │  │ │ │  VERDE     │ │ │
│  │  └────────────┘  │ │  └────────────┘  │ │ └────────────┘ │ │
│  │  Cover: $50K     │ │  Cover: $25K     │ │ Cover: $10K    │ │
│  │  Strike: $71K    │ │  Strike: $2.2K   │ │ Asset: USDT    │ │
│  │  Exp: 23 days    │ │  Exp: 12 days    │ │ Exp: 45 days   │ │
│  │  ────────────    │ │  ────────────    │ │ ────────────   │ │
│  │  12,500 LUMINA   │ │  5,800 LUMINA    │ │ 2,100 LUMINA   │ │
│  │  (~$13,125)      │ │  (~$6,090)       │ │ (~$2,205)      │ │
│  │  [BUY] [OFFER]   │ │  [BUY] [OFFER]   │ │ [BUY] [OFFER]  │ │
│  └──────────────────┘ └──────────────────┘ └────────────────┘ │
│                                                                 │
│  ┌──────────────────┐ ┌──────────────────┐ ┌────────────────┐ │
│  │  🪙 VS #89       │ │  🪙 VL #34       │ │ 🪙 SL #12     │ │
│  │  ┌────────────┐  │ │  ┌────────────┐  │ │ ┌────────────┐ │ │
│  │  │   🪙 VS    │  │ │  │   🪙 VL    │  │ │ │   🪙 SL    │ │ │
│  │  │  MONEDA    │  │ │  │  MONEDA    │  │ │ │  MONEDA    │ │ │
│  │  │  DORADA    │  │ │  │  DORADA    │  │ │ │  PLATEADA  │ │ │
│  │  └────────────┘  │ │  └────────────┘  │ │ └────────────┘ │ │
│  │  NAV: $102,340   │ │  NAV: $48,700    │ │ NAV: $200,120  │ │
│  │  P&L: +4.4%      │ │  P&L: +2.1%      │ │ P&L: +8.7%     │ │
│  │  Cooldown: 22d   │ │  Cooldown: 65d   │ │ Cooldown: 310d │ │
│  │  ────────────    │ │  ────────────    │ │ ────────────   │ │
│  │  95,000 LUMINA   │ │  45,000 LUMINA   │ │ 180,000 LUMINA │ │
│  │  (~$99,750)      │ │  (~$47,250)      │ │ (~$189,000)    │ │
│  │  [BUY] [OFFER]   │ │  [BUY] [OFFER]   │ │ [BUY] [OFFER]  │ │
│  │  [🤖 EXIT NOW]   │ │  [🤖 EXIT NOW]   │ │ [🤖 EXIT NOW]  │ │
│  └──────────────────┘ └──────────────────┘ └────────────────┘ │
│                                                                 │
│  ┌─ LIVE MARKET DATA (updates every second) ────────────────┐ │
│  │  BTC: $71,234 ▲0.5%  ETH: $2,198 ▼0.3%  LUMINA: $1.05  │ │
│  │  Protocol TVL: $2.1M  Policies: 47  Vault Util: 62%     │ │
│  │  LUMINA Supply: 94.2M (burned: 5.8M)  ETH/BTC: 0.031    │ │
│  └───────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**API para agentes de IA (mismo marketplace, interfaz JSON):**
```
GET  /api/v2/marketplace/listings?type=POLICY&product=BTCCAT-001&sort=price_asc
GET  /api/v2/marketplace/listings/:id
POST /api/v2/marketplace/buy       { listingId, maxPriceLumina }
POST /api/v2/marketplace/list      { nftContract, tokenId, priceLumina }
POST /api/v2/marketplace/offer     { listingId, offerPriceLumina }
POST /api/v2/marketplace/cancel    { listingId }
GET  /api/v2/marketplace/stats
GET  /api/v2/marketplace/exit-engine/offers  → ver ofertas del protocolo
POST /api/v2/marketplace/exit-engine/accept  { vaultShareTokenId }  → vender al protocolo
```

### 3.2 — Fee structure

```
Fee total: 3% del precio de venta

Distribución:
- Vendedor paga: 1.5% del precio
- Comprador paga: 1.5% del precio

Del 3% total:
- 1% → Tesorería del protocolo (en LUMINA)
- 2% → Compra automática de LUMINA en el DEX → BURN permanente

Nota: la verdadera riqueza del proyecto sale del token, no de los fees.
Los fees son un mecanismo deflacionario, no una fuente de revenue.
El valor del token viene de: supply decreciente + utilidad creciente + alt season release.
```

### 3.3 — Access control

```
Para LISTAR: necesitás AccessNFT + ser dueño del NFT
Para COMPRAR: necesitás AccessNFT + LUMINA suficiente
Para VER: cualquiera (lectura pública, web + API)
Para EXIT ENGINE: necesitás AccessNFT + VaultShareNFT

Admin puede:
- Cambiar % de fees (seller/buyer)
- Cambiar distribución del fee (treasury/burn)
- Pausar/despausar el marketplace
- Cambiar treasury address
- Fijar % de descuento del Exit Engine
- Decidir si comprar o no cada vault (manualmente o via agente IA)
- Libre disponibilidad de fondos para comprar y vender en el mercado

Admin NO puede:
- Mintear LUMINA (la función no existe)
- Cancelar listings de otros
- Mover NFTs de otros
- Forzar una venta
```

---

## PARTE 4 — EXIT ENGINE

### 4.1 — Funcionamiento (automático y obligatorio)

El Exit Engine es automático: cuando un LP lista su VaultShareNFT para "LUMINA INSTANT EXIT", el protocolo muestra la oferta con el descuento configurado. Si el LP acepta, la transacción se ejecuta inmediatamente. No hay aprobación manual por operación.

```
FLUJO OBLIGATORIO:

1. LP tiene un VaultShareNFT (posición wrappeada)
2. LP clickea "🤖 EXIT NOW" en el marketplace (o POST via API)
3. El contrato calcula automáticamente:
   - NAV actual del vault share ($100,000)
   - Descuento configurado por admin para ese vault (25%)
   - LUMINA a pagar: $75,000 / precio LUMINA actual
   - Verifica que la reserva tiene suficiente LUMINA
4. Si la reserva alcanza → ejecuta INSTANTÁNEAMENTE:
   - Toma el VaultShareNFT del LP
   - Paga LUMINA de la reserva al LP
5. Después del cooldown (automático, el relayer lo ejecuta):
   - Unwrap NFT → shares
   - Request withdrawal
   - Complete withdrawal → USDC
   - Compra LUMINA con TODO el USDC en Uniswap → BURN

El LP no espera aprobación. Si el Exit Engine está activo y tiene 
reserva, la venta es instantánea.
```

### 4.2 — Descuento configurable (5% a 99%)

```
El admin puede ofrecer CUALQUIER descuento entre 5% y 99%.
No es compulsivo — el LP decide si acepta o no.

Rango: 5% a 99% (sin límite superior real excepto 99%)
El admin pone el número que quiera desde la consola.

Disponible para:
- Admin humano: via consola web (slider + botón apply)
- Agente de IA: via API POST /api/v2/admin/exit-engine/set-discount

Ejemplo extremo:
- Admin pone descuento 80% en VolatileShort durante un crash
- Un LP con $100K recibe solo $20K en LUMINA
- ¿Alguien aceptaría? Probablemente no, pero el admin tiene la libertad
- Al día siguiente el admin baja a 15% y los LPs empiezan a vender

El descuento es la herramienta principal del admin para:
- Atraer vendedores (descuento bajo → más atractivo para LPs)
- Proteger la reserva (descuento alto → gasta menos LUMINA)
- Maximizar el burn (más USDC recuperado vs LUMINA gastado → más burn)
```

### 4.3 — Sin límites de operación

```
NO hay:
- Máximo de operaciones por día
- Máximo de USD por operación individual
- Pausa automática por precio del token
- Pausa automática por reserva baja

La ÚNICA forma de pausar el Exit Engine es por decisión del admin.
El admin pausa cuando quiere y despausa cuando quiere.

¿Por qué? Porque el descuento ya es el regulador natural:
- Si el admin pone descuento 50%, pocos LPs venderán → pocas operaciones
- Si el admin pone descuento 10%, muchos LPs venderán → muchas operaciones
- Si la reserva se agota → las operaciones fallan naturalmente (no hay LUMINA para pagar)
- No necesitamos límites artificiales — el mercado se auto-regula

El admin siempre puede DEJAR DE COMPRAR. Si no le conviene, simplemente
no compra. Puede desactivar el Exit Engine por tiempo indefinido.
```

### 4.4 — Recompra garantizada

```
PROBLEMA: ¿Qué pasa si la reserva + tesorería se agotan?
SOLUCIÓN: El Exit Engine se pausa naturalmente (no tiene LUMINA para pagar).

¿Cómo se reabastece?
1. Cada vez que el Exit Engine completa un cooldown y quema LUMINA,
   la tesorería recibe el 1% del fee del marketplace → acumula LUMINA
2. Cuando se liberen los tokens bloqueados (alt season), la tesorería
   puede recibir una recarga
3. El marketplace genera fees continuos → parte va a tesorería

¿Puede el protocolo quedarse sin poder de recompra?
- Si los 20M LUMINA libres (10% reserva + 10% tesorería) se gastan y
  el marketplace no genera suficientes fees → sí, temporalmente
- Pero esto solo significa que el Exit Engine se pausa
- Los LPs siguen pudiendo vender en el marketplace persona-a-persona
- Los LPs siguen pudiendo esperar el cooldown y retirar normal
- EL PROTOCOLO DE SEGUROS NUNCA SE AFECTA

IMPORTANTE: Lumina puede dejar de comprar cuando quiera. Lo hará 
mientras no le convenga. Esto no es un bug, es un feature — el 
protocolo solo compra cuando tiene los recursos y el descuento es 
favorable.
```

---

## PARTE 5 — CONSOLA DE ADMINISTRACIÓN

### 5.1 — Token Tracker

```
LUMINA TOKEN — LIVE TRACKER

┌─ SUPPLY ──────────────────────────────────────────────────────┐
│  Max Supply:       100,000,000 LUMINA (inmutable)             │
│  Circulating:       19,234,567 LUMINA (libre)                │
│  Locked (alt season): 80,000,000 LUMINA (80%)                │
│  Total Burned:         765,433 LUMINA (0.77%)                │
│  Price (TWAP 30m):  $1.05                                     │
│  Circulating Cap:   $20,196,295                               │
│                                                                │
│  ████░░░░░░░░░░░░░░░░░░░░░░░░░░░░ 19.2% circulando          │
│  ░░░░████████████████████████████░  80.0% bloqueado           │
│  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░█   0.8% quemado             │
└────────────────────────────────────────────────────────────────┘

┌─ ALT SEASON ORACLE ───────────────────────────────────────────┐
│  ETH/BTC Ratio:    0.031  (threshold: > 0.050) ❌             │
│  BTC Dominance:    63.4%  (threshold: < 50%)   ❌             │
│  Status:           🔴 NO ALT SEASON — tokens bloqueados      │
│  Days until earliest possible release: unknown                │
│                                                                │
│  When triggered: 80M LUMINA released in 3 tranches            │
│  Tranche 1 (month 0):  26,666,666 LUMINA                     │
│  Tranche 2 (month 3):  26,666,667 LUMINA                     │
│  Tranche 3 (month 6):  26,666,667 LUMINA                     │
└────────────────────────────────────────────────────────────────┘

┌─ BURN ACTIVITY (últimas 24h) ─────────────────────────────────┐
│  Total burned: 2,500 LUMINA ($2,625)                          │
│                                                                │
│  Sources:                                                      │
│  ████████████████░░░░░░  Exit Engine:  1,800 LUMINA (72%)     │
│  ████░░░░░░░░░░░░░░░░░  Marketplace:    500 LUMINA (20%)     │
│  ██░░░░░░░░░░░░░░░░░░░  Access NFTs:    200 LUMINA  (8%)     │
│                                                                │
│  Net deflation: -2,500 LUMINA 🟢                              │
│  Projected annual burn: 912,500 LUMINA (0.91% of max)        │
└────────────────────────────────────────────────────────────────┘

┌─ EXIT ENGINE STATUS ──────────────────────────────────────────┐
│  Reserve balance:   9,450,000 LUMINA (de 10M inicial)        │
│  Treasury balance:  9,800,000 LUMINA (de 10M inicial)        │
│  Total disponible:  19,250,000 LUMINA                         │
│  Pending exits:     2 positions                               │
│  USDC in cooldown:  $154,000                                  │
│  Next completion:   in 14 days                                │
│                                                                │
│  Discounts:                                                    │
│  VolatileShort: [25%] ◄──●──────► StableShort: [20%]        │
│  VolatileLong:  [30%] ◄────●────► StableLong:  [25%]        │
│                                                                │
│  Status: 🟢 ACTIVO  [Pausar]  [Aplicar descuentos]          │
│                                                                │
│  ┌─ Ofertas pendientes ──────────────────────────────────┐   │
│  │ VaultShareNFT #89 (VS) — NAV $102K — 25% desc        │   │
│  │ LP recibiría: 72,857 LUMINA (~$76.5K)                 │   │
│  │ Reserva post-op: 9,377,143 LUMINA                     │   │
│  │ [✅ EJECUTAR]  [❌ RECHAZAR]                          │   │
│  └───────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────┘

┌─ SUPPLY HISTORY (gráfico) ────────────────────────────────────┐
│  100M ┤ ═══════════════════════════════  (max supply)          │
│       │                                                        │
│   20M ┤────────────────                                        │
│       │                ──────────                              │
│   19M │                          ──────                        │
│       │                                ────────               │
│   18M │                                                        │
│       └─────────────────────────────────────────               │
│       W1    W2    W3    W4    W5    W6    W7    W8            │
│                                                                │
│  🟢 Circulating supply decreasing (locked tokens unchanged)   │
└────────────────────────────────────────────────────────────────┘

┌─ MARKETPLACE STATS ───────────────────────────────────────────┐
│  Active listings:    12 (8 policies + 4 vaults)               │
│  Volume 24h:         45,000 LUMINA ($47,250)                  │
│  Fees 24h:           1,350 LUMINA (3%)                        │
│    Treasury:         450 LUMINA (1%)                           │
│    Burned:           900 LUMINA (2%)                           │
│  Access NFTs sold:   47 (LUMINA burned: 4,476)               │
│  Floor price policy: 850 LUMINA (DEPEG #201)                  │
│  Floor price vault:  42,000 LUMINA (VS #124)                  │
└────────────────────────────────────────────────────────────────┘
```

---

## PARTE 6 — CAPAS DE ARQUITECTURA

```
┌─────────────────────────────────────────────────────────────┐
│  LAYER 4: Admin Console + Token Tracker                      │
│  (React frontend, read-only data display)                    │
│  → Si se cae: nada se rompe, solo pierde visibilidad        │
├─────────────────────────────────────────────────────────────┤
│  LAYER 3: Marketplace + Exit Engine                          │
│  (LuminaMarketplace, ExitEngine, PolicyNFT, VaultShareNFT)  │
│  → Si se cae: LPs/agents pierden mercado secundario         │
│  → El protocolo de seguros sigue funcionando 100%            │
├─────────────────────────────────────────────────────────────┤
│  LAYER 2: Token LUMINA + Access + Price Oracle               │
│  (ERC-20, AccessNFT, LuminaPriceOracle, AltSeasonVesting)   │
│  → Si se cae: marketplace no funciona                        │
│  → El protocolo de seguros sigue funcionando 100%            │
├─────────────────────────────────────────────────────────────┤
│  LAYER 1: Protocolo de Seguros (CORE — NUNCA SE TOCA)       │
│  (CoverRouter, PolicyManager, Vaults, OracleV2, ShieldsV2)  │
│  → SIEMPRE funciona, independiente de todo lo de arriba      │
└─────────────────────────────────────────────────────────────┘

Regla de oro: cada layer solo depende de los de abajo, nunca de los de arriba.
Layer 1 no sabe que Layer 2-4 existen.
```

---

## PARTE 7 — CONTRATOS A CREAR

```
CONTRATOS NUEVOS (8):
1. src/token/LuminaToken.sol              — ERC-20, max 100M, burn-only post-genesis
2. src/token/LuminaPriceOracle.sol        — Uniswap V3 TWAP 30min
3. src/token/AltSeasonVesting.sol         — Oráculo paramétrico ETH/BTC + BTC dom
4. src/marketplace/LuminaAccessNFT.sol    — Soulbound, $10 burn-to-enter
5. src/marketplace/PolicyNFT.sol          — ERC-721 escudo, transferable policies
6. src/marketplace/VaultShareNFT.sol      — ERC-721 moneda, wrapped vault positions
7. src/marketplace/LuminaMarketplace.sol  — Order book, 3% fee (1% treasury + 2% burn)
8. src/marketplace/ExitEngine.sol         — Compra vaults con descuento, auto-burn

CONTRATO MODIFICADO (1):
9. src/core/PolicyManager.sol             — agregar updateBeneficiary()

FRONTEND NUEVO (3 páginas):
10. app/marketplace/page.tsx              — UX tipo OpenSea/Blur con escudos y monedas
11. app/admin/page.tsx                    — Consola de admin completa
12. app/admin/token-tracker/page.tsx      — Supply tracker en tiempo real

API ENDPOINTS NUEVOS (10):
13. GET  /api/v2/marketplace/listings
14. GET  /api/v2/marketplace/listings/:id
15. POST /api/v2/marketplace/buy
16. POST /api/v2/marketplace/list
17. POST /api/v2/marketplace/offer
18. POST /api/v2/marketplace/cancel
19. GET  /api/v2/marketplace/stats
20. GET  /api/v2/token/info
21. GET  /api/v2/exit-engine/status
22. POST /api/v2/admin/exit-engine/set-discount
```

---

## PARTE 8 — DEPLOYMENT ORDER

```
1. Deploy LuminaToken (mint 100M distribuido según tabla 1.2)
2. Deploy AltSeasonVesting (recibe 80M bloqueados, lee oracleV2 para ETH/BTC)
3. Create Uniswap V3 LUMINA/USDC pool + liquidez inicial (de tesorería)
4. Market maker inicia operaciones en el pool
5. Deploy LuminaPriceOracle (apunta al pool)
6. Deploy LuminaAccessNFT
7. Deploy PolicyNFT (linked a PolicyManager)
8. Deploy VaultShareNFT
9. Deploy LuminaMarketplace
10. Deploy ExitEngine (recibe 10M LUMINA de reserva)
11. Set BURNER_ROLE en token para ExitEngine + Marketplace + AccessNFT
12. Upgrade PolicyManager via Timelock (add updateBeneficiary)
13. Transfer ownership de todo al TimelockController
14. Deploy frontend (marketplace + admin console + token tracker)
15. Add API endpoints
```

---

## PARTE 9 — PREGUNTAS PARA ANÁLISIS

1. ¿El oráculo de alt season usando ETH/BTC ratio (100% on-chain via Chainlink) es suficiente como trigger único? ¿O necesitamos BTC dominance como segundo indicador? Si sí, ¿cómo lo hacemos trustless?

2. ¿20% libre desde día 1 (10M reserva + 10M tesorería = 20M LUMINA) es suficiente para operar el Exit Engine + proveer liquidez + costos? ¿O debería ser más?

3. ¿El mecanismo de alt season vesting (80% bloqueado hasta ETH/BTC > 0.050 por 7 días) tiene precedente en DeFi? ¿Hay riesgos legales o de percepción?

4. ¿Sin max supply minteable post-genesis y sin límites de operación en el Exit Engine, qué pasa si un whale dumea 5M LUMINA del Exit Engine en un DEX con poca liquidez?

5. ¿$10 por Access NFT es suficiente para filtrar spam? ¿O necesitamos rate-limiting adicional (ej: 1 compra de AccessNFT por wallet por día)?

6. ¿El descuento de 5-99% sin límite es un riesgo? ¿Un admin malicioso podría poner 99% y regalar la reserva?

7. ¿Cómo se protege el admin console? ¿Solo via Gnosis Safe/Timelock? ¿O necesita auth adicional?

8. ¿La liberación en 3 tranches de 3 meses después del trigger de alt season es demasiado rápida? ¿Debería ser 6 tranches de 6 meses?

9. ¿Qué market maker usar para el pool LUMINA/USDC en Base? ¿Wintermute? ¿GSR? ¿Alguno especializado en L2?

10. ¿El precio inicial del token debería estar definido antes del diseño del contrato (afecta los cálculos de reserva) o se puede dejar para el market maker?
