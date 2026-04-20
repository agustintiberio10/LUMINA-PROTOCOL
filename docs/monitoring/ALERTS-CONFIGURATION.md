# LUMINA Protocol V5.0 — Alerts Configuration

## Alert Severity Levels

| Level | Response | Notification Method | Examples |
|-------|----------|-------------------|----------|
| **Critical** | Page immediately, respond within 15 min | PagerDuty + Phone + Signal | Fund risk, exploit, oracle failure |
| **Warning** | Acknowledge within 1 hour | Signal + Email | Degraded performance, threshold approaching |
| **Info** | Review in daily check | Email + Dashboard | Routine events, minor anomalies |

---

## Critical Alerts (Page Immediately)

### CRIT-001: CoverRouter Paused Unexpectedly

- **Condition**: `CoverRouter.paused() == true` AND not triggered by multisig within last 5 minutes
- **Threshold**: Immediate on state change
- **Action**: Verify if auto-pause or unauthorized. If unauthorized, treat as P0 incident.

### CRIT-002: LUMINA Price Below Critical Threshold

- **Condition**: LUMINA/USD price < $0.005
- **Threshold**: Sustained for 2 consecutive price updates
- **Action**: Verify auto-pause activated. Begin P1 incident response.

### CRIT-003: SolvencyOracle Emergency Pause

- **Condition**: `SolvencyOracle.emergencyPaused() == true`
- **Threshold**: Immediate on state change
- **Action**: Confirm intentional. If not, investigate immediately.

### CRIT-004: BondVault Balance Critical

- **Condition**: BondVault balance < 10% of total outstanding obligations
- **Threshold**: Checked every block
- **Action**: Initiate BondVault low balance incident response.

### CRIT-005: Unauthorized Admin Function Call

- **Condition**: Any admin/owner function called by address not in approved list
- **Threshold**: Immediate
- **Action**: P0 incident — possible exploit or compromise.

### CRIT-006: Large Unexpected Token Transfer

- **Condition**: Transfer from protocol contracts > $100,000 to non-whitelisted address
- **Threshold**: Immediate
- **Action**: Verify against pending multisig transactions. If unmatched, P0 incident.

### CRIT-007: Chainlink Feed Stale (Extended)

- **Condition**: `latestRoundData` timestamp > 6 hours old
- **Threshold**: After 6 hours of staleness
- **Action**: Emergency pause SolvencyOracle, investigate feed status.

### CRIT-008: Mass Trigger Event

- **Condition**: More than 10 bonds triggered within 1 hour
- **Threshold**: Rolling 1-hour window
- **Action**: Verify legitimacy, assess vault capacity, begin mass trigger response.

---

## Warning Alerts (Acknowledge Within 1 Hour)

### WARN-001: Chainlink Feed Stale (Initial)

- **Condition**: `latestRoundData` timestamp > 2 hours old
- **Threshold**: After 2 hours of staleness
- **Action**: Monitor. If not resolved within 4 hours, escalate to critical.

### WARN-002: BondVault Balance Low

- **Condition**: BondVault balance < 30% of total outstanding obligations
- **Threshold**: Checked every 15 minutes
- **Action**: Review treasury allocation, prepare to supplement if needed.

### WARN-003: Chainlink Automation Missed Execution

- **Condition**: Expected automation execution did not occur within window
- **Threshold**: 30 minutes past expected execution time
- **Action**: Check LINK balance, verify automation registration, manual execution if needed.

### WARN-004: Daily Buyback Failed

- **Condition**: TWAPBurner daily execution reverted or did not execute
- **Threshold**: 2 hours past scheduled execution time
- **Action**: Check USDC balance, router availability, slippage conditions.

### WARN-005: Multisig Transaction Pending >48 Hours

- **Condition**: Safe transaction queued but not executed for >48 hours
- **Threshold**: 48 hours since first signature
- **Action**: Contact missing signer, assess urgency.

### WARN-006: Coverage Ratio Declining

- **Condition**: Coverage ratio dropped >10% in 24 hours
- **Threshold**: Checked hourly
- **Action**: Investigate cause (price movement, claims, vault outflow).

### WARN-007: Gas Price Spike

- **Condition**: Base fee > 100 gwei sustained for 1 hour
- **Threshold**: Hourly average
- **Action**: Delay non-urgent operations, monitor automation cost impact.

### WARN-008: Unusual Bonding Pattern

- **Condition**: Bond creation rate >3x 7-day average
- **Threshold**: Rolling 4-hour window
- **Action**: Verify organic growth vs. potential manipulation.

---

## Info Alerts (Daily Review)

### INFO-001: New Bond Created

- **Condition**: `BondCreated` event emitted
- **Threshold**: Each occurrence (batched in daily digest)
- **Action**: Review in daily check for anomalies.

### INFO-002: Bond Triggered

- **Condition**: `BondTriggered` event emitted
- **Threshold**: Each occurrence
- **Action**: Verify payout processed correctly.

### INFO-003: Buyback Executed

- **Condition**: `BuybackExecuted` event emitted
- **Threshold**: Daily
- **Action**: Log amount, verify tokens burned.

### INFO-004: Solvency Parameter Updated

- **Condition**: SolvencyOracle parameters changed
- **Threshold**: Each occurrence
- **Action**: Verify change was authorized and expected.

### INFO-005: Treasury Allocation

- **Condition**: `Allocated` or `Spent` event from TreasuryManager
- **Threshold**: Each occurrence
- **Action**: Log for monthly reconciliation.

### INFO-006: Chainlink Automation Executed

- **Condition**: Successful performUpkeep execution
- **Threshold**: Each occurrence (batched)
- **Action**: Confirm expected behavior in daily review.

---

## Recommended Tools

### Primary Monitoring Stack

| Tool | Purpose | Priority |
|------|---------|----------|
| **Forta** | Real-time threat detection, custom bot for LUMINA-specific patterns | Critical |
| **Tenderly** | Transaction simulation, alerting on state changes, debugging | Critical |
| **OpenZeppelin Defender** | Automated actions, relay for keeper operations, admin management | High |
| **Dune Analytics** | Historical analytics, public dashboards, financial tracking | High |
| **PagerDuty** | Alert routing, escalation policies, on-call scheduling | Critical |

### Integration Architecture

```
Forta Bots ──────┐
Tenderly Alerts ──┼──> PagerDuty ──> Phone/Signal (Critical)
Defender Sentinels┘                ──> Email (Warning)
                                   ──> Digest (Info)

Dune Dashboards ──> Daily review (manual)
```

### Forta Bot Configuration

Deploy custom Forta bots for:
- Monitor all LUMINA contract function calls
- Detect flash loan interactions with protocol contracts
- Track large token movements (>$50,000)
- Monitor governance/admin function calls
- Detect reentrancy patterns

### Tenderly Alert Configuration

- Web3 Actions for automated responses
- Alert on specific event emissions
- State change monitoring for critical variables
- Gas usage anomaly detection
- Failed transaction monitoring

### OpenZeppelin Defender Configuration

- Sentinels monitoring all protocol contracts
- Autotask for keeper operations backup
- Admin management for multisig operations
- Relay for gasless meta-transactions (if applicable)

---

## Alert Tuning

### False Positive Management

- Review alert accuracy weekly
- Tune thresholds based on first 30 days of data
- Document any suppressed alerts with rationale
- Re-evaluate suppressed alerts monthly

### Escalation Overrides

- Any team member can manually escalate Info → Warning or Warning → Critical
- During known events (planned maintenance, market volatility), alerts may be temporarily adjusted
- All threshold changes must be documented with reason and revert date
