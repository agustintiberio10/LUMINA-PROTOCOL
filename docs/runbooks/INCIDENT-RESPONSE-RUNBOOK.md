# LUMINA Protocol V5.0 — Incident Response Runbook

## Severity Levels

| Level | Description | Response Time | Examples |
|-------|-------------|---------------|----------|
| **P0** | Critical — Funds at immediate risk or protocol non-functional | 15 minutes | Exploit in progress, oracle manipulation, total system failure |
| **P1** | High — Degraded functionality or potential fund risk | 1 hour | Chainlink feed stale >2h, auto-pause triggered, signer compromise suspected |
| **P2** | Medium — Non-critical issue requiring attention | 4 hours | Automation missed execution, minor UI discrepancy, elevated gas costs |

---

## Communication Protocol

| Severity | Primary Channel | Escalation | Public Communication |
|----------|----------------|------------|---------------------|
| P0 | Phone calls + Signal group | Immediate all-hands | Within 30 min of confirmation |
| P1 | Signal group | Within 15 min if no response | Within 2 hours |
| P2 | Telegram ops channel | Next business day | In weekly update |

---

## Scenario 1: Chainlink Feed Stuck

**Severity**: P1 (escalate to P0 if >6 hours)

**Symptoms**:
- SolvencyOracle `lastUpdated` timestamp is stale (>2 hours old)
- Monitoring alert: "Chainlink heartbeat missed"
- `latestRoundData()` returning same `answeredInRound` for multiple calls

**Step-by-Step Response**:

1. **Verify** (5 min):
   - Check Chainlink feed directly on Etherscan
   - Confirm it's not a monitoring false positive
   - Check Chainlink status page (status.chain.link)
   - Verify other Chainlink feeds on same network are updating

2. **Assess Impact** (10 min):
   - Is SolvencyOracle using stale data for decisions?
   - Are any trigger evaluations pending that would use bad data?
   - Check `staleFeedThreshold` — has it been exceeded?

3. **Mitigate** (if stale >4 hours):
   - Call `SolvencyOracle.setEmergencyPause(true)` via multisig
   - This prevents any solvency decisions based on stale data
   - Communicate to users: "Solvency checks temporarily paused due to oracle delay"

4. **Monitor Recovery**:
   - Watch Chainlink feed for resumption
   - Once 3 consecutive valid updates received, consider unpausing
   - Verify SolvencyOracle resumes correctly after unpause

5. **Post-Incident**:
   - Document duration and impact
   - Evaluate if `staleFeedThreshold` needs adjustment
   - Consider secondary oracle integration

---

## Scenario 2: LUMINA Price < $0.005 Auto-Pause

**Severity**: P1

**Symptoms**:
- CoverRouter automatically paused
- Alert: "LUMINA price below critical threshold"
- New bonds rejected with "Protocol paused" error
- Community reports inability to bond

**Step-by-Step Response**:

1. **Verify** (5 min):
   - Confirm LUMINA price on DEX matches reported price
   - Rule out oracle manipulation (check multiple sources)
   - Verify auto-pause was triggered by legitimate price action

2. **Assess Cause** (30 min):
   - Large sell event? Check on-chain transactions
   - Liquidity removal? Check pool reserves
   - Market-wide crash? Check ETH and BTC prices
   - Manipulation? Check for flash loan activity

3. **Immediate Actions**:
   - Do NOT unpause immediately — the auto-pause is protective
   - Assess treasury solvency at current price level
   - Calculate coverage ratio at current market values
   - Communicate transparently: acknowledge pause, explain it's protective

4. **Recovery Decision Tree**:
   - If manipulation → report to community, wait for price recovery, unpause
   - If organic decline → assess if protocol is still solvent at new price
   - If solvent → unpause when price recovers above $0.007 (with buffer)
   - If insolvency risk → keep paused, assess options, communicate plan

5. **Unpause Criteria**:
   - [ ] Price above $0.007 for at least 1 hour
   - [ ] No ongoing manipulation detected
   - [ ] Treasury coverage ratio above minimum threshold
   - [ ] 2-of-3 multisig approval

---

## Scenario 3: Mass Trigger Event

**Severity**: P0

**Symptoms**:
- Multiple bonds triggering simultaneously
- BondVault balance decreasing rapidly
- Alert: "Trigger rate exceeds normal threshold"
- SolvencyOracle reports coverage ratio dropping

**Step-by-Step Response**:

