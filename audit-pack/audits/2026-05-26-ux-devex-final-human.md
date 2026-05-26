# UX/DevEx Final — Human Audit: Developer + Non-Tech (V1 → V2)

**Date:** 2026-05-26 · **Method:** two human personas (developer, non-technical retail
user) against live surfaces (landing, docs, API, npm, GitHub, BaseScan) + repo
ground-truth. 30 tests (15 + 15).

## Scores

| Profile | V1 (measured) | V2 (post-fix repo, projected after deploy) |
|---------|:--:|:--:|
| Developer | 6.4 | 8.5 |
| Non-tech user | 3.9 | 7.0 |
| **GLOBAL** | **5.1** | **7.75** |

> Developer experience is genuinely solid for an internal/testnet project; the
> **non-technical & trust surface** is where V1 fell down. Several gaps there are
> **founder/business decisions** (doxxing, binding legal terms, external audit, live
> community) that code cannot close — they are flagged, not invented.

## C.1 Developer (15 tests) — V1 6.4
Strong: GitHub org public (4 repos), README + `audit-pack/` (7 reports, ADRs, runbooks,
manifests), testnet deploys with BaseScan links + `/health`, CI/CD (`ci`, `coverage`,
`echidna`, `halmos`, `mythril`, `aderyn`), runnable Foundry suite.
Gaps fixed this sprint:
- README labelled **V5.1** → **fixed to V5.4**.
- `docs/RISK-DISCLOSURES.md` dead link (README:70) → **created**.
- No `CONTRIBUTING.md` → **created** (local dev + test workflow, the real one, not Mintlify boilerplate).
- CHANGELOG top entry `2.0.0`/"V5.1" stale → **added [5.4] entry + bumped current-version label**.
- `AUDIT_STATUS.md` referenced by docs `contracts/audits.mdx` → addressed (see fixes report).
Remaining (flagged): ABI not first-class published; docs-site `development.mdx`/`essentials/*` are Mintlify boilerplate; gas-report CI job disabled (`if:false`, documented nonce-drift bug); no Discord.

## C.2 Non-tech (15 tests) — V1 3.9
Strong: transparent premium table + live quotes, testnet faucet + code-free sandbox,
honest roadmap.
Gaps fixed this sprint:
- `/legal` 404 → **scaffolded `app/legal/page.tsx`** (testnet disclaimer + risk factors; binding legal text marked `[PLACEHOLDER — pending legal review]`).
- `/tutorial` stuck "loading…" → **investigated/fixed** in landing (see fixes report).
- No glossary → **created `docs/glossary.mdx`** + nav entry.
- `concepts/overview.mdx` dev-jargon-first → **added plain-English lead** for non-coders.
- Risk transparency → new `RISK-DISCLOSURES.md` (token-price, oracle, liquidity, parametric/basis, regulatory).

### Founder/business decisions (CANNOT be auto-fixed — STOP + report)
These materially cap the non-tech/trust score and require the founder, not code:
- **Anonymous team / no doxxing** (#3, #14). For an insurance product this is a fundamental trust gap. *Decision needed: publish team/entity/advisors or a governance+multisig statement.*
- **Binding legal ToS / Privacy** — only a scaffold was created; real terms need legal counsel.
- **External audit, live bug bounty, multisig custody** — operational/funding decisions (correctly self-disclosed in the Tier-1 assessment as pre-mainnet blockers).
- **Explainer videos, testimonials, social proof, Discord/Telegram** — content/community the founder must produce.

## Verdict
V1 **5.1/10** → projected V2 **7.75/10** after merge+deploy. Reaching ~9–10 on the human
side is **gated on founder decisions** (team doxxing, legal review, external audit, live
community) — explicitly out of scope for an autonomous code sprint and flagged here per
the sprint's STOP-and-report rule.
