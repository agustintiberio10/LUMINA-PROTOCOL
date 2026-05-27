# Testnet E2E Exhaustive — LUMINA V5.4

**Date**: 2026-05-26
**Network**: Base Sepolia (chainId 84532)
**API**: https://lumina-api-production-ac85.up.railway.app
**Landing**: https://www.lumina-org.com
**Founder/test wallet**: 0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8
**Relayer**: 0x168dC7105e907294f9d066cee24f30caa5A17E4a

> ⚠️ **Scope limit — no signing key.** `instrucciones2.txt` line 7 (`FOUNDER_PRIVATE_KEY=<PEGAR_AQUI_PRIV_KEY>`)
> was left as a placeholder and no key was present in the environment. Per the standing rule (never
> fabricate/reuse a private key), **all phases that require a signed transaction were not executed and are
> marked BLOCKED**: Phase C (trigger→bond→redeem), Phase D writes (marketplace list/cancel/buy), Phase E
> revert-path edge cases, Phase J (multi-wallet), Phase K.1/K.2 (write stress). Every **read-only / sandbox /
> API / SDK / MCP** test below ran for real with live responses + tx hashes.

---

## Test Matrix

| Category | Tests | Pass | Fail | Blocked (no key) |
|---|---|---|---|---|
| Products (quote+sandbox) | 6 | 6 | 0 | 0 |
| Triggers (C) | 8 | 0 | 0 | 8 |
| Marketplace (D) | 8 | 2 (reads) | 0 | 6 |
| Edge cases (E) | 10 | 3 | 1 | 6 |
| API (F) | 17 | 15 | 2 | 0 |
| SDK (G) | 72 | 71 | 0 | 1 skip |
| MCP (H) | 11 | 11 | 0 | 0 |
| Frontend (I) | 19 | manual checklist | | |
| Multi-wallet (J) | 9 | 0 | 0 | 9 |
| Stress (K) | 8 | 2 (K.3) | 0 | 6 |

---

## Phase A — Setup + canary  ✅ ALL GREEN

| Check | Result |
|---|---|
| API `/health` | 200, 1.22s |
| Landing `https://www.lumina-org.com` | 200 |
| RPC `cast block-number` | 42,036,879 ✅ |
| Faucet relayer ETH | 0.2198 ETH (~4 claims left) |
| Founder ETH | 0.0584 ETH |
| Founder mUSDC | 999,976.59 mUSDC |
| Founder LUMINA | 5,002,222 LUMINA |
| Mock oracle `0xC1A7…6183` | has code ✅ (live) |

---

## Phase B — 6 real products  ✅ 6/6

**B.1 Quotes** (coverage $100, payout $80 = 80% all):

| Product | Premium | Trigger prob |
|---|---|---|
| FLASHBTC1H-001 | $0.288 | 18 bps |
| FLASHBTC24-001 | $5.264 | 329 bps |
| FLASHBTC48-001 | $14.864 | 929 bps |
| FLASHETH1H-001 | $0.160 | 10 bps |
| FLASHETH24-001 | $4.576 | 286 bps |
| FLASHETH48-001 | $12.304 | 769 bps |

Premium scales monotonically with trigger probability — sane.

**B.2 Sandbox purchase** — `POST /sandbox/try` ✅ real on-chain txs:
- FLASHBTC1H-001 → policyId, tx `0x5150…`, premium 288000
- FLASHETH1H-001 → policyId, tx `0xa1e0…`, premium 160000
- FLASHETH1H-001 → policyId 2, tx `0x430e0be0…f1263` — **verified on-chain**: receipt status `1 (success)`, block 42,037,031, from relayer → CoverRouter `0xcdB7…F566`.

**B.3 On-chain verify** ✅: decoded the CoverRouter event in the sandbox tx — buyer indexed = founder `0xe585…fDa8`, productId + policyId match the API response. Sandbox is a **real** signed-by-relayer purchase on behalf of the connected wallet, not a simulation.

---

## Phase C — Trigger → bond → redeem  ⛔ BLOCKED (no signing key)
C.2/C.4/C.6/C.7 all require `cast send` (MockOracle.setPrice, Adapter.checkAndSettlePolicy, BondVault.setBondMaturitySeconds, redeemBond) signed by the founder/owner. Not executed. Mock oracle is live (`0xC1A7…6183` has code) so this flow is runnable once a key is provided. **Founder action required.**

