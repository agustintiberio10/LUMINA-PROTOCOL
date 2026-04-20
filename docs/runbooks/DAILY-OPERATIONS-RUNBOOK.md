# LUMINA Protocol V5.0 — Daily Operations Runbook

## Morning Checklist (10 minutes)

Perform every day, ideally at the same time each morning.

### System Health (3 min)

- [ ] SolvencyOracle last update < 2 hours ago
- [ ] Chainlink feeds reporting (check `latestRoundData` timestamp)
- [ ] CoverRouter status: not paused (unless intentional)
- [ ] No pending multisig transactions older than 24 hours

### Financial Status (3 min)

- [ ] BondVault balance above minimum threshold
- [ ] Treasury balance within expected range
- [ ] Previous day's buyback executed successfully
- [ ] No unexpected large withdrawals or transfers

### Monitoring Review (2 min)

- [ ] Review overnight alerts — any P0/P1 triggered?
- [ ] Check Chainlink Automation execution log — any missed runs?
- [ ] Gas prices within normal range for scheduled operations

### Community Pulse (2 min)

- [ ] Scan community channels for reported issues
- [ ] Check for new support tickets or questions
- [ ] Note any trending concerns for follow-up

---

## Weekly Tasks (Every Monday)

### Financial Review (30 min)

- [ ] Calculate weekly treasury inflow vs. outflow
- [ ] Review buyback efficiency (average price vs. TWAP)
- [ ] Assess coverage ratio trend (improving, stable, declining)
- [ ] Compare actual spend vs. budget for maintenance category
- [ ] Verify CEX allocations match intended strategy

### Technical Review (20 min)

- [ ] Review Chainlink Automation LINK balance — top up if < 5 LINK
- [ ] Check contract gas consumption trends
- [ ] Review any failed transactions in the past week
- [ ] Verify all monitoring alerts are still configured and active
- [ ] Check for any Ethereum network upgrades or changes upcoming

### Operational Review (15 min)

- [ ] Update internal status document
- [ ] Review any deferred P2 incidents — resolve or schedule
- [ ] Confirm all multisig signers responsive (quick Signal ping)
- [ ] Back up any operational logs or data

### Community Update (15 min)

- [ ] Prepare weekly transparency summary:
  - Bonds created / triggered / expired
  - Buyback amount and tokens burned
  - Treasury balance (rounded)
  - Any system events or pauses
- [ ] Post update to designated community channel

---

## Monthly Tasks (First Monday of Month)

### Financial Audit (1 hour)

- [ ] Complete monthly treasury reconciliation
- [ ] Verify all on-chain balances match expected values
- [ ] Review all multisig transactions for the month
- [ ] Calculate monthly P&L for protocol operations
- [ ] Assess runway at current burn rate
- [ ] Publish monthly financial transparency report

### Security Review (45 min)

- [ ] Review access controls — all roles correctly assigned
- [ ] Check for any new known vulnerabilities in dependencies
- [ ] Verify multisig configuration unchanged (signers, threshold)
- [ ] Review Etherscan for any unusual contract interactions
- [ ] Confirm no proxy implementation changes outside of planned upgrades

### Parameter Assessment (30 min)

- [ ] Evaluate current solvency parameters vs. market conditions
- [ ] Assess if daily buyback amount needs adjustment
- [ ] Review bond pricing/terms for competitiveness
- [ ] Check if any parameter changes should be proposed

### Infrastructure (30 min)

- [ ] Verify RPC provider uptime and latency for the month
- [ ] Review monitoring tool subscriptions and costs
- [ ] Check Chainlink Automation performance stats
- [ ] Ensure all documentation is up to date
- [ ] Rotate any expiring API keys or credentials

---

## Quarterly Tasks (First Week of Quarter)

### Strategic Review (2 hours)

- [ ] Comprehensive protocol health assessment
- [ ] Quarter-over-quarter metrics comparison:
  - Total bonds created
  - Total value locked
  - Total tokens burned
  - Treasury growth/decline
  - User growth
- [ ] Assess progress toward roadmap milestones
- [ ] Identify risks for upcoming quarter
- [ ] Set operational priorities for next quarter

### Security Audit (Variable)

- [ ] Evaluate need for external audit
- [ ] Review any findings from previous audits — all resolved?
- [ ] Assess if new features require additional review
- [ ] Update threat model if protocol has changed significantly

### Governance Assessment (1 hour)

- [ ] Review multisig signer performance (response times, availability)
- [ ] Assess if signer composition needs changes
- [ ] Evaluate if spending limits need adjustment
- [ ] Review decision-making process — any bottlenecks?
- [ ] Document any governance process improvements

### Disaster Recovery Test (2 hours)

- [ ] Verify all signers can access their hardware wallets
- [ ] Test emergency pause procedure (on testnet or fork)
- [ ] Confirm backup contacts are still valid
- [ ] Review incident response runbook for accuracy
- [ ] Simulate one incident scenario (tabletop exercise)

---

## Operational Log Template

Maintain a daily log for accountability and post-incident reference:

```
Date: YYYY-MM-DD
Operator: [Name]
Morning check: [PASS/ISSUES]
  - Issues noted: [none or description]
Actions taken: [none or list]
Alerts received: [none or list with resolution]
Notes: [any observations]
```

---

## Escalation Reminders

- Any FAIL on morning checklist → investigate immediately
- BondVault below 50% capacity → escalate to weekly review agenda
- 2+ consecutive missed Chainlink Automation runs → investigate within 2 hours
- Any unauthorized transaction detected → P0 incident, immediate response
- Signer unresponsive >48 hours → initiate replacement discussion
