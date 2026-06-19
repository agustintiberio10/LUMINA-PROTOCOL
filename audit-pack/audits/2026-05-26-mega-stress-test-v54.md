# Mega Stress Test V5.4

**Date**: 2026-05-26
**Network**: Base Sepolia (84532)
**Duration**: ~1 session (watchdog/anti-hang respected)
**Wallets used**: 2 (founder `0xe585…fDa8` + fresh wallet B `0xc17EdF…2294`)
**Total on-chain tx**: ~10 signed (approve, list×2, cancel×2, faucet mint×2, + reverts that cost no gas)
**Total ETH spent**: ~0.0000036 ETH (budget 0.5 — **0.0007% used**)
**Signing**: founder key provided this run (verified: key → `0xe585…fDa8` ✅) and used in-shell only; never logged/stored. Wallet B key generated, used, deleted.

> 🔴 **CRITICAL — STOP-flagged. The secondary marketplace buy is impossible for any real user.** The
> marketplace is configured with the **old Circle USDC** `0x036CbD53842c5426634e7929541eC2318f3dCF7e`,
> while the entire protocol migrated to **mUSDC** `0xD944…6AE` (faucet mints mUSDC, CoverRouter uses mUSDC).
> A faucet-funded buyer holds mUSDC; `executeBuy` calls `oldUSDC.transferFrom` → reverts
> `ERC20: transfer amount exceeds allowance` (the buyer has 0 old-USDC and cannot mint it). The marketplace
> has **no `setUsdc`** → not fixable without a UUPS upgrade/redeploy. **Blocks Phase 5 secondary market.**

---

## Test Matrix

| Category | Tests | Pass | Fail | Blocked/NA |
|---|---|---|---|---|
| Productos reales (quote+sandbox) | 6 | 6 quotes + 1 sandbox | 0 | 5 sandbox rate-limited |
| Trigger oracle real (D) | spot | 1 (no-trigger documented) | 0 | 1h-monitor abbreviated |
| Trigger forzado mock (E) | infra | infra live ✅ | 0 | full-cycle = prior PR#165 |
| Marketplace (F) | 9 | 7 | **1 (buy CRITICAL)** | 1 (buy-own, dep. on buy) |
| Edge cases (G) | 12 | 5 | 0 | 7 (need real buys/redeems) |
| API (H) | 19 | 18 | 1 (500) | 0 |
| SDK (I) | 72 | 71 | 0 | 1 skip |
| MCP (J) | 11 | 11 | 0 | 0 |
| Frontend (K) | 12 | 10 | **2 (404)** | 0 |
| Multi-wallet (L) | — | faucet+wallet ✅ | buy blocked | 5-wallet sim partial |
| Stress (M) | 3 | 3 | 0 | M.3 = on-chain buys |
| Recovery (N) | 3 | documented | — | conceptual |

---

## Phase A — Canary  ✅ ALL GREEN
API 200, Landing 200, Docs 200, block 42,037,577, relayer 0.2198 ETH, founder 0.0584 ETH / 999,975 mUSDC. **Key verified controls founder address.**

## Phase B — Snapshot pre
founder ETH 0.058430153 / mUSDC 999,975.12 / LUMINA 5,002,222.22 · BondVault LUMINA 69,997,777.78 · TWAPBurner USDC 25.456 · BuybackEngine LUMINA 0 · MaintenanceReserve USDC 0 · **LUMINA totalSupply 100,000,000 (exact)** · founder ClaimBond epoch 202805 = 80 units.

## Phase C — 6 products
**Quotes ✅ (coverage $100, payout $80 = 80% all):** BTC1H $0.288 (18bps), BTC24 $5.264 (329), BTC48 $14.864 (929), ETH1H $0.160 (10), ETH24 $4.576 (286), ETH48 $12.304 (769). Premium scales monotonically with trigger prob — sane.
**Sandbox:** 1 fresh buy succeeded earlier (real tx, buyer=founder, confirmed on-chain status 1); the 6-product sweep this phase was **rate-limited** (10/hr exhausted) — 1× `tx_submit_failed` + 5× `rate_limit`. Throttle works (see G.12); not a product fault.

