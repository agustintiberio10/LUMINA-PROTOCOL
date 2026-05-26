# Whitepaper Consistency Audit V5.4

**Date:** 2026-05-26
**Methodology:** Canonical spec derived on-chain (Base Sepolia 84532) + contract
source (`spec-canonical-v54.json`), compared claim-by-claim against the written
surfaces. **READ-ONLY — nothing was modified, nothing merged.**
**Scope:** 4 whitepapers + docs (Mintlify) + landing + llms.txt/llms-full.txt +
SDK README + live `/products` API.

## Executive Summary

The whitepapers' **hard numeric promises are sound**. Both long whitepapers (EN +
ES V5.3) had **zero value mismatches** across supply, distribution, burn split,
marketplace fee, payout/deductible, all six trigger thresholds, maturity, throttle,
floor/reset, and every AltSeason value — and EN ↔ ES agree on all of them. The
short interactive WP is also numerically correct.

The defects are concentrated in **(a) one systemic *labeling* error** — the 8% and
5% fee-split slices are mislabeled "treasury / founder" instead of the canonical
**buyback / maintenance** on ~10 surfaces (the *values* 85/8/2/5 are correct
everywhere) — and **(b) stale supporting artifacts** (a V3-branded `/whitepaper`
hub, `llms-full.txt` listing retired products, $50/$1 coverage examples, one wrong
AltSeason docs page). One long-WP claim — a **"125% solvency floor"** — does **not
exist anywhere in code** (the real mechanism is a 50% commitment cap = 200% backing).

- **Claim-checks performed:** ~130 across all surfaces (EN 39, ES 39, short ~14, docs ~18, landing ~20, SDK ~9, llms.txt 8, llms-full ~11, API).
- **Distinct inconsistencies:** **16** (1 CRITICAL, 5 HIGH, 5 MEDIUM, 5 LOW) + INFO.
- **Global match rate (numeric values): ~92%** (the systemic issue is a *name*, not a number).

## Severity Distribution

| Severity | Count |
|---|---|
| CRITICAL | 1 |
| HIGH | 5 |
| MEDIUM | 5 |
| LOW | 5 |
| INFO | 2 |

## CRITICAL

**C-1 — "125% solvency floor" is not implemented in code.**
Both long whitepapers cite a **125% solvency floor** (EN/ES `LUMINA-WHITEPAPER-*-V5.3.html` L202, L324, L371, L419). No `125`/`12500` constant exists in `BondVault.sol`. The actual solvency mechanism is `SAFETY_FACTOR_BPS = 5000` (BondVault.sol:53) → committed obligations ≤ **50%** of reserve value → **200% backing**; the only related ratio is `BuybackEngine.MIN_SOLVENCY_FOR_DOUBLE_BURN = 15000` (**150%**). Per the audit rule "a WP number that doesn't exist in code = CRITICAL." *Direction note:* the real backing (200%) is **stronger** than the stated 125%, so this is conservative — not investor-harmful — but it is factually wrong and likely a stale V5.1 figure. **Fix:** restate as "≤50% commitment cap / 200% reserve backing" (and reference the 150% buyback gate separately).

## HIGH

**H-1 — Fee-split slices mislabeled "treasury / founder" (should be "buyback / maintenance"). SYSTEMIC.**
The values 85/8/2/5 are correct everywhere, but the **8%** and **5%** channels are repeatedly named *treasury* and *founder* instead of the canonical **buyback** (8%) and **maintenance** (5%) — `TWAPBurner.FALLBACK_BUYBACK_BPS=800` / `FALLBACK_MAINTENANCE_BPS=500`. Affected (file:line):
- short WP `copy.en.ts:55` / `copy.es.ts:44` ("fund treasury/ops/founder")
- docs `concepts/marketplace.mdx:30,81`; `concepts/overview.mdx:47`; `concepts/lifecycle.mdx:10,30,50,210`; `concepts/lumina-token.mdx:31-33`
- `llms.txt:8`
- landing `HowItWorks.tsx:13-14`; `Roadmap.tsx:7`; `BurnEngine.tsx:117,138` (self-contradicts its own correct line 113)
Canonical (already correct) references: `docs/tokenomics.mdx:41-44`, `lib/docs.ts:129,315`, `whitepaper-short/copy.en.ts:120` bar labels. *(Note: a prior sprint fixed the bucket names in some spots but not this prose set — incomplete.)*

**H-2 — Landing `Hero.tsx:12` shows marketplace fee "Bond resale 2%".** Canonical 3% (1.5%+1.5%). Every other marketplace surface is correct at 3%.

