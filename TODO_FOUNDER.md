# TODO Founder — Sprint Z.2 vesting fix (post-merge manual ops)

**Sprint:** Z.2 · **Fecha:** 2026-05-15 · **Branch:** `feat/sprint-z2-vesting-fix` · **ADR:** ADR-024

Este archivo lista TODO lo que el founder tiene que ejecutar a mano una vez
mergeada la PR de Sprint Z.2. NO hay bot keeper, NO hay landing admin
button — todas las operaciones son **broadcast manual** desde la wallet
founder `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8`.

Pre-requisitos:
- `PRIVATE_KEY` env exportado en la shell donde se corren los scripts.
- Wallet `0xe585…fda8` con ETH suficiente en Base Sepolia (~0.005 ETH cubre las 4 txs holgado).
- RPC alias `base_sepolia` configurado en `foundry.toml` (ya está; apunta a `https://sepolia.base.org`).
- Commit que se mergeó incluye los 4 scripts + 3 contratos nuevos + tests.

---

## 1. Broadcast on-chain (orden estricto — 4 transacciones)

### 1.a) UUPS upgrade LuminaTokenV2 → RescueV1

Habilita la función one-shot `emergencyRecover` en el proxy del token.

```bash
forge script script/upgrade/UpgradeToRescueV1.s.sol \
  --rpc-url base_sepolia \
  --broadcast
```

Verificar post-broadcast:
- `cast call 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02 "emergencyRecoverUsed()(bool)" --rpc-url base_sepolia` → `false`
- BaseScan → LuminaTokenV2 proxy → Read as Proxy → confirmar que `emergencyRecover` aparece en el ABI.

### 1.b) Deploy FounderVestingV2

```bash
forge script script/deploy/DeployFounderVestingV2.s.sol \
  --rpc-url base_sepolia \
  --broadcast
```

Capturar la address devuelta por el script (aparece en stdout y en
`broadcast/DeployFounderVestingV2.s.sol/84532/run-latest.json`).

Exportarla de inmediato a la shell:

```bash
export FOUNDER_VESTING_V2_ADDRESS=0x...   # reemplazar con la addr real
```

Verificar wiring on-chain (críticamente: oracle = SET A):

```bash
cast call $FOUNDER_VESTING_V2_ADDRESS "oracle()(address)" --rpc-url base_sepolia
# expected: 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194  (LuminaOracleV2 SET A)
cast call $FOUNDER_VESTING_V2_ADDRESS "recipient()(address)" --rpc-url base_sepolia
# expected: 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8
cast call $FOUNDER_VESTING_V2_ADDRESS "luminaToken()(address)" --rpc-url base_sepolia
# expected: 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02
cast call $FOUNDER_VESTING_V2_ADDRESS "SUSTAINED_DURATION()(uint256)" --rpc-url base_sepolia
# expected: 86400  (1 day)
cast call $FOUNDER_VESTING_V2_ADDRESS "FALLBACK_DURATION()(uint256)" --rpc-url base_sepolia
# expected: 94608000  (1095 days)
```

### 1.c) Ejecutar rescate (mueve 8M LUMINA de FV legacy → FV V2)

```bash
FOUNDER_VESTING_V2_ADDRESS=$FOUNDER_VESTING_V2_ADDRESS \
  forge script script/upgrade/ExecuteRescue.s.sol \
  --rpc-url base_sepolia \
  --broadcast
```

El script llama `LuminaTokenV2_RescueV1.emergencyRecover(FV_legacy, FV_V2, 8e24)`
desde la wallet founder (tiene DEFAULT_ADMIN_ROLE). Solo se puede llamar
una vez — el flag `emergencyRecoverUsed` se setea a `true` post-tx.

Verificar:

