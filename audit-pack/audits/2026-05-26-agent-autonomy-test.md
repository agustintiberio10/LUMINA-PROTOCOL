# Agent Autonomy Test V5.4

**Methodology**: zero-knowledge AI agent — "find Lumina, learn it, buy a policy, report." No prior
context, no GitHub, no private keys; only a browser + the public API + the (intended) testnet faucet.
**Date**: 2026-05-26 · Endpoints exercised live: `lumina-org.com`, `docs.lumina-org.com`, the API
(`/health`, `/products`, `/api/v1/faucet/claim`, `/sandbox/try`), npm registry.

## Journey steps score

| Step | Score | Notes |
|---|---|---|
| 1 Discovery | 8/10 | `lumina-org.com` title + meta is clear: "The Safety Net for Autonomous AI Agents… Parametric insurance on Base L2… 100% automated via Chainlink." I understood the product in <30s. Minus: meta says **"5 products"** (actually 6 flash shields / API returns 7). |
| 2 Products | 7/10 | `/products` is clean JSON: name, displayName, shield/adapter, coveredAsset, `payoutRatioBps:8000`, `marginBps`, `durationSeconds`, `active`. Clear enough to choose. Minus: **count mismatch** (landing 5 / API 7 / 6 real) confuses "how many products are there really?". |
| 3 Setup | 8/10 | SDK `@lumina-org/sdk@0.7.0` published; `docs.lumina-org.com` 200; a "sandbox-first" path exists. Clear how an agent integrates (API or SDK). |
| 4 Faucet | 3/10 | Two frictions: (a) route is **`/api/v1/faucet/claim`**, not `/faucet` (root has `/health`+`/products` un-versioned → I guessed wrong first); (b) it returns **`out_of_eth` — "Faucet temporarily out of ETH. Contact team."** → a real agent **cannot get testnet gas** right now. Blocks the non-sandbox flow. |
| 5 First purchase | 9/10 | `POST /sandbox/try {"productName":"FLASHBTC1H-001"}` → `ok:true`, `policyId`, `txHash`, `blockExplorer`, `next` link. **No wallet, no gas, no code** — a single unauthenticated POST buys a policy. This bypasses the broken faucet entirely. |
| 6 Post-purchase | 8/10 | Response is self-explanatory: policyId + on-chain `txHash` + BaseScan link + "next" docs URL. Clear what happened and how to verify. Minus: redeem/claim path not surfaced in the same response. |
| **OVERALL** | **7.2/10** | Strong sandbox-first onboarding; gated by the empty faucet + minor inconsistencies. |

## Time metrics (sandbox path)

- **Time to first policy: ~1–2 min** (a single `curl` to `/sandbox/try`).
- **Lines of code written: 0** (one HTTP POST; no SDK/contract code required).
- **Endpoints touched: 1** for the purchase (`/sandbox/try`); 3 for discovery (`/health`, `/products`, docs).
- **Wallet/gas required: none** (sandbox uses the protocol relayer).

## Friction points (by severity)

1. **[HIGH] Faucet out of ETH** — `out_of_eth`. The real (non-sandbox) flow can't fund gas. *Operational*
   (refund the faucet wallet; relates to OP-013). Until then, only the sandbox path works for agents.
2. **[MEDIUM] Faucet route discovery** — `/api/v1/faucet/claim` vs root-level `/products`/`/health`;
   inconsistent base path. Recommend a single base path or a discoverable route index at `/`.
3. **[MEDIUM] Product-count inconsistency** — landing "5", API `count:7`, 6 real flash shields. Pick 6
   and reconcile landing meta + API + docs.
4. **[LOW] Redeem/claim not surfaced post-purchase** — the success payload should link "how to claim
   if triggered" (payout = 80% of coverage).

## Recommendations (prioritized)

1. **Refund the testnet faucet** (unblocks the gas path) — operational, immediate.
2. **Lead agents to the sandbox** (it's the genuinely great path): make `/sandbox/try` the headline
   "first policy in 1 curl" on the landing + docs.
3. **Reconcile product count to 6** across landing/API/docs; investigate the API's 7th entry.
4. **Unify the API base path** (or publish a route index) so faucet/policies are discoverable.
5. Add redeem/claim guidance to the post-purchase response + a "verify your policy" endpoint.

## Benchmarks (onboarding for an autonomous agent)

| Protocol | To first action | Wallet | Gas | Code |
|---|---|---|---|---|
| Compound (supply) | minutes | required | required | connect + approve + tx |
| Aave (lend) | minutes | required | required | connect + approve + tx |
| Nexus Mutual (cover) | minutes–hours (KYC-ish, quote flow) | required | required | multi-step |
| **Lumina (sandbox)** | **~1 min, 1 curl** | **none** | **none** | **none** |

**Verdict**: Lumina's **sandbox-first onboarding is best-in-class for AI agents** — a policy bought
with a single unauthenticated POST, no wallet/gas/code. That is a genuine differentiator. The
non-sandbox path is currently **blocked by an empty faucet** and dinged by minor count/route
inconsistencies. Fix the faucet + reconcile the product count and this is a 9/10 onboarding.

**Honesty note**: this test used the live public endpoints with no internal context for the journey
scoring; the friction (faucet out-of-ETH, route 404, "5 products") was discovered, not assumed.
