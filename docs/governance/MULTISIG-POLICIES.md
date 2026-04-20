# LUMINA Protocol V5.0 — Multisig Policies

## Multisig Composition

| Parameter | Value |
|-----------|-------|
| Type | Gnosis Safe (Safe{Wallet}) |
| Threshold | 2-of-3 |
| Network | Ethereum Mainnet |
| Total Signers | 3 |

### Signer Roles

| Signer | Role | Requirement |
|--------|------|-------------|
| Signer 1 | Founder / Protocol Lead | Hardware wallet, dedicated device |
| Signer 2 | Technical Advisor | Hardware wallet, independent custody |
| Signer 3 | External Trusted Party | Hardware wallet, different jurisdiction |

### Signer Requirements

- All signers MUST use hardware wallets (Ledger or Trezor)
- No two signers may share custody infrastructure
- Signers must be reachable within 1 hour during business hours
- Signers must be reachable within 4 hours during off-hours
- At least 2 signers must be in different timezones or geographic locations

---

## Spending Limits by Category

### CEX Allocations

| Parameter | Limit |
|-----------|-------|
| Per-transaction maximum | $50,000 |
| Daily maximum | $50,000 |
| Weekly maximum | $200,000 |
| Monthly maximum | $500,000 |
| Approved destinations | Pre-registered CEX deposit addresses only |

**Additional Controls**:
- New CEX addresses must be registered 48 hours before first use
- Large allocations (>$25,000) require written justification logged on-chain

### Maintenance Spending

| Parameter | Limit |
|-----------|-------|
| Per-transaction maximum | $10,000 |
| Monthly maximum | $30,000 |
| Quarterly maximum | $75,000 |
| Approved categories | Infrastructure, audits, tooling, legal, service providers |

**Additional Controls**:
- Expenses >$5,000 require invoice or contract reference in reason string
- Recurring expenses must be pre-approved quarterly
- Audit expenses exempt from monthly cap (tracked separately)

### Buyback Configuration

| Parameter | Limit |
|-----------|-------|
| Minimum daily buyback | $500 |
| Maximum daily buyback | $5,000 |
| Adjustment frequency | No more than once per week |
| Maximum single adjustment | 50% increase or decrease from current |

**Additional Controls**:
- Buyback changes must be justified by treasury health analysis
- Cannot reduce below $500/day without community communication
- Cannot exceed $5,000/day without governance-level approval

---

## Emergency Actions

### Actions Requiring 2-of-3 Approval

| Action | Maximum Response Time |
|--------|----------------------|
| Pause CoverRouter | Target: 30 minutes |
| Pause SolvencyOracle | Target: 30 minutes |
| Emergency fund transfer | Target: 1 hour |
| Signer replacement | Target: 4 hours |
| Contract upgrade | Target: 24 hours (non-emergency) |

### Emergency Pause Authority

- During the first 30 days post-launch, the Founder (Signer 1) has unilateral authority to pause contracts via a separate EmergencyPause role
- This role is time-limited and automatically revokes after 30 days
- All unilateral pauses must be ratified by 2-of-3 within 12 hours or auto-unpause

### Actions Explicitly Prohibited Without Full Process

- Minting new LUMINA tokens (not possible by design)
- Changing multisig threshold below 2-of-3
- Removing a signer without adding replacement
- Transferring proxy admin to EOA
- Any action that would make funds irrecoverable

---

## Transparency Commitments

### Public Reporting

| Report | Frequency | Content |
|--------|-----------|---------|
| Treasury Summary | Weekly | Balances, inflows, outflows, buyback totals |
| Financial Report | Monthly | Full reconciliation, runway analysis |
| Multisig Activity | Monthly | All transactions with justifications |
| Security Status | Quarterly | Audit results, access control review |

### On-Chain Transparency

- All multisig transactions are publicly visible on Etherscan
- Transaction `reason` strings provide context for every spend
- No private or hidden multisig transactions — Safe address is public
- Treasury contract balances are queryable by anyone at any time

### Conflict of Interest

- Signers must disclose any personal financial interest in protocol decisions
- Signer compensation (if any) must be publicly disclosed
- No signer may approve a transaction that pays themselves without the other 2 signers approving

---

## Policy Changes

- Changes to spending limits require 2-of-3 approval and 7-day notice
- Changes to signer composition require 2-of-3 approval (immediate for compromise)
- Changes to threshold require all 3 signers
- All policy changes documented publicly with effective date

---

## Annual Review

This policy document must be reviewed and reaffirmed (or updated) at minimum once per year. Review should cover:

- Are spending limits appropriate for current protocol scale?
- Is signer composition still optimal?
- Have any policy violations occurred that suggest changes needed?
- Does the community have feedback on governance transparency?
