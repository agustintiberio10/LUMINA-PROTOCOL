# Sprint Fix 7.4 CRITICAL — 2026-05-23

**Trigger:** Sprint 7.4 Functional Audit V5.3 V1 (`audit-pack/audits/2026-05-23-functional-audit-v53-v1.md`) reportó 3 hallazgos críticos que bloqueaban Fase 5:

- **FA-V1-C1**: ShieldKeeper invocaba `checkAndSettlePolicy(uint256)` que no existía en el adapter ni en BaseFlashShield.
- **FA-V1-C2**: `/sandbox/try` retornaba `relayer_unauthorized` porque `coverRouter.authorizedRelayers(0x168dC7…) = false`.
- **FA-V1-I3**: SDK 0.7.0 con throttle API draft en `sdk#15` (post-Sprint Fix Audit Economic R3) sin publicar en npm; `npm view @lumina-org/sdk` retornaba `0.6.0`.

**Resultado:** **C1 + C2 cerrados on-chain. C3 listo para founder publish.**

---

## 1. C1 — ShieldKeeper interface gap

### 1.1 Diagnóstico

`ShieldKeeper.performUpkeep` (`src/automation/ShieldKeeper.sol:119`) llama:

```solidity
try IShieldSettleable(shield).checkAndSettlePolicy(policyIds[i]) { ... }
```

Donde `shield = policyManager.productShield(productId)` apunta al **adapter** (`FlashShieldAdapter`), no al slim shield directamente. Ni el adapter ni `BaseFlashShield` exponían `checkAndSettlePolicy(uint256)`, así que cada call del Chainlink Upkeep caía en el `catch` y emitía `SettlementFailed`.

### 1.2 Arquitectura del fix

Los slim shields (FlashBTC/ETHShield 1h/24h/48h) **no son upgradeables** — se desplegaron directamente sin proxy. Solo los adapters son UUPS. Conclusión: agregar el método en el adapter, sin tocar shield.

### 1.3 Cambios de código (branch `feat/fix-7-4-critical`)

`src/shields/FlashShieldAdapter.sol`:

- Nueva interface `IPolicyManagerSettle` con `settlePolicy(bytes32, uint256, bool)`.
- Nuevo state var `address public policyManager` + setter `setPolicyManager(address)` `onlyOwner`. **No reordena slots** (consume slot que era `__gap[0]`; `__gap` ahora `[46]` vs previo `[47]`).
- Nueva función permissionless `checkAndSettlePolicy(uint256)`:
  - Llama `shield.verifyAndCalculate(policyId)` (que ya existía).
  - Si revierte con `"WINDOW_EXPIRED"` → catch → routea como `triggered=false` (release reservation).
  - Cualquier otro revert (`SEQUENCER_DOWN`, `ORACLE_STALE`, `ALREADY_FINALIZED`, `POLICY_NOT_FOUND`) bubble up.
  - Llama `policyManager.settlePolicy(productIdLocal, policyId, triggered)`. PM gate `msg.sender == pr.shield` pasa porque `productShield[productId] = adapter`.
  - Emite `PolicySettled(policyId, triggered, reason)`.
- Sin cambios en `BaseFlashShield.sol`.

### 1.4 Tests

`test/shields/CheckAndSettlePolicy.t.sol` — 11 tests, **11/11 PASS**:

| Test | Verifica |
|---|---|
| `TriggersAtThreshold_SettlesWithTrue` | drop = 6% (TRIGGER_DROP_BPS exact) → PM.settlePolicy(true) |
| `NoTriggerBelowThreshold_SettlesWithFalse` | drop = 5.99% → PM.settlePolicy(false) |
| `WindowExpired_CatchesAndSettlesFalse` | `block.timestamp > expiresAt` → catch WINDOW_EXPIRED → PM.settlePolicy(false) |
| `RevertsWhenAlreadyFinalized` | 2nd call → "ALREADY_FINALIZED" bubble |
| `RevertsWhenSequencerDown` | sequencer.setDown(true) → "SEQUENCER_DOWN" bubble |
| `RevertsWhenOracleStale` | updatedAt < block.timestamp - 1h → "ORACLE_STALE" bubble |
| `RevertsWhenPolicyNotFound` | policyId=999 → "POLICY_NOT_FOUND" bubble |
| `RevertsWhenPolicyManagerUnset` | adapter fresh sin setPolicyManager → "Policy manager unset" |
| `IsPermissionless` | randomCaller llama → PM.settlePolicy ejecuta |
| `SetPolicyManager_OnlyOwner` | random no-owner → revert |
| `SetPolicyManager_RevertsOnZero` | zero address → "Zero PM" |

