# Shields — Operations Runbook

> Sprint EE. Lenguaje no-técnico. 6 secciones: qué hace cada shield, activar trigger,
> redimir bond, verificar póliza, sequencer/oracle down, emergencias.

## Set final de shields (post-Sprint EE)

Después del Sprint Deploy posterior, Lumina tendrá **7 shields** activos:

| Shield | Activo cubierto | Trigger | Ventana | Payout |
|---|---|---|---|---|
| FlashBTC 1h | BTC | Caída > 5% del precio spot | 1 hora | 80% del coverage (20% deductible) |
| FlashBTC 24h | BTC | Caída > 10% | 24 horas | 80% |
| FlashBTC 48h | BTC | Caída > 15% | 48 horas | 80% |
| FlashETH 1h | ETH | Caída > 7% | 1 hora | 80% |
| FlashETH 24h | ETH | Caída > 12% | 24 horas | 80% |
| FlashETH 48h | ETH | Caída > 18% | 48 horas | 80% |
| RateShock | USDC (vía Aave V3) | Borrow rate > 10% APY | 7 días | 80% |

**Eliminados en Sprint EE**: MicroDepegShield (sin feed USDT confiable en Sepolia), FlashBTC4h (asimetría con FlashETH).

---

## 1. "Cómo activar el trigger manualmente"

Si tenés una póliza y el precio cae al umbral durante la ventana, vos (o cualquiera) podés activar el trigger.

### Opción A — BaseScan UI

1. Abrir: `https://basescan.org/address/<SHIELD_ADDRESS>` (la dirección del shield específico).
2. Tab **"Contract"** → **"Write Contract"** → conectar wallet (MetaMask/Rabby).
3. Buscar la función **`checkAndSettlePolicy`** o **`verifyAndCalculate`**.
4. Ingresar:
   - `policyId` (te lo dieron al comprar la póliza)
   - `oracleProof` (lo genera el oracle service automáticamente; pegar bytes hex)
5. Click **"Write"** y confirmar.

### Opción B — Terminal (cast)

```bash
cast send <SHIELD_ADDRESS> "checkAndSettlePolicy(uint256)" <policyId> \
  --rpc-url $RPC \
  --private-key $YOUR_PK
```

**Costo gas estimado**: $0.20 — $0.80 en Base mainnet.

### Qué pasa después

El shield evalúa:
- ¿La firma del oracle es válida?
- ¿El proof está fresco (< 15 min)?
- ¿El precio cayó al o por debajo del trigger?
- ¿Estamos dentro de la ventana de la póliza?

Si las 4 condiciones se cumplen, **se emite `PolicySettledTriggered`** y se mintea un bond ERC-1155 al policy holder.

---

## 2. "Cómo redimir el bond"

Una vez triggereado, el shield no te paga inmediatamente — recibís un **bond ERC-1155** que vence en 2 años.

### Esperar el vencimiento

- Bond redimible a partir de `triggerTimestamp + 2 años`.
- Si intentás redimir antes, la tx revierte.

### Redimir

Opción A — BaseScan: `BondVault` contract → Write → `redeem(bondId)` → confirm.

Opción B — cast:
```bash
cast send <BOND_VAULT_ADDRESS> "redeem(uint256)" <bondId> \
  --rpc-url $RPC \
  --private-key $YOUR_PK
```

### Cuánto recibís

Recibís **LUMINA equivalente al precio actual del token al momento de la redención**.

Ejemplo:
- Bond face value: $1,000 USDC
- Precio LUMINA al momento de redimir: $0.50
- Recibís: 1,000 / 0.50 = **2,000 LUMINA**

Si el precio LUMINA es $2.00 al redimir, recibís 500 LUMINA.

---

## 3. "Cómo verificar mi póliza" (3 formas independientes)

### Forma 1 — BaseScan

1. Abrir el shield en BaseScan → tab **"Contract"** → **"Read Contract"**.
2. Buscar `getPolicyInfo(uint256)` → ingresar tu `policyId` → Query.
3. Verás: `insuredAgent`, `coverageAmount`, `premiumPaid`, `maxPayout`, `startTimestamp`, `expiresAt`, status final.

### Forma 2 — Wallet (MetaMask/Rabby)

1. La póliza es un asset ERC-1155 en el `PolicyManagerV2`.
2. Agregar el contrato `PolicyManagerV2` → ver tu balance.

### Forma 3 — cast

```bash
cast call <SHIELD_ADDRESS> "getPolicyInfo(uint256)" <policyId> --rpc-url $RPC
```

Decodificar el tuple devuelto.

---

## 4. "Si Chainlink o el sequencer caen"

Decisión founder confirmada en ADR-026:

- **Fail silent**: la póliza expira sin payout. No hay payout retroactivo.
- **NO hay recovery histórico**. Si el oracle estaba caído cuando hubiera triggereado tu póliza, lo perdiste.
- Razón: introducir lógica de recovery histórico abre vectores de manipulación post-hoc.

**Mitigación**: el oracle Chainlink + sequencer Base tienen SLAs altos. Probabilidad de caída > 1h en una ventana de 24-48h es baja pero no cero.

---

## 5. "Verificar wiring on-chain post-deploy" (founder pre-flight)

Antes de anunciar el set como "live", para cada shield correr:

```bash
# Constants check
cast call <SHIELD> "TRIGGER_DROP_BPS()(uint256)" --rpc-url $RPC
cast call <SHIELD> "MIN_DURATION()(uint32)" --rpc-url $RPC
cast call <SHIELD> "DEDUCTIBLE_BPS()(uint256)" --rpc-url $RPC

# Wiring check
cast call <SHIELD> "router()(address)" --rpc-url $RPC      # ⇒ PolicyManagerV2 address
cast call <SHIELD> "oracle()(address)" --rpc-url $RPC      # ⇒ LuminaOracleV2 SET A
```

Si cualquier valor difiere del ADR-026, **DETENER el deploy** y revisar el script.

---

## 6. "Emergencia"

### Caso 1: Bug crítico encontrado en un shield

**Acción**: UUPS upgrade vía `onlyOwner`. El owner (founder o multisig) llama:
```bash
cast send <SHIELD_PROXY> "upgradeToAndCall(address,bytes)" <NEW_IMPL> 0x \
  --rpc-url $RPC --private-key $PK
```

Los policies existentes mantienen su storage; los proxies apuntan al nuevo impl.

### Caso 2: Oracle comprometido

**Acción**: el founder rota la address del oracle:
```bash
cast send <SHIELD> "setOracle(address)" <NEW_ORACLE> --rpc-url $RPC --private-key $PK
```

Emite evento `OracleRotated`. Las pólizas futuras usarán el nuevo oracle.

### Caso 3: Whale manipulation

No hay pause individual por shield (decisión founder). Si detectás manipulación masiva:
- El oracle EIP-712 signer puede dejar de firmar precios manipulados.
- UUPS upgrade puede agregar `nonReentrant` u otros guards si se necesita.

### Caso 4: Cascade failure (varios shields fallan)

`GlobalPauseRegistry` puede pausar TODO el protocol simultáneamente. Owner-only call.

---

## Referencias técnicas

- ADR-026 (`tracking/architectural-decisions.md`)
- Source code: `src/products/{FlashBTCShield1h,24h,48h,FlashETHShield1h,24h,48h,RateShockShield}.sol`
- BaseShield: `src/products/BaseShield.sol`
- Tests: `test/{unit,integration,echidna,stress}/shields/`
- Oracle SET A canonical: `0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194` (Sepolia)
- Aave V3 Pool Sepolia: `0xcc0606b64275c08539770864081D209A8C9b178a`
