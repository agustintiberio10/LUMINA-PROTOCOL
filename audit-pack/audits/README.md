# Audits

Detailed audit reports executed during Lumina development.

Each file represents one complete audit with findings, severity, scores,
and recommendations.

## Index

| Date | Audit | File |
|---|---|---|
| 2026-05-22 | UX/DevEx V1 | [2026-05-22-ux-devex-v1.md](./2026-05-22-ux-devex-v1.md) |
| 2026-05-23 | UX/DevEx V2 | [2026-05-23-ux-devex-v2.md](./2026-05-23-ux-devex-v2.md) |
| 2026-05-23 | Economic V5.3 V2 (post-fix) | [2026-05-23-economic-audit-v53-v2.md](./2026-05-23-economic-audit-v53-v2.md) |
| 2026-05-23 | Functional V5.3 V1 (testnet) | [2026-05-23-functional-audit-v53-v1.md](./2026-05-23-functional-audit-v53-v1.md) |
| 2026-05-24 | Red Team Adversarial V5.3 V2 (post-fix, Sprint Fix 7.2) | [2026-05-24-red-team-audit-v53-v2.md](./2026-05-24-red-team-audit-v53-v2.md) |
| 2026-05-25 | Manual Review V5.3 V1 (CertiK line-by-line) | (PR #157 — `2026-05-25-manual-review-v53.md`) |
| 2026-05-25 | Manual Review V5.3 V2 (post-fix, Sprint Fix 7.3) | [2026-05-25-manual-review-v53-v2.md](./2026-05-25-manual-review-v53-v2.md) |
| 2026-05-26 | Operational Security V5.3 (Sprint 7.6) | [2026-05-26-operational-audit-v53.md](./2026-05-26-operational-audit-v53.md) |

## Convention

Files named: `YYYY-MM-DD-<audit-name>.md`

Each audit file should include:

- Date + scope
- Methodology (who/how)
- Scores per dimension
- Findings (severity: Critical / High / Medium / Low)
- Recommendations
- Verdict
- Linked fix sprints (cross-ref to `audit-pack/sprints/`)
