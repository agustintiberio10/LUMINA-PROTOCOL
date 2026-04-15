# LUMINA PROTOCOL — SKILL V4.0 (SINGLE SOURCE OF TRUTH)
## Mercado de especulación de riesgo paramétrico para AI agents
### Base L2 (Chain 8453) | Token: $LUMINA | Última actualización: Abril 2026

---

## 1. QUÉ ES LUMINA

Lumina Protocol es un mercado donde humanos y AI agents apuestan
contra eventos de mercado. Pagan primas baratas. Si el evento ocurre,
reciben ClaimBond tokens (ERC-1155) cobrables en $LUMINA en 24 meses.
Si no ocurre, la prima compra y quema $LUMINA para siempre.

Dos tipos de usuarios:
  1. Especuladores (humanos via web + AI agents via API):
     compran pólizas baratas, cobran bonds con retornos de 17x a 333x
  2. Yield Seekers (humanos + fondos + agents):
     compran bonds con descuento, esperan 24 meses, cobran 67-150% IRR

No es solo seguros. Es especulación paramétrica con deflación incorporada.

---

## 2. TOKEN $LUMINA

```
Supply total:     100,000,000 (fijo, sin mint)
Burn:             ERC20Burnable + BURNER_ROLE
Chain:            Base L2 (8453)
DEX:              Uniswap V3 (LUMINA/USDC)

DISTRIBUCIÓN:
  82,000,000 (82%)  →  BondVault.sol        Bond Reserve
   5,000,000  (5%)  →  Fjord Foundry        LBP (genera liquidez con $0)
  10,000,000 (10%)  →  FounderVesting.sol   Founder (AltSeason conditions)
   3,000,000  (3%)  →  TreasuryVesting.sol  Treasury (locked 6m, 250K/mes después)
```

---

## 3. BONDVAULT — LA CAJA FUERTE

```
Contiene:         82,000,000 LUMINA
Tipo:             Contrato INMUTABLE (no Ownable, no UUPS, no proxy)
Admin:            NADIE
Withdraw:         NO EXISTE
Emergency:        NO EXISTE
Upgrade:          NO EXISTE

ÚNICA SALIDA: redeemBond(tokenId, amount)
  Requiere: block.timestamp >= maturityDate[tokenId]
  Efecto: quema ERC-1155 del caller, transfiere LUMINA al caller

Ni el founder, ni un multisig, ni governance pueden sacar tokens.
Verificable en BaseScan. El código es la ley.
```

---

## 4. PRODUCTOS — 9 PRODUCTOS DE ESPECULACIÓN

### Fórmula de pricing:
```
Prima  = Cobertura × 0.80 × P(trigger) × 1.50
Payout = Cobertura × 0.80 (como ClaimBond ERC-1155, 24 meses)
El agente elige el monto de cobertura. Prima y payout escalan proporcionalmente.
El múltiplo es FIJO por producto.
```

### Tabla de productos:
```
┌─────────────────┬─────────────────────────────────┬──────────┬─────────┬────────┐
│ ID              │ Trigger                         │ Ventana  │P(trigger│ Mult.  │
├─────────────────┼─────────────────────────────────┼──────────┼─────────┼────────┤
│ FLASH-BTC-1H    │ BTC cae 5%                      │ 1 hora   │ 0.20%   │ 333x   │
│ FLASH-BTC-4H    │ BTC cae 8%                      │ 4 horas  │ 0.35%   │ 190x   │
│ FLASH-BTC-24H   │ BTC cae 10%                     │ 24 horas │ 1.50%   │  44x   │
│ FLASH-BTC-48H   │ BTC cae 15%                     │ 48 horas │ 0.80%   │  83x   │
│ FLASH-ETH-1H    │ ETH cae 7%                      │ 1 hora   │ 0.25%   │ 266x   │
│ FLASH-ETH-24H   │ ETH cae 12%                     │ 24 horas │ 2.00%   │  33x   │
│ FLASH-ETH-48H   │ ETH cae 18%                     │ 48 horas │ 0.90%   │  74x   │
│ MICRO-DEPEG     │ USDT cotiza debajo de $0.995    │ 7 días   │ 3.50%   │  19x   │
│ RATE-SHOCK      │ Aave USDC borrow rate supera 10%│ 7 días   │ 4.00%   │  17x   │
└─────────────────┴─────────────────────────────────┴──────────┴─────────┴────────┘
```

