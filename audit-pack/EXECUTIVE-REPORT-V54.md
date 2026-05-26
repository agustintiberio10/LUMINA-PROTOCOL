# Lumina Protocol V5.4 — Executive Audit Report

**Date**: 2026-05-26 · **Network**: Base Sepolia testnet (chainId 84532) · **Audience**: investors, external auditors, partners

> **Read this first.** Every audit summarized below was performed by a single AI reviewer
> (Claude). They are a rigorous **internal first pass**, **not** an external Tier‑1 certification.
> No third‑party firm (Trail of Bits, OpenZeppelin, Spearbit, Zellic, CertiK, Code4rena) has
> reviewed this code. Treat the scores here as internal QA signal, not as institutional diligence.
> See **§7 Limitations** and **§8 Pending External Audits**.

---

## 1. Overview

Lumina is an on‑chain **parametric insurance** protocol on Base: users buy short‑dated "flash
shields" (BTC/ETH, 1h/24h/48h windows) that pay out if the asset drops past a threshold within the
window. Payouts are backed by a single USD‑collateral `BondVault` (ClaimBond ERC‑1155 = $1 each,
730‑day maturity), priced/settled by `CoverRouterV2` + `PolicyManagerV2` against Chainlink feeds
with a multi‑block confirmation gate, and a LUMINA token with deflationary buyback/burn mechanics.

**Status**: deployed and functional on **Base Sepolia testnet**. Core contracts are UUPS‑upgradeable
and currently owned by a **single founder EOA** (no multisig yet). The protocol is **pre‑mainnet**.

## 2. Audit history (chronological)

All audits internal (Claude). "V1→V2" = initial audit → re‑audit after fixes.

| Date | Audit | Scope | Score | Verdict |
|---|---|---|---|---|
| 05‑22/23 | UX / DevEx V1 → V2 | docs, SDK, API developer experience | — | improved |
| 05‑23 | **Economic** V5.3 V1 → V2 | tokenomics, premium/payout, solvency | 6.4 → **8.4** | SOUND |
| 05‑23 | **Functional** V5.3 V1 | testnet end‑to‑end | 7.7 | NEEDS‑ADJ → 3 criticals fixed |
| 05‑24 | **Red Team** V5.3 V1 → V2 | adversarial + Slither/Mythril/Echidna/Aderyn | 6.0 → **8.6** | SOUND (39 findings fixed) |
| 05‑25 | **Manual Review** V5.3 V1 → V2 | CertiK‑style line‑by‑line | 8.0 → **9.3** | SOUND (28 findings + 1 new HIGH found) |
| 05‑26 | **Operational** V5.3 | OpSec, IR, governance, monitoring | **6.0** | NEEDS‑HARDENING (16 open) |

**On‑chain milestones**: Shields UUPS + F‑01 redeploy; 8 UUPS Manual‑Review upgrades broadcast
(verified + smoke‑tested); full legacy test suite migrated green (~1,900 tests); canonical address
manifest derived on‑chain (PR #160). Formal methods: Echidna (200k runs/property), Halmos (4
contracts), Foundry invariants.

## 3. Findings summary (code)

Aggregate across the code audits (Red Team + Manual Review; Economic/Functional fixes folded in):

| Severity | Found | Fixed / dispositioned | Open (code) |
|---|---|---|---|
| Critical | 2 (F‑01 flash‑trigger; MR‑L10 committed double‑decrement, found while fixing) | 2 | 0 |
| High | ~8 | ~8 | 0 |
| Medium | ~20 | ~20 | 0 |
| Low | ~22 | ~22 | 0 |
| Informational | ~16 | documented | — |

**Code findings are resolved and the highest‑severity fixes are live on‑chain.** Separately, the
Operational audit opened **16 process findings (1 Critical, 4 High, 7 Medium, 3 Low, 1 Info)** that
are **open** — these are operational, not code (see §5).

## 4. Tier‑1 readiness assessment (honest)

A Tier‑1 protocol (Aave/Compound/Maker level) bar vs Lumina today:

| # | Criterion | Tier‑1 standard | Lumina today | Gap |
|---|---|---|---|---|
| 1 | External Tier‑1 audit | ToB / OZ / CertiK | ❌ internal (AI) only | **CRITICAL** |
| 2 | Secondary independent audit | Spearbit / Zellic / Code4rena | ❌ none | HIGH |
| 3 | Bug bounty | Immunefi $500k+ | ❌ none ( `security@` + SLA only) | HIGH |
| 4 | Formal verification | critical contracts proven | ⚠️ Echidna + Halmos(4) + invariants | MEDIUM |
| 5 | Multisig + Timelock | required | ❌ single founder EOA | **CRITICAL** |
| 6 | Docs (NatSpec/ADR/runbooks) | ~100% | ⚠️ strong runbooks/ADRs, NatSpec partial (~70%) | MEDIUM |
| 7 | Test coverage + invariants | >90% | ⚠️ ~**60.8% line / 27.1% branch** + invariants | MEDIUM/HIGH |
| 8 | Monitoring + alerting | live (Tenderly/Defender/Forta) | ❌ documented, not wired | HIGH |
| 9 | IR tested | regular fire drills | ❌ runbooks never rehearsed | HIGH |
| 10 | Legal opinions | multi‑jurisdiction | ❌ checklist only | HIGH |
| 11 | Insurance fund / safety module | yes | ⚠️ MaintenanceReserve + solvency floor (partial) | OK‑partial |
| 12 | Public post‑mortems | history | N/A (no incidents) | N/A |
| 13 | DAO governance | Snapshot + execution | ❌ none (future) | MEDIUM |

