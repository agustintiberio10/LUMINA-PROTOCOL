# Lumina V5.4 — Integral Revision (spec canónico vs landing/docs/SDK/API)

**Date**: 2026-05-26 · **Scope**: canonical on-chain spec contrasted against the landing,
docs, SDK and API. Read-only on-chain; landing config fixed where stale. No contracts modified.

## Executive Summary

The protocol's **runtime surfaces are consistent and correct**: the live API (`/health.contracts`,
`/products`) serves the canonical V5.4 addresses and reflects the on-chain Manual-Review fixes
(`payoutRatioBps = 8000`). The landing uses a **runtime-fetch architecture** (`hooks/use-contracts.ts`
→ `/health.contracts`), so the 6 user-facing contracts display correctly at runtime.

The gaps are in **static/fallback config and stale marketing copy**, not the live data path:
the landing's hardcoded `lib/lumina-config.ts` contract registry was **fully zeroed** ("OBSOLETE –
awaiting redeploy Sprint Z.2") and never repopulated — fixed this sprint with canonical addresses.
A product‑count inconsistency (landing "5 products" vs API 7 vs 6 real flash shields) and an API
base‑path inconsistency remain (documented).

**Consistency score: 7.5 / 10. Ready for Fase 5 público: YES** (with the documented follow-ups).

## Spec Canonical V5.4 (source: on-chain + /health + /products)

**Core (proxies, LIVE):** BondVault `0x193a…B6EC`, CoverRouterV2 `0xcdB7…F566`, PolicyManagerV2
`0x546C…cDd8`, ClaimBond `0xaa57…1FB4`, TWAPBurner `0x242d…1bC0`, BuybackEngine `0x56B5…d8B4`,
AdaptiveFeeDistributor `0xeC78…59D54`, Marketplace `0x0938…4345`, CapacityOracle `0xd52a…6545`,
SolvencyOracle `0x23f7…B7fe`, MaintenanceReserve `0xD78A…2A48`. **Token/non-upgradeable:**
LuminaTokenV2 `0x62C0…6680`, LuminaOracleV2 `0x9bfa…71dD`, FounderVesting `0xfF4D…2832`, mUSDC
`0xD944…6AE`. **6 flash shields + 6 adapters** (V5.4, per manifest). Full table:
`audit-pack/manifests/V5.4-canonical-deployed.{json,md}`.

**Products (from `/products`, verified):** all `payoutRatioBps = 8000` (MR-M01 live), `marginBps =
20000`, per-product `triggerProbBps`/`durationSeconds`; FLASHBTC 1h/24h/48h + FLASHETH 1h/24h/48h,
all `active:true`. **Gaps**: ShieldKeeper not wired (`adapter.keeper()==0x0` → relayer settlement),
CEXLiquidityReserve dormant (`cexReserve()==0x0`). Blockers: BL-USDC, BL-SANDBOX, BL-MULTISIG.

## Gaps detected

| # | Item | On-chain / API | Landing | Docs/SDK | Severity | Status |
|---|---|---|---|---|---|---|
| 1 | Core contract registry | canonical (live) | `lumina-config.ts` **all 0x0** "OBSOLETE" | n/a | 🔴 High (fallback) | **FIXED this sprint** (repopulated canonical) |
| 2 | CapacityOracle/TWAPBurner/BuybackEngine addresses | live | 0x0 in config (not in /health) | n/a | ⚠️ Medium | **FIXED** (repopulated) |
| 3 | mUSDC + Chainlink feed addresses | live | 0x0 "OBSOLETE" in config | n/a | ⚠️ Medium | **FIXED** (mUSDC `0xD944…`, BTC/ETH feeds) |
| 4 | Product count | API `count:7`; 6 real flash shields | landing meta **"5 products"** | docs vary | ⚠️ Medium | OPEN (stale marketing copy + API surfaces a 7th/legacy entry) |
| 5 | API base path | `/health`,`/products` at root; `/api/v1/faucet/claim` versioned | — | docs reference | ⚠️ Low | OPEN (inconsistent → agent friction) |
| 6 | payoutRatioBps=8000 (MR-M01) | ✅ /products | ✅ runtime | ✅ | ✅ | consistent |
| 7 | SDK version | — | — | npm `@lumina-org/sdk` **0.7.0** ✅ | ✅ | consistent |
| 8 | docs site | — | — | docs.lumina-org.com **HTTP 200** ✅ | ✅ | up |
| 9 | ShieldKeeper / CEXReserve | 0x0 (gap) | now 0x0 + comment | — | ⚠️ | documented gap |

## Updates Applied (this sprint)

- **Landing `lib/lumina-config.ts`** — repopulated the zeroed `CONTRACTS` registry + `TOKENS.USDC`
  + `ORACLES.{ETH,BTC}_USD` with canonical V5.4 addresses (ShieldKeeper/Phala/TreasuryVesting left
  0x0 with accurate gap comments). PR `feat/landing-live-data-v54`.

## Live Data Implementation (assessment — honest)

The landing **already implements runtime contract resolution** (`hooks/use-contracts.ts` →
`/health.contracts`), which is the right "redeploy-proof" pattern and why user-facing addresses are
correct despite the zeroed static config. A fuller live-stats layer (TVL, active policies, bonds
outstanding, capacity %, activity feed) as sketched in the sprint spec is **recommended but not
built here** — it requires a verified Next.js build I cannot validate in this environment, and the
core consistency win was repopulating the canonical fallback (done). Recommended next step: a
`lib/lumina-live.ts` reading `/health` + on-chain `BondVault`/`CapacityOracle` with ISR (30–60s) and
an RPC-down fallback to the static snapshot now in `lumina-config.ts`.

## Verdict

- **Consistency score: 7.5 / 10.** Runtime data path correct; static/fallback + marketing copy were
  the gaps (registry fixed; product-count + base-path open).
- **Listo para Fase 5 público: SÍ**, con follow-ups: (a) reconcile product count to 6 across
  landing/API/docs; (b) unify API base path; (c) build the live-stats layer; (d) refund the faucet
  (see agent-autonomy report — currently out of ETH).
