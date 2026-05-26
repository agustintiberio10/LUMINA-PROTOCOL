# UX/DevEx Final — Fixes Applied

**Date:** 2026-05-26 · **Scope:** auto-fix pass following the Agent and Human audits.
All changes are documentation / SDK-example / API-serialization fixes — **no Solidity
contract code was modified**. Nothing was merged or deployed (founder-gated). Each repo
has a draft PR on branch `feat/ux-devex-final-fixes`.

## Ground-truth corrections established this sprint (verified on-chain / in-source)

| Topic | Truth | Source |
|---|---|---|
| Marketplace fee | **3%** = 1.5% seller + 1.5% buyer | `LuminaBondMarketplace` `SELLER_FEE_BPS=150`/`BUYER_FEE_BPS=150` (live reads = 150/150) |
| Minimum coverage | **$100** (`coverageAmount >= 100e6`) | `CoverRouterV2.sol:264` (`InvalidCoverage`) — the `/quote` endpoint does NOT enforce it, which is why $50 quotes returned values |
| Payment token | **mUSDC** `0xD944…6AE` | live `/health.contracts.usdc`; CoverRouter reconfigured off Circle USDC |
| Sandbox input | `/sandbox/try` **accepts `productName`** (and productId) | `sandbox.ts:45,114` — productName wins; docs using productName are correct |
| `lumina.bonds` API | only `list()`; **no `redeem()`/`getRedemptionStatus()`** | `src/bonds.ts`; redemption is on-chain `BondVault.redeemBond`, status via the separate `BondQueue` class |
| Burn/fee split | 85% burn / 8% buyback / 2% ops / 5% maintenance | `TWAPBurner`/`AdaptiveFeeDistributor` |
| Genesis split | BondVault 70 / CEX-DEX 14 / Founder 8 / LBP 5 / Treasury 3 (M) = 100M | token manifest |

> ⚠️ **Self-correction logged for honesty:** an intermediate version of this pass wrongly
> concluded "$50 is valid, no $100 minimum" (because `/quote` priced $50). That was caught
> by reading `CoverRouterV2.sol:264` before shipping and **reverted** — all surfaces now
> state the correct **$100** minimum. The `MIN_PRICE_FOR_NEW_POLICIES = $0.005` constant is
> a LUMINA *price* floor, NOT the coverage minimum (the docs had misattributed it).

## Fixes by repo

### docs (Mintlify) — branch `feat/ux-devex-final-fixes`
- **`llms-full.txt`** — replaced 6 STALE contract addresses (coverRouter/policyManager/bondVault/claimBond/marketplace/luminaToken) with canonical V5.4 (snapshot 2026-05-26); marketplace address; corrected the `InvalidCoverage` row to the real $100 minimum.
- **`llms.txt`** — corrected min-coverage to $100; SDK install pin `@^0.6.0`→`@^0.7.0`.
- **`contracts/deployed.mdx`** — USDC: Circle `0x036C…`→ mUSDC `0xD944…6AE`.
- **`agents/get-test-usdc.mdx`** — removed the stale "known issue" claiming mUSDC purchases revert (no longer true).
- **`agents/first-policy.mdx`, `agents/monitor-bonds.mdx`** — fixed `policies.get` to two-arg `(productId, policyId)`; removed nonexistent `bonds.get()`.
- **`sdk/bonds.mdx`, `sdk/examples.mdx`, `concepts/bondvault-throttle.mdx`** — removed nonexistent `lumina.bonds.redeem()` / `lumina.bonds.getRedemptionStatus()`; documented on-chain `BondVault.redeemBond` + the `BondQueue` helper for status.
- **Marketplace fee 2%→3%** across `concepts/{marketplace,lifecycle,claimbonds,overview,lumina-token}.mdx`, `contracts/architecture.mdx`.
- **`tokenomics.mdx`** — rewrote stale allocation table to canonical split; added 85/8/2/5 fee split; "BuybackEngine (planned)" → deployed `0x56B5…1FB4`.
- **`glossary.mdx`** (new) + `docs.json` nav entry; **`concepts/overview.mdx`** plain-English lead for non-coders.

### lumina-sdk — branch `feat/ux-devex-final-fixes`
- **`examples/end-to-end-flow.ts`, `examples/redeem-bond.ts`** — removed invalid `privateKey` config field; replaced nonexistent `Bond` fields (`epochId/balance/maturityDate`) with real ones (`bondId/amount/faceValueUsdc/maturityEpoch`); replaced nonexistent `bonds.redeem()` with on-chain `BondVault.redeemBond` + `BondQueue.getRedemptionStatus`; added required `buyer`. `tsc --noEmit` passes.
- **`examples/buy-policy.ts`** — resolve friendly name → bytes32 before `products.quote()`.
- **`examples/README.md`** — corrected end-to-end-flow.ts description.
- **`README.md`** — fee 2%→3% (now self-consistent); bonds endpoint comment `/api/v1/bonds`→`/api/v1/bonds/:wallet`.

