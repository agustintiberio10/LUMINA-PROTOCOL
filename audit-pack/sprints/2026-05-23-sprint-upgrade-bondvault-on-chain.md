# Sprint Upgrade BondVault On-Chain — 2026-05-23

**Trigger:** PR #149 (Sprint Fix Audit Economic Complete) cerró R1 (CEX
auto-injection + LUMINA floor pause) en código, pero la implementation
on-chain del BondVault proxy `0x193acBc1EdC5E565a4aBE96941C7E7AeF637B6EC`
seguía siendo pre-#149. Faltaba aplicar el upgrade UUPS para que el código
R1 sea ejecutable on-chain.

**Scope:** on-chain — UUPS upgrade del BondVault proxy. **No** se deploya
una `CEXLiquidityReserve` fresca; el setter `setCexReserve(address)` queda
en el código pero no se invoca. Resultado: la rama de auto-injection del
`_checkAndInject` queda inactiva (gate `cexReserve != address(0)`), mientras
que la rama de **LUMINA floor pause** (independiente del CEX reserve) sí
queda activa con el upgrade.

**Decisión del founder:** skip CEX Reserve wire en este sprint. El cost/benefit
de redeployar una CEXLiquidityReserve fresca + moverle LUMINA del treasury
no justifica el ROI testnet; se difiere a post-Fase 5 o se descarta.

**Resultado:** smoke test e2e exitoso (`policyId=1` minted post-upgrade);
selectors R1 (`policiesPaused`, `cexReserve`, `totalInjectedFromCex`,
`availableCapacityRatioBps`) responden; storage layout preservado; estado
crítico (`totalReservedUSD = $80`, `lumina.balanceOf(proxy) = 70M LUMINA`)
intacto.

---

## 1. Acciones

### 1.1 Nuevo script de deploy

`script/deploy/UpgradeBondVault.s.sol` — patrón calcado de
`UpgradeCoverRouterV2.s.sol` (IUUPSUpgradeable interface + `vm.envUint("PRIVATE_KEY")`
+ `console2.log` del proxy + new impl).

### 1.2 UUPS upgrade

| Contrato     | Proxy address (sin cambio)                     | Implementation nueva                           | Tx hash upgradeToAndCall                                                  |
| ------------ | ---------------------------------------------- | ---------------------------------------------- | -------------------------------------------------------------------------- |
| `BondVault`  | `0x193acBc1EdC5E565a4aBE96941C7E7AeF637B6EC`   | `0x6BBDE25a235DC07c0145A8a1A1d570E4f7ABdFaA`   | `0xa395c8b664c93afe29472ef99cb8806bac5b092761a2b21e095a6992c103a477`        |

### 1.3 NO se ejecutó

- `bondVault.setCexReserve(<address>)` — explicit skip por decisión founder.
- Deploy fresh `CEXLiquidityReserve` — explicit skip.
- Mover LUMINA al CEX reserve — N/A.

---

## 2. Tx hashes on-chain

| Tx                                  | Hash                                                                  | Gas    | Bloque    |
| ----------------------------------- | --------------------------------------------------------------------- | ------ | --------- |
| Deploy new BondVault impl           | `0xbd301ea9c59ee382e2eb23b363da57282c1b29d662b43942c625e3fecdab2737`   | 3,019,266 | 41906716 |
| `upgradeToAndCall(newImpl, "")`     | `0xa395c8b664c93afe29472ef99cb8806bac5b092761a2b21e095a6992c103a477`   | 37,894    | 41906716 |
| `mUSDC.approve(CoverRouter, 100e6)` (smoke prep) | `0x30c48e8ec50d2c9a946542886b77b85598b442f0e5cde792b1387a792c3cedfb` | -      | 41906819 |
| `purchasePolicy("FLASHBTC24-001", 100e6, "BTC")` (smoke) | `0x1fb93639f28d31d8bcefc26915178c6c44453765f401c9366b13daa09f9cd756` | 524,521 | 41906837 |

Signer: `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8` (DEFAULT_ADMIN_ROLE).

---

## 3. Storage layout

**Pre-R1** (commit `2bf0456^`): slots 0–11 + `__gap[46]` @ slot 12.
**Post-R1** (PR #149): slots 0–11 + `cexReserve` + `policiesPaused`
(packed @ slot 12) + `totalInjectedFromCex` @ slot 13 + `__gap[43]` @ slot 14.

Slots 0–11 idénticos → estado preservado. Slots 12 y 13 estaban dentro del
`__gap` previo (zero-initialized en el proxy) → la nueva impl los lee como
`cexReserve = 0x0`, `policiesPaused = false`, `totalInjectedFromCex = 0`,
que es exactamente el estado deseado.

`__gap` neto: 46 → 43 (1 slot de cushion extra que el dev consumió de más en
el accounting; no afecta upgrade-safety).

**Verdict:** layout COMPATIBLE — no breaking change.

---

## 4. Verificación post-upgrade

### 4.1 R1 selectors nuevos (PHASE F)

```
availableCapacityRatioBps()    → 9999          (~100% capacity)
policiesPaused()               → false         (floor branch arm-able)
cexReserve()                   → 0x0           (auto-inject inactivo)
totalInjectedFromCex()         → 0
LUMINA_FLOOR_PRICE()           → 5e15          ($0.005)
FLOOR_RECOVERY_HYSTERESIS_BPS()→ 12000         (120%)
INJECTION_AMOUNT_BPS()         → 1000          (10%)
CAPACITY_RATIO_THRESHOLD_BPS() → 5000          (50%)
```

### 4.2 Estado preservado (PHASE G)

```
lumina()                       → 0x62C0b58bB30CA857674ec593F1e23B3F15266680
claimBond()                    → 0xaa57Ab52Eb00f296Ad4CFA9E9c201f3737271FB4
priceOracle()                  → 0xd52aef11ff411E9e54F7a1bB680065F158cF6545
totalCommittedUSD              → 0
totalReservedUSD               → 80e18 ($80)
bondMaturitySeconds            → 63,072,000 (2 years)
lumina.balanceOf(proxy)        → 70,000,000e18 (70M LUMINA)
hasRole(DEFAULT_ADMIN_ROLE, founder) → true
```

### 4.3 Smoke test purchase (PHASE H)

| Step                                                         | Resultado |
| ------------------------------------------------------------ | --------- |
| `mUSDC.approve(CoverRouter, 100e6)`                          | ✅        |
| `CoverRouter.purchasePolicy(keccak("FLASHBTC24-001"), 100e6, "BTC")` | ✅ (status 1) |
| `PolicyManager.PolicyRecorded` event: `policyId=1`, premium $5.264, payout $80 | ✅ |
| `BondVault.ReservedCapacity` event (slot 12/13 untouched after upgrade) | ✅ |

El BondVault upgradeado responde a `reserveCapacity(buyer, payoutAmount,
asset)` desde PolicyManager sin reverts ni warnings. Flow end-to-end:
faucet mUSDC → approve → purchase → premium @ TWAPBurner → policy minted.

---

## 5. Estado funcional R1 post-upgrade

| Sub-feature R1                                                 | On-chain status                                                                      |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| LUMINA floor pause (`policiesPaused = true` si `price < $0.005`) | **ACTIVA** — el branch no depende de `cexReserve`; gateado por `LUMINA_FLOOR_PRICE`. |
| Recovery hysteresis (`policiesPaused = false` si `price >= 120% × floor`) | **ACTIVA** — mismo branch.                                                  |
| CEX auto-injection (10% del reserve hacia BondVault si ratio < 50%) | **INACTIVA** (intencional). `cexReserve == 0x0` ⇒ rama gateada salta. Reactivable post-deploy CEX reserve + `setCexReserve()`. |
| Métrica `totalInjectedFromCex`                                | Disponible como view; permanente en 0 hasta CEX wire.                                |

`CoverRouterV2._purchase` consulta `capacityOracle.getLuminaPrice()` antes de
permitir nuevas pólizas (sección "Fix audit #28 INFO-7"); el chequeo de
`policiesPaused` se mantiene del lado de `BondVault.reserveCapacity` (revert
implícito si está pausado). No se modificó CoverRouterV2 en este sprint.

---

## 6. Mainnet implications

- **No nuevos blockers** sobre `BL-USDC` ya existente. El cleanup de
  `setCexReserve` no es estrictamente necesario antes de mainnet — los
  setters son `onlyRole(DEFAULT_ADMIN_ROLE)` (mismo nivel que
  `setBondMaturitySeconds`).
- Si se decide reactivar auto-injection post-mainnet, sólo hace falta
  deployar una `CEXLiquidityReserve` v5.1+, fundearla con LUMINA y llamar
  `bondVault.setCexReserve(<reserveAddress>)`. No requiere otro UUPS upgrade.

---

## 7. Archivos modificados en este sprint

| Path                                                   | Cambio                                                          |
| ------------------------------------------------------ | --------------------------------------------------------------- |
| `script/deploy/UpgradeBondVault.s.sol`                 | **NEW** — script UUPS upgrade del proxy BondVault.              |
| `audit-pack/sprints/2026-05-23-sprint-upgrade-bondvault-on-chain.md` | **NEW** — este documento.                          |
| `audit-pack/what-is-pending.md`                        | Changelog entry + item nuevo `CEX-RESERVE-DEFERRED`.            |

Tests Foundry: no se ejecutaron en este sprint (full `forge test` hangs en
Windows). Cobertura R1 ya estaba en main vía `test/audit/economic/` (Sprint
Fix Audit Economic Complete) — esos tests son código-side y no dependen del
estado on-chain.

---

## 8. Conclusión

R1 **aplicado on-chain parcialmente**: floor pause + hysteresis activos;
auto-injection diferido. PR draft `feat/upgrade-bondvault-on-chain`.
