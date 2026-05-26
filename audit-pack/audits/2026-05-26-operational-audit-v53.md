# Lumina V5.3 — Operational Security Audit (Sprint 7.6)

**Auditor**: Senior Operational Security Auditor (CertiK / ToB methodology)
**Methodology**: processes, runbooks, OpSec, key management, incident response, monitoring,
governance ops, bug-bounty/disclosure, vendor risk, legal ops — **NO code review** (that was
7.2/7.3), **NO economic model** (7.5), **NO functional** (7.4).
**Date**: 2026-05-26 · **Scope**: operations end-to-end, Base Sepolia testnet → mainnet readiness.
**Constraints honored**: no code modified, no PR merged (report only), read-only inventory + on-chain reads.

---

## Executive Summary

Lumina's operational **documentation** is unusually mature for a pre-mainnet protocol: a full
runbook suite (`docs/runbooks/`: daily-ops, incident-response, deploy-mainnet, multisig-ops,
shields-ops, founder-vesting), governance framework (`docs/governance/`: decision-framework,
multisig-policies, roles-and-responsibilities), key-rotation plan, Gnosis-Safe setup, threat
model, anti-fraud playbook, monitoring config, legal compliance checklist, incident-comms
templates, and signer/developer training. That breadth is a genuine strength and is credited
below.

The gap is **execution and enforcement**, not documentation. The most expensive operational
risks here are the classic "the doc says X but reality is Y" failures:

- The **KEY-ROTATION-PLAN exists and is provably NOT executed** — the founder private key is
  handled in plaintext (Desktop `instrucciones2.txt`), reused for live on-chain broadcasts, and
  exposed in cleartext at least twice across sprints; never rotated.
- **`main` has no branch protection and no CODEOWNERS** — 7 CI workflows exist but are not
  enforced as merge gates; direct pushes to `main` are possible.
- A fully-documented **multisig + timelock governance is not deployed** — a single founder EOA
  owns all 8 UUPS proxies and can upgrade them instantly (demonstrated this sprint: 8 upgrades
  applied in minutes, zero timelock, zero user warning).
- The IR comms/escalation matrix assumes a **team that does not exist** (all-hands, Signal
  group, on-call escalation) — operations are effectively a **team of one**.

**Operational Maturity Score: 6.0 / 10 — ⚠️ NEEDS HARDENING.** Public testnet (Fase 5): **YES**.
Mainnet (Fase 7): **NO** until the Critical/High items are closed (est. **4–6 weeks** of ops hardening).

---

## Severity Distribution

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 4 |
| Medium | 7 |
| Low | 3 |
| Info | 1 |

---

## Findings

### OP-001 [CRITICAL] — Key-rotation plan documented but NOT executed; founder key handled in plaintext
**Category**: Key Management · **Likelihood**: High · **Impact**: Critical · **Status**: Open · **Mainnet**: REQUIRED
**Description**: `docs/KEY-ROTATION-PLAN.md` correctly self-identifies the state as "INSECURE — all
three roles use the SAME private key" and lays out a sound target (Safe multisig + dedicated
oracle/relayer keys + hardware/cold storage). In practice the plan is unexecuted: the founder
key is stored in **plaintext** in `C:\Users\AGUSTIN\Desktop\instrucciones2.txt`, was pasted in
cleartext for at least two sprints, and was used directly for live broadcasts (e.g. the 8 UUPS
upgrades this week). The deployer/owner, and historically the oracle/relayer, share key material.
**Scenario**: Any exfiltration of that file (malware, backup sync, screen-share, shoulder-surf)
hands an attacker owner control of all 8 proxies + relayer + oracle signer simultaneously —
instant, total, irreversible drain on mainnet.
**Recommendation**: Execute the existing plan before mainnet: generate fresh dedicated keys;
move owner to a Gnosis Safe on a hardware wallet; relayer = low-balance gas-only key in a secrets
manager (not a Desktop file); oracle signer separate. **Rotate the currently-exposed keys now**
(they are burned). Never place private keys in plaintext files.