### lumina-api — branch `feat/ux-devex-final-fixes`
- **`src/services/products.ts`** — public `/products` now lists only canonically-registered products; the leaked E2E **mock product** (`0x9e5eef02…`, nameless "Unknown product") is hidden (count 8→7 = 6 active + paused RateShock). Direct `GET /products/:id` still works. (`tests/integration/routes.test.ts` mock updated to canonical ids; 18/18 pass.)
- **`docs/skills/*.md`** (9 files) — removed retired FLASHBTC4H/MICRODEPEG and paused RATESHOCK from buyable lists (6 active flash shields); fixed a friendly-name quote URL to bytes32; kept the correct **$100** minimum (reverted an erroneous intermediate $50 edit).

### v0-lumina-landing-page — branch `feat/ux-devex-final-fixes`
- Marketplace fee 2%→3% across whitepaper EN/ES HTML, interactive WP `copy.en/es.ts`, `tutorial-data.tsx`, `BurnEngine.tsx`, `MarketplaceSection.tsx`, `lib/docs.ts`; whitepaper made internally self-consistent.
- Skill count 22→24 + "Mocking…"→"Maintaining…" typo (EN+ES); fee-bucket labels → Burn/Buyback/Operations/Maintenance.
- GitHub link → `…/LUMINA-PROTOCOL`; footer link to `/legal`.
- **`app/legal/page.tsx`** (new) — testnet ToS / risk / privacy scaffold (binding text marked `[PLACEHOLDER — pending legal review]`).
- **`app/tutorial/page.tsx`** — fixed the stuck "Tutorial · loading…" bug: it was the only route missing `export const dynamic = 'force-dynamic'`, so Next prerendered the Suspense fallback (root cause: `useSearchParams()` in a client page under `output: "standalone"`).

### LUMINA-PROTOCOL — branch `feat/ux-devex-final-fixes`
- **`README.md`** — V5.1 → V5.4. **`CHANGELOG.md`** — added `[5.4]` entry, bumped current-version label.
- **`docs/RISK-DISCLOSURES.md`** (new) — fixes README dead link. **`AUDIT_STATUS.md`** (new) — fixes docs `contracts/audits.mdx` dead link.
- **`CONTRIBUTING.md`** (new) — real local-dev/test workflow.
- **`audit-pack/audits/`** — these 3 reports + index update.

## Founder decisions required (NOT auto-fixed — flagged per sprint rules)

1. **Coverage minimum policy**: the $100 floor (`CoverRouterV2.sol:264`) and the API mirror (`policies.ts:23`) carry a comment that misstates *why*; product decision whether to lower it to match the $0.005 contract floor / SDK $50 examples, or keep $100. **No contract change made.**
2. **Team doxxing / entity disclosure** — required for an insurance product's trust surface.
3. **Binding legal ToS / Privacy** — only a scaffold was created; needs counsel.
4. **External audit, live bug bounty, multisig custody** — pre-mainnet operational blockers.
5. **Community (Discord/Telegram), explainer videos, testimonials** — content the founder must produce.
6. **Skill-count canonical value**: `lumina-api/docs/skills/` has 24 `.md` (+INDEX); landing `lib/skills.ts` array has 23 entries; labels set to 24 — reconcile the missing entry.
7. **Optional API hardening (deferred):** rejecting unknown-canonical productIds in the *purchase* path was evaluated but skipped — two security tests purchase with a `0x000…0` productId, so a guard would break them. The `/products` list filter already hides leaked products from discovery.
8. **lumina-api skill-doc addresses** still show an older snapshot (with a "fetch from /health" disclaimer); a full address refresh of `lumina-api/docs/skills/*.md` is a follow-up.

## Re-test (Phase H) — projected V2 after merge+deploy

| Dimension | V1 | V2 (proj.) |
|---|--:|--:|
| Agent: Discovery / Docs / llms.txt / First-Policy / Post-Purchase / SDK | 8.5 / 8.0 / 6.0 / 9.5 / 6.5 / 6.5 | 9.5 / 9.5 / 10 / 10 / 9.0 / 9.5 |
| **Agent GLOBAL** | **7.4** | **9.5** |
| Human: Developer / Non-tech | 6.4 / 3.9 | 8.5 / 7.0 |
| **Human GLOBAL** | **5.1** | **7.75** |

V2 reflects the **post-fix repository**; live surfaces still serve V1 until the PRs merge
and docs/npm/landing redeploy. Human-side ceiling (~10) is gated on the founder decisions
above, not code.
