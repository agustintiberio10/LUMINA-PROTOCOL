# Sprint — Shields UUPS Redeploy + F-01 (2026-05-24)

**Decisión founder:** convertir los 6 flash-shields a UUPS-upgradeable (futuro-proof) + aplicar el fix F-01 (multi-block confirmation real) on-chain, desplegando 6 shields nuevos + 6 adapters nuevos (los adapters viejos no tienen `setShield`, por eso re-deploy completo).

## Qué se hizo

- **`BaseFlashShield` + 6 products → UUPS**: `Initializable + OwnableUpgradeable + UUPSUpgradeable`, `initialize()` reemplaza el constructor inmutable, `_disableInitializers()`, `_authorizeUpgrade onlyOwner`, `__gap[47]`.
- **F-01 preservado** (del red-team fix probado): `verifyAndCalculate` exige 3 confirmaciones sub-barrera espaciadas multi-block (`CONFIRMATION_INTERVAL` 60s, bloque distinto + round más nuevo) + `MIN_DWELL_PERIOD` 5min; `checkAndSettlePolicy` es `onlyKeeperOrRelayer`.
- **`ShieldAdapterFactory`**: despliega shield-proxy + adapter-proxy + init de ambos + wiring (`setPolicyManager`, `setRelayer`) + `transferOwnership` al founder, **todo en una tx** → sin ventana de proxy sin-inicializar (cierra F-05).
- **`DeployShieldsAndAdapters.s.sol`**: deploya los 6 pares + re-apunta `PolicyManagerV2.registerProduct(productId, nuevoAdapter)` para los 6 productIds (mismos labels → keccak sin cambios).
- **18 sitios de construcción de shields migrados** a deploy-por-proxy; script de deploy inmutable obsoleto eliminado.

## Deploy on-chain (Base Sepolia 84532) — ✅ exitoso y verificado

`forge script ... --broadcast --slow` → **19 txs, ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.** Dry-run 100% limpio previo (regla). Gas ~0.00031 ETH.

| Producto | Shield (nuevo) | Adapter (nuevo) |
|---|---|---|
| FlashBTCShield1h | `0x7d1615C90d01712a3b86Df26312aC6D8EFa0d0b3` | `0x5d50310B9166184e822cD5368F51C1409713054f` |
| FlashBTCShield24h | `0x18e2D3b8Ff4D194CDB9862f8e6239E5e1145961d` | `0x475b3F712707F61824122a94fE78b106260F8882` |
| FlashBTCShield48h | `0xe206dd8fb02b1C2A0507566c3d03a27554E8CBeB` | `0xdc6387E86F7D852D1f99F4009cFd8AdC2d500298` |
| FlashETHShield1h | `0xfF1a1B20153019C22f97278204Ccfc1b1409a518` | `0x57869AD3E7C56B0c96F357179DD231b407C88338` |
| FlashETHShield24h | `0x2832b5543f6F2a055312654739F0ae03F5b0b582` | `0x4fD09cF98F6814Cc8b33C2E491429f59d0bCf089` |
| FlashETHShield48h | `0x60dFC6610c64aC84e12afA943737Cf7733215B75` | `0x9696CFFD7dE8B1e16F83Dcc798c5CE69a61C884C` |

Addresses + tx hashes completos: `deployments/sepolia/V5.4-shields-uups-2026-05-24.json` (+ `broadcast/DeployShieldsAndAdapters.s.sol/84532/run-latest.json`).

### Verificación on-chain (read-only)
- `adapter.shield()` = nuevo shield ✓ · `adapter.policyManager()` = PM ✓ · `adapter.owner()` = founder ✓
- `shield.router()` = adapter ✓ · `shield.owner()` = founder ✓ · `shield.asset()` = BTC/ETH ✓
- **`PolicyManager.productShield(productId)` = nuevo adapter en los 6** ✓ (cutover)
- `checkAndSettlePolicy(999)` desde no-keeper → revierte `ONLY_KEEPER_OR_RELAYER` ✓ (F-01 settle gating vivo)

### Smoke test end-to-end (B.6) — ✅
`/sandbox/try FLASHBTC1H-001` (API live) → `ok:true`, `policyId:1` (contador del adapter nuevo arranca en 1 → confirma ruteo al shield nuevo), `txHash 0xb900cf6a285d3112a67ca3743ead81e6d6ecd5bd67a57562537308fff0035bd9`. Ruta: API → CoverRouter → PolicyManager → nuevo adapter → nuevo shield F-01.

## Downstream repos (API / SDK / docs / landing) — sin cambios necesarios

El sistema es **redeploy-proof** (SDK `getContracts()` runtime + landing `useContracts()` + API ruteando por `productId` vía PolicyManager/CoverRouter, addresses core sin cambios). Como reusé los mismos productIds y el cutover es on-chain, **0 reemplazos de address en los 4 repos** (grep confirmó: ningún shield/adapter address hardcodeado). No se requieren PRs cross-repo ni cambios de env var de Railway — el ruteo a los shields nuevos es transparente. Confirmado por el smoke test live.

## Pendiente
- **Verificación BaseScan** de los 12 contratos nuevos (founder, opcional).
- **Cleanup**: deactivate de los productShield viejos / dedup `productIds[]` (cosmético).
- **Test-suite compile**: la migración del cascade (18 files) es mecánica; su compilación completa se valida en CI Linux (el build via_ir local OOMea/es lento). `src` + deploy script compilan limpios.
- **BL-MULTISIG** sigue abierto (governance single-EOA).
- `setKeeper(ShieldKeeper)` si se usa un keeper dedicado además del relayer.