### Ejemplo a $1,000 de cobertura:
```
┌─────────────────┬──────────┬────────────┬────────┐
│ Producto        │ Prima    │ Payout     │ Mult.  │
├─────────────────┼──────────┼────────────┼────────┤
│ FLASH-BTC-1H    │ $2.40    │ $800 bond  │ 333x   │
│ FLASH-BTC-4H    │ $4.20    │ $800 bond  │ 190x   │
│ FLASH-BTC-24H   │ $18.00   │ $800 bond  │  44x   │
│ FLASH-BTC-48H   │ $9.60    │ $800 bond  │  83x   │
│ FLASH-ETH-1H    │ $3.00    │ $800 bond  │ 266x   │
│ FLASH-ETH-24H   │ $24.00   │ $800 bond  │  33x   │
│ FLASH-ETH-48H   │ $10.80   │ $800 bond  │  74x   │
│ MICRO-DEPEG     │ $42.00   │ $800 bond  │  19x   │
│ RATE-SHOCK      │ $48.00   │ $800 bond  │  17x   │
└─────────────────┴──────────┴────────────┴────────┘
```

### Pricing grid completo:
```
┌─────────────────┬──────────┬──────────┬──────────┬──────────┬───────────┐
│ Producto        │ $100 cov │ $500 cov │$1,000 cov│$5,000 cov│$10,000 cov│
├─────────────────┼──────────┼──────────┼──────────┼──────────┼───────────┤
│ FLASH-BTC-1H    │ $0.24    │ $1.20    │ $2.40    │ $12.00   │ $24.00    │
│ FLASH-BTC-4H    │ $0.42    │ $2.10    │ $4.20    │ $21.00   │ $42.00    │
│ FLASH-BTC-24H   │ $1.80    │ $9.00    │ $18.00   │ $90.00   │ $180.00   │
│ FLASH-BTC-48H   │ $0.96    │ $4.80    │ $9.60    │ $48.00   │ $96.00    │
│ FLASH-ETH-1H    │ $0.30    │ $1.50    │ $3.00    │ $15.00   │ $30.00    │
│ FLASH-ETH-24H   │ $2.40    │ $12.00   │ $24.00   │ $120.00  │ $240.00   │
│ FLASH-ETH-48H   │ $1.08    │ $5.40    │ $10.80   │ $54.00   │ $108.00   │
│ MICRO-DEPEG     │ $4.20    │ $21.00   │ $42.00   │ $210.00  │ $420.00   │
│ RATE-SHOCK      │ $4.80    │ $24.00   │ $48.00   │ $240.00  │ $480.00   │
└─────────────────┴──────────┴──────────┴──────────┴──────────┴───────────┘
Payout siempre = cobertura × 80%, como ClaimBond ERC-1155 a 24 meses.
```

---

## 5. CLAIMBONDS — ERC-1155 POR ÉPOCA

### Estructura:
```
Standard:       ERC-1155 (fungible por época, fraccionable)
Token ID:       época de maduración (formato: YYYYMM)
                Ejemplo: 202804 = todos los bonds que maduran abril 2028
Unidad:         1 unidad = 1 LUMINA de claim al vencimiento
Cantidad:       payout_usd / precio_lumina_al_emitir

EJEMPLO:
  Agente triggereia el 15 de abril 2026. LUMINA está a $0.036.
  Cobertura $1,000, payout $800.
  Bond: 22,222 unidades de token "202804" ($800 / $0.036)
  
  Otro agente triggereia el 28 de abril 2026.
  Cobertura $5,000, payout $4,000.
  Bond: 111,111 unidades de token "202804"
  
  Ambos holders tienen el MISMO token. Son fungibles entre sí.
  Total circulante de "202804": 133,333 unidades.

OPERACIONES DEL HOLDER:
  - Holdear todo → esperar 24 meses → redimir por LUMINA
  - Vender todo en el marketplace → recibir USDC hoy con descuento
  - Vender una parte → quedarse con el resto para redimir después
  - Ejemplo: tiene 22,222 unidades
    → vende 15,000 en el marketplace ($540 USDC hoy con 60% descuento)
    → holdea 7,222 → redime en 24 meses → recibe 7,222 LUMINA

REDENCIÓN:
  Cuando block.timestamp >= maturityDate del token ID:
  → Holder llama bondVault.redeemBond(tokenId, amount)
  → Contrato quema `amount` unidades del ERC-1155
  → Contrato transfiere `amount` LUMINA del reserve al holder
  → Redención parcial permitida (redime 5,000 de 22,222, por ejemplo)
```

### Marketplace secundario:
```
Los tokens ERC-1155 se pueden tradear en:
  - Marketplace propio (LuminaBondMarketplace.sol)
  - Cualquier marketplace de ERC-1155 (OpenSea, Blur, etc.)
  - Pools de Uniswap V3 (un pool por época: 202804/USDC, 202805/USDC)
  - OTC directo (transferFrom entre wallets)

Yield Seekers compran bonds con descuento:
  - Bond "202804" vale 1 LUMINA en abril 2028
  - Si LUMINA spot es $0.10 → el bond vale ~$0.10 al vencimiento
  - Compran a $0.04-0.06 hoy → IRR de 67-150% en 24 meses
  - El descuento depende de: tiempo al vencimiento, confianza en el protocolo, 
    expectativa de precio de LUMINA
```

