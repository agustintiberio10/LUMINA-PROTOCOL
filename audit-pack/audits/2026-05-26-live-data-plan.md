# Live Data Audit + Real-Time Plan (landing)

**Date:** 2026-05-26 · **Scope:** inventory every number shown on the public web
(lumina-org.com + docs) — hardcoded vs live — and a plan to make the right ones
real-time. **READ-ONLY: audit + plan, nothing modified.**

## Executive Summary

The landing is **already ~half live**: contract addresses, API health, the short
whitepaper's "Live State" section, product **premiums**, and the whole `/operate`
app pull live data. The gap is the **home Hero stats block** (price, total burned,
bond reserve, active bonds, burn ratio) and the footer — **100% hardcoded mock
values**, the most prominent numbers on the site. The infrastructure to fix this
largely **already exists**: a proven server-side ISR fetch pattern in `app/page.tsx`
(used for premiums) + `Section8LiveState` (`/health`, `revalidate:30`), and a set of
**stats endpoints already coded in `lumina-api`** (`indexer.ts`) that are simply
**disabled** (the Ponder indexer is parked).

---

## Phase A — Inventory of numbers

| Surface | Number(s) | Source | Live? | Refresh |
|---|---|---|---|---|
| Home **Hero** | $LUMINA price `$0.0364` (+2.31%) | hardcoded `Hero.tsx:92` | ❌ | never |
| Home Hero | Total Burned `1,284,402` | hardcoded `Hero.tsx` | ❌ | never |
| Home Hero | Bond Reserve `82,000,000` | hardcoded (real ≈70M) | ❌ | never |
| Home Hero | Active ClaimBonds `2,184` | hardcoded | ❌ | never |
| Home Hero | Burn Ratio (30d) | hardcoded | ❌ | never |
| Home Hero | `BURN_EVENTS` ticker | hardcoded fake (`setInterval`) | ❌ | fake |
| Home **Products** | premium per product (6) | **LIVE** `/products/{id}/quote` (server fetch, `app/page.tsx:43-72`, fallback to static) | ✅ | ISR 1h |
| Short WP **Live State** | chain/block/relayer/contracts | **LIVE** `/health` (`Section8LiveState`, `revalidate:30`) | ✅ | 30s |
| Contract addresses (app) | coverRouter/bondVault/… | **LIVE** `/health` (`hooks/use-contracts.ts`, react-query) | ✅ | on load |
| `LiveStatusBadge` / `protocol-status` | API up + chainId | **LIVE** `/health` (`no-store`) | ✅ | on view |
| **SiteFooter** | "BURN RATIO 1.50 · 6 PRODUCTS" | hardcoded `SiteFooter.tsx:120` | ❌ | never |
| `/operate` app (bonds/policies/marketplace) | user positions | **LIVE** authed API (client) | ✅ | client |
| docs Mintlify (`/tokenomics`, specs) | distribution, triggers, etc. | hardcoded mdx (correct, static) | ❌ (by design) | — |

**Backend (lumina-api) availability:**
- **Live now:** `/health` (chain block, relayer balance, contracts), `/products` + `/products/{id}/quote`, `/api/v1/marketplace/stats`.
- **On-chain derivable now (RPC, no indexer):** LUMINA price (`CapacityOracle.getLuminaPrice()`), Bond Reserve (`LUMINA.balanceOf(bondVault)`), capacity used (`BondVault.availableCapacityUSD()`).
- **Coded but DISABLED:** `indexer.ts` stats — `/api/v1/stats/{total-policies,total-bonds-issued,total-lumina-burned,burn-rate-7d,policy-volume-24h}` — commented out in `app.ts:145` because they `SELECT … FROM policy` against a **Ponder indexer DB that is parked** (would 503). Confirmed **404 live**.

---

## Phase B — What to make live (prioritized)

### ✅ Live NOW from existing endpoints (no indexer needed)
| Stat | Source | Note |
|---|---|---|
| LUMINA price | `CapacityOracle.getLuminaPrice()` (RPC) | replaces hardcoded `$0.0364`; real ≈ $0.036 |
| Bond Reserve | `LUMINA.balanceOf(bondVault)` (RPC) | replaces `82,000,000`; real ≈ 70M |
| Capacity used % | `BondVault.availableCapacityUSD()` vs reserve value | new, meaningful |
| Premiums (6) | `/products/{id}/quote` | **already live** ✅ |
| Chain / API status | `/health` | **already live** ✅ |

### ⚠️ Needs the (parked) Ponder indexer — historical/cumulative
- Total LUMINA burned (cumulative), Total bonds issued, **Active ClaimBonds count**, Policy volume 24h, Burn rate 30d, ActivityFeed (recent events). All require event indexing (`indexer.ts` already implements them; the Ponder runtime must be revived + `indexerRouter` mounted).