**H-3 — `docs/concepts/lumina-token.mdx:84-86` states the wrong AltSeason paths.** Says PATH1 = "ETH≥$5,000 AND LUMINA≥$1 1d"; PATH2 = "LUMINA≥$1 sustained". Canonical (FounderVesting.sol + `docs/contracts/architecture.mdx:111-114` + `lib/docs.ts:633`): PATH1 = 2-of-3 [ETH/BTC>0.050, ETH>$4,000, Aave V3 USDC borrow >7% APY] sustained 1d; PATH2 = ETH>$5,000 sustained 1d; PATH3 = 1095d. This is an intra-docs contradiction (architecture.mdx is right).

**H-4 — `llms-full.txt` lists retired products as active.** `FLASHBTC4H-001` (L195) and `MICRODEPEG-001` (L201) appear in the products table; both retired in T-30c. (`llms.txt` correctly excludes them.)

**H-5 — `/whitepaper` hub page is stale V3 copy.** `app/whitepaper/page.tsx` advertises "Whitepapers · V3.0" (L23), "Full Whitepaper · V3.0 / 17 sections / ~50 pages" (L37-38), and "**9 ClaimBond products**" (L47, L59) — though the `/whitepaper/en` and `/es` routes correctly serve V5.3 (6 flash shields). Investor-facing and contradicts reality.

## MEDIUM

**M-1 — `llms-full.txt` example "BTC drops 20% in 1h"** (L168) — FLASHBTC1H threshold is 2.5%, not 20%.
**M-2 — SDK README $50 coverage examples** (`README.md:54,62` `coverageAmount '50000000'`) below the $100 on-chain minimum (CoverRouterV2 reverts <100e6). llms-full.txt repeats $50 (L109/115,215,339).
**M-3 — Sandbox cap stated as "$1"** in SDK README:120 and llms-full.txt:129; live `coverageCapUsdc = 100000000` ($100, per `llms.txt:115`).
**M-4 — `llms-full.txt` has no tokenomics/fee-split/AltSeason section at all** (gap vs `llms.txt`, which covers it).
**M-5 — `lib/lumina-config.ts:327-328` frames `feeBps:300` as "3% on premiums, payouts, and vault performance"** — legacy vault-yield framing, not the V5.3 premium-burn model.

## LOW

**L-1 — Stale V3 artifacts still bundled in `/public`:** `LUMINA-WHITEPAPER-EN-V3.html`, `ES-V3.html`, `LUMINA-WHITEPAPER-EN.pdf`, `ES.pdf` (describe the old 9-product LP-vault model). Unlinked from the app but reachable by direct URL.
**L-2 — `lib/lumina-config.ts:184-275` holds a dead pre-V5.3 product catalog** (BCS/EAS/DEPEG/IL/EXPLOIT, FLASH_BTC −18%/−22%, FLASH_ETH −20%/−28%). NOT imported by any rendering component (Products.tsx + operate/products.ts define their own canonical consts) — latent landmine.
**L-3 — `docs/tokenomics.mdx:44`** says "Maintenance reserve / founder" (mild variant of H-1).
**L-4 — `lib/docs.ts:619`** lists the split as "5% maintenance, 2% ops" (values right, 2/5 order swapped vs 85/8/2/5).
**L-5 — Whitepaper omissions** (consistent EN↔ES, not wrong, just absent): per-user redemption cap 10% of epoch; floor-recovery $0.006 (120%); testnet 60s maturity override (readers on testnet observe 60s, not 730d).

## INFO

**I-1 — CEX Reserve (14M) and LBP (5M) allocations are documented but not deployed** (cexReserve=0x0; LBP Fase 7.3). The WPs disclose this — acceptable, flagged for completeness.
**I-2 — Locale formatting only** (EN `2.5%`/`$2,92` vs ES `2,5%`/`$2.92`; date order). Not a defect.

## Master comparison (key claims)

