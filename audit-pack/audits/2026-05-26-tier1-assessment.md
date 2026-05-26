# Tier‑1 Readiness Assessment (internal) — 2026-05-26

**Verdict: Lumina is NOT Tier‑1 today. It is Tier 2–3 with a credible path to Tier‑1.**
**Tier‑1 readiness score: ~4.5 / 10.**

This is the blunt internal companion to `audit-pack/EXECUTIVE-REPORT-V54.md`. No score inflation.

---

## Why NOT Tier‑1 (explicit)

1. **No external audit.** Every review to date is internal and AI‑performed. Tier‑1 protocols carry
   ≥1 (usually ≥2) audits from Trail of Bits / OpenZeppelin / Spearbit / Zellic / CertiK plus a
   public contest (Code4rena/Cantina). Lumina has zero. This alone disqualifies Tier‑1.
2. **Single‑EOA governance.** All 8 UUPS proxies are owned by one founder key, no timelock. A
   Tier‑1 protocol routes upgrades through a multisig + timelock with a public delay. (Documented
   as `BL-MULTISIG`; not deployed.)
3. **Key management is insecure in practice.** The founder private key is handled in plaintext and
   reused across roles/broadcasts; the `KEY-ROTATION-PLAN` is written but unexecuted. (OP‑001.)
4. **No live monitoring / on‑call.** Alerting is documented but not wired; incident response is a
   team of one and the runbooks have never been rehearsed. (OP‑004/007/008.)
5. **No bug bounty.** A `security@` channel + SLA exists, but no Immunefi program, no payout tiers,
   and the disclosure scope is stale. (OP‑005.)
6. **Coverage below bar.** ~60.8% line / 27.1% branch vs the >90% Tier‑1 expectation. Formal
   verification is partial (Echidna + Halmos on 4 contracts).
7. **No legal opinion.** Parametric‑derivative vs "insurance" classification and jurisdiction
   (Argentina/LATAM) are unresolved; ToS/privacy presence unverified.
8. **No SDLC enforcement.** `main` has no branch protection / CODEOWNERS; PRs merged with red CI.

## What IS genuinely strong (don't undersell)

- Multiple **adversarial internal passes** (Red Team, CertiK‑style manual) with **all code findings
  fixed** and the highest severities (F‑01, MR‑L10) **live on‑chain and smoke‑tested**.
- A **new HIGH bug (MR‑L10)** was found *while fixing* and corrected — evidence the process catches
  real defects, not just confirms.
- Broad **tooling**: Foundry invariants, Echidna 200k, Halmos, Slither, Aderyn, Mythril; 7 CI workflows.
- **Operational documentation depth** (runbooks/IR/governance/threat‑model/key‑rotation/monitoring/
  legal/training) that rivals mature teams — the gap is execution, not authorship.
- **Disciplined on‑chain ops** this cycle: dry‑run → storage‑layout verify → broadcast → selector +
  smoke verification, with a canonical on‑chain‑derived address manifest.

## Roadmap to Tier‑1 (cost / timeline — indicative)

| Step | Indicative cost | Timeline | Priority |
|---|---|---|---|
| External audit — Trail of Bits / OpenZeppelin | $80–150k | 8–12 wk | **Required** |
| Secondary audit — Spearbit / Zellic / Code4rena | $40–80k | 4–6 wk | **Required** |
| Bug bounty — Immunefi | $50k+/yr | ongoing | **Required** |
| Multisig (Gnosis Safe) + TimelockController | ~$0 | 1 wk | **Required** |
| Key rotation + secrets manager (stop plaintext) | ~$0 | 1 wk | **Required** |
| Monitoring + paging (Forta/Tenderly/Defender + PagerDuty) | ~$5k/yr | 2 wk | **Required** |
| IR fire drills + key‑rotation drill | ~$0 (time) | 4–6 wk | **Required** |
| Legal opinion + ToS/privacy | $20–50k | 4–6 wk | **Required** |
| Raise coverage >90% + expand formal verification | $30–60k (or internal time) | 6–8 wk | Recommended |
| Branch protection + CODEOWNERS + CI gates + npm token hygiene | ~$0 | days | **Required** |

**Indicative total: ~$200–400k + ~4–6 months.** Order: governance/keys/SDLC (cheap, fast) → external
audit (long pole) → bug bounty + monitoring + legal in parallel.

## D.1 — What we did NOT test
- No external/independent review (the central gap).
- Coverage holes: mainnet‑fork stress (real Aave/Uniswap/flash‑loan economics), actuarial threshold
  validation, multi‑DEX routing edge cases, extended Echidna `seqLen`, full Halmos on ~23 contracts,
  LBP mechanics — all tracked in `what-is-pending.md`.
- Live‑system aspects unverifiable from the repo: real monitoring/paging, landing ToS, npm token state.
- The MR‑H01 freshness gate's *active* behavior on a real Uniswap pool (it is dormant on testnet
  because `CapacityOracle.pool()==0x0`; it activates only when a real pool is wired at mainnet).

## D.2 — Limitations of this audit (Claude)
- **I am an AI, not a human auditor.** No professional liability, no firm process, no peer review.
- **Same model audited everything** — no diversity of mind; my blind spots propagate across every
  report and the fixes I wrote for them. Self‑review cannot find what I systematically don't see.
- **Possible systematic biases**: over‑trusting my own prior conclusions; pattern‑matching to common
  vuln classes and missing novel/protocol‑specific ones; environment‑induced shortcuts (Windows
  build limits → per‑folder verification rather than one clean full run).
- **This is NOT certification.** Pre‑mainnet, an external Trail‑of‑Bits‑grade audit is **mandatory**.

## D.3 — What if Claude is wrong?
- **Investor posture**: treat these as an internal first pass that lowers (not eliminates) risk.
  Fund contingent on external audit + multisig + bug bounty. Do not rely on AI scores as diligence.
- **User posture**: it's testnet; no real funds should be at risk. At mainnet, the safety case must
  rest on external audits + a live bug bounty + multisig, not on this report.
- **Team posture**: keep these as "internal QA", version them, and hand the code to an external firm
  before any mainnet value is at stake. A confident internal score (9.3 Manual Review) is *evidence
  of diligence*, not *proof of safety*.

## Is the audit‑pack ready for external review?
**Mostly yes for hand‑off, with caveats.** The audit‑pack (audits/, sprints/, manifests/,
what‑we‑tested, what‑is‑pending, this assessment + executive report) is organized and honest enough
to give an external firm a strong starting context. Before sending: refresh `SECURITY.md` scope to
the canonical V5.4 addresses, ensure NatSpec is complete on public/external functions, and attach
the canonical manifest as the single source of truth.

**Sprint CLOSED ✅.** Next: external audit engagement + the Required roadmap items, in parallel with
Fase 5 public testnet.
