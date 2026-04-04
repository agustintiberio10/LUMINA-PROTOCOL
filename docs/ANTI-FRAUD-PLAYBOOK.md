# LUMINA PROTOCOL — ANTI-FRAUD PLAYBOOK
## Operator Guide for Detecting and Responding to Fraudulent Payouts

---

## DEFENSE LAYERS (Pre-Payout)

| Layer | Mechanism | What it prevents |
|-------|-----------|-----------------|
| 1 | Oracle cryptographic signature | Fake events (oracle must sign proof) |
| 2 | Waiting period (1h BSS, 24h Depeg, 14d Exploit) | Same-block front-running |
| 3 | Dual verification (Exploit: Oracle + Phala TEE) | Single-point oracle compromise |
| 4 | EmergencyPause (instant, no delay) | Halt protocol before trigger |
| 5 | Scheduled payout delay ($50K+) | Window to pause before execution |

---

## IF YOU DETECT A FRAUDULENT PAYOUT ATTEMPT

### Scenario A: Oracle key potentially compromised

**Time available:** Until the attacker calls `triggerPayout()`

1. **IMMEDIATELY** call `EmergencyPause.emergencyPauseAll()` from Gnosis Safe
   - This blocks `purchasePolicy` and `purchasePolicyFor` (no new fraudulent policies)
   - `triggerPayout` still works (by design) but `executePayout` reverts if vault is paused
2. Rotate oracle key: `LuminaOracle.setOracleKey(newKey)` via TimelockController
3. If multisig oracle: `removeSigner(compromisedKey)` + `setRequiredSignatures(N)`
4. Unpause after key rotation

### Scenario B: Fraudulent payout already triggered (large, scheduled)

**Time available:** `largePayoutDelay` (configured, minimum 1 hour)

1. The payout is scheduled, not yet executed
2. Call `EmergencyPause.emergencyPauseAll()` — this blocks `executeScheduledPayout` (vault paused)
3. Investigate the claim off-chain
4. If fraud confirmed: the scheduled payout cannot be cancelled (by design) BUT it also cannot execute while paused
5. Upgrade the CoverRouter via UUPS to add the ability to void this specific payout, then unpause
6. If legitimate: simply unpause, the scheduled payout executes normally

### Scenario C: Fraudulent payout already executed (small, immediate)

**Time available:** None — funds already transferred

1. The damage is limited to: `maxPayout` of the specific policy
2. Pause protocol to prevent further attacks
3. Rotate compromised keys
4. The `maxPayoutsPerDay` rate limit caps total daily damage

---

## MONITORING CHECKLIST

| Check | Frequency | Tool |
|-------|-----------|------|
| Oracle key usage patterns | Real-time | Subgraph + alerts |
| Unusual payout amounts | Real-time | API monitoring |
| USDC depeg (< $0.95) | Every 5 min | `EmergencyPause.checkUSDCDepeg()` |
| Sequencer uptime | Real-time | Chainlink feed |
| Vault utilization spikes | Hourly | Dashboard |
| Multiple policies from same agent | Daily | Subgraph query |

---

## RESPONSE TIME TABLE

| Scenario | Detection → Pause | Pause → Investigation | Investigation → Resolution |
|----------|------------------|----------------------|---------------------------|
| Oracle compromise | < 5 min | Instant | 1-24h (key rotation) |
| USDC depeg | < 30 min | Instant | Until depeg resolves |
| Aave V3 issue | < 15 min | Instant | Until Aave resolves |
| Protocol exploit | < 5 min | Instant | Days (upgrade + audit) |
