# Sprint T-30a — Founder Decisions Snapshot

**Fecha**: 2026-05-20
**Sprint**: T-30a (re-implementación shields + protecciones P0)
**Status**: ACEPTADO + EN EJECUCIÓN

## 10 decisiones founder (NO discutir, ya tomadas)

| # | Decisión | Implementación |
|---|---|---|
| 1 | RateShock: BORRAR completamente | `git rm` shield + tests + workflow refs (Phase B) |
| 2 | Re-deploy fresco (no UUPS upgrade) | T-30a NO deploya (deploy es T-30c) |
| 3 | Throttle BondVault: MAX 1.08%/sem | `MAX_REDEMPTION_PER_EPOCH_BPS=108`, FIFO queue (Phase D) |
| 4 | Primas: margin 2.00x | `marginBps=20000`, multiplicador efectivo 1.60x (config side) |
| 5 | Sequencer L2 check | `whenSequencerActive` modifier en CoverRouterV2 + shields (Phase E) |
| 6 | Strike snapshot: spot al momento de compra | `strikePrice` capturado en `createPolicy` (no average) |
| 7 | Trigger: "drop from purchase price" | `(strikePrice - currentPrice) * 10000 / strikePrice >= TRIGGER_DROP_BPS` |
| 8 | Deductible: 20% | `DEDUCTIBLE_BPS=2000` constant |
| 9 | Oracle: Chainlink BTC/USD y ETH/USD | Direct AggregatorV3Interface, NO LuminaOracleV2 EIP-712 |
| 10 | Auto-refill BondVault: NO | Sin auto-refill — manual top-up + throttle protege |

## 6 productos nuevos (RateShock borrado, no se reemplaza)

| Shield | Trigger drop | Ventana | TRIGGER_DROP_BPS | WINDOW (s) | Oracle |
|---|---|---|---|---|---|
| FlashBTCShield1h | BTC ↓ 2.5% desde compra | 1h | 250 | 3600 | Chainlink BTC/USD |
| FlashBTCShield24h | BTC ↓ 6% desde compra | 24h | 600 | 86400 | Chainlink BTC/USD |
| FlashBTCShield48h | BTC ↓ 10% desde compra | 48h | 1000 | 172800 | Chainlink BTC/USD |
| FlashETHShield1h | ETH ↓ 4% desde compra | 1h | 400 | 3600 | Chainlink ETH/USD |
| FlashETHShield24h | ETH ↓ 8.5% desde compra | 24h | 850 | 86400 | Chainlink ETH/USD |
| FlashETHShield48h | ETH ↓ 14% desde compra | 48h | 1400 | 172800 | Chainlink ETH/USD |

## Constantes comunes

```solidity
uint16 constant DEDUCTIBLE_BPS = 2000;       // 20% deductible → 80% payout
uint8  constant ORACLE_CONFIRMATIONS = 3;    // 3 lecturas separadas
uint32 constant CONFIRMATION_INTERVAL = 60;  // 60s entre lecturas
// MIN_DURATION = MAX_DURATION = WINDOW (póliza dura exactamente la ventana)
```

## Cross-refs

- ADR-026 (Sprint EE): set 7 shields, MicroDepeg + FlashBTC4h removidos. **Sprint T-30a invalida ADR-026**: RateShock también removido + los 6 restantes se re-implementan con drop-from-purchase mechanic (en V5.2 era drop-from-strike-snapshot signed via EIP-712).
- ADR-027 (Sprint Deploy): 26 contratos V5.2 deployados a Sepolia. Sprint T-30a NO deploya — eso es T-30c.

## Sprint T-30a scope (ESTRICTO)

- Phase A: setup + decisions ADR (este doc).
- Phase B: delete old shields + RateShock + tests + workflow refs.
- Phase C: implement BaseFlashShield + 6 new shields.
- Phase D: BondVault throttle + tests.
- Phase E: Sequencer L2 check + tests.
- Phase F: unit + integration + Echidna property scaffolds (NO 200k runs).
- Phase G: forge build + test (validación local; CI corre full).
- Phase H: audit-pack update.
- Phase I: push + draft PR.

## Out of scope (NO ejecutar acá)

- ⛔ NO deploy (T-30c).
- ⛔ NO Echidna 200k full (T-30b).
- ⛔ NO Halmos full (T-30b).
- ⛔ NO Slither/Aderyn/Mythril deep dive (T-30b).
- ⛔ NO modificar Railway/Vercel.
- ⛔ NO merge PR.
