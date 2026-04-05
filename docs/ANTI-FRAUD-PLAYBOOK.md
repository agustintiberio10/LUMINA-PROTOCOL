# LUMINA PROTOCOL — ANTI-FRAUD PLAYBOOK (Option E)
## Operator Guide for Detecting and Responding to Fraudulent Payouts

---

## CORE PRINCIPLE

**Once a payout passes its delay window and becomes Claimable, the insured agent ALWAYS receives their funds. No admin, multisig, or timelock can stop it.** The admin's only window to act is DURING the scheduled delay period.

---

## DEFENSE LAYERS

| Layer | Mechanism | What it prevents | Timing |
|-------|-----------|-----------------|--------|
| 1 | Oracle multisig (currently 1-of-1, planned upgrade to 2-of-3) | Fake events | Pre-trigger |
| 2 | Waiting period (1h BSS, 24h Depeg, 14d Exploit) | Front-running | Pre-trigger |
| 3 | Dual verification (Exploit: Oracle + Phala TEE) | Single-point compromise | Pre-trigger |
| 4 | EmergencyPause (instant, no delay) | Halt new purchases/triggers | Pre-trigger |
| 5 | Scheduled payout delay (largePayoutDelay, min 1h) | Window to investigate + veto | Post-trigger |
| 6 | `cancelScheduledPayout` targeted veto | Cancel specific fraudulent payouts | During delay only |
| 7 | Weekly veto limit (max 3/week) | Prevent admin abuse of veto power | Always |

---

## PAYOUT LIFECYCLE

```
EVENT → triggerPayout() → [SCHEDULED: delay period] → [CLAIMABLE: agent collects]
                               ↑                          ↑
                          Admin can VETO here        Admin CANNOT act here
                          (cancelScheduledPayout)    (payout is final)
```

---

## FRAUD RESPONSE PROCEDURE

### DETECTION
1. Off-chain monitoring detects suspicious trigger (unusual amount, timing, oracle data inconsistency)
2. Alert sent to operations team (Slack, PagerDuty, etc.)

### ACTION WINDOW
3. Admin has from `triggerPayout()` until `sp.executeAfter` to act
4. Delay value: `largePayoutDelay` (configurable, minimum 1 hour)
5. Only payouts > `largePayoutThreshold` are scheduled (small payouts are instant)

### IF FRAUD CONFIRMED (within delay window)
6. Admin calls `cancelScheduledPayout(payoutId)` from Gnosis Safe (requires 2/3 EMERGENCY_ROLE)
7. Funds return to vault (benefit all LPs), allocation released
8. Event `PayoutVetoed` emitted for transparency
9. Max 3 vetoes per week to prevent admin abuse
10. Investigate attack vector, rotate compromised keys

### IF FRAUD NOT CONFIRMED
11. Do nothing. Delay passes. Payout becomes Claimable.
12. Agent calls `executeScheduledPayout(payoutId)` — collects full payout.

### AFTER DELAY PASSES (Claimable)
13. `cancelScheduledPayout` reverts with "delay passed, agent can claim"
14. Agent collects whenever they want, even during protocol pause
15. `executePayout` has no pause check — funds flow regardless

### SMALL PAYOUTS (below threshold)
16. Execute immediately in `triggerPayout` — no delay, no veto window
17. If suspicious, admin must pause protocol BEFORE the trigger (Layer 4)

---

## MONITORING CHECKLIST

| Check | Frequency | Tool |
|-------|-----------|------|
| Oracle key usage patterns | Real-time | Subgraph + alerts |
| Unusual payout amounts | Real-time | API monitoring |
| USDC depeg (< $0.95) | Every 5 min | `EmergencyPause.checkUSDCDepeg()` |
| Sequencer uptime | Real-time | Chainlink feed |
| Vault utilization spikes | Hourly | Dashboard |
| Veto count this week | Daily | On-chain query |
| Multiple policies from same agent | Daily | Subgraph query |

---

## RESPONSE TIME TABLE

| Scenario | Detection → Action | Available Window | Max Damage |
|----------|-------------------|-----------------|------------|
| Oracle compromise (large payout) | < 5 min | `largePayoutDelay` (1h+) | Veto cancels it |
| Oracle compromise (small payout) | < 5 min | None (instant) | maxPayout of 1 policy |
| USDC depeg | < 30 min | Pause before triggers | 0 if paused in time |
| Protocol exploit | < 5 min | Pause immediately | 0 if paused in time |

---

## CONFIGURATION RECOMMENDATIONS

| Parameter | Recommended Value | Why |
|-----------|-------------------|-----|
| `largePayoutThreshold` | $50,000 (50_000e6) | Payouts above this get scheduled delay |
| `largePayoutDelay` | 6 hours | Enough time for 2/3 multisig to respond |
| `maxPayoutsPerDay` | 10 | Limits daily drain from compromised oracle |
| `requiredSignatures` | 2 (of 3) | Oracle multisig |
| `MAX_VETOES_PER_WEEK` | 3 | Hardcoded — prevents admin abuse |