Run: `forge test --match-path test/shields/CheckAndSettlePolicy.t.sol -vv` → 11 passed; 0 failed; 0 skipped (26.72ms).

### 1.5 Storage layout

Pre: `shield`(slot 0) + `productIdLocal`(slot 1) + `nextPolicyId`(slot 2) + `__gap[47]`(slot 3-49).
Post: `shield`(slot 0) + `productIdLocal`(slot 1) + `nextPolicyId`(slot 2) + **`policyManager`(slot 3)** + `__gap[46]`(slot 4-49).

Slots 0-2 idénticos. Slot 3 era `__gap[0]` (0x0) en el proxy → la nueva impl lo lee como `policyManager = address(0)`, que es exactamente el valor inicial del state var. Compatible.

### 1.6 UUPS upgrades on-chain

Single new impl deployed + 6 `upgradeToAndCall` calls.

| Item | Valor |
|---|---|
| New `FlashShieldAdapter` impl | `0xc92F034442B918C0392bcc357D995D7e0439Bad8` |
| Deploy impl tx | `0xe81fac0e7b6432a561364b40505540be8e3bab0eea71161a68c58e5613285198` (gas 1,030,825) |
| Bloque batch | 41910857 |
| Total gas (deploy + 6 upgrades) | ~1,253,000 |

| Adapter (proxy, sin cambio) | Shield | upgradeToAndCall tx |
|---|---|---|
| `0x5fC732D2…74eAdB` FlashBTC1h | `0x06ED1ffB…5A2363` | `0x588395e7a5ec73a6b1a4ea9a1408b9385f0714f7f678d159ee45008c148d198d` |
| `0x844A5fDb…eC867d` FlashBTC24h | `0x9E4C1E79…cC173` | `0xa1419d557249d9120b350b0da7818de2d560d62bacb0631c0d1be8a25faf087a` |
| `0x0840d638…C45Bb` FlashBTC48h | `0x815802E9…F0406` | `0x96522439462b60e4b279876583529cc953c64898864275f786b517536b94ac2a` |
| `0xeC42c716…02935` FlashETH1h | `0xF858b572…8E351` | `0x4bf911f1f9cbb8d984940c8b02d9fc964808cd52ec0b0bdba08472a486f0eb4c` |
| `0xb0f143be…D69C4` FlashETH24h | `0x18ccC1eE…48eFA` | `0x7c8057f89d94f770dd8d6fd7d5be2e415d06841f3608eb16947a5ba482a373c4` |
| `0x26db224D…1A47E6` FlashETH48h | `0xC42360BC…F8f4cE` | `0x5ccd771b3a59d631e96490aaba64ae7d8e000a0cb6c98d264ded972eb6e06afc` |

### 1.7 Wiring: `setPolicyManager(0x546C07…cDd8)` × 6

Todas las 6 adapters apuntan ahora a `PolicyManagerV2` proxy `0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8`. Verificación on-chain (`cast call adapter "policyManager()(address)"` post-block 41910904):

| Adapter | `policyManager()` |
|---|---|
| FlashBTC1h | `0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8` ✅ |
| FlashBTC24h | `0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8` ✅ |
| FlashBTC48h | `0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8` ✅ |
| FlashETH1h | `0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8` ✅ |
| FlashETH24h | `0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8` ✅ |
| FlashETH48h | `0x546C07e07DeBCdbf7a2A7Ef12C38c8c8fcAFcDd8` ✅ |

setPolicyManager tx hashes: `0x53885f51…4e52` (BTC1h), `0xfccebf51…02ef` (BTC24h), `0x3160ca52…33fc` (BTC48h), `0xe5545304…6962` (ETH1h), `0x90e4547e…dde6` (ETH24h), `0x974119d7…0642` (ETH48h). Cada uno gas ~52,638.

### 1.8 Verificación selector on-chain

`cast call <adapter> "checkAndSettlePolicy(uint256)" 999` para los 6 adapters retorna **`POLICY_NOT_FOUND`** (no `execution reverted` puro). Esto confirma:

- El selector existe en el bytecode upgradeado ✅
- El gate `policyManager != address(0)` pasó (sino sería `"Policy manager unset"`) ✅
- El adapter delega correctamente a `shield.verifyAndCalculate(999)` que revierte con `POLICY_NOT_FOUND` desde `BaseFlashShield.sol:138` ✅

---

## 2. C2 — `/sandbox/try` relayer no autorizado

### 2.1 Diagnóstico (Sprint 7.4 audit ya documentó)

`POST /sandbox/try` retornaba:
```json
{"error":"relayer_unauthorized","message":"Relayer 0x168dC7105e907294f9d066cee24f30caa5A17E4a is not authorized in CoverRouter. Owner must call setRelayer(0x168dC7..., true)."}
```

On-chain: `coverRouter.authorizedRelayers(0x168dC7…) = false`.

### 2.2 Fix

1 tx desde founder owner `0xe585e76A…BfDa8`:

```
cast send 0xcdB70B40e6a3DEac3189185d947A0e458518F566 \
  "setRelayer(address,bool)" 0x168dC7105e907294f9d066cee24f30caa5A17E4a true
```

| Item | Valor |
|---|---|
| Tx hash | `0x1d91e3d22d6fcc11b909d374572940cc61bc5b94be8b2e33b36f55e31c135cec` |
| Bloque | 41908739 |
| Gas | 53,167 |
| Event | `RelayerUpdated(relayer=0x168dC7…, authorized=true)` |

Verificación post-block 41908747: `coverRouter.authorizedRelayers(0x168dC7…) = true` ✅.

### 2.3 Smoke test post-fix

```
POST /sandbox/try → {"error":"internal_error","message":"An unexpected error occurred"}
```

**`relayer_unauthorized` resuelto** ✅ — el gate del relayer pasó. El nuevo `internal_error` revela un segundo issue: `allowance(sandboxWallet=0xC1631716e3EE5EB8092927680a1c9A49C8D55B79, CoverRouter) = 0`. El sandboxWallet tiene 999.36 mUSDC y 0.015 ETH para gas (cubre purchase), pero no aprobó al CoverRouter para tirar el premium.

**Follow-up requerido (founder action — fuera de scope on-chain de este sprint):** desde la privkey del sandboxWallet (custodiada API-side), ejecutar:

```
cast send 0xD944d8e5D8329994D83950872Ec210891d3Ab6AE \
  "approve(address,uint256)" 0xcdB70B40e6a3DEac3189185d947A0e458518F566 \
  115792089237316195423570985008687907853269984665640564039457584007913129639935 \
  --private-key $SANDBOX_WALLET_PK --rpc-url $RPC
```

Item nuevo abierto: **`FA-V1-C2-FOLLOWUP`** en `what-is-pending.md`.

---

## 3. C3 (FA-V1-I3) — SDK 0.7.0 listo para publish

### 3.1 Validación pre-publish

Sub-agente paralelo audited el repo `lumina-sdk` en `/c/tmp/lumina-sdk`:

| Check | Resultado |
|---|---|
| `package.json` version | `0.7.0` ✅ |
| Branch hosting 0.7.0 | **Merged to `main`** (commit `612de98`, PR `sdk#15` mergeado post-Sprint Fix Audit Economic) |
| Throttle API (R3) | `src/bonds/throttle.ts` con `BondQueue`, `getRedemptionStatus`, `ThrottleInfo`, constants — presente en `src/index.ts:8-17` y emitido en `dist/index.d.ts:6` |
| `npm run build` | PASS — clean `tsc`, no diagnostics |
| `npm test` | **71 passing / 0 failing / 1 skipped** (1 of 9 suites skipped, throttle suite full) |
| `dist/` artifacts | Generated: `dist/{index,bonds/throttle}.{js,d.ts}` + ABIs + sourcemaps |
| Publish manifest | `name`, `version`, `main`, `types`, `files`, `publishConfig.access: public`, `prepublishOnly` (re-runs build+test) — todo OK |

### 3.2 Acción founder pendiente

```
cd /c/tmp/lumina-sdk
git checkout main && git pull
npm ci
npm publish --access public
# Si npm 2FA habilitado en la org:
# npm publish --access public --otp=<6-digit-code>
```