---

## 6. FLUJO COMPLETO DE UNA OPERACIÓN

```
1. AGENTE COMPRA PÓLIZA
   POST /api/v2/purchase { productId: "FLASH-BTC-1H", coverage: 1000 }
   → Paga $2.40 USDC de prima
   → Recibe confirmación de póliza (1 hora de cobertura)

2. PRIMA SE DIVIDE
   $2.40 USDC → CoverRouter → TWAPBurner
   → 85% ($2.04) → micro-compras LUMINA cada 15 min → burn
   → 15% ($0.36) → USDC Treasury (ops)

3a. NO HAY TRIGGER (99.8% del tiempo)
   Pasa 1 hora. BTC no cayó 5%.
   Póliza expira. Prima quemada. Supply bajó.
   Fin.

3b. TRIGGER (0.2% del tiempo)
   BTC cae 6% en 47 minutos. Oracle confirma.
   PolicyManager → BondVault.issueBond()
   → Calcula: $800 payout / $0.036 precio = 22,222 unidades
   → Mint 22,222 unidades de ERC-1155 token "202804" al agente
   → BondVault reserva 22,222 LUMINA internamente
   → La prima ($2.04) ya se quemó

4. AGENTE TIENE OPCIONES
   A) Holdear → esperar 24 meses → redimir 22,222 LUMINA
   B) Vender todo en marketplace → recibir USDC hoy con descuento
   C) Vender parte, holdear parte
   
5. MES 25: BOND MADURA
   Holder llama bondVault.redeemBond(202804, 22222)
   → Se queman 22,222 unidades del ERC-1155
   → Se transfieren 22,222 LUMINA del Bond Reserve al holder
   → Bond Reserve: -22,222 LUMINA
   → Circulante: +22,222 LUMINA
   → PERO: en 24 meses se quemaron ~28,333 LUMINA de ese "lote"
   → Neto: -6,111 LUMINA = DEFLACIONARIO
```

---

## 7. MOTOR DEFLACIONARIO

### Identidad algebraica:
```
Burn / Emisión = margen × split = 1.50 × 0.85 = 1.275

Por cada 1 LUMINA que sale del Bond Reserve por un bond maduro,
se quemaron 1.275 LUMINA en primas.
Neto: -0.275 LUMINA por cada LUMINA liberado.
DEFLACIONARIO POR CONSTRUCCIÓN.
Margen de seguridad: 27.5% sobre breakeven.
```

### Revenue split:
```
Primas en USDC:
  85% → TWAPBurner → compra LUMINA en Uniswap → burn
  15% → USDC Treasury → gas, infra, emergencias
```

### Fórmula de capacidad:
```
max_policies/día = (BondReserve × 0.50 × precio) / (payout × 730 × p_promedio)
                 = (82,000,000 × 0.50 × precio) / ($500 × 730 × 0.01)
                 = 11,233 × precio_LUMINA

A $0.036: 404 pólizas/día
A $0.10:  1,123 pólizas/día
A $1.00:  11,233 pólizas/día

Circuit breaker: si precio < $0.005 → pausa emisión de pólizas
Reactivación: precio > $0.008 (histéresis)
```

---

## 8. FOUNDER — 10% ALTSEASON VESTING

```
Contrato:         FounderVesting.sol (nuevo, clon de AltSeasonVesting)
Recipient:        Agustín (1 address)
Amount:           10,000,000 LUMINA
Condiciones:      2-of-3 sostenidas 7 días:
                    A: ETH/BTC > 0.050
                    B: ETH > $4,000
                    C: Aave V3 USDC borrow > 7%
Fallback:         1460 días (4 años)
Release:          3 tranches cada 31 días
                    Tranche 1: 3,333,333 LUMINA
                    Tranche 2: 3,333,333 LUMINA
                    Tranche 3: 3,333,334 LUMINA
updateRecipient:  sí (por si Agustín cambia de wallet)
```

---

## 9. TREASURY — 3% CON TIMELOCK

```
Contrato:         TreasuryVesting.sol
Amount:           3,000,000 LUMINA
Lock:             6 meses (cero disponible)
Post-lock:        máximo 250,000 LUMINA/mes
Controlado por:   Gnosis Safe (2-of-3 multisig)
Usos permitidos:  top-up de liquidez en pool, market maker deal,
                  bug bounties, emergency bond reserve top-up
NO se vende en mercado abierto.
```

---

## 10. TGE — LANZAMIENTO CON $0