---

## Phase D — Marketplace  ▶ reads PASS, writes BLOCKED
- **D.4 reads** ✅: `GET /api/v1/marketplace/listings` → `{count:0,total:0,listings:[]}` (200); `GET /api/v1/marketplace/stats` → `{floor:"0",volume24h:"0",…}` (200). Currently 0 active listings on testnet.
- **D.3/D.5/D.6/D.7 (list/cancel/relist/buy), D.8 (3% fee→TWAPBurner)** ⛔ require signed txs — BLOCKED.

---

## Phase E — Edge cases  (3 pass / 1 fail / 6 blocked)
| # | Case | Method | Result |
|---|---|---|---|
| E.1 | coverage < $100 quote | read | `/quote?coverageAmount=50000000` → **200** (quote endpoint does NOT enforce $100 min; it's a pure calc). MCP/SDK enforce min $100 in zod. Minor inconsistency. |
| E.1b | sandbox coverage < $100 | sandbox | returns `coverageAmount:"100000000"` — **silently ignores** the passed `coverageAmount` and forces $100. Not a security issue but a surprising no-op param. |
| E.3 | unknown product quote | read | valid-format but nonexistent bytes32 → **500** (should be 404/400). Malformed `0xdeadbeef` → 400 (correct). **FAIL: 5xx on unknown valid-format id.** |
| E.2/E.4/E.5/E.6 | insufficient balance / redeem-not-matured / redeem-redeemed / list>balance | — | ⛔ BLOCKED (need signed tx to hit the reverts) |
| E.7 | drop < threshold | — | ⛔ BLOCKED (needs trigger flow) |
| E.8 | throttle on rapid buys | — | ⛔ BLOCKED (needs signed buys); read-side rate-limit see F.3 |
| E.9 | capacity > 50% committed | — | ⛔ BLOCKED |
| E.10 | oracle staleness (MR-H01) | review | freshness gate present; dormant on testnet (pool=0x0) per prior Manual-Review audit. Not live-exercisable here. |

---

## Phase F — API exhaustive  (15 pass / 2 fail)

| Endpoint | Status | Time |
|---|---|---|
| `/health` | 200 | 1.23s |
| `/products` | 200 | 0.84–1.70s |
| `/products/{id}/quote` | 200 | 1.35s |
| `/sandbox/try` | 201 | **~9.0s (slow)** |
| `/api/v1/public/policies/{wallet}` | 200 | 0.6–1.2s |
| `/api/v1/public/bonds/{wallet}` | 200 | 1.08s |
| `/api/v1/live-stats` | 200 | 0.79–0.93s |
| `/marketplace/listings` (unversioned) | **404** | — |
| `/marketplace/stats` (unversioned) | **404** | — |
| `/api/v1/marketplace/listings` | 200 | 0.84s |
| `/api/v1/marketplace/stats` | 200 | 1.15s |
| `/api/v1/faucet/status` | 200 | 0.93s |
| `/api/v1/faucet/claim` | — | SKIPPED (write) |
| neg: `policies/0xZZZ` | 400 | ✅ |
| neg: `bonds/0x123` | 400 | ✅ |
| neg: `quote/0xdeadbeef` | 400 | ✅ |
| neg: `/api/v1/nope` | 404 | ✅ |

**F.2** input validation clean & consistent (`validation_error`, descriptive messages). **No 5xx anywhere** on the API agent's run (the one 500 I hit was the unknown-valid-bytes32 quote, E.3).
**F.3** rate-limit: 25 rapid calls to `/public/policies` → all 200, no 429 observed (limiter higher than 25 or not on this read route).
**F.4** cache: `/live-stats` back-to-back 0.85s/0.84s — warm both times, miss/hit delta not observable.
**F.5** latency: **no read endpoint under the 500ms target** (~0.6–1.7s); `/sandbox/try` ~9s.

---

## Phase G — SDK `@lumina-org/sdk@0.7.0`  ✅
- **Build** `npm install && npm run build` (tsc) → exit 0, clean.
- **Tests** `npm test` (jest --runInBand) → **71 passed, 1 skipped** (8 suites). The skip is `health-live.test.ts` (network-gated by design).
- **Surface**: `LuminaClient` + sub-APIs `products/policies/bonds/marketplace/agent/sandbox/webhooks`, `BondQueue` throttle, product-map + marketplace helpers.
- **Read fns executed live** (against real API): `health` ✅ (7 canonical contracts), `products.list` ✅ (7), `products.quote` ✅ ($1000 BTC1H → $2.88 premium / $800 payout), `marketplace.listings/stats` ✅ (empty), `sandbox.info` ✅ (cap $100, wallet 0xe585…fDa8). `marketplace.history` + `policies.get` hit **429** on back-to-back calls (IP throttle, not a code defect — succeed on retry).
- **Write model nuance**: SDK does **not** use unsigned-tx. `policies.purchase()` → relayer (server pays gas, returns real txHash, no signer). Marketplace writes + `ensureAllowance` + `agent.onboard` require an ethers v6 Signer and submit directly (throw `requireSigner` if absent). Verified by source read; not executed (no key).

## Phase H — MCP server `@lumina-org/mcp-server@0.1.0`  ✅
- **Build** tsc → exit 0. **Tests** `npm test` (vitest) → **11 passed**.
- **Inventory** (confirmed live via InMemoryTransport): **11 tools** (browse_products, quote_policy, buy_policy_sandbox, buy_policy_real, get_policy_status, get_bond_balance, redeem_bond, marketplace_list, marketplace_buy, watch_triggers, get_protocol_stats); **4 resources** (`lumina://products`, `lumina://stats`, `lumina://policies/{wallet}`, `lumina://bonds/{wallet}`); **3 prompts** (first_policy, compare_products, monitor_portfolio).
- **Live e2e** (real API): `browse_products` ✅ (6 active), `quote_policy` ✅ ($2.88/$800), `get_protocol_stats` ✅ (block 42037080, relayer gas 0.2198 ETH, LUMINA $0.0360), `watch_triggers` ✅ (6), `buy_policy_real` ✅ built **2 unsigned txs** — USDC.approve(coverRouter, 1e9) calldata `0x095ea7b3…` correct + CoverRouter.purchasePolicy. Addresses resolved live from `/health`.
- **Unsigned-tx model confirmed**: `src/lib/tx.ts` builds `{chainId,to,data,value}` with no signer; server never holds a key. buy_policy_real→2, redeem_bond→1, marketplace_list→2, marketplace_buy→1.

---

## Phase I — Frontend manual checklist (for founder)

The migrated operate views now fetch the cached API first and only fall back to an on-chain `getLogs` scan,
so "FAILED TO LOAD" should be gone **once the stacked landing PRs (#49–#55) are merged + Vercel redeploys**.
Until then the LIVE site still runs the old client-side-scan code.

Pages:
- [ ] `/` home — hero live data, no fake numbers
- [ ] `/products` — 6 products with live premiums
- [ ] `/tokenomics`
- [ ] `/whitepaper` — EN/ES links
- [ ] `/docs/*` — Mintlify loads
- [ ] `/skills` — 22 skills + MCP card
- [ ] `/tutorial` — MCP banner, signup
- [ ] `/app/human/portfolio` — < 2s, shows my policies + bonds (API-first)
- [ ] `/app/human/marketplace` — < 2s, listings (API-first)
- [ ] `/app/agent/dashboard` — < 2s
- [ ] `/app/agent/policies` — < 2s
- [ ] `/app/agent/bonds` — < 2s

Actions:
- [ ] Connect wallet · [ ] Switch network · [ ] Buy policy (real) · [ ] List bond · [ ] Cancel listing · [ ] Redeem matured bond · [ ] Faucet claim

---

## Phase J — Multi-wallet  ⛔ BLOCKED (no key — needs 3 funded wallets + signed buys)

## Phase K — Stress
- **K.1 (10 buys same wallet → throttle)** ⛔ BLOCKED (signed)
- **K.2 (5 simultaneous buys, relayer nonce)** ⛔ BLOCKED (signed)
- **K.3 concurrent reads** ✅:
  - 20× `/products` parallel: 20/20 ok, wall 2.38s, avg 2.04s, max 2.36s — **slow under concurrency**
  - 20× `/public/bonds` parallel: 20/20 ok, wall 0.71s, avg 0.62s — good

---

## Findings

### CRITICAL
_None confirmed._ (Trigger/redeem/marketplace-write paths were not exercisable without a key — a residual risk, not a confirmed bug.)

### HIGH
- **H-1 · Intermittent empty portfolio under load/cold-cache.** `/api/v1/public/policies/{founder}` returned **0** immediately after a burst of sandbox buys + 20× concurrent `/products` (RPC pressure), then **stabilized at 7** on the next 8 consecutive calls. The endpoint silently returns `[]` when the wide `eth_getLogs` scan times out / rate-limits, instead of erroring. This is the same live-log-scan fragility behind the whole "FAILED TO LOAD" saga and **directly affects the migrated PortfolioView / AgentPoliciesView** (they show empty rather than an error). **Permanent fix: revive the parked Ponder indexer** so reads don't depend on live getLogs.

### MEDIUM
- **M-1 · `/products` slow under concurrency** (avg ~2.0s for 20 parallel; ~0.8–1.7s single). Misses the <500ms target. Likely RPC round-trips per request + Railway baseline; consider longer/edge cache.
- **M-2 · Unknown valid-format productId → 500** (E.3). Should be 404. Error-handling gap on `/products/:id/quote`.
- **M-3 · Marketplace routes only under `/api/v1/`** — unversioned `/marketplace/*` 404s. Doc/brief references the stale path; confirm canonical and/or add alias so existing clients don't break.

### LOW / INFO
- **L-1 · `/sandbox/try` ~9s** — it's a real on-chain tx, but the synchronous wait is rough UX with no progress/streaming.
- **L-2 · sandbox silently ignores `coverageAmount`** — always forces $100 (E.1b). Either honor it or reject the param.
- **L-3 · `/quote` does not enforce $100 min** (E.1) while SDK/MCP do (zod). Minor cross-surface inconsistency; enforcement does happen at purchase.
- **INFO** · read-side rate limiter not observed at 25 calls; cache hit/miss not measurable from timing.
- **INFO** · product count inconsistent across surfaces — catalog total **7** (SDK `products.list`) vs **6 active** (`browse_products`/`get_protocol_stats`). Known issue (one inactive product); harmless but worth normalizing.
- **INFO** · SDK back-to-back calls hit **429** (shared IP throttle); all succeed on retry — environment artifact, not a defect.

---

## Performance Metrics
- **API read latency**: 0.6–1.7s typical (target <500ms **not met**).
- **`/sandbox/try`**: ~9s (real tx).
- **Concurrency**: 20× /products 2.38s wall; 20× /public/bonds 0.71s wall.
- **On-chain**: sandbox purchase tx confirmed status 1 within one block; cost well under budget (read-only sprint, ~0 ETH spent beyond relayer-funded sandbox buys).
- **RPC head**: block 42,036,879 → 42,037,031 during run.

## Recommendations Pre-Mainnet
1. **Revive the Ponder indexer** (kills H-1 + M-1 + the entire client/server getLogs-scan fragility class). Highest leverage.
2. Merge the stacked draft PRs in order — lumina-api #44/#45/#46 → Railway deploy → landing #49–#55 → Vercel deploy — so the LIVE site actually runs the API-first views.
3. Fix M-2 (404 not 500 on unknown product) and decide M-3 canonical marketplace path (+alias).
4. Run Phases C/D/E-writes/J/K-writes with a key (in a controlled session) before public launch — trigger→bond→redeem and marketplace cross-wallet are the riskiest unverified flows.
5. L-1/L-2/L-3 polish: async sandbox UX, honor-or-reject coverageAmount, align $100 min across quote/SDK/MCP.

## Reverse audit /10
**Testnet readiness for the surfaces actually testable without a key: 8.0/10.** Canary green, all 6 products quote+sandbox correctly and land on-chain, API healthy with clean validation and no 5xx (bar M-2), MCP/SDK build & test. Held back by H-1 (intermittent empty reads under load — the recurring getLogs fragility) and sub-target latency. **The signed core flows (trigger/redeem/marketplace-write/multi-wallet) remain UNVERIFIED this run — that is the real gate before Phase 5, not a score.**
