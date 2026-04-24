# Audit V5.1 #29 — Role Rotation Runbook

Step-by-step procedures for every realistic role rotation scenario.

---

## Rotation A — EOA → Multisig 3-of-5 (initial hardening)

**When:** after initial deploy, before opening to public. Transition from single-EOA admin to a Gnosis Safe multisig.

### Steps (AccessControl contracts)

1. **Deploy** Gnosis Safe with desired signers + threshold.
2. **Test** the multisig — queue a harmless no-op tx (e.g., `grantRole(SOME_NON_ADMIN_ROLE, address_you_control)`) and confirm all signers can sign.
3. **From the EOA**, call `grantRole(DEFAULT_ADMIN_ROLE, multisigAddress)` on each AccessControl contract.
4. **From the multisig**, execute a canary admin operation on each contract (e.g., grant a non-critical role) to prove end-to-end control works.
5. **Only now**, from the EOA, call `renounceRole(DEFAULT_ADMIN_ROLE, EOA)`. Or `revokeRole(DEFAULT_ADMIN_ROLE, EOA)` executed from the multisig (preferred — avoids renouncing).
6. **Verify** `hasRole(DEFAULT_ADMIN_ROLE, EOA) == false` and `hasRole(DEFAULT_ADMIN_ROLE, multisig) == true`.

### Steps (Ownable contracts)

1. **Test** multisig as above.
2. **From the EOA**, call `transferOwnership(multisig)` — instant 1-step transfer.
3. **From the multisig**, execute a canary owner-only operation.

### Checklist
- [ ] Multisig Safe deployed with signer list committed to runbook.
- [ ] Canary operation succeeded on every migrated contract.
- [ ] EOA role/ownership revoked.
- [ ] Post-verification: `hasRole` / `owner()` reads match expectations.
- [ ] Announcement to community with tx hashes.

---

## Rotation B — Multisig → Multisig (team changes)

**When:** signer set needs to change (staff rotation, key compromise, governance upgrade).

### Steps

1. **Deploy** the new Safe with updated signers/threshold.
2. **From the old multisig**, execute `grantRole(DEFAULT_ADMIN_ROLE, newMultisig)` (AC contracts) or `transferOwnership(newMultisig)` (Ownable).
3. **From the new multisig**, verify control with a canary op.
4. For AC contracts: from the new multisig, execute `revokeRole(DEFAULT_ADMIN_ROLE, oldMultisig)`.
5. For Ownable: already done in step 2 (transferOwnership is 1-step).
6. Verify.

### Key safety rule
**Never skip step 3.** If the new multisig signers can't actually sign (e.g., a script misconfig), and you've already revoked the old one, the contract is stuck.

---

## Rotation C — Add a Timelock controller

**When:** production operations want enforced delay on admin actions (48h review window).

### Steps (AccessControl — representative)

1. **Deploy** `TimelockController` with the multisig as both proposer and executor, 48h delay.
2. **From the current multisig**, execute `grantRole(DEFAULT_ADMIN_ROLE, timelock)`.
3. **From the current multisig**, schedule a no-op in the timelock, wait 48h, execute — prove timelock works.
4. **From the current multisig**, execute `revokeRole(DEFAULT_ADMIN_ROLE, multisig)`.
5. Now the only admin is the timelock. All future admin ops require:
   - `timelock.schedule(contract, calldata, delay)` (from proposer = multisig).
   - Wait 48h.
   - `timelock.execute(...)` (from executor = multisig).

### Steps (Ownable)

Same pattern — `transferOwnership(timelock)`.

### Why bother
- Enforces public review period.
- Protects against compromised signers (72h window to detect + cancel).
- Aligns with DeFi best practice for production protocols.

---

## Rotation D — Emergency admin change (compromised key)

**When:** at least one multisig signer's key is compromised. Need to lock them out before they can gather threshold signatures.

### Steps

1. **From the remaining uncompromised signers** (if they alone can meet threshold): propose a Safe tx that replaces the compromised signer in the Safe's owner list. This is a Safe-level operation, not a protocol one.
2. If the compromised signer has already reached threshold → assume worst case: protocol funds are at risk. **Pause everything** that supports pausing (CoverRouterV2.setPaused, ShieldKeeper.pause, SolvencyOracle.setEmergencyPause) **if those signers can still be reached**.
3. Draft a community communication.
4. Once remediation complete, re-validate all admin roles with `hasRole`/`owner()`.