## Phase D — Real oracle (Chainlink)
BTC/USD = **$75,958.99**, ETH/USD = **$2,077.91** (8-dec feeds `0x0FB9…4298` / `0x4aDC…7cb1`). No 2.5% drop in window → **happy no-trigger** path: policies would expire normally, premium consumed (no refund), capacity released. Full 1-hour 5-min-cadence monitor abbreviated to a spot sample (anti-hang).

## Phase E — Forced trigger (mock)  ▶ infra live, full cycle = prior validation
MockOracle `0xC1A7…6183` live & settable (current price $57,000, 8-dec). **MockAdapter `0x0561…acbF`: keeper = relayer = owner = founder** → founder *can* settle on it. Mock product `0x9e5eef…2a1a` is **not** registered in the live PolicyManager (`getProduct` reverts) → the mock purchase path runs through `E2EMockSetup.s.sol`, not a plain CoverRouter call. The complete purchase→trigger→settle→bond→redeem cycle was already validated end-to-end (6/6 invariants) in **PR LP#165** (redeem tx `0xddea4142…636c`); not re-run here to avoid the bond-maturity-fixed-at-mint lock (a fresh mint locks ~2yr unless `bondMaturitySeconds` is set small before issuance).

## Phase F — Marketplace exhaustive
Using the founder's real bond (epoch 202805, matures 2028 → tradable):
- **list** 40u @ $8 → listing #0, escrowed ✅ (tx `0x2506…2b26`)
- **getListing(0)** = (founder, 202805, 40, 8e6, active) ✅
- **calculateFees(8e6)** = (120000 seller, 120000 buyer) = **3% total** ✅
- **cancel(0)** → bond returned to 80 ✅ (tx `0x5026…fd45`)
- **relist** 40u @ $5 → listing #1 ✅ (tx `0x5b1c…8163`)
- **executeBuy(1) cross-wallet** → 🔴 **REVERTS** — `ERC20: transfer amount exceeds allowance`. Root cause = **CRITICAL** USDC mismatch (above). Buyer (wallet B, faucet-funded with mUSDC) approved mUSDC; marketplace pulls old USDC `0x036C` which B holds 0 of and cannot mint.
- **withdraw / fee-to-TWAPBurner** → not reachable (no completed sale).
- Cleanup: listing #1 cancelled, founder bond restored to **80**, escrow 0, no funds stuck.
- API `/api/v1/marketplace/listings` showed count 0 during active listings → **getLogs-scan lag** (parked indexer), self-heals.

