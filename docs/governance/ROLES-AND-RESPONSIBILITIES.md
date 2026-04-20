# LUMINA Protocol V5.0 — Roles and Responsibilities

## Current Roles

### Founder / Protocol Lead

**Status**: Active

**Identity**: Primary creator and operator of LUMINA Protocol

**Responsibilities**:

- **Technical Leadership**
  - All smart contract development and architecture decisions
  - Security review and audit coordination
  - Deployment execution and verification
  - Infrastructure management (RPC, monitoring, automation)

- **Operational Management**
  - Daily operations (morning checklist, monitoring review)
  - Incident commander for all P0/P1 events
  - Treasury management within approved limits
  - Multisig Signer 1

- **Strategic Direction**
  - Protocol roadmap definition
  - Feature prioritization
  - Partnership evaluation and outreach
  - Economic model design and tuning

- **Community**
  - Primary public representative
  - Transparency report publication
  - Community question response
  - Crisis communication

**Authority Level**: Level 1 (sole), Level 2 (with advisor), Level 3 (as multisig signer)

**Time Commitment**: Full-time

**Accountability**: Public transparency reports, on-chain transaction history, community feedback

---

### Technical Advisor

**Status**: Active

**Identity**: Experienced smart contract developer or security researcher

**Responsibilities**:

- **Technical Review**
  - Code review for all mainnet-bound changes
  - Architecture review and recommendations
  - Security assessment of new features
  - Gas optimization suggestions

- **Operational Support**
  - Multisig Signer 2
  - Second opinion on parameter changes
  - Incident response support (P0/P1)
  - Deployment verification (independent check)

- **Knowledge**
  - Stay current on Solidity/EVM security developments
  - Monitor ecosystem for relevant threats or opportunities
  - Advise on best practices for DeFi protocols
  - Review audit reports and findings

**Authority Level**: Level 2 (with founder), Level 3 (as multisig signer)

**Time Commitment**: Part-time (5-10 hours/week), on-call for emergencies

**Accountability**: Response time SLAs, quality of technical feedback

---

### Multisig Signer 3 (External Trusted Party)

**Status**: Active

**Identity**: Independent third party with aligned interests

**Responsibilities**:

- Sign multisig transactions after independent verification
- Provide tie-breaking vote if Signer 1 and 2 disagree
- Available for emergency actions within SLA (4 hours max)
- Maintain hardware wallet security
- Report any potential conflicts of interest

**Authority Level**: Level 3 (as multisig signer only)

**Time Commitment**: Minimal (1-2 hours/week), on-call for emergencies

**Accountability**: Response time tracking, signing accuracy

---

## Future Roles (Planned)

### Development Team

**Status**: Planned (when protocol revenue supports hiring)

**Composition**: 1-3 developers initially

**Responsibilities**:

- Feature development under founder's technical direction
- Test writing and maintenance
- Frontend development and maintenance
- Subgraph and indexing infrastructure
- Bug fixes and minor improvements
- Documentation maintenance

**Authority Level**: Level 1 (delegated by founder for specific domains)

**Hiring Criteria**:
- Solidity experience (2+ years for smart contract work)
- Strong testing discipline
- Security-conscious mindset
- Ability to work asynchronously
- Alignment with protocol mission

**Accountability**: Code quality metrics, delivery timelines, test coverage

---

### Community Moderators

**Status**: Planned (when community reaches sufficient size)

**Composition**: 2-5 community members

**Responsibilities**:

- Monitor community channels (Discord, Telegram, forums)
- Answer routine questions using approved FAQs
- Escalate technical issues or bug reports to development team
- Enforce community guidelines
- Provide feedback on community sentiment to founder
- Help with documentation translations (if applicable)

**Authority Level**: None (advisory and communication only)

**Qualifications**:
- Active community member for 3+ months
- Demonstrated understanding of LUMINA Protocol
- Professional communication skills
- Available for minimum 5 hours/week
- No conflicts of interest with competing protocols

**Compensation**: To be determined (token allocation, USDC stipend, or hybrid)

**Accountability**: Community health metrics, response times, escalation quality

---

### External Auditors

**Status**: Engaged as needed

**Composition**: Professional smart contract audit firms

**Responsibilities**:

- Comprehensive security audit of smart contracts before mainnet
- Follow-up audits for major upgrades
- Specific scope reviews (e.g., new module, oracle integration)
- Provide written report with findings and recommendations
- Available for clarification questions post-audit

**Authority Level**: None (advisory only — findings are recommendations)

**Engagement Criteria**:
- Before any mainnet deployment of new contracts
- Before any major upgrade affecting user funds
- After any significant architecture change
- Minimum annually for existing deployed code

**Preferred Firms** (in priority order):
1. Trail of Bits
2. OpenZeppelin
3. Spearbit
4. Cyfrin
5. Code4rena (competitive audit)

**Accountability**: Report quality, finding severity accuracy, timeline adherence

---

## Role Transitions

### Adding New Roles

1. Founder identifies need based on workload or expertise gap
2. Draft role description and requirements
3. Level 2 approval (founder + advisor consensus)
4. If budget impact >$5,000/month: Level 3 approval (multisig)
5. Recruitment and onboarding

### Removing or Changing Roles

1. Performance issue or role no longer needed identified
2. Discussion at appropriate decision level
3. If multisig signer: replacement must be arranged before removal
4. Transition period for knowledge transfer
5. Access revocation checklist completed

### Succession Planning

**If Founder becomes unavailable**:
- Technical Advisor assumes operational leadership
- Multisig continues to function (2-of-3 with Signer 2 and 3)
- Community notified within 48 hours
- Long-term plan developed within 30 days

**If Technical Advisor becomes unavailable**:
- Founder continues operations solo (Level 1 and some Level 2)
- New advisor recruited within 30 days
- Multisig signer replacement executed

---

## Access Control Matrix

| System/Resource | Founder | Tech Advisor | Signer 3 | Dev Team | Moderators |
|----------------|---------|--------------|-----------|----------|------------|
| Smart contract deploy | Yes | View | No | No | No |
| Multisig signing | Yes | Yes | Yes | No | No |
| Repository (write) | Yes | Yes | PR only | No | No |
| Monitoring dashboards | Yes | Yes | No | Yes | No |
| Community channels (admin) | Yes | No | No | No | Yes |
| Treasury view | Yes | Yes | Yes | No | No |
| RPC/Infra credentials | Yes | Emergency only | No | Limited | No |

---

## Communication Expectations

| Role | Response Time (Normal) | Response Time (Emergency) | Primary Channel |
|------|----------------------|--------------------------|-----------------|
| Founder | 4 hours | 15 minutes | Signal |
| Technical Advisor | 24 hours | 1 hour | Signal |
| Signer 3 | 48 hours | 4 hours | Phone |
| Dev Team (future) | 8 hours | 2 hours | Slack/Discord |
| Moderators (future) | 2 hours | N/A | Discord |