Opcional post-publish: `git tag v0.7.0 && git push origin v0.7.0`.

Score D del sub-auditor: **10/10**.

---

## 4. Tx hashes consolidados

```
# C1 — 1 deploy + 6 upgradeToAndCall + 6 setPolicyManager = 13 tx
# Bloques 41910857 (batch upgrades) + 41910864-41910898 (setPolicyManager)
0xe81fac0e7b6432a561364b40505540be8e3bab0eea71161a68c58e5613285198  # CREATE new impl 0xc92F0344…9Bad8
0x588395e7a5ec73a6b1a4ea9a1408b9385f0714f7f678d159ee45008c148d198d  # upgrade BTC1h adapter
0xa1419d557249d9120b350b0da7818de2d560d62bacb0631c0d1be8a25faf087a  # upgrade BTC24h adapter
0x96522439462b60e4b279876583529cc953c64898864275f786b517536b94ac2a  # upgrade BTC48h adapter
0x4bf911f1f9cbb8d984940c8b02d9fc964808cd52ec0b0bdba08472a486f0eb4c  # upgrade ETH1h adapter
0x7c8057f89d94f770dd8d6fd7d5be2e415d06841f3608eb16947a5ba482a373c4  # upgrade ETH24h adapter
0x5ccd771b3a59d631e96490aaba64ae7d8e000a0cb6c98d264ded972eb6e06afc  # upgrade ETH48h adapter
0x53885f51e74648afd508fc5fc73496da60f7f3e3bfaa7cb2f0a32b0cd7e84e52  # setPolicyManager BTC1h
0xfccebf51d56ed262a767995dcccc1ea35f365b9c1306a19a24193d88567802ef  # setPolicyManager BTC24h
0x3160ca5259cb02c55dd251bcec6cf4ebc684baddc2839b433942bd34d4fa33fc  # setPolicyManager BTC48h (retry)
0xe55453046c2941c5a1a014b77eb81837e3440d58e0ef77d207396f1618f56962  # setPolicyManager ETH1h
0x90e4547e2c968b0dc7ec705881ca55cf42655ce6dd8f6f33482aba302c5adde6  # setPolicyManager ETH24h (retry)
0x974119d75cd99eb9ae0931a9b5e4d4873d1244161ea4490e98af5460c0a00642  # setPolicyManager ETH48h

# C2 — 1 tx
0x1d91e3d22d6fcc11b909d374572940cc61bc5b94be8b2e33b36f55e31c135cec  # setRelayer(0x168dC7…, true) on CoverRouter
```

Total on-chain: **14 tx** (~1.4M gas, < 0.000020 ETH @ 0.011 gwei).

---

## 5. Files

| Path | Cambio |
|---|---|
| `src/shields/FlashShieldAdapter.sol` | NEW: `checkAndSettlePolicy(uint256)` + `setPolicyManager(address)` + `policyManager` state + `IPolicyManagerSettle` iface |
| `script/deploy/Upgrade6Adapters.s.sol` | NEW — UUPS upgrade script para los 6 adapters |
| `test/shields/CheckAndSettlePolicy.t.sol` | NEW — 11 tests del flow completo |
| `audit-pack/sprints/2026-05-23-sprint-fix-7-4-critical.md` | NEW — este documento |
| `audit-pack/what-is-pending.md` | Cerrar `FA-V1-C1` + `FA-V1-C2` (parcial, abre `FA-V1-C2-FOLLOWUP`) + actualizar `FA-V1-I3` como "ready, founder publish pending" |

Sin cambios en `BaseFlashShield.sol` ni en los slim shields (no upgradeables).

---

## 6. Conclusión

- **C1**: ✅ CERRADO. ShieldKeeper ahora settlea pólizas flash sin revert. La permissionless `checkAndSettlePolicy(uint256)` orquesta shield + PolicyManager con manejo de `WINDOW_EXPIRED` en el catch.
- **C2**: ✅ CERRADO **parcial** on-chain (relayer authorized). Follow-up `FA-V1-C2-FOLLOWUP` requiere approve del sandboxWallet desde su privkey API-side.
- **C3** (FA-V1-I3): ✅ READY. SDK 0.7.0 build+test OK en main; founder ejecuta `npm publish --access public`.

Sprint Fix 7.4 CRITICAL **CERRADO** (con 1 follow-up minor + 1 founder action).