```bash
cast call 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02 \
  "balanceOf(address)(uint256)" 0xa3e7685E21A141930F63432E927D679fD3FDE876 \
  --rpc-url base_sepolia
# expected: 0  (FV legacy drenada)
cast call 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02 \
  "balanceOf(address)(uint256)" $FOUNDER_VESTING_V2_ADDRESS \
  --rpc-url base_sepolia
# expected: 8000000000000000000000000  (8M LUMINA en FV V2)
cast call 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02 "emergencyRecoverUsed()(bool)" \
  --rpc-url base_sepolia
# expected: true
```

### 1.d) UUPS upgrade LuminaTokenV2 → PostRescueV2 (cerrar la puerta)

```bash
forge script script/upgrade/UpgradeToPostRescueV2.s.sol \
  --rpc-url base_sepolia \
  --broadcast
```

Esta impl mantiene el slot `emergencyRecoverUsed` (storage preservation)
pero ELIMINA la función `emergencyRecover` del ABI. Después de este
upgrade es imposible llamar emergencyRecover (selector no responde) aun
si alguien obtuviera DEFAULT_ADMIN_ROLE.

Verificar:

```bash
# Esta call debe revertir (selector no existe en la impl actual):
cast call 0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02 \
  "emergencyRecover(address,address,uint256)" \
  0x0000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000 \
  0 \
  --rpc-url base_sepolia
# expected: revert (function selector not found)
```

---

## 2. Off-chain follow-ups (post-broadcast)

### 2.a) Railway env update — lumina-api

Cambiar `FOUNDER_VESTING_ADDRESS` en el environment del servicio Railway:

- **Antes:** `0xa3e7685E21A141930F63432E927D679fD3FDE876` (FV legacy, deprecada).
- **Después:** `<FOUNDER_VESTING_V2_ADDRESS>` (la del paso 1.b).

Trigger redeploy automático Railway tras guardar la env. Verificar `/health`
en producción responde con la new address.

### 2.b) Publicar SDK 0.5.3 en npm

Después de mergear `chore/sprint-z2-sdk-bump` en `@lumina-org/sdk`:

```bash
cd /path/to/lumina-sdk
git checkout main
git pull
# Reemplazar el placeholder "TBD_POST_DEPLOY" en src/constants.ts con la addr real.
# Verificar package.json version = 0.5.3.
npm run build
npm test
npm publish
git tag v0.5.3
git push --tags
```

---

## 3. Validación on-chain post-broadcast (gating del cierre del sprint)

Re-correr el wiring fork-test con la new address inyectada por env:

```bash
FOUNDER_VESTING_V2_ADDRESS=$FOUNDER_VESTING_V2_ADDRESS \
  forge test --match-path test/integration/immutables/FounderVestingV2Wiring.t.sol \
  --fork-url base_sepolia -vv
```

Espera 6 tests PASS (oracle, recipient, owner, luminaToken, aavePool, USDC).
Si alguno falla → NO declarar Sprint Z.2 cerrado; investigar primero.

---

## 4. Opcional — Validación Sepolia (Chainlink ETH/USD + BTC/USD)

LuminaOracleV2 SET A todavía corre con `MockAggregatorV3` (Sprint G). Para
testear el AltSeason path con feeds reales en Sepolia:

1. Buscar las addresses Chainlink **Sepolia** (NO las de mainnet) para
   ETH/USD y BTC/USD. **NO hardcodear desde memoria** — leerlas de
   https://docs.chain.link/data-feeds/price-feeds/addresses?network=base
   filtrando por Sepolia testnet. La spec de Sprint Z.2 no las pinea.
2. Por cada feed (con la wallet founder, owner de LuminaOracleV2 SET A):
   ```bash
   cast send 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194 \
     "registerFeed(bytes32,address,uint256)" \
     $(cast --format-bytes32-string "ETH") \
     <CHAINLINK_ETH_USD_SEPOLIA> \
     3600 \
     --rpc-url base_sepolia --private-key $PRIVATE_KEY
   ```
   Idem para BTC.

