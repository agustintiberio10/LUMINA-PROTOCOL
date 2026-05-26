# Architectural Decision Records (index)

ADRs are recorded inline within the sprint reports (`audit-pack/sprints/`) and the architecture
docs (`docs/architecture/`), rather than as standalone numbered files. This index orients an
external reviewer to the key recorded decisions.

| ADR | Decision | Where |
|---|---|---|
| ADR-015 | Close Phase 2 over BondVault (SET C) | sprint: SET C BondVault deploy |
| ADR-016 | Slither static-analysis disposition | sprint: Slither |
| ADR-017 | Hardening (via_ir, divide-before-multiply suppressions) | sprint: Hardening |
| ADR-021/022/023 | Immutables hardening (Echidna-proven) | sprint: Z.1 Immutables |
| ADR-024 | Pre-redeploy cleanup | sprint: Z.2 cleanup |
| ADR-025 | FounderVestingV2 override (3-path) | sprint: FV override |
| ADR-026 | Oracle signer blast radius + verifyAndCalculate idempotency | referenced in `what-is-pending.md` §9 |

Architecture docs: `docs/architecture/ORACLE-V2.md`, `TWAPBURNER-V2.md`, `AAVE-INTEGRATION.md`;
threat model: `docs/audit/THREAT-MODEL.md`.

> Tier‑1 gap (see assessment): ADRs are present but scattered; for external review they should be
> consolidated into numbered standalone files. Tracked as a documentation hardening item.