**Honest readiness scoring:**

| Category | Score /10 |
|---|---|
| Internal audit rigor | 8 |
| External audit | 2 |
| Tooling | 7 |
| Documentation | 6 |
| OpSec | 4 |
| Governance | 3 |
| Legal | 2 |
| Community | 3 |
| **OVERALL Tier‑1 readiness** | **~4.5 / 10** |

**Verdict: Lumina is NOT Tier‑1 today. It is Tier 2–3 with a credible path to Tier‑1.** Its code has
had unusually thorough *internal* adversarial review (multiple passes, all findings fixed, highest
severities live on‑chain) — strong for a pre‑external‑audit project — but the hard Tier‑1
requirements (external audit, multisig/timelock, bug bounty, live monitoring, legal) are not met.

## 5. Critical gaps for mainnet (prioritized)

1. **External Tier‑1 audit** (Trail of Bits / OpenZeppelin) — *non‑negotiable before mainnet.*
2. **Key management**: founder key is in plaintext and reused; **rotate + execute the key‑rotation plan**.
3. **Multisig + Timelock** governance (replace single EOA owner of the 8 UUPS proxies).
4. **Live monitoring + on‑call/paging**; rehearse incident‑response runbooks.
5. **Branch protection + CODEOWNERS + CI‑as‑merge‑gate** (currently `main` is unprotected).
6. **Bug bounty** (Immunefi) + refreshed disclosure scope.
7. **Legal opinion** (parametric‑derivative vs insurance classification, jurisdiction) + ToS/privacy.
8. **Raise test coverage** toward the >90% bar; broaden formal verification.

## 6. Mainnet roadmap (indicative)

| Step | Indicative cost | Timeline | Priority |
|---|---|---|---|
| External audit (Trail of Bits / OZ) | $80–150k | 8–12 wk | Required |
| Secondary audit (Spearbit / Code4rena) | $40–80k | 4–6 wk | Required |
| Bug bounty (Immunefi) | $50k+/yr | ongoing | Required |
| Multisig + Timelock | ~$0 | 1 wk | Required |
| Monitoring + paging | ~$5k/yr | 2 wk | Required |
| IR fire drills + key rotation | ~$0 | 4–6 wk | Required |
| Legal opinions + ToS | $20–50k | 4–6 wk | Required |
| Formal verification (expand) | $30–60k | 6–8 wk | Recommended |

**Indicative total: ~$200–400k + ~4–6 months.** (Cost ranges are industry‑typical estimates, not quotes.)

## 7. Methodology & tools

Internal audits used: **Foundry** (`forge test` + invariants, ~1,900 tests), **Echidna** (200k
runs/property), **Halmos** (symbolic, 4 contracts), **Slither** + **Aderyn** (static), **Mythril**
(limited), and manual line‑by‑line review. CI runs 7 workflows (ci, coverage, echidna, mythril,
aderyn, halmos, gas‑snapshot). On‑chain verification via `cast` + dry‑run/broadcast/smoke‑test
discipline (documented per upgrade).

### Limitations of these audits (important)
- **Performed by a single AI (Claude).** The same model reviewed the code, wrote the fixes, *and*
  re‑audited them — no human reviewer, no firm diversity, no independent adversary. Systematic
  blind spots are plausible and would not be caught by self‑review.
- **Not a certification.** These reports are an internal first pass. They do **not** substitute for
  an external Tier‑1 audit and should not be presented as one.
- **Coverage gaps acknowledged**: ~60.8% line / 27.1% branch coverage; several scenarios deferred
  (mainnet‑fork stress, actuarial threshold validation, multi‑DEX edge cases, extended Echidna
  sequences) — see `what-is-pending.md`.
- **Environment caveats**: full test suite verified per‑folder (the full run OOMs/hangs on the
  audit host); some checks deferred to CI Linux.

**What confidence is warranted?** For investors/users: treat this as evidence the team takes
security seriously and has done diligent internal work — **not** as a green light. The appropriate
posture pre‑mainnet is: external Trail‑of‑Bits‑grade audit **mandatory**, multisig **mandatory**,
bug bounty **mandatory**.

## 8. Pending external audits

None engaged yet. Recommended sequence before mainnet: (1) Trail of Bits or OpenZeppelin full
review; (2) a secondary independent audit or a Code4rena/Cantina contest; (3) launch an Immunefi
bug bounty at/after mainnet. Until at least (1) completes, Lumina should remain on testnet.

---

*This report is intentionally conservative. If it were submitted to an institutional investor as
diligence, the correct reading is: "promising, thoroughly self‑reviewed, not yet externally
certified — fund contingent on external audit + governance hardening."*