Si las stable price de Chainlink Sepolia muestran ETH > $4k sostenido 1d,
los condA + condB de FV V2 deberían cumplir y `triggerTimestamp` arranca.

---

## 5. CRÍTICO — Pre-launch mainnet (Chainlink Base mainnet feeds)

**Estas addresses SÍ están pineadas en la spec de Sprint Z.2** (verificadas
durante Phase A). Registrar en LuminaOracleV2 (mainnet equivalent — TBD
deploy):

```bash
# ETH/USD on Base mainnet:
cast send <LuminaOracleV2_mainnet> \
  "registerFeed(bytes32,address,uint256)" \
  $(cast --format-bytes32-string "ETH") \
  0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70 \
  3600 \
  --rpc-url base_mainnet --private-key $PRIVATE_KEY

# BTC/USD on Base mainnet:
cast send <LuminaOracleV2_mainnet> \
  "registerFeed(bytes32,address,uint256)" \
  $(cast --format-bytes32-string "BTC") \
  0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F \
  3600 \
  --rpc-url base_mainnet --private-key $PRIVATE_KEY
```

`maxStaleness = 3600` (1 hora) — coherente con la heartbeat 1h de
Chainlink ETH/BTC en Base mainnet.

**Sin estos feeds registrados, el AltSeason path de FounderVestingV2 NUNCA
puede triggerear en mainnet.** Es el item más importante de este TODO post
launch.

---

## 6. Resumen rápido (cheat-sheet)

| # | Acción | Comando | Verificación |
|---|---|---|---|
| 1 | Upgrade Token → RescueV1 | `forge script script/upgrade/UpgradeToRescueV1.s.sol --broadcast` | `emergencyRecoverUsed() == false` |
| 2 | Deploy FV V2 | `forge script script/deploy/DeployFounderVestingV2.s.sol --broadcast` | guardar address en `FOUNDER_VESTING_V2_ADDRESS` env |
| 3 | Ejecutar rescate | `FOUNDER_VESTING_V2_ADDRESS=… forge script script/upgrade/ExecuteRescue.s.sol --broadcast` | FV legacy bal = 0; FV V2 bal = 8M |
| 4 | Upgrade Token → PostRescueV2 | `forge script script/upgrade/UpgradeToPostRescueV2.s.sol --broadcast` | `emergencyRecover` removida del ABI |
| 5 | Railway env | UI Railway → `FOUNDER_VESTING_ADDRESS` = new V2 addr | `/health` muestra new addr |
| 6 | npm publish SDK | `npm publish` en lumina-sdk@0.5.3 | `npm view @lumina-org/sdk@0.5.3` ok |
| 7 | Wiring fork-test | `FOUNDER_VESTING_V2_ADDRESS=… forge test --match-path …Wiring.t.sol --fork-url base_sepolia` | 6/6 PASS |
| 8 | (mainnet pre-launch) Chainlink feeds | `cast send … registerFeed …` ETH + BTC | `getLatestPrice("ETH")` returns valid int256 |

---

## Notas

- Sprint Z.2 NO toca los 9 shields (ya bound a LuminaOracleV2 SET A desde
  Sprint Oracle V2 2026-05-05).
- Sprint Z.2 NO toca BondVault SET C, PolicyManagerV2, ClaimBond, etc. —
  redeployan solo el contrato bug-trapped (FounderVesting).
- Si algo va mal en pasos 1.a o 1.b, abortar SIN broadcast del 1.c.
  Mientras emergencyRecoverUsed = false, el rescate sigue disponible.
- El paso 1.d es **idempotente respecto al rescate** — aún sin él, una
  segunda llamada a emergencyRecover revertiría por el flag. Pero el
  upgrade lo borra del ABI por defense-in-depth.
- Ver `tracking/sprint-z2-vesting-fix.md` y `runbooks/founder-vesting-operations.md`
  en el repo `lumina-tracker` para más contexto y operaciones rutinarias post-rescate.
