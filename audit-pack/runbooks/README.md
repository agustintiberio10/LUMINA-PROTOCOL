# Runbooks (index)

Operational runbooks live in [`docs/runbooks/`](../../docs/runbooks/) (the source of truth). This
index points an external reviewer to the operationally-relevant procedures. Their maturity and gaps
are assessed in [`../audits/2026-05-26-operational-audit-v53.md`](../audits/2026-05-26-operational-audit-v53.md).

| Runbook | Path | Op-audit note |
|---|---|---|
| Daily operations | `docs/runbooks/DAILY-OPERATIONS-RUNBOOK.md` | exists |
| Incident response | `docs/runbooks/INCIDENT-RESPONSE-RUNBOOK.md` | P0/P1/P2 + comms matrix; **never rehearsed (OP-007)**, assumes a team that doesn't exist (OP-004); title still "V5.0" (OP-006) |
| Mainnet deploy | `docs/runbooks/DEPLOY-MAINNET-RUNBOOK.md` | + `script/deploy/UpgradeManualReviewV54.s.sol` demonstrated dry-run→broadcast→smoke this cycle; **no upgrade timelock (OP-009)** |
| Multisig operations | `docs/runbooks/MULTISIG-OPERATIONS-RUNBOOK.md` | aspirational — multisig **not deployed** (BL-MULTISIG, OP-003) |
| Shields operations | `docs/runbooks/SHIELDS-OPERATIONS.md` | exists |
| Founder vesting operations | `docs/runbooks/FOUNDER-VESTING-OPERATIONS.md` | exists |
| Key rotation | `docs/KEY-ROTATION-PLAN.md` | **documented but NOT executed — keys in plaintext, never rotated (OP-001, CRITICAL)** |

Related: `docs/communications/INCIDENT-TEMPLATES.md`, `docs/monitoring/ALERTS-CONFIGURATION.md`
(documented, live wiring unverified — OP-008), `docs/governance/`, `docs/legal/COMPLIANCE-CHECKLIST.md`.
