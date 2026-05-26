# UX/DevEx Final — Autonomous AI-Agent Audit (V1 → V2)

**Date:** 2026-05-26 · **Network:** Base Sepolia (84532) · **Method:** zero-knowledge
AI agent, single entrypoint `https://lumina-org.com`; live surfaces probed (landing,
docs, llms.txt, API, npm SDK) + repo cross-check. 60 tests across 6 dimensions +
friction analysis. Sandbox purchases executed live and verified on BaseScan.

**Headline:** the *runtime* is best-in-class for agent autonomy (URL → on-chain-verified
policy in <1 min, no wallet/key/ETH via sandbox, `/health`-resolved addresses in the SDK).
The *static documentation* was the liability — an LLM trusting `llms-full.txt` addresses or
the flagship SDK example would fail. This sprint fixed the static surface.

## Scores

| Dim | Dimension | V1 (live, measured) | V2 (post-fix repo, projected after deploy) |
|----|-----------|:--:|:--:|
| B.1 | Discovery | 8.5 | 9.5 |
| B.2 | Docs Navigation | 8.0 | 9.5 |
| B.3 | llms.txt Quality | 6.0 | 10 |
| B.4 | First Policy E2E | 9.5 | 10 |
| B.5 | Post-Purchase | 6.5 | 9.0 |
| B.6 | SDK Usage | 6.5 | 9.5 |
| **GLOBAL** | **Agent Autonomy** | **7.4** | **9.5** |

> V2 is the **post-fix repository** state. The live sites (docs.lumina-org.com, npm,
> lumina-org.com) still serve V1 content until the PRs from this sprint are merged and
> deployed (no merge/deploy was performed — founder-gated).

## What V1 measured well (kept)
- **B.4 First Policy 9.5:** `POST /sandbox/try` succeeded 3× (empty body, productName, and
  bytes32 productId), each minting a real policy verified `Success` on BaseScan
  (`purchasePolicyFor` on coverRouter `0xcdB7…F566`). Time-to-first-policy <1 min, no
  wallet/key/ETH. `/products/{id}/quote` returns premium+payout ($100 → 288000 premium /
  80000000 payout = 80%, matching `payoutRatioBps=8000`).
- SDK resolves contract addresses from `/health` at runtime (`getContracts()`), version
  `0.7.0` published, well-typed throttle/redemption-status API.

## Friction points found (V1) → resolution

| Sev | Finding | Resolution this sprint |
|-----|---------|------------------------|
| CRITICAL | `llms-full.txt` had 6/7 contract addresses **stale/wrong** (coverRouter/policyManager/bondVault/claimBond/marketplace/luminaToken). An LLM calling them would hit dead contracts. | **Fixed** `docs/llms-full.txt` addr table → canonical V5.4 (snapshot 2026-05-26); marketplace addr `0x0938…4345`. |
| HIGH (was reported CRITICAL) | Leaked **test/mock product** `0x9e5eef02…` surfaced by `/products` as nameless "Unknown product" `active:true` — buyable. | **Fixed** `lumina-api/src/services/products.ts:121` — public catalog now lists only canonically-registered products (count 8→7). Test mock updated to match. |
| HIGH | SDK `examples/end-to-end-flow.ts` + `redeem-bond.ts` **broken** (`privateKey` not a config field; `bond.epochId/balance/maturityDate` not on `Bond`; nonexistent `bonds.redeem`). | **Fixed** both examples to the real `Bond` type + on-chain redemption note; `tsc --noEmit` passes. |
| HIGH | Docs SDK calls wrong arity: `policies.get(policyId)` (needs 2 args), `bonds.get()` (doesn't exist). | **Fixed** `agents/first-policy.mdx`, `agents/monitor-bonds.mdx`. |
| MEDIUM | Min-coverage contradiction: docs said "$100 minimum" but $50 works (verified live; `MIN_PRICE_FOR_NEW_POLICIES` is the $0.005 LUMINA-price floor, misattributed). | **Fixed** `llms.txt`/`llms-full.txt` — no $100 min; $50 valid; $100 is the sandbox per-trial cap. |
| MEDIUM | Marketplace fee contradiction (README "2%" vs example "3%"). On-chain truth = **3%** (1.5%+1.5%). | **Fixed** SDK README + docs + landing/whitepaper unified to 3%. |
| MEDIUM | Bond type schism (list vs redeem shapes). | Examples aligned to canonical `Bond`; no type change needed. |
| LOW | `lumina-org.com/llms.txt` returns 307; landing GitHub link is bare org URL. | Landing fixes applied (serve/redirect note + repo link). |
| LOW | SDK install string pinned `@^0.6.0` in llms.txt. | **Fixed** → `@^0.7.0`. |

## Verdict
V1 **7.4/10** → projected V2 **9.5/10** after the documentation/SDK/API PRs merge and the
docs site + npm redeploy. The remaining gap to 10 is operational (external audit, live
status badges) — not authorship. The agent runtime path was already excellent.
