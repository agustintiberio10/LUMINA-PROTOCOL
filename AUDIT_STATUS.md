# Audit Status

> **Honest disclosure:** every review below is **internal and AI-assisted**
> (Slither, Aderyn, Mythril, Halmos, Echidna + AI-performed manual/red-team/
> economic passes). **No completed third-party audit exists yet.** Do not treat
> these scores as external diligence. Mainnet is gated on an external audit, a
> live bug-bounty, and multisig custody. See
> [`audit-pack/audits/2026-05-26-tier1-assessment.md`](./audit-pack/audits/2026-05-26-tier1-assessment.md).

Current architecture: **V5.4** on Base Sepolia (chainId 84532). Full reports live
in [`audit-pack/audits/`](./audit-pack/audits/).

| Date | Audit | Verdict / Score | Report |
|---|---|---|---|
| 2026-05-22 | UX/DevEx V1 | baseline | `audit-pack/audits/2026-05-22-ux-devex-v1.md` |
| 2026-05-23 | UX/DevEx V2 | improved | `2026-05-23-ux-devex-v2.md` |
| 2026-05-23 | Economic V5.3 V2 (post-fix) | 8.4/10 SOUND | `2026-05-23-economic-audit-v53-v2.md` |
| 2026-05-23 | Functional V5.3 V1 (testnet) | 7.7/10 NEEDS-ADJUSTMENT | `2026-05-23-functional-audit-v53-v1.md` |
| 2026-05-24 | Red Team Adversarial V5.3 V2 (post-fix) | 8.6/10 SOUND | `2026-05-24-red-team-audit-v53-v2.md` |
| 2026-05-25 | Manual Review V5.3 V2 (post-fix) | 9.3/10 SOUND | `2026-05-25-manual-review-v53-v2.md` |
| 2026-05-26 | Operational Security V5.3 | 6.0/10 NEEDS-HARDENING | PR #162 |
| 2026-05-26 | Tier-1 Readiness Assessment | ~4.5/10 (NOT Tier-1) | `2026-05-26-tier1-assessment.md` |
| 2026-05-26 | E2E Full-Flow (mock-oracle) | PASS (6/6 invariants) | `2026-05-26-e2e-test-full-flow.md` |
| 2026-05-26 | UX/DevEx Final — Agent | 7.4 → 9.5 (proj.) | `2026-05-26-ux-devex-final-agent.md` |
| 2026-05-26 | UX/DevEx Final — Human | 5.1 → 7.75 (proj.) | `2026-05-26-ux-devex-final-human.md` |

## Static analysis & test tooling (CI)

- `forge test` (unit + invariant/fuzz), `forge fmt --check`
- Slither, Aderyn, Mythril, Halmos, Echidna (see `.github/workflows/`)
- Coverage: ~60.8% line / ~27.1% branch (below the 90% Tier-1 bar — see Tier-1 assessment)

## Pre-mainnet blockers (open)

1. External third-party audit (not started).
2. Live bug-bounty program (Immunefi planned, not launched).
3. Multisig custody (owner is currently a single EOA).
4. Key rotation + on-call/incident-response maturation (Operational audit).

See [`audit-pack/what-is-pending.md`](./audit-pack/what-is-pending.md) for the full list.
