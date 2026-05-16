# 📜 Deprecated — historical reference only

> ⚠️ OBSOLETO — Direcciones citadas blanked en Sprint Z.2 pre-redeploy (bug L476-477).
> Documento conservado como registro histórico. Direcciones se repoblarán post-redeploy.

> ⚠️ **This document describes contracts from V1/V2/V4 that are NO LONGER DEPLOYED in V5.1.** Kept for historical reference and to prevent re-deployment of stale addresses. For current V5.1 architecture, see [`SECURITY.md`](../SECURITY.md), [`docs/ROADMAP-V5.md`](./ROADMAP-V5.md), and [`docs/architecture/AAVE-INTEGRATION.md`](./architecture/AAVE-INTEGRATION.md).

---

# V1 Deprecated Contracts — Base Mainnet

These contracts are deployed on Base mainnet (Chain ID 8453) from the V1 vault-based insurance model. They are **deprecated** and will be paused after V5.0 launch. No users, no active policies.

## Deployed Addresses

| Contract | Address | Status |
|---|---|---|
| CoverRouter (UUPS proxy) | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xd5f8678A0F2149B6342F9014CCe6d743234Ca025) --> | Deprecated |
| PolicyManager (UUPS proxy) | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xCCA07e06762222AA27DEd58482DeD3d9a7d0162a) --> | Deprecated |
| LuminaOracle V1 | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0x4d1140Ac8F8cB9d4fB4f16cAe9C9cBA13C44bC87) --> | Deprecated |
| LuminaOracleV2 | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0x87B576f688bE0E1d7d23A299f55b475658215105) --> | Deprecated |
| TimelockController | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xd0De5D53dCA2D96cdE7FAf540BA3f3a44fdB747a) --> | Active (governance) |
| Gnosis Safe (2/3) | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xa17e8b7f985022BC3c607e9c4858A1C264b33cFD) --> | Active (governance) |
| USDC (Base native) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Active (not ours) |

## V1 Vaults (all deprecated, zero TVL)

| Vault | Address |
|---|---|
| VolatileShort | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xbd44547581b92805aAECc40EB2809352b9b2880d) --> |
| VolatileLong | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904) --> |
| StableShort | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC) --> |
| StableLong | `0x0000000000000000000000000000000000000000` <!-- OBSOLETE - Sprint Z.2 cleanup, awaiting redeploy (was 0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c) --> |

## V1 Source Code

Archived in branch `legacy/v1-archive` and `archive/v1-vault-model/` + `archive/v1-deprecated/`.

## V5.0 Plan

V5.0 is a completely new deployment — no migration, no interaction with V1 contracts. V1 contracts will be paused via TimelockController after V5.0 launch.
