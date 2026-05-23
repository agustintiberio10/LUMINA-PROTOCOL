# Sprints

Detailed sprint reports for sprints that did NOT receive a dedicated section
in `audit-pack/what-we-tested.md` (typically off-chain sprints — docs, API,
SDK, ops — or sprints that closed audit-derived items without a single big
contract change).

Sprints with major on-chain impact (deploys, contract changes, fuzz/halmos
runs) live as numbered sections in `what-we-tested.md`. This directory
complements that for the rest.

## Index

| Date | Sprint | File |
|---|---|---|
| 2026-05-22 | Fix Critical+High (post-audit UX/DevEx V1) | [2026-05-22-sprint-fix-critical-high.md](./2026-05-22-sprint-fix-critical-high.md) |
| 2026-05-23 | CR USDC Reconfig | [2026-05-23-sprint-cr-usdc-reconfig.md](./2026-05-23-sprint-cr-usdc-reconfig.md) |

## Convention

Files named: `YYYY-MM-DD-sprint-<slug>.md`

Each sprint file should include:

- Date + scope
- Trigger (which audit / which gap / which decision motivated it)
- Actions taken (PRs, deploys, txs)
- Outcomes (issues closed, files changed, tests added)
- Linked items closed in `what-is-pending.md`
- Cross-ref to upstream audit if applicable