### Prerequisite for this to work
- Multisig threshold must be achievable by uncompromised signers.
- If compromise is ≥ threshold: this runbook cannot save you; fall back to protocol-level defenses (timelock delay, if configured).

---

## Rotation E — Renounce role (ONLY after replacement verified)

**When:** truly wanting to decentralize — permanent admin removal after a successor is fully live.

### **Warning box**

> ⚠️ **Renouncing the ONLY admin permanently locks the contract.** Never renounce without a verified working successor. This operation is irreversible even for the original deployer.

### Steps

1. **Prerequisite:** Rotation A, B, or C completed. Successor admin (multisig / timelock) has already executed at least one successful admin tx.
2. **From the EOA (or old admin)**, call `renounceRole(DEFAULT_ADMIN_ROLE, self)` (AC) or `renounceOwnership()` (Ownable).
3. Verify with `hasRole` / `owner()`.

### **Never renounce if:**
- Only one admin address exists.
- The successor hasn't been tested yet.
- You're uncertain whether the admin slot is needed for future upgrades.

### Dangerous anti-pattern
Calling `revokeRole(DEFAULT_ADMIN_ROLE, self)` from self when self is the sole admin is EQUIVALENT to renounce — same permanent loss. Tested in `test_Rotation_DangerousGap_RevokeBeforeGrant_ContractLosesAdmin`.

---

## Rotation F — Granting a secondary role (e.g., BUYBACK_OPERATOR_ROLE)

**When:** daily ops needs a role but not full admin access (privilege separation).

### Steps

1. **From DEFAULT_ADMIN (multisig)**, execute `grantRole(BUYBACK_OPERATOR_ROLE, opsAddress)`.
2. **From the ops address**, test the operator-gated function (e.g., `BuybackEngine.setDailyBuyback`).
3. Document the ops address in operational records.

### Rotating the operator
1. Grant new operator.
2. Test new operator.
3. Revoke old operator.

### Renouncing an operator role
- Lower impact than renouncing DEFAULT admin — if all operators renounce, DEFAULT admin can still grant new ones.
- OK to renounce an operator role voluntarily (e.g., stepping down from the team).

---

## Rotation G — BondVault authorizedCaller rotation

**When:** replacing BuybackEngine with a newer version that must call `decreaseObligations` / `burnFromReserves`.

### Steps

1. **From AUTHORIZED_CALLER_ADMIN_ROLE holder**, execute `setAuthorizedCaller(newBuyback, true)` on BondVault.
2. Test the new BuybackEngine — run one `executeOffer` end-to-end.
3. **From the admin**, execute `setAuthorizedCaller(oldBuyback, false)`.
4. Verify via `authorizedCallers(oldBuyback) == false && authorizedCallers(newBuyback) == true`.

### Safety
- The 5%-per-tx cap on `burnFromReserves` limits damage if a rogue authorized caller is granted.
- Still, always test-then-revoke, never revoke-then-test.

---

## Cross-rotation invariants

Every rotation procedure must end with these checks:

1. At least one valid admin exists (or timelock with executor).
2. All canary operations succeed from the new admin.
3. Old admin (if revoking) truly has no role (`hasRole = false`).
4. No contract is "admin-less" unintentionally.
5. Announcement posted with tx hashes and new admin address.

---

## Appendix — Quick command reference

### AccessControl (Solidity)

```solidity
// Grant
contract.grantRole(ROLE, newAddress);

// Revoke (from admin)
contract.revokeRole(ROLE, oldAddress);

// Renounce (from self)
contract.renounceRole(ROLE, self);

// Query
contract.hasRole(ROLE, address);
contract.getRoleAdmin(ROLE);
```

### Ownable (Solidity)

```solidity
// Transfer (1-step)
contract.transferOwnership(newAddress);

// Renounce (permanent!)
contract.renounceOwnership();

// Query
contract.owner();
```

### BondVault authorizedCaller mapping

```solidity
// Grant
bondVault.setAuthorizedCaller(address, true);

// Revoke
bondVault.setAuthorizedCaller(address, false);

// Query
bondVault.authorizedCallers(address);
```