### OP-002 [HIGH] — `main` not branch-protected; no CODEOWNERS; CI not enforced as a merge gate
**Category**: SDLC / Governance · **Likelihood**: High · **Impact**: High · **Status**: Open · **Mainnet**: REQUIRED
**Description**: `GET …/branches/main/protection` → 404 "Branch not protected". No `.github/CODEOWNERS`.
The repo has 7 CI workflows (ci, coverage, echidna, mythril, aderyn, halmos, gas-snapshot) but
nothing forces them to pass before merge, and nothing requires review. PRs were merged this month
with red CI (build/fmt). Direct `git push origin main` is possible.
**Scenario**: A buggy or malicious change reaches `main` (and any auto-deploy) without review or
green CI — exactly how supply-chain / insider issues land.
**Recommendation**: Enable branch protection on `main`: require PR + ≥1 review, require the CI +
fmt checks to pass, dismiss stale approvals, restrict force-push. Add CODEOWNERS for `src/`,
`script/deploy/`, `.github/`. (Pre-multisig this can be self-review, but the gate forces green CI.)

### OP-003 [HIGH] — Single EOA owns all 8 UUPS proxies; multisig+timelock documented but not deployed
**Category**: Governance / Key Management · **Likelihood**: Medium · **Impact**: Critical · **Status**: Open (BL-MULTISIG) · **Mainnet**: REQUIRED
**Description**: `docs/governance/MULTISIG-POLICIES.md`, `docs/GNOSIS-SAFE-SETUP.md`,
`docs/training/MULTISIG-SIGNER-TRAINING.md` describe quorum, thresholds, and signer duties — but
on-chain the owner of every proxy is the single founder EOA `0xe585…fDa8`. There is no timelock:
this sprint upgraded 8 proxies in minutes with no delay and no user-facing warning window.
**Scenario**: Single-key compromise = full control; or an honest fat-finger upgrade with no
review/timelock corrupts a live contract instantly.
**Recommendation**: Deploy the Gnosis Safe + `TimelockController` (the documented `BL-MULTISIG`),
transfer all proxy ownership + `DEFAULT_ADMIN_ROLE`, adopt `Ownable2Step`, and route upgrades
through the timelock with a public delay before mainnet.

### OP-004 [HIGH] — Incident-response assumes a team that does not exist (team-of-one SPOF)
**Category**: Incident Response · **Likelihood**: High · **Impact**: High · **Status**: Open · **Mainnet**: REQUIRED
**Description**: `INCIDENT-RESPONSE-RUNBOOK.md` defines solid P0/P1/P2 severities and a comms
matrix ("Phone calls + Signal group", "all-hands", "escalation within 15 min if no response").
But operations are effectively a single founder — no on-call rotation, no second responder, no
24/7 coverage. At 3am UTC a P0 (oracle manipulation / drain) has one human who may be asleep.
**Scenario**: A live exploit during the founder's off-hours runs unmitigated for hours; the
runbook's escalation steps have no one to escalate to.
**Recommendation**: Before mainnet, establish at least a 2-person on-call with a pager
(PagerDuty/Opsgenie) wired to the monitoring alerts; or contract a monitoring/IR service
(e.g. Hypernative/Forta + a response retainer). Update the comms matrix to real, named people.