1. **Verify Legitimacy** (5 min):
   - Are triggers from legitimate bond holders?
   - Is the solvency condition genuinely met?
   - Rule out contract exploit (check trigger logic)

2. **Assess Capacity** (10 min):
   - Current BondVault balance vs. total pending claims
   - Can all claims be honored?
   - What is the projected vault balance after all current triggers process?

3. **If Vault Can Honor All Claims**:
   - Let the system function as designed
   - Monitor vault balance continuously
   - Pause new bonds if vault drops below safety threshold
   - Communicate: "System functioning as designed — claims being processed"

4. **If Vault Cannot Honor All Claims**:
   - Pause CoverRouter immediately: `setPaused(true)`
   - Assess gap between obligations and available funds
   - Determine if treasury can supplement vault
   - If yes: transfer funds from treasury to vault, process claims
   - If no: communicate situation, propose resolution plan

5. **Post-Event**:
   - Full accounting of all claims processed
   - Publish transparency report
   - Review if trigger thresholds need adjustment
   - Assess protocol sustainability at current parameters

---

## Scenario 4: BondVault Balance Low

**Severity**: P2 (escalate to P1 if <20% of obligations)

**Symptoms**:
- Monitoring alert: "BondVault balance below threshold"
- Coverage ratio declining over days/weeks
- Projected runway insufficient for current obligations

**Step-by-Step Response**:

1. **Assess** (1 hour):
   - Current balance vs. total outstanding bond obligations
   - Rate of outflow (claims) vs. inflow (new bonds, buyback revenue)
   - Days until critical threshold at current rate

2. **If >30 days runway**:
   - Monitor daily
   - Review buyback allocation — reduce if needed to preserve vault
   - Consider adjusting bond parameters to increase inflow

3. **If 7-30 days runway**:
   - Reduce daily buyback amount via `setDailyBuyback()`
   - Allocate additional treasury funds to vault
   - Pause marketing of new bonds temporarily
   - Weekly status updates to community

4. **If <7 days runway**:
   - Transfer emergency reserves to vault
   - Consider pausing new bonds to prevent additional obligations
   - Daily public updates on vault status
   - Develop medium-term recapitalization plan

---

## Scenario 5: Multisig Signer Lost/Unavailable

**Severity**: P1 (P0 if during active incident)

**Symptoms**:
- Signer unresponsive for >24 hours during non-emergency
- Signer unresponsive for >1 hour during active incident
- Signer reports lost access to hardware wallet

**Step-by-Step Response**:

1. **Attempt Contact** (1 hour for non-emergency, 15 min for emergency):
   - Phone call (primary number)
   - Signal message
   - Email
   - Secondary contact (pre-shared emergency contact)

2. **If Signer Temporarily Unavailable**:
   - Remaining 2 signers can still meet 2-of-3 threshold
   - Proceed with any urgent operations using available signers
   - Document that 3rd signer was unavailable and why
   - Set deadline: if no contact in 72 hours, escalate

3. **If Signer Permanently Lost**:
   - Remaining 2 signers execute signer replacement:
     - Remove lost signer address from Safe
     - Add pre-designated backup signer address
   - Update all documentation
   - Verify new signer can transact successfully
   - Communicate change (without compromising security details)

4. **If 2 Signers Lost** (catastrophic):
   - Single remaining signer cannot execute any transactions
   - Activate disaster recovery plan (if pre-configured with timelock)
   - This scenario must be prevented through geographic distribution and redundancy

---

## General Incident Process

### During Any Incident

1. **Assign Incident Commander** — typically the founder unless delegated
2. **Open incident channel** — dedicated Signal thread or call
3. **Log all actions** with timestamps
4. **Do not speculate publicly** — only communicate confirmed facts
5. **Prioritize user funds** over protocol functionality

### Post-Incident (All Severities)

- [ ] Incident timeline documented (what happened, when, what was done)
- [ ] Root cause identified
- [ ] Preventive measures defined
- [ ] Monitoring gaps addressed
- [ ] Post-mortem published (P0/P1 only, within 72 hours)
- [ ] Follow-up tasks tracked to completion

---

## Emergency Contacts

| Role | Primary Contact | Backup Contact |
|------|----------------|----------------|
| Founder / IC | Phone + Signal | Email |
| Technical Advisor | Signal | Phone |
| Signer 3 | Phone | Signal |
| Chainlink Support | support.chain.link | Discord |
| Safe Support | safe.global/support | Discord |