### LBP en Fjord Foundry:
```
Plataforma:       Fjord Foundry (Base L2)
Tokens:           5,000,000 LUMINA (5% del supply)
USDC inicial:     $0
Duración:         72 horas
Peso inicial:     96/4 (LUMINA/USDC) → precio implícito ~$0.15
Peso final:       50/50 → precio final ~$0.03-0.04
Anti-sniper:      precio alto al inicio + max cap por wallet

Recaudación estimada:
  Conservador: $52,500 USDC (30% vendido)
  Base:        $90,000 USDC (50% vendido)
  Optimista:   $133,000 USDC (70% vendido)

Post-LBP:
  USDC recaudados + LUMINA sobrante → pool Uniswap V3 (POL)
  El protocolo controla la posición. Nunca se retira.
```

### Estado post-TGE:
```
Circulante:       ~5,000,000 LUMINA (5% del supply)
Precio:           ~$0.036
FDV:              ~$3,600,000
MCap circulante:  ~$180,000
Liquidez pool:    ~$180,000 bilateral
```

---

## 11. CONTRATOS — LISTA COMPLETA

### Nuevos (8):
```
1. LuminaTokenV2.sol          ERC20 + Burnable + AccessControl, 100M fijo
2. BondVault.sol               Inmutable, sin owner, 82M LUMINA
3. ClaimBond.sol               ERC-1155, épocas mensuales, fraccionable
4. CapacityOracle.sol          Precio TWAP + fórmula capacidad + circuit breaker
5. TWAPBurner.sol              Buy & burn distribuido, buffer USDC, BURNER_ROLE
6. FounderVesting.sol          10M, condiciones AltSeason, 3 tranches
7. TreasuryVesting.sol         3M, lock 6m, 250K/mes post-lock
8. LuminaBondMarketplace.sol   Orderbook simple para ERC-1155 bonds (post-MVP)
```

### Upgrades (2):
```
9. PolicyManagerV2.sol         Sin vaults, integra BondVault + CapacityOracle
10. CoverRouterV2.sol          Sin vaults, envía USDC al TWAPBurner
```

### Shields nuevos (3):
```
11. FlashBTCShield1h.sol       BTC -5%, 1 hora
12. FlashBTCShield4h.sol       BTC -8%, 4 horas
13. FlashETHShield1h.sol       ETH -7%, 1 hora
14. MicroDepegShield.sol       USDT <$0.995, 7 días
15. RateShockShield.sol        Aave USDC >10%, 7 días
```

### Shields modificados (4):
```
16. FlashBTCShield24h.sol      Trigger cambia a -10% (era -18%)
17. FlashBTCShield48h.sol      Trigger cambia a -15% (era -22%)
18. FlashETHShield24h.sol      Trigger cambia a -12% (era -20%)
19. FlashETHShield48h.sol      Trigger cambia a -18% (era -28%)
```

### Deprecados (16):
```
6 Vaults, InstantLiquidity, VaultShareNFT, LuminaMarketplace viejo,
BTCCatastropheShield (V1+V2), ETHApocalypseShield (V1+V2),
DepegShield (V1+V2), ExploitShield (V1+V2), ILIndexCover (V1+V2),
BlackSwanShield
```

---

## 12. API — ENDPOINTS

```
POST /api/v2/purchase          Comprar póliza (USDC)
GET  /api/v2/products          Lista de productos con pricing
GET  /api/v2/capacity          Capacidad actual del protocolo
GET  /api/v2/stats             Burn total, rate, supply, precio

GET  /api/v2/bonds/:address    Bonds de un address (ERC-1155 balances por época)
GET  /api/v2/bonds/epoch/:id   Detalle de una época (supply, maturity, holders)
POST /api/v2/bonds/redeem      Redimir bonds maduros

GET  /api/v2/marketplace/listings      Bonds en venta
POST /api/v2/marketplace/list          Listar bonds para venta
POST /api/v2/marketplace/buy           Comprar bonds listados
POST /api/v2/marketplace/cancel        Cancelar listing

POST /api/v2/keys/create       Crear API key (requiere wallet signature)
GET  /api/v2/keys/list         Listar API keys del wallet
```

---

## 13. REGLAS INMUTABLES

```
1. El BondVault NO tiene withdraw, NO tiene owner, NO tiene upgrade.
2. El protocolo NUNCA compra bonds (Regla de Oro — Gemini).
3. $LUMINA NO tiene mint. Supply solo baja.
4. Los bonds son ERC-1155 agrupados por época mensual de maduración.
5. Los holders de bonds pueden fraccionar y vender parcialmente.
6. Las primas se dividen 85% burn / 15% ops. Siempre.
7. El margen de pricing es 1.50. Siempre.
8. El founder NO puede acceder a tokens hasta AltSeason o 4 años.
9. El treasury se libera después de 6 meses, max 250K/mes.
10. Lumina Protocol es 100% DeFi. No tiene relación con seguros tradicionales.
```