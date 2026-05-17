# Architectural decisions — LUMINA-PROTOCOL (Sprint FV slice)

> This file in **LUMINA-PROTOCOL** carries the Sprint-FV-specific ADR slice
> only. The canonical ADR ledger lives in `lumina-testnet-tracker` →
> `tracking/architectural-decisions.md`. ADR-025 below will be mirrored there
> in a follow-up tracker PR.

---

## ADR-025 — FounderVesting V2: PATH 2 Override + adjusted durations + oracle wiring fix

**Fecha**: 2026-05-16
**Estado**: APROBADO por founder. Código + tests listos. Deploy diferido a Sprint Deploy posterior.
**PR asociada**: `feat/sprint-fv-override` en `LUMINA-PROTOCOL`.

### Decisión

Cuatro cambios al `FounderVesting`:

1. **`SUSTAINED_DURATION = 1 day`** (antes 7 días).
2. **`FALLBACK_DURATION = 1095 days`** = 3 años (antes 1460 días = 4 años).
3. **Nueva condición override**: `ETH_OVERRIDE_THRESHOLD = $5,000 USD` (`500_000_000_000` en decimales Chainlink 8-dec) como PATH 2 independiente. ETH > $5000 sostenido 1 día activa el unlock sin necesidad de que PATH 1 (2-of-3) se cumpla.
4. **Owner = Recipient = founder wallet** (`0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8`). `recipient` modificable vía `updateRecipient(address)` (`onlyOwner`). `owner` es immutable post-deploy.

Cambio adicional crítico en el deploy script (`script/deploy/DeployLuminaV5Complete.s.sol:246-249`):

5. **Oracle wiring fix**: FV ahora se construye con `res.luminaOracleV2` (EIP-712 price oracle con `getLatestPrice(bytes32)`), **NO** `res.capacityOracle` (que tiene una ABI distinta). En Sepolia esto resuelve a `LuminaOracleV2 SET A 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194`. Sin este fix la versión deployada en Sprint VA/VB quedaba con un oracle wrong-typed que hubiera revertido al primer `checkAltSeason()` real.

### Lógica final — 3 paths independientes, primer trigger gana

| Path | Condición | Sostenido | Trigger event |
|---|---|---|---|
| 1 | 2-of-3 (A: ETH/BTC > 0.050; B: ETH > $4000; C: Aave V3 USDC borrow > 7% APY) | 1 día | `AltSeasonTriggered` |
| 2 | ETH > $5000 USD | 1 día | `OverrideTriggered(ethPrice, timestamp)` |
| 3 | Fallback 1095 días desde `deployedAt` | n/a | `FallbackTriggered` |

En `checkAltSeason()`:
- PATH 1 se evalúa primero. Si ya sostuvo, `return`.
- PATH 2 se evalúa segundo. Si ya sostuvo, `return`.
- Si ambas dejan de cumplir en la misma transacción, los contadores se resetean independientemente (con eventos `SustainedPeriodReset` / `OverrideConditionLost`).
- Si PATH 1 y PATH 2 satisfacen el sostenido en el mismo bloque, PATH 1 gana (orden de evaluación).

### Razones

- **1 día sostenido**: respuesta más rápida sin perder protección contra manipulación whale. 7d era excesivo para Sepolia y mainnet con feed estable.
- **3 años fallback**: timeline más realista para certeza de inversores; 4 años se sentía punitivo.
- **Override $5,000**: founder quiere acelerar unlock si ETH llega a un nivel donde altseason es altamente probable, incluso si las otras 3 condiciones no convergen en el mismo bloque.
- **Owner = Recipient**: simplicidad operativa para founder no-técnico. Si la wallet se compromete, `updateRecipient` permite recuperar antes de que un atacante dispare `releaseTranche`.
- **Oracle fix**: bug detectado en revisión post-Sprint Z.2; FV viejo nunca se ejercitó on-chain debido al testnet bricked, pero hubiera fallado al primer trigger real.

### Lecciones aplicadas (de incidentes previos)

1. **Bug L476-477 multisig grant+revoke** (Sprint T → ADR-012) — invariantes `require(...)` en deploy script se preservan; este sprint NO toca esa zona.
2. **Oracle wiring wrong** (Sprint Z.2 forensics) — fix punto 5 arriba + tests Wiring fork (W1-W8) verifican que `FV.oracle()` apunta a SET A.
3. **Tests previos solo usaban mocks** — Sprint FV añade `test/integration/immutables/FounderVestingV2E2EFlows.t.sol` (fork Base Sepolia + `vm.mockCall` sobre la address REAL del oracle SET A).
4. **Antes solo se auditaban contratos `.sol`, no scripts de deploy** — Sprint FV audita el deploy script en Phase A + corrige el oracle wiring en Phase B.
5. **Founder no-técnico** — runbook operativo `runbooks/founder-vesting-operations.md` (Phase F) explica verificación de cobro en 3 formas independientes (BaseScan / Wallet / cast call).

### Tests

- **Echidna 10 props** (`test/echidna/immutables/EchidnaFounderVestingV2.sol`) — 8 invariantes Z.1-style + 2 nuevas para PATH 2. Config en `echidna-fv.yaml` (200k runs, seqLen 100).
- **60 edge cases** (`test/unit/immutables/FounderVestingV2EdgeCases.t.sol`) — 41 ajustados (7d→1d, 4y→3y) + 19 nuevos (10 T-OVR + 9 T-COBRO).
- **10 E2E fork** + **8 wiring fork** (`test/integration/immutables/FounderVestingV2{E2EFlows,Wiring}.t.sol`) — fork Base Sepolia, oracle SET A, todos guardados con `requiresFork` para skipear local sin RPC.

### Confirmación on-chain post-deploy (obligatorio en Sprint Deploy posterior)

```bash
cast call <FV_ADDRESS> "SUSTAINED_DURATION()(uint256)" --rpc-url $RPC
# expected: 86400

cast call <FV_ADDRESS> "FALLBACK_DURATION()(uint256)" --rpc-url $RPC
# expected: 94608000

cast call <FV_ADDRESS> "ETH_OVERRIDE_THRESHOLD()(uint256)" --rpc-url $RPC
# expected: 500000000000

cast call <FV_ADDRESS> "oracle()(address)" --rpc-url $RPC
# expected: 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194  (LuminaOracleV2 SET A)
```

Si cualquiera de los 4 valores no matchea, **DETENER el deploy** y revisar el script.

### Decisiones founder ya tomadas (no preguntar de nuevo)

- 4ta condición override es PATH INDEPENDIENTE (no se requiere combinación con condA/B/C).
- Sostenido 1 día para override (mismo período que PATH 1).
- Override NO afecta fallback PATH 3 — los 3 paths permanecen independientes.
- Owner = Recipient = founder wallet.
- NO bot keeper — activación manual del founder (o cualquiera puede llamar `checkAltSeason`).
- Tests deben ser EXHAUSTIVOS sobre cobro: balance pre/post, evento emitido, address destino, dust handling.

### Consecuencias

**Pro:**
- Unlock más rápido si las condiciones se cumplen (1d vs 7d).
- Path adicional para escenarios alcistas extremos sin requerir convergencia de 3 indicadores.
- Fallback timeline más realista para inversores.
- Bug oracle wiring fixed antes del próximo deploy.
- Cobertura de tests más profunda: fork + Echidna + 60 edge cases.

**Con:**
- Más superficie de attack: 2 paths activos en `checkAltSeason()` en lugar de 1.
- Mayor sensibilidad a ETH spikes manipulados — mitigado por sostenido 1d.
- Override threshold $5,000 es un número discreto; si ETH baila alrededor (e.g. $4998-$5002) y el founder no calibró bien, el counter resetea constantemente.

### Status

ACEPTADO — código + tests + runbook listos. Deploy real en Sprint Deploy posterior (incluye redeploy completo V5.1 post-Sprint Z.2 cleanup).

---

## ADR-026 — Sprint EE: Shield Testing Exhaustivo + Eliminación MicroDepeg + Asimetría

**Fecha**: 2026-05-17
**Estado**: APROBADO por founder, pendiente de deploy
**PR asociada**: `feat/sprint-ee-shields-testing` en `LUMINA-PROTOCOL`.

### Decisión

1. **ELIMINAR `MicroDepegShield`** del set actual (Phase A).
2. **ELIMINAR `FlashBTCShield4h`** al final del sprint para simetría con FlashETH (Phase H).
3. **SET FINAL: 7 shields** (FlashBTC 1h/24h/48h, FlashETH 1h/24h/48h, RateShock).
4. **Testing exhaustivo**: 64 Echidna props × 200k + 480 unit + 80 E2E fork + 64 wiring + 50 stress = **738 tests + 64 props**.

### Razones

- **MicroDepeg**: Chainlink Sepolia no tiene un feed USDT confiable. No se puede validar el trigger de depeg en fork tests. Sin testing E2E confiable, el shield no puede deployarse responsablemente.
- **FlashBTC 4h**: la asimetría con FlashETH (que solo tiene 1h/24h/48h) no está justificada actuarialmente. La 4h se eliminó **después** de haber sido testeada (cumple la lección: probar antes de borrar).
- **Stress testing**: Sprint FV cubrió FounderVesting (3 paths, surface limitada). Los shields tienen attack-surface más amplio: precio oracle, ventana, sequencer, premium, redención de bond, gas griefing — momento de probarlos a fondo.

### Parámetros confirmados por founder (no preguntar de nuevo)

| Parámetro | Valor |
|---|---|
| Umbral caída | Valor actuarial del `.sol` actual (no modificar) |
| Ventana | Desde firma hasta cumplir X horas (móvil) |
| Cooldown | NO (cada póliza tiene su ventana independiente) |
| Confirmación oracle | 3 lecturas separadas 60s (filtra flash crashes) |
| Staleness Chainlink | Fail silent — la póliza expira sin payout |
| Sequencer Base L2 down | Fail silent (mismo criterio) |
| Duración póliza | Igual a la ventana (Flash 1h dura 1h) |
| Payout | Bond ERC-1155 redimible 2 años en LUMINA al precio del momento |

### Lecciones aplicadas

1. Bug L476-477 multisig grant+revoke (Sprint T → ADR-012) — invariantes `require(...)` confirmadas intactas en Phase A.2.
2. Oracle wiring wrong (Sprint Z.2 + FV fix) — tests E2E con address REAL `LuminaOracleV2 SET A 0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194`.
3. Tests con mocks no detectan bugs de integración — fork tests obligatorios con `requiresFork` modifier.
4. Auditar deploy scripts integralmente — ambos modificados en Phase A (MicroDepeg removal) y Phase H (FlashBTC4h removal).
5. Founder no-técnico — runbook `docs/runbooks/SHIELDS-OPERATIONS.md` con activación trigger, redención bond, 3-formas verificación.

### Test coverage delivered

| Shield | Echidna | Edge | E2E fork | Wiring |
|---|---|---|---|---|
| FlashBTC 1h | 8 | 60 | 10 | 8 |
| FlashBTC 4h * | 8 | 60 | 10 | 8 |
| FlashBTC 24h | 8 | 60 | 10 | 8 |
| FlashBTC 48h | 8 | 60 | 10 | 8 |
| FlashETH 1h | 8 | 60 | 10 | 8 |
| FlashETH 24h | 8 | 60 | 10 | 8 |
| FlashETH 48h | 8 | 60 | 10 | 8 |
| RateShock | 8 | 60 | 10 | 8 |
| **TOTAL** | **64** | **480** | **80** | **64** |

\* FlashBTC 4h testeada antes de eliminación en Phase H.

Plus **50 stress tests** en `test/stress/shields/ShieldStressAttacks.t.sol`.

### Findings de stress tests (informativo, NO auto-fixed)

5 puntos de diseño que merecen revisión pre-mainnet:

1. `BaseShield` no tiene `nonReentrant` modifier — defense-in-depth via `onlyRouter`. Aceptable si router es trusted, pero documenta una asunción.
2. Shields aceptan premiums arbitrariamente bajos — solvencia delegada a `PolicyManagerV2`/`BondVault`.
3. No hay selector `pause()` a nivel shield — solo via UUPS upgrade o `GlobalPauseRegistry` global.
4. Trigger usa precio firmado EIP-712, no spot live — expande blast radius del signer.
5. `verifyAndCalculate` es idempotente pre-finalize — gate de finalización está en `markPaidOut`.

### Confirmación on-chain post-deploy (obligatorio en Sprint Deploy)

Por cada shield deployado:

```bash
cast call <SHIELD> "TRIGGER_DROP_BPS()(uint256)" --rpc-url $RPC
cast call <SHIELD> "MIN_DURATION()(uint32)" --rpc-url $RPC
cast call <SHIELD> "DEDUCTIBLE_BPS()(uint256)" --rpc-url $RPC
cast call <SHIELD> "router()(address)" --rpc-url $RPC      # == PolicyManagerV2
cast call <SHIELD> "oracle()(address)" --rpc-url $RPC      # == LuminaOracleV2 SET A
```

Si valores no matchean wiring tests W7, **DETENER deploy**.

### Consequences

**Pro:**
- 7 shields probados con 738 tests + 64 Echidna props + 50 stress.
- Set simétrico (BTC y ETH con mismas ventanas).
- Lecciones Sprint FV aplicadas (oracle wiring real, fork tests).
- Stress adversarial cubre flash loans, MEV, gas grief, reentry, DoS, timing, multi-shield cascade.

**Con:**
- Tiempo CI alto: Echidna 8 × 200k = ~6h en CI Linux (sequential per shield).
- 480 unit tests aumentan `forge test FULL` (~+5-10 min).
- Stress tests pueden ser flaky (mocks complejos).
- ~20 `vm.skip(true)` documentados — tests que asumen comportamiento que vive en otros contratos (BondVault, CoverRouterV2, PolicyManagerV2).

### Status

ACEPTADO — código + tests + runbook listos. Deploy real en Sprint Deploy posterior (redeploy completo 27 contratos V5.1 con set final 7 shields).