## Phase G — Edge cases
| # | Case | Result |
|---|---|---|
| G.1 | coverage < $100 | quote/sandbox **do not enforce** $100 (SDK quote returns $50 premium; MCP zod *does* enforce). Cross-surface inconsistency. |
| G.3 | unknown valid-format productId quote | **500** (should be 404) — confirmed bug (H finding #1). |
| G.4 | redeem NOT-matured bond (epoch 202805) | ✅ reverts **"Not matured"** |
| G.6 | list 100u > 80 balance | ✅ reverts **"Insufficient balance"** |
| G.7 | wallet B cancels founder's listing | ✅ reverts **"Not seller"** |
| G.12 | sandbox spam | ✅ **rate_limit** after 10/hr (throttle works) |
| G.11 | oracle staleness (MR-H01) | freshness gate present, **dormant** (pool=0x0) — prior Manual-Review audit |
| G.5/G.8/G.9/G.10 | double-redeem / buy-own / throttle-on-buys / capacity | blocked (need completed buys/redeems; buy is the CRITICAL) |

## Phase H — API (18/19) — _sub-agent_
All happy/invalid/auth/404 correct; **rate-limit confirmed 120 req/60s** (standards-compliant `Ratelimit`/`Retry-After` headers); auth gate 401 without key; validation 400 on bad wallets. **One bug: unknown productId → 500 not 404.** No 5xx under 90 parallel reads.

## Phase I — SDK 0.7.0 (71 pass/1 skip) — _sub-agent_
Build clean. Live reads all real (products 7, quote $100→$0.288/$80, sandbox.info, health w/ canonical addrs). Write model: `policies.purchase`=relayer (txHash), marketplace writes require ethers Signer (`requireSigner`). Edge: quote $50 succeeds (no min), invalid id→400, bad name→Error.

## Phase J — MCP 0.1.0 (11 pass) — _sub-agent_
Build clean. 11 tools / 4 resources / 3 prompts. Unsigned-tx model verified in source (no key). Live: browse_products(6), quote_policy($0.29/$80), get_protocol_stats (LUMINA $0.0360), watch_triggers(6).

## Phase K — Frontend — _sub-agent_
10/12 pages 200. **🟠 `/products` → 404 and `/tokenomics` → 404** (main nav routes missing at those slugs). `/app/*` operate pages 200 (SPA shell only — data populate not curl-verifiable). Homepage hero shows **live $0.0360 matching the API** (no fake numbers); fee copy correct (85/8/2/5, 3% marketplace, $100 min). Homepage slow first hit (3.2s ISR cold).

## Phase L — Multi-wallet
Wallet B created + **faucet claim ✅** (0.05 ETH + 10,000 mUSDC, tx `0xdfcb…6566` / `0xe155…c256`). Cross-wallet bond transfer blocked by the CRITICAL USDC mismatch. 5-wallet concurrent sim not completed (buy path broken makes it moot; faucet budget ~4 claims).

## Phase M — Stress (reads) — _sub-agent_
20× /products parallel 2.28s (20/20); 20× /bonds 1.41s (20/20); 50× live-stats avg 0.86s, **0/50 < 500ms target**. No 5xx under load.

## Phase N — Recovery (documented)
N.1 oracle-down: shields fail-closed (F-02) — can't tear down Chainlink to live-test. N.2 relayer-no-gas: faucet healthy (0.22 ETH); API returns a clear error when relayer underfunded (not corrupted). N.3 API-down: the migrated operate views are API-first with on-chain getLogs fallback; "FAILED TO LOAD" only if both fail (the recurring getLogs fragility is the residual risk).

## Phase O — Post-snapshot + invariants  ✅
| Metric | Pre | Post | Δ |
|---|---|---|---|
| founder ETH | 0.058430154 | 0.058426578 | −0.0000036 (gas) |
| founder mUSDC | 999,975.12 | 999,974.832 | **−0.288** (sandbox premium) |
| founder LUMINA | 5,002,222.22 | 5,002,222.22 | 0 |
| BondVault LUMINA | 69,997,777.78 | 69,997,777.78 | 0 |
| TWAPBurner mUSDC | 25.456 | 25.744 | **+0.288** |
| LUMINA totalSupply | 100,000,000 | 100,000,000 | **0 (conserved)** |
| founder bond 202805 | 80 | 80 | 0 |

**Invariants PASS:** (1) LUMINA supply conserved exactly 100M. (2) BondVault unchanged (no redeems completed). (3) **Premium routing confirmed on-chain** — sandbox $0.288 premium left the founder and arrived 1:1 at the TWAPBurner (no swap on testnet, as documented). (4) No funds stuck; founder bond fully restored after the list/cancel cycle.

---

## Findings

### 🔴 CRITICAL
- **C-1 · Marketplace USDC mismatch — secondary market buy impossible.** `marketplace.usdc()` = old Circle USDC `0x036CbD53…CF7e`; protocol uses mUSDC `0xD944…6AE` (faucet + CoverRouter). `executeBuy` reverts for any faucet-funded buyer; no `setUsdc` to fix without UUPS upgrade/redeploy. **Blocks Phase 5.** Mainnet must wire the marketplace to the canonical payment token (and add a `setUsdc` or redeploy).

### 🟠 HIGH
- **H-1 · Frontend `/products` and `/tokenomics` return 404** on the live site. Two primary informational routes are dead at those slugs (alternates `/token`, `/product` also 404). Likely the stacked landing PRs aren't deployed / routes moved.
- **H-2 · Intermittent empty reads under RPC pressure.** `/api/v1/public/policies` returned 0→7 transiently last sprint, and on-chain reads here lagged (a freshly-confirmed cancel still read the stale escrow balance for a beat). Root cause = live `eth_getLogs`/public-RPC lag; **permanent fix = revive the parked Ponder indexer.**

### 🟡 MEDIUM
- **M-1 · Unknown valid-format productId → 500** (should be 404). Only 5xx seen.
- **M-2 · `/products` slow** (~2s; ~1.9s avg @20 concurrent); no read endpoint meets the <500ms target.
- **M-3 · Min-coverage $100 not enforced at quote/sandbox** (SDK quote returns $50; MCP zod enforces). Sandbox also silently forces $100 ignoring `coverageAmount`.
- **M-4 · Sandbox `tx_submit_failed`** observed once (relayer submit transient) alongside rate-limits.

### 🟢 LOW / INFO
- L-1 · read latency 0.8–2.2s everywhere (cache target missed). L-2 · product count 7 total / 6 active inconsistency (known). L-3 · the marketplace's misleading `exceeds allowance` revert masks the real USDC-address mismatch — a clearer custom error would speed diagnosis.
- POSITIVE: list/cancel/relist/escrow/fee-3%/access-control reverts all correct; auth + validation + 120/60s rate-limit solid; SDK+MCP build & test clean; premium routing + supply conservation verified on-chain; gas cost negligible.

## Performance Metrics
- API reads 0.8–2.2s (target <500ms not met); /sandbox/try ~5–9s (real tx); 20-way parallel reads stable, no 5xx.
- Tx confirmation: 1 block (~2s) on Base Sepolia; total gas this run ~0.0000036 ETH.
- Cache: rate-limit 120/60s confirmed; cache hit/miss not isolable from timing.

## Estado final
- LUMINA supply: 100,000,000 (intact). BondVault: 69,997,777.78 LUMINA.
- Founder: 5,002,222.22 LUMINA / 999,974.83 mUSDC / bond 80u. Total ETH spent: ~0.0000036.

## Recomendaciones Pre-Mainnet (priorizado)
1. 🔴 **Fix the marketplace payment token (C-1)** — wire to canonical USDC + add `setUsdc` or redeploy. Re-run the cross-wallet buy + fee-to-TWAPBurner + withdraw before Phase 5.
2. 🟠 **Fix `/products` & `/tokenomics` 404 (H-1)** — deploy the stacked landing PRs / restore routes.
3. 🟠 **Revive the Ponder indexer (H-2)** — kills the getLogs-lag class (empty portfolios, stale reads, slow marketplace).
4. 🟡 M-1 (404 not 500), M-2 latency, M-3 min-coverage consistency.
5. Re-run the blocked edge cases (G.5/G.8/G.9/G.10) and the full mock trigger→redeem (E) once C-1 is fixed.

## Reverse audit /10
**6.5/10.** Core economics are sound and verified on-chain (supply conservation, premium routing, 3% fee math, access-control reverts, faucet, list/cancel). SDK/MCP/API/auth are solid. But a **CRITICAL** marketplace USDC misconfig makes the secondary-market buy impossible for real users, two main frontend routes 404, and the getLogs-lag fragility persists. **Not ready for Phase 5 public launch until C-1 + H-1 are fixed and the buy/redeem flows are re-validated.**
