# LUMINA Protocol V5.0 — Multisig Operations Runbook

## Overview

This runbook documents all routine and emergency operations performed through the LUMINA Treasury multisig (2-of-3). Each operation includes a checklist, function references, and verification steps.

---

## Routine Operations

### 1. Allocate CEX Reserves

**Purpose**: Move funds from treasury to CEX wallets for liquidity provisioning or market making.

**Function**: `TreasuryManager.allocate(address destination, uint256 amount, string category)`

**Checklist**:

- [ ] Verify destination address matches approved CEX deposit wallet
- [ ] Confirm amount is within daily CEX allocation limit ($50,000/day)
- [ ] Check current treasury balance can sustain allocation
- [ ] Verify no pending allocations that would exceed weekly limit

**Steps**:

1. Prepare transaction in Safe UI:
   - Target: TreasuryManager contract
   - Function: `allocate()`
   - Parameters:
     - `destination`: CEX deposit address
     - `amount`: Amount in USDC (6 decimals)
     - `category`: "CEX_LIQUIDITY"
2. First signer reviews and signs
3. Second signer independently verifies parameters and signs
4. Transaction executes automatically after 2nd signature
5. Verify funds arrived at destination within 5 minutes

**Verification**:
- [ ] Treasury balance decreased by exact amount
- [ ] Destination received funds
- [ ] Event `Allocated(destination, amount, category)` emitted

---

### 2. Spend Maintenance Funds

**Purpose**: Pay for operational expenses (hosting, services, audits, tooling).

**Function**: `TreasuryManager.spend(address recipient, uint256 amount, string reason)`

**Checklist**:

- [ ] Verify expense is pre-approved or within standing authorization
- [ ] Confirm recipient address is correct (double-check with recipient)
- [ ] Amount is within maintenance spending limit ($10,000/transaction, $30,000/month)
- [ ] Document reason string clearly for transparency reports

**Steps**:

1. Prepare transaction in Safe UI:
   - Target: TreasuryManager contract
   - Function: `spend()`
   - Parameters:
     - `recipient`: Payee address
     - `amount`: Amount in USDC (6 decimals)
     - `reason`: Clear description (e.g., "Audit_TrailOfBits_Phase1")
2. First signer reviews invoice/documentation and signs
3. Second signer verifies and co-signs
4. Confirm execution and record in expense log

**Verification**:
- [ ] Payment received by recipient
- [ ] Event `Spent(recipient, amount, reason)` emitted
- [ ] Monthly spend tracker updated

---

### 3. Configure Daily Buyback Amount

**Purpose**: Adjust the daily LUMINA buyback-and-burn amount based on treasury health and market conditions.

**Function**: `TWAPBurner.setDailyBuyback(uint256 amountUSDC)`

**Checklist**:

- [ ] Review current treasury balance and runway
- [ ] Assess market conditions (LUMINA price, volume, liquidity depth)
- [ ] Confirm new amount is within governance-approved range ($500–$5,000/day)
- [ ] Verify TWAPBurner has sufficient USDC allowance

**Steps**:

1. Prepare transaction in Safe UI:
   - Target: TWAPBurner contract
   - Function: `setDailyBuyback()`
   - Parameters:
     - `amountUSDC`: Daily amount in USDC (6 decimals)
2. Both signers review rationale and sign
3. Verify new daily amount is active

**Verification**:
- [ ] `dailyBuybackAmount()` returns new value
- [ ] Next scheduled buyback uses updated amount
- [ ] Event `DailyBuybackUpdated(oldAmount, newAmount)` emitted

---

### 4. Update Solvency Parameters

**Purpose**: Adjust solvency thresholds as protocol matures.

**Function**: `SolvencyOracle.updateParameters(uint256 minRatio, uint256 warningRatio)`

**Checklist**:

- [ ] New parameters reviewed by technical advisor
- [ ] Changes documented with rationale
- [ ] Impact analysis completed (how many current bonds affected)

**Steps**:

1. Prepare multisig transaction with new parameters
2. Both signers review impact analysis and sign
3. Monitor SolvencyOracle behavior for 24 hours post-change

---

## Emergency Operations

### E1. Pause CoverRouter (Stop New Bonds)

**Severity**: P0/P1
**Function**: `CoverRouter.setPaused(bool paused)`

**When to Use**:
- Critical vulnerability discovered
- Oracle manipulation detected
- Abnormal bonding patterns suggesting exploit

**Steps**:

1. **Any single authorized signer** initiates pause discussion
2. Prepare transaction:
   - Target: CoverRouter
   - Function: `setPaused(true)`
3. Obtain 2 signatures as fast as possible (phone/Signal)
4. Execute immediately — do not wait for full analysis
5. Communicate to community within 30 minutes

**Unpause Procedure**:
- Requires full root cause analysis
- Fix deployed or confirmed not needed
- 2-of-3 multisig approval to call `setPaused(false)`
- Monitor closely for 24 hours post-unpause

---

### E2. Pause SolvencyOracle (Stop Trigger Evaluations)

**Severity**: P0
**Function**: `SolvencyOracle.setEmergencyPause(bool paused)`

**When to Use**:
- Oracle returning incorrect/manipulated data
- Chainlink feed compromised or permanently stale
- False solvency failure being reported

**Steps**:

1. Confirm oracle data is incorrect (cross-reference with manual calculation)
2. Prepare transaction:
   - Target: SolvencyOracle
   - Function: `setEmergencyPause(true)`
3. Obtain 2 signatures immediately
4. Execute — this prevents any trigger events from processing
5. Investigate root cause
6. If Chainlink issue: contact Chainlink team, assess alternative feeds

**Unpause Procedure**:
- Oracle accuracy confirmed with 3+ independent data sources
- Root cause resolved or mitigated
- 2-of-3 approval to call `setEmergencyPause(false)`

---

### E3. Handle Signer Compromise

**Severity**: P0
**Function**: Safe multisig signer management

**When to Use**:
- Signer private key potentially exposed
- Signer device stolen/compromised
- Unauthorized transaction submitted to Safe

**Immediate Steps**:

1. Remaining 2 signers coordinate via secure channel (pre-agreed Signal group)
2. Reject any pending transactions from compromised signer
3. Prepare signer replacement transaction:
   - Remove compromised address
   - Add new address (from pre-generated cold wallet)
4. Execute with remaining 2 valid signatures
5. Revoke any token approvals granted to compromised address
6. Audit all recent transactions for unauthorized activity

**Post-Incident**:
- [ ] Full audit of last 30 days of multisig transactions
- [ ] Rotate any shared secrets the compromised signer had access to
- [ ] Update all documentation with new signer address
- [ ] Post-mortem within 72 hours

---

### E4. Emergency Fund Recovery

**Severity**: P0
**Function**: Various — depends on scenario

**When to Use**:
- Funds stuck in contract due to bug
- Need to migrate funds before exploit is used

**Steps**:

1. Assess scope: which contracts, how much value at risk
2. Determine if existing admin functions can recover funds
3. If upgrade needed: deploy patched implementation, upgrade via proxy
4. Execute recovery with 2-of-3 multisig
5. Account for all recovered funds publicly

---

## Operational Security Reminders

- Never share transaction details in public channels before execution
- Always verify contract addresses against official registry before signing
- Use hardware wallets for all multisig signing
- Never sign transactions you haven't personally verified the calldata for
- Keep at least one signer in a different timezone for 24/7 coverage
- Rotate Safe UI sessions regularly — do not stay permanently logged in

---

## Transaction Verification Checklist (For Every Transaction)

Before any signer approves:

- [ ] Correct target contract address
- [ ] Correct function selector (match ABI)
- [ ] Parameters match intended values (decode calldata independently)
- [ ] No unexpected delegatecall or nested calls
- [ ] Transaction value (ETH) is zero unless intentional
- [ ] Gas limit is reasonable for the operation
