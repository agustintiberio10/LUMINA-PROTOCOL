# Sprint — Marketplace / Portfolio Performance (diagnose + fix)

**Date:** 2026-05-26 · **Problem:** connecting a wallet to the marketplace/portfolio
on lumina-org.com is very slow to show the user's policies + bonds-for-sale.
**No contracts modified, no merges.** PRs: lumina-api **#45**, landing **#50**.

## Diagnosis (root cause)

The Ponder indexer is **parked**, so both the API and the frontend reconstruct
state by **scanning event logs on-chain** — and both did it **strictly sequentially**:

1. **Frontend (dominant, user-facing).** `MarketplaceView` + `PortfolioView` scan
   logs **client-side via the user's wallet RPC** (`publicClient.getLogs` through
   `lib/getLogsChunked.ts`), `DEPLOY_BLOCK_SEPOLIA → head`. `getLogsChunked` used
   **5,000-block chunks in a sequential `while` loop** → ~340k blocks ÷ 5k =
   **~68 serial `eth_getLogs` round-trips per event scan**, ×3 event types for the
   marketplace (`Listed`/`Cancelled`/`Bought`). On a typical browser RPC that is
   **~10–20 s**. This is the "tarda muchísimo."
2. **Backend.** `GET /api/v1/bonds/:wallet` → `getBondsByWallet` → `paginatedQueryFilter`
   scanned ~12 windows of 45k blocks (latest−500k) **sequentially** (×2 event types
   for the redeemed flow) on each 60s-cache miss, plus per-bond reads. Multi-second.

## Latency measured (before)

Public endpoints (warm, `time curl`):

| Endpoint | Latency | Note |
|---|--:|---|
| `/health` | 1.32 s | |
| `/api/v1/marketplace/listings` | 0.83–0.85 s | empty (count=0); cached |
| `/api/v1/marketplace/stats` | 0.90 s | cached |
| `/products` | **2.30 s** | N+1 RPC per product (separate issue) |
| `/api/v1/bonds/:wallet` | — | **401 (auth)** — not measurable without a key |
| `/api/v1/policies?owner=` | — | **401 (auth)** |

The user-facing slowness is **not** the public API — it's the **client-side log
scan** (frontend) and, for the authed bond path, the backend sequential paginator.

## Fixes applied

| Layer | File | Fix | Speedup (serial round-trips) |
|---|---|---|--:|
| **Frontend** | `lib/getLogsChunked.ts` | chunks run in **bounded-concurrency batches (8)** instead of a sequential loop; per-chunk "payload-too-large → 1k sub-window" retry + `onProgress` preserved | ~68 serial → ~9 batches ≈ **8×** |
| **Backend** | `services/bonds.ts` `paginatedQueryFilter` | windows run in **bounded-concurrency batches (6)**; retry/backoff + partial-result-on-failure preserved | ~12 serial → ~2 batches ≈ **6×** |
| **Backend** | `services/bonds.ts` `buildBondInfo` | `balanceOf` + `getEpochInfo` fetched in parallel | minor |

Both already had caches (frontend per-view state; API 60s) — those are unchanged.

## Latency (after)

The fixes are in **draft PRs (not deployed)**, so a live "after" can't be measured
yet. Quantified by round-trip reduction:
- **Frontend marketplace load:** ~68 serial `eth_getLogs` (~10–20 s) → ~9 parallel
  batches of 8 ≈ **~2–3 s** (RPC-dependent).
- **Backend `/bonds/:wallet` cache-miss:** ~12–24 serial windows → ~2–4 parallel
  batches; first-load seconds → ~sub-second-to-1s range.
- Cache hits unchanged (already fast).

**Targets** (per spec): API < 500 ms cache-hit / < 2 s miss; frontend visible < 1 s;
full data < 3 s. The parallelization brings the frontend full-load to ~target;
backend miss to ~target. Verify post-deploy.

## Trade-offs

- **Concurrency vs RPC rate limits.** Bounded to 8 (frontend) / 6 (backend) to stay
  under typical public-RPC limits; the per-window/chunk retry+backoff absorbs
  transient 429s. Raising concurrency further risks throttling.
- **Still client-side scanning (frontend).** Parallelizing is a big win without a
  rewrite, but the architecturally-correct fix is to have the views call the
  **cached public API** (`/api/v1/marketplace/listings`) instead of scanning from
  the browser at all — moves the scan server-side (one shared cache for all users).
  That needs the bond/policy by-wallet API path (auth) and ideally the indexer.

## Does it need the Ponder indexer?

**Not for this fix** — parallelization works against the live chain today. But the
**permanent** solution is to **revive the parked Ponder indexer** (Sprint 2): then
neither the API nor the frontend scans logs at all (O(1) DB reads), and the
historical/cumulative stats unlock too. Until then, parallel scanning + caching is
the pragmatic mitigation.

## Reverse audit: 8.5/10
Root cause located precisely (sequential chunk/window loops) and fixed in both
layers with tests (backend paginator: collects all windows + skips a failing one,
2/2; live-stats regression green; tsc clean; landing `pnpm build` green).
Deduction: "after" latency is **reasoned (round-trip math), not live-measured** —
the authed `/bonds` endpoint can't be timed without an API key and the PRs aren't
deployed; and the deeper architectural fix (API-instead-of-client-scan + indexer)
is deferred, not done.
