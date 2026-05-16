# Founder Vesting — Operations Runbook

> Sprint FV. Lenguaje no-técnico. 4 secciones: cobrar tokens, activar trigger,
> cambiar wallet recipient, emergencias. Cross-refs ADR-025.

---

## 1. "Cómo cobrar mis tokens"

El contrato `FounderVesting` libera **8,000,000 LUMINA** en **3 tranches** (entregas) de aproximadamente **2,666,666.66 LUMINA cada uno**, una vez que alguno de los 3 paths se activa:

- **Path 1** — 2 de 3 condiciones de altseason cumplidas durante 1 día seguido.
- **Path 2** — ETH > $5,000 USD durante 1 día seguido.
- **Path 3** — Pasaron 3 años (1095 días) desde el deploy.

### Paso 1 — Verificar si puedo cobrar

Opción A — **BaseScan UI**:

1. Abrir: `https://basescan.org/address/<FV_ADDRESS>` (la dirección del contrato FounderVesting que te van a pasar post-deploy).
2. Click en la tab **"Contract"** → sub-tab **"Read Contract"**.
3. Encontrar la función `getStatus` → click en "Query".
4. Mirar los valores:
   - Si `triggered = true` → puedo intentar cobrar.
   - Si `tranchesReleased = 3` → ya cobré los 3 tranches; no queda nada.
   - Si `triggered = false` y `nextReleaseAt = 0` → todavía no se activó ningún path.

Opción B — **Terminal (cast)**:

```bash
cast call <FV_ADDRESS> "getStatus()(bool,uint256,uint256,uint256,uint256,uint256,uint256,uint256)" --rpc-url $RPC
```

El primer `bool` = `triggered`. Los siguientes números son los timestamps + contadores.

### Paso 2 — Llamar `releaseTranche()`

Opción A — **BaseScan Write Contract**:

1. Abrir el FV en BaseScan → tab "Contract" → sub-tab **"Write Contract"**.
2. Click en **"Connect to Web3"** y conectar tu wallet (MetaMask/Rabby).
3. Encontrar la función `releaseTranche` → click en "Write".
4. Confirmar la transacción en el wallet.
5. Esperar ~5-15 segundos a que confirme on-chain.

Opción B — **Terminal (cast)**:

```bash
cast send <FV_ADDRESS> "releaseTranche()" \
  --rpc-url $RPC \
  --private-key $FOUNDER_PRIVATE_KEY
```

**Costo de gas estimado**: ~$0.30 — $1.50 en Base mainnet, ~$0.01 en Sepolia.

### Paso 3 — Verificar que recibí los tokens (3 formas independientes)

> Es importante hacer **al menos 2 de las 3** verificaciones; si solo una falla pero las
> otras 2 confirman, probablemente fue un glitch de UI. Si las 3 fallan, abrir incidente.

#### Forma 1 — BaseScan (recommended)

1. Abrir: `https://basescan.org/address/0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8` (la dirección recipient — la del founder o la nueva si se cambió).
2. Tab **"Token Transfers"**: buscar la transferencia más reciente. Esperado:
   - Token name: `LUMINA`
   - Quantity: `2,666,666.666...` (tranches 1 y 2) o `2,666,666.668` (tranche 3, recibe el dust residual).
   - From: la address del `FounderVesting`.
   - To: tu wallet.
3. Tab **"Tokens"** (o "Tokens 0x..." en algunas UIs): debe aparecer el token LUMINA con tu balance acumulado.

#### Forma 2 — Wallet (MetaMask / Rabby / Frame / etc.)

1. Abrir tu wallet → red **Base** (o Base Sepolia para testnet).
2. Buscar el token LUMINA. Si no aparece:
   - Click **"Import token"** o equivalente.
   - Pegar la dirección del contrato LUMINA (te la van a pasar post-deploy).
   - El wallet auto-detecta nombre / símbolo / decimales (18).
3. Confirmar que el balance que ves coincide con lo esperado.

#### Forma 3 — Comando cast (terminal)

```bash
cast call <LUMINA_TOKEN_ADDRESS> "balanceOf(address)(uint256)" \
  0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8 \
  --rpc-url $RPC
```

Output: un número grande (e.g. `2666666666666666666666666`). Dividir entre `1e18` para
ver el valor humano (e.g. `2,666,666.666...`).

Quick formula:

```bash
echo "scale=18; $(cast call ... balanceOf ...) / 10^18" | bc
```

### Paso 4 — Repetir cada 31 días para tranche 2 y 3

- **Tranche 1**: disponible inmediatamente después del trigger.
- **Tranche 2**: disponible 31 días después del trigger.
- **Tranche 3**: disponible 62 días después del trigger.

El intervalo es `block.timestamp >= triggerTimestamp + (N * 31 days)` donde N es el índice
de la tranche (0, 1, 2). Si llamás `releaseTranche()` antes de tiempo, la tx revierte con
`"Too early"`.

---

## 2. "Activar el trigger manualmente"

El contrato **no auto-checkea** las condiciones. Alguien tiene que llamar
`checkAltSeason()` cuando crea que las condiciones se están cumpliendo.

Cualquiera puede llamarla (no requiere ownership). No hay bot/keeper — es responsabilidad
del founder (o de un voluntario) llamarla.