### ❌ Keep hardcoded (correct)
- Tokenomics distribution (70/14/8/5/3), product specs (triggers/windows), explanatory copy. Static by design — these don't change.

---

## Phase C — Recommended architecture: **Option C (Hybrid)**

1. **Aggregate "instant" stats → ISR.** Add a `GET /api/v1/live-stats` aggregator in `lumina-api` that server-side reads `/health` + RPC (price/reserve/capacity) and **caches 30–60s**. The frontend makes **one** cached fetch (ISR `revalidate:30`), not N RPC calls per visitor. Extend the **existing proven pattern** in `app/page.tsx` (already does this for premiums) + `Section8LiveState` (already does `/health` ISR) to feed `<Hero stats={…} />`.
2. **Historical aggregates → revive Ponder + mount `indexerRouter`.** The endpoints are already written; this is an ops task (run the indexer, un-comment `app.ts:145`). Powers total-burned / bonds-count / volume / ActivityFeed.
3. **User-specific data → client-side.** Already done in `/operate` (authed, live). No change.

This beats pure client-side (Option B: every visitor spams RPC) and pure ISR (Option A: no per-user liveness), matching the existing codebase patterns.

---

## Phase D — UI components (most already exist)

| Proposed | Status | Action |
|---|---|---|
| **LiveStatsHero** | Hero is hardcoded | Refactor `Hero.tsx` to accept a `stats` prop; `app/page.tsx` passes ISR `live-stats` (mirror the premium pattern). **Main UI work.** |
| **LivePremiumCard** | ✅ done | `Products.tsx` live-premium overlay already shipped. |
| **LivePriceTicker** | — | Small: LUMINA price from `live-stats`; can replace the static Hero price line. |
| **ActivityFeed** | fake `BURN_EVENTS` | Needs indexer (recent policies/bonds/burns). Replace the mock ticker. |
| **StatusIndicator** | ✅ mostly | `LiveStatusBadge`/`protocol-status` exist; extend with capacity/oracle/sequencer from `live-stats`. |

---

## Phase E — Backend changes

- **New:** `GET /api/v1/live-stats` aggregator (RPC reads: LUMINA price, bond reserve, capacity, + echo chain/relayer from health) with a **30–60s in-process cache**. Removes RPC load from the frontend; single fetch.
- **Revive:** the parked **Ponder indexer** + un-comment `app.use("/api/v1", indexerRouter)` (`app.ts:145`) to unlock the 5 historical stats endpoints (already implemented).
- No contract changes.

---

## Phase F — Effort estimate

| Item | Effort |
|---|---|
| `/api/v1/live-stats` aggregator (instant stats, cached) | 0.5–1 day |
| Wire `<Hero>` to ISR live-stats (refactor props + page fetch) | 0.5 day |
| LivePriceTicker + StatusIndicator polish | 0.5 day |
| Revive Ponder indexer + mount `indexerRouter` (historical) | 1–2 days (ops) |
| ActivityFeed (real events, needs indexer) | 0.5 day |
| **Total** | **~3–4 days** |
| **Instant-stats-only subset** (no indexer; biggest credibility win) | **~1.5–2 days** |

---

## Phase G — Trade-offs (caching vs freshness)

- **ISR 30–60s via aggregator (recommended):** efficient (1 cached server fetch), no RPC spam, ≤60s stale — imperceptible for TVL/price/reserve. Risk: a paused/failed aggregator serves last-good or falls back to static (the existing premium/health code already fails-silent to hardcoded — keep that pattern so the page never breaks).
- **Pure client-side 30s:** truly live but every visitor hits RPC/API → cost + rate-limit risk at scale. Reserve for `/operate` per-user data (already the case).
- **Historical stats depend on the Ponder indexer**, which is currently parked — until revived, surface only the instant on-chain stats and **omit** (don't fake) cumulative numbers. The current hardcoded "Total Burned / Active ClaimBonds" should either go live (needs indexer) or be removed rather than shown as invented figures.

### Key recommendation
Ship the **instant-stats subset first** (~1.5–2 days): replace the fake Hero price/reserve/capacity with `/api/v1/live-stats` (real values already on-chain), and **remove or gate** the cumulative "Total Burned / Active ClaimBonds / Burn Ratio" mock numbers until the Ponder indexer is revived — showing invented aggregates on the homepage is the biggest credibility risk today.

## Confidence / limitations
Inventory verified by reading the landing source + testing endpoints live (stats endpoints 404; /health, /products/quote live). Did not run a full DOM crawl of every Mintlify page (docs numbers are static mdx, covered by the separate whitepaper-consistency audit). No code changed.