### OP-005 [MEDIUM] — Disclosure scope (SECURITY.md) is obsolete; in-scope addresses blanked/bricked
**Category**: Bug Bounty / Disclosure · **Likelihood**: Medium · **Impact**: Medium · **Mainnet**: REQUIRED
**Description**: `SECURITY.md` has a good `security@lumina-org.com` channel + 24h ack / 72h
response SLA, but its in-scope table is explicitly marked OBSOLETO with all addresses blanked to
`0x0` (references the bricked V5.1). A researcher cannot determine what is actually in scope. The
canonical live V5.4 addresses (PR #160) are not reflected.
**Recommendation**: Refresh SECURITY.md with the canonical V5.4 addresses, define severity tiers +
payout ranges (even testnet "hall of fame" + mainnet $ bounty), add a PGP key for encrypted
reports, and state fix-SLA per severity + public-disclosure timeline.

### OP-006 [MEDIUM] — Runbooks / threat model stale vs the deployed V5.4
**Category**: Documentation · **Likelihood**: Medium · **Impact**: Medium · **Mainnet**: RECOMMENDED
**Description**: `INCIDENT-RESPONSE-RUNBOOK.md` is titled "V5.0"; `SECURITY.md` is V5.1; several
docs predate the V5.3 red-team/manual-review changes (multi-block trigger, fail-closed oracle,
per-user throttle, MR-H01 freshness gate, the canonical-address correction). No doc-freshness owner
or review cadence.
**Recommendation**: Version-stamp each runbook, assign an owner, and add a "review every release /
post-sprint" checklist item. Refresh IR scenarios to current behaviors (e.g. the MR-H01 freshness
gate's dormant-while-pool==0x0 state; relayer-only settlement since ShieldKeeper is unwired).

### OP-007 [MEDIUM] — Runbooks never tested (no drill/tabletop evidence)
**Category**: Incident Response / Resilience · **Likelihood**: Medium · **Impact**: High · **Mainnet**: REQUIRED
**Description**: The runbooks are well-written but there is no evidence any was rehearsed. The
KEY-ROTATION-PLAN is provably untested (the insecure state it warns against is still live). A
runbook that has never been executed under time pressure is a hypothesis, not a control.
**Recommendation**: Run at least one tabletop per P0 scenario (oracle manipulation, BondVault
drain, relayer-key compromise) and one *live* dry-run of key rotation + the pause path on testnet
before mainnet. Record outcomes + fix gaps.

### OP-008 [MEDIUM] — Monitoring documented but live alerting/paging unverified ("alerts but nobody sees")
**Category**: Monitoring · **Likelihood**: Medium · **Impact**: High · **Mainnet**: REQUIRED
**Description**: `docs/monitoring/ALERTS-CONFIGURATION.md` + `DASHBOARDS.md` enumerate the right
signals (large redemptions, oracle deviation, failed-tx spikes, capacity-threshold breach,
sequencer downtime). There is no evidence these are wired to a live alerting backend with a human
recipient. Documented-but-not-wired monitoring is the canonical "alerts but nobody sees" gap.
**Recommendation**: Stand up real on-chain monitoring (Forta/Hypernative/Tenderly alerts) +
API monitoring (Railway metrics + error-rate alerts) feeding the OP-004 pager. Verify end-to-end
with a synthetic alert.

### OP-009 [MEDIUM] — UUPS upgrades have no timelock and no user-warning window
**Category**: Deploy / Governance · **Likelihood**: Medium · **Impact**: High · **Mainnet**: REQUIRED
**Description**: Demonstrated this sprint — `upgradeToAndCall` applies immediately on owner
signature. No timelock, no announcement. On mainnet this removes the user's ability to exit before
a change and concentrates trust in one signer.
**Recommendation**: Route upgrades through the OP-003 `TimelockController` with a published delay;
pre-announce upgrades via the comms channel (OP-012). Tie into the DEPLOY-MAINNET-RUNBOOK.

### OP-010 [MEDIUM] — Sandbox wallet custody gap (BL-SANDBOX)
**Category**: Key Management · **Likelihood**: Medium · **Impact**: Medium · **Mainnet**: REQUIRED
**Description**: A prior sprint surfaced a sandbox wallet usable without a clearly-custodied key.
For mainnet the public sandbox must use a dedicated, low-balance, properly-custodied key with
caps (the API already enforces a global daily cap + $100 ceiling per F-20).
**Recommendation**: Document `BL-SANDBOX`: generate a dedicated sandbox key in a secrets manager,
fund minimally, monitor, and rotate on a schedule.

### OP-011 [MEDIUM] — Stale/abandoned deployment manifests in-repo (operational confusion risk)
**Category**: Deploy / Documentation · **Likelihood**: High · **Impact**: Medium · **Mainnet**: RECOMMENDED
**Description**: `deployments/sepolia/*.json` + `base-sepolia-v5.0-deprecated.json` carry STALE
V5.0 addresses for CapacityOracle/SolvencyOracle/MaintenanceReserve/ShieldKeeper. This directly
caused a real operational failure: the first UUPS-upgrade dry-run reverted because it used the
stale `0xAf99…` CapacityOracle. (Resolved by the PR #160 canonical manifest derived on-chain.)
**Recommendation**: Update the in-repo manifests to the canonical V5.4 values (PR #160), delete or
clearly quarantine deprecated manifests, and make the canonical manifest the single source of truth
referenced by all runbooks/scripts.

### OP-012 [LOW] — User-facing incident comms channel existence/staffing unverified
**Category**: Communications · **Likelihood**: Medium · **Impact**: Medium · **Mainnet**: RECOMMENDED
**Description**: Comms docs reference Twitter/Discord/Telegram and a 30-min P0 public-comms SLA, but
there is no confirmed live status page or staffed channel. The 30-min SLA is unmeetable by a
team-of-one mid-incident.
**Recommendation**: Stand up a status page (e.g. Instatus) + one staffed channel; pre-write the
incident templates (already in `INCIDENT-TEMPLATES.md`) into the publishing tool.

### OP-013 [LOW] — Vendor SPOFs with untested fallbacks (Railway / Vercel / Base / Chainlink / npm)
**Category**: Vendor Risk · **Likelihood**: Medium · **Impact**: Medium · **Mainnet**: RECOMMENDED
**Description**: `docs/audit/v5.1-uups/24-disaster-recovery/` covers scenarios, but fallbacks are
untested: API on Railway (down → no relayer purchases, but on-chain still usable directly),
landing on Vercel, single L2 (Base), Chainlink feeds, npm registry for the SDK. Prior npm publish
used a 2FA-bypass (token rotation status unknown — see OP-014).
**Recommendation**: Test the documented fallbacks once; confirm the protocol degrades gracefully
when the API/landing are down (on-chain path intact); document a provider-migration runbook.

### OP-014 [LOW] — npm publish token / 2FA hygiene; CI secret handling
**Category**: Key Management / Supply Chain · **Likelihood**: Low · **Impact**: Medium · **Mainnet**: RECOMMENDED
**Description**: A prior SDK publish used a 2FA bypass; the npm automation token's rotation status
is unknown. A compromised npm token lets an attacker publish a malicious `@lumina-org/sdk`.
**Recommendation**: Use a granular, expiring npm automation token in CI secrets only; require 2FA;
enable npm provenance; rotate the token; confirm no tokens in plaintext.

### OP-015 [INFO] — Legal/compliance classification risk documented but unresolved
**Category**: Legal · **Likelihood**: Low · **Impact**: High (long-tail) · **Mainnet**: RECOMMENDED
**Description**: `docs/legal/COMPLIANCE-CHECKLIST.md` exists; the open question (parametric
derivative vs "insurance", Argentina/LATAM jurisdiction, KYC/AML, ToS/privacy on the landing) is
acknowledged but unresolved. Visible off-chain ToS/disclaimer presence on the live landing was not
confirmable from the repo.
**Recommendation**: Obtain a legal opinion on product classification + jurisdiction before mainnet;
ensure a clear ToS/disclaimer + privacy policy are linked from the landing and (optionally) an
on-chain ToS-accept gate.

---

## Operational Readiness Matrix

| Category | Maturity | Mainnet Ready? | Note |
|---|---|---|---|
| Key Management | 3/10 | ❌ | great plan, insecure practice (OP-001/003/010/014) |
| Deploy Procedures | 7/10 | ⚠️ | runbooks + checklists + demonstrated dry-run/storage/smoke; needs timelock (OP-009) + canonical manifest (OP-011) |
| Incident Response | 6/10 | ❌ | excellent docs, but team-of-one + untested (OP-004/007) |
| Monitoring | 5/10 | ❌ | config documented, live wiring unverified (OP-008) |
| Bug Bounty / Disclosure | 5/10 | ⚠️ | channel+SLA good, scope obsolete (OP-005) |
| Governance | 5/10 | ❌ | framework documented, single EOA on-chain (OP-003) |
| Legal | 5/10 | ⚠️ | checklist exists, classification unresolved (OP-015) |
| Vendor Risk | 5/10 | ⚠️ | DR docs, fallbacks untested (OP-013) |
| Documentation | 8/10 | ✅ | broad + high-quality; staleness spots (OP-006) |
| Communications | 5/10 | ⚠️ | templates ready, channel/staffing unverified (OP-012) |
| **OVERALL** | **6.0/10** | **❌ (mainnet)** | strong docs, weak enforcement/execution |

---

## Critical Gaps Before Mainnet (prioritized)

1. **OP-001** Rotate exposed keys + execute KEY-ROTATION-PLAN (stop plaintext key handling). *[Critical]*
2. **OP-003 / OP-009** Deploy Gnosis Safe + TimelockController; transfer ownership; timelocked upgrades. *[High]*
3. **OP-002** Branch protection on `main` + CODEOWNERS + CI-as-merge-gate. *[High]*
4. **OP-004 / OP-007 / OP-008** Real on-call + pager + live monitoring; rehearse P0 runbooks. *[High]*
5. **OP-005** Refresh SECURITY.md disclosure scope + bounty tiers. *[Medium]*
6. **OP-011** Canonical manifest as single source of truth; quarantine deprecated. *[Medium]*

## Recommended Roadmap

| Sprint | What | Priority |
|---|---|---|
| 7.6a Key Hardening | Rotate keys, secrets manager, stop plaintext, BL-SANDBOX | Required |
| 7.6b Governance | Gnosis Safe + Timelock + Ownable2Step, ownership transfer | Required |
| 7.6c SDLC | Branch protection, CODEOWNERS, CI gates, npm token hygiene | Required |
| 7.6d Resilience | On-call + pager + live monitoring; P0 tabletops; key-rotation drill | Required |
| 7.6e Disclosure/Legal | SECURITY.md refresh + bounty; legal opinion; ToS/privacy on landing | Recommended |

---

## Comparison with industry best practice

Versus Nexus Mutual / Sherlock / InsurAce and L2 teams (Optimism/Base/Arbitrum): Lumina's
**documentation depth rivals mature teams** (most pre-mainnet projects lack this runbook/IR/
governance breadth). It lags on **operational execution**: those teams run multisig+timelock,
24/7 monitoring with paging, enforced branch protection/CODEOWNERS, live bug-bounty (Immunefi)
with $ tiers, and rehearsed IR. Closing the documented-vs-deployed gap is the entire task.

## Verdict

**Score: 6.0 / 10 — ⚠️ NEEDS HARDENING.**
- **Fase 5 (testnet público): SÍ** — testnet stakes are low and the docs/CI are adequate; proceed
  while hardening ops in parallel.
- **Fase 7 (mainnet): NO** — gated by OP-001 (keys), OP-003/009 (multisig+timelock), OP-002 (SDLC
  gates), OP-004/007/008 (on-call + live monitoring + rehearsed IR).
- **Recommended mainnet timeline: 4–6 weeks** of operational hardening (roadmap above), assuming
  the code is already audited (it is: 7.2/7.3/7.4/7.5 + on-chain MR fixes).

**Reverse-audit self-assessment: 8/10** — findings grounded in the actual repo inventory + live
on-chain reads + observed practice across this engagement (plaintext keys, single-EOA upgrades,
red-CI merges). Honest limits: I could not verify live monitoring/paging, the landing's ToS, or
npm token state from the repo alone — flagged as such rather than asserted.

**Sprint 7.6 — Operational Security Audit: CLOSED ✅.** Next: Fase 5 testnet público (with ops
hardening in parallel).