### Cuándo llamar

- Cuando ETH > $5,000 USD por más de 24 horas → PATH 2 listo para triggerear.
- Cuando 2 de 3 condiciones (ETH/BTC > 0.050, ETH > $4000, Aave borrow USDC > 7%) se cumplen por más de 24h → PATH 1 listo.
- Una llamada cada hora durante el período sostenido es suficiente; no necesitás spammear.

### Cómo llamar

Opción A — **BaseScan Write Contract** → función `checkAltSeason` → "Write" → confirmar.

Opción B — **cast**:

```bash
cast send <FV_ADDRESS> "checkAltSeason()" \
  --rpc-url $RPC \
  --private-key $YOUR_PK
```

**Costo gas**: ~$0.30 — $0.50 en Base mainnet.

### Qué pasa después

El contrato emite uno de estos eventos:

- `ConditionsChecked(condA, condB, condC, metCount, timestamp)` — siempre se emite, te muestra el estado.
- `SustainedPeriodStarted(timestamp)` — PATH 1 cumple 2-of-3 por primera vez después de un reset.
- `OverrideConditionMet(ethPrice, timestamp)` — PATH 2 cumple ETH > $5k por primera vez.
- `AltSeasonTriggered(timestamp)` — **¡PATH 1 activado!** Ya podés cobrar tranche 1.
- `OverrideTriggered(ethPrice, timestamp)` — **¡PATH 2 activado!**

Si esperaste el período sostenido completo (1 día) y llamás `checkAltSeason()`, la misma
tx que evalúa las condiciones también activa el trigger.

### Trigger del fallback (3 años)

Si pasaron 1095 días desde el deploy y ningún path se activó, cualquiera puede llamar:

```bash
cast send <FV_ADDRESS> "triggerFallback()" --rpc-url $RPC --private-key $YOUR_PK
```

Esto activa el trigger por timeout (path 3). Tranche 1 disponible inmediatamente
después.

---

## 3. "Cambiar wallet recipient"

Sólo el **owner** del contrato (founder) puede llamar.

```bash
cast send <FV_ADDRESS> "updateRecipient(address)" 0xNUEVA_WALLET \
  --rpc-url $RPC \
  --private-key $FOUNDER_PRIVATE_KEY
```

O via BaseScan → Write Contract → `updateRecipient` → pegar nueva dirección → confirmar.

### Cuándo es útil

- **Wallet original comprometida**: cambiar a una segura ANTES de que alguien malicioso
  llame `releaseTranche` y se lleve los tokens a la wallet vieja.
- **Migración a multisig**: cuando el founder mueve sus activos a un Gnosis Safe.
- **Cambio de jurisdicción / planning**: cambiar a una entidad legal.

### Efecto

- Inmediato.
- Las tranches futuras irán al nuevo recipient.
- Las tranches **ya cobradas** quedan en la wallet anterior (no se devuelven automáticamente).
- Emite evento `RecipientUpdated(old, new)`.

### Verificación post-cambio

```bash
cast call <FV_ADDRESS> "recipient()(address)" --rpc-url $RPC
```

Debe devolver la nueva dirección.

---

## 4. "Emergencia"

### Caso 1: Wallet comprometida

**Acción**: Llamar `updateRecipient(nueva_address)` lo antes posible, ANTES de que el
atacante pueda llamar `releaseTranche` y dirigir los fondos a la wallet vieja.

Si ya cobraron una tranche a la wallet vieja: esos tokens están perdidos
(el contrato no tiene undo). Las tranches futuras quedan protegidas.

### Caso 2: Oracle se cae

Síntoma: `checkAltSeason()` no avanza, conditions se devuelven todos `false`.

**Acción**: Esperar a que el oracle vuelva. El contrato es paciente — las funciones que
dependen del oracle usan `try/catch` y simplemente no avanzan si el feed revierte. El
contador `conditionsMetSince` puede resetear si el feed da `false` durante una llamada
intermedia; en ese caso hay que reempezar el período sostenido.

**Nunca** intentar redeployar el oracle sin coordinación — la address de FV es immutable y
apunta a un oracle específico.

### Caso 3: 3 años sin trigger

Si llegaste a `deployedAt + 1095 days` sin que PATH 1 ni PATH 2 hayan activado:

**Acción**: Cualquiera llama `triggerFallback()`. Esto fuerza el unlock por timeout
(path 3). Tranche 1 disponible inmediatamente después.

```bash
cast send <FV_ADDRESS> "triggerFallback()" --rpc-url $RPC --private-key $YOUR_PK
```

### Caso 4: Quiero verificar que mi wallet está realmente recibiendo los tokens y no es un fake

Triple verificación (BaseScan + Wallet + cast) como en Sección 1, Paso 3. Si las 3 dan
balances diferentes, es un bug — abrir incidente.

---

## Referencias técnicas

- ADR-025 (`tracking/architectural-decisions.md`)
- Contrato fuente: `src/token/FounderVesting.sol`
- Deploy script: `script/deploy/DeployLuminaV5Complete.s.sol` STEP 6
- Bug L476-477 (multisig grant+revoke) ya neutralizado en Sprint T → ADR-012.
- Oracle wiring SET A: `0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194` (Sepolia). Mainnet TBD post-deploy.