| Claim | WP-EN | WP-ES | WP short | docs | landing | llms.txt | llms-full | Code | Status |
|---|---|---|---|---|---|---|---|---|---|
| Total supply | 100M | 100M | 100M | 100M | 100M | 100M | 100M | 100M | ✅ |
| Distribution 70/14/8/5/3 | ✅ | ✅ | ✅ | ✅ | ✅ | — | ❌(absent) | 70/14/8/5/3 | ✅ (gap llms-full) |
| Burn split values 85/8/2/5 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | — | 8500/800/200/500 | ✅ |
| Fee-split slice **names** | buyback/maint ✅ | ✅ | ❌ treasury/founder | ❌ (most) | ❌ (several) | ❌ | — | buyback/maintenance | ❌ H-1 |
| Marketplace fee | 3% | 3% | 3% | 3% | 3% (Hero ❌2%) | — | 3% | 150+150=3% | ❌ H-2 (Hero) |
| Payout/deductible | 80/20 | 80/20 | 80 | 80/20 | 80/20 | 80/20 | — | 8000/2000 | ✅ |
| Min coverage | $100 | $100 | $100 | $100 | $100 | $100 | $50 ❌ | 100e6 | ❌ M-2 |
| Trigger thresholds (6) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 20% ❌(eg) | 250…1400 | ✅ (M-1 eg) |
| Bond maturity | 730d | 730d | 730d | 730d | 730d | 730d | 730d | 730d default | ✅ |
| Throttle 1.08%/7d | ✅ | ✅ | — | ✅ | ✅ | ✅ | — | 108bps/7d | ✅ |
| Floor $0.005 / reset $0.008 | ✅ | ✅ | — | ✅ ($0.006 too) | — | — | — | 5e15/8e15/12000 | ✅ |
| Solvency "125%" | ❌ | ❌ | — | — | — | — | — | 50% cap (200%) | ❌ C-1 |
| AltSeason paths | ✅ | ✅ | (omit) | ✅ arch / ❌ token | ✅ | — | — | FounderVesting | ❌ H-3 (1 page) |
| Retired products excluded | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | T-30c | ❌ H-4 |
| chainId 84532 | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | 84532 | ✅ |

## Per-Whitepaper Score

| Whitepaper | Match Rate | Score |
|---|---|---|
| EN long (V5.3) | 38/39 numeric ✅ (C-1 only) | 9.5/10 |
| ES long (V5.3) | 38/39 (mirror, faithful translation) | 9.5/10 |
| Short interactive | 13/14 (H-1 label only) | 8.5/10 |
| "4th" = V3 HTMLs/PDFs + `/whitepaper` hub | stale V3 (H-5) | 3/10 |

## Per-Surface Score

| Surface | Match Rate |
|---|---|
| Whitepapers EN/ES (long) | ~98% |
| Short interactive WP | ~93% |
| docs (Mintlify) | ~70% (H-1 labels + H-3) |
| landing | ~80% (H-1 labels + H-2 Hero) |
| llms.txt | ~88% (H-1 label only) |
| SDK README | ~78% (M-2, M-3) |
| llms-full.txt | ~55% (H-4, M-1/3/4) |
| live `/products` API | 100% |

## Recommendations (priority order — founder decides what to update)

1. **C-1:** correct "125% solvency floor" → "≤50% commitment cap / 200% backing" in EN+ES long WPs.
2. **H-1:** global find/replace fee-slice names → 8% **buyback** / 5% **maintenance** across short WP, docs, llms.txt, landing components (10 locations).
3. **H-3:** fix `lumina-token.mdx` AltSeason to the canonical 2-of-3 / $4k / $5k / 3-year paths (model after `architecture.mdx`).
4. **H-2:** `Hero.tsx:12` "Bond resale 2%" → 3%.
5. **H-4 / M-1 / M-3:** regenerate `llms-full.txt` — drop retired products, fix the "20% in 1h" example, $50→$100, $1→$100 sandbox cap, add the tokenomics/fee-split/AltSeason section.
6. **H-5:** rewrite the `/whitepaper` hub copy to V5.3 (6 products, correct section count); remove or relabel stale V3 HTMLs/PDFs in `/public` (L-1); delete the dead `lib/lumina-config.ts` catalog (L-2).
7. **M-2:** SDK README examples → $100.
8. **L-5:** optionally add the omitted mechanics (per-user 10% cap, $0.006 hysteresis, testnet 60s note) to the long WPs.

## Confidence

**Reverse audit: 9/10.** Canonical spec was derived directly from on-chain reads
(fees, supply, throttle, floors) + contract source (shield thresholds, AltSeason,
distribution, safety factor) and cross-checked; the "125%" non-existence and the
fee-label systemic issue were both independently re-verified against source.

**Limitations (honest):** (a) The long-WP audit relied on agent line citations
against an 80KB HTML; a handful of line numbers are approximate. (b) Premium
*formula* outputs (the per-$1k premium figures in the WPs) were checked for
consistency of inputs (margin/triggerProb), not recomputed to the cent. (c) The
PDFs were treated as legacy by filename/links, not parsed. (d) FounderVesting**V2**
exists (mainnet-pending); V1 was used as the deployed canonical reference. (e) This
is a documentation-vs-code audit, not a security or economic-soundness audit.
