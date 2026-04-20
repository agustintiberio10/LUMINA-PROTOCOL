# LUMINA Protocol V5.0 — Decision Framework

## Overview

This framework defines four levels of decision-making authority, progressing from centralized (early-stage speed) toward decentralized (mature governance). Each level specifies who decides, what scope they cover, and how decisions are documented.

---

## Level 1: Technical Decisions

**Authority**: Founder (sole discretion)

**Scope**:
- Code implementation details
- Gas optimization choices
- Testing strategies and tooling
- Development workflow and CI/CD
- Bug fixes and minor contract improvements
- Documentation updates
- Repository management (branches, PRs, releases)
- Testnet deployments
- Development environment configuration

**Process**:
1. Founder identifies need or opportunity
2. Implements solution
3. Documents in commit messages and changelogs
4. No approval required

**Constraints**:
- Must not change user-facing behavior without Level 2+ approval
- Must not modify economic parameters
- Must not alter access control or permissions
- Security-critical changes require at minimum a self-review checklist

**Documentation**: Git commit history, PR descriptions, technical notes

---

## Level 2: Operational Decisions

**Authority**: Founder + Technical Advisor (consensus)

**Scope**:
- Adjusting buyback daily amounts (within approved range)
- Solvency parameter tuning
- Chainlink Automation configuration changes
- DEX router additions or removals for TWAPBurner
- Infrastructure provider changes (RPC, monitoring tools)
- Incident response actions during P1/P2 events
- Scheduling and prioritizing maintenance work
- Community communication timing and content
- Partnership evaluations (technical due diligence)

**Process**:
1. Either party proposes change with rationale
2. Discussion via secure channel (Signal or call)
3. Both parties agree (or escalate to Level 3 if disagreement)
4. Execute change
5. Document decision and rationale

**Constraints**:
- Must stay within governance-approved parameter ranges
- Cannot exceed spending limits without Level 3 approval
- Cannot make irreversible changes without Level 3 approval

**Documentation**: Operational decision log (private), public changelog for user-facing changes

---

## Level 3: Strategic Decisions

**Authority**: Full Multisig (2-of-3 minimum)

**Scope**:
- Contract upgrades and deployments to mainnet
- Spending limit changes
- New feature activation (e.g., adaptive mode)
- Multisig signer changes
- Major parameter changes outside normal ranges
- Emergency actions (pauses, fund recovery)
- Partnership agreements with financial commitments
- Audit engagements and scope
- Protocol economic model changes
- Token distribution decisions
- Public roadmap commitments

**Process**:
1. Proposal drafted with:
   - Problem statement
   - Proposed solution
   - Alternatives considered
   - Risk assessment
   - Implementation timeline
2. Circulated to all signers (minimum 48-hour review for non-emergency)
3. Discussion and refinement
4. 2-of-3 approval via multisig transaction or documented consensus
5. Execute
6. Public communication if user-facing

**Constraints**:
- 48-hour minimum review period (waived for emergencies)
- Must include risk assessment for any change affecting user funds
- Irreversible decisions require all 3 signers to acknowledge (even if only 2 sign)

**Documentation**: Multisig transaction history, governance log, public announcements

---

## Level 4: Community Decisions (Future)

**Authority**: Governance token holders (future implementation)

**Scope** (planned):
- Protocol fee structure changes
- Major economic model modifications
- Treasury allocation strategy (broad direction)
- Protocol sunset or migration decisions
- Multisig composition changes (adding community-elected signers)
- Grant program parameters
- Cross-chain expansion decisions

**Implementation Criteria** (must be met before activating Level 4):
- Protocol operational for 6+ months without critical incidents
- Sufficient token distribution (no single entity >30% of governance power)
- Governance infrastructure audited and tested
- Community demonstrates engagement and understanding of protocol
- Legal framework supports decentralized governance

**Planned Process**:
1. Proposal submitted on-chain (minimum token threshold to propose)
2. Discussion period (7 days)
3. Voting period (5 days)
4. Timelock (48 hours) before execution
5. Multisig executes community-approved changes

**Transition Plan**:
- Phase A: Advisory votes (non-binding, multisig commits to follow majority)
- Phase B: Binding votes on limited scope (fee changes, allocation percentages)
- Phase C: Full governance authority with multisig as executor only

---

## Decision Escalation

| Situation | Escalation Path |
|-----------|----------------|
| Technical disagreement | Level 1 → Level 2 |
| Operational disagreement | Level 2 → Level 3 |
| Exceeds approved parameters | Any Level → Level 3 |
| Irreversible action | Any Level → Level 3 |
| Affects user funds | Any Level → Level 3 |
| Community backlash | Level 3 → Level 4 (when available) |

---

## Decision Record Template

For Level 2+ decisions, maintain a record:

```
Decision ID: LUMINA-YYYY-NNN
Date: YYYY-MM-DD
Level: [2/3/4]
Title: [Brief description]
Proposer: [Name/Role]
Approvers: [Names/Roles]
Status: [Proposed/Approved/Executed/Rejected]

Context:
[Why is this decision needed?]

Decision:
[What was decided?]

Alternatives Considered:
[What else was evaluated?]

Risks:
[What could go wrong?]

Follow-up:
[Any monitoring or review needed?]
```

---

## Principles

1. **Speed at early stage**: Don't let process slow down critical development
2. **Safety over speed**: When user funds are involved, take time to be right
3. **Progressive decentralization**: Earn the right to decentralize through stability
4. **Transparency by default**: Document and share unless security requires privacy
5. **Reversibility preference**: Prefer decisions that can be undone over those that cannot
