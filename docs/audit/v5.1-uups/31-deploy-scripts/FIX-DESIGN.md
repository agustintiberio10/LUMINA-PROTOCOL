# Fix #31 — Deploy Scripts Design

Resolves the CRITICAL + selected HIGH/MEDIUM findings from audit V5.1 #31. Pre-mainnet blocking work.

---

## 1. CRITICAL fix — Marketplace + BuybackEngine authorization in deploy

### Problem

Both `DeployLuminaV5Complete.s.sol` and `DeployLuminaV5Sepolia.s.sol` deploy `LuminaBondMarketplace` and `BuybackEngine` but never call `claimBond.setAuthorizedOperator(...)` for them. Fix #18's transfer whitelist requires this — without it, every marketplace `list()`, `executeBuy()`, and BuybackEngine `executeOffer()` call reverts at the ClaimBond level.

### Fix

Add two lines to both deploy scripts in the wiring phase (after Marketplace + BuybackEngine deploy + after BondVault.setAuthorizedCaller):

```solidity
// [Fix audit #31 CRITICAL] Authorize Marketplace + BuybackEngine as ClaimBond operators.
claimBond.setAuthorizedOperator(address(marketplace), true);
claimBond.setAuthorizedOperator(address(buybackEngine), true);
console.log("Marketplace + BuybackEngine authorized as ClaimBond operators");
```

### Why both?

- **Marketplace** — directly calls `claimBond.safeTransferFrom` for listing escrow + buy settlement.
- **BuybackEngine** — calls `claimBond.burnByHolder` (which is gated separately) and pays via Marketplace.executeBuy → marketplace.safeTransferFrom. The marketplace is already authorized so technically BuybackEngine doesn't need direct authorization for the buy path — but it's defensive: a future flow that bypasses marketplace and calls ClaimBond directly would need it. Adding it now is cheap and safe.

---

## 2. HIGH-1 fix — VerifyLuminaV5Deployment checks marketplace wiring

### Problem

The verify script doesn't read `claimBond.authorizedOperators(marketplace)`. The CRITICAL bug above would have been caught in CI if it did.

### Fix

1. Add `marketplace` to env-var loads (was missing).
2. Add `IClaimBondMinimal.authorizedOperators(address)` to the minimal interface.
3. After the existing ClaimBond.bondVault check, add:

```solidity
{
    bool mpAuth = IClaimBondMinimal(claimBond).authorizedOperators(marketplace);
    if (mpAuth) {
        console2.log("[PASS] ClaimBond.authorizedOperators[marketplace] == true");
    } else {
        console2.log("[FAIL] ClaimBond.authorizedOperators[marketplace] != true (CRITICAL — Fix #18)");
        failures++;
    }
}
{
    bool bbAuth = IClaimBondMinimal(claimBond).authorizedOperators(buybackEngine);
    if (bbAuth) {
        console2.log("[PASS] ClaimBond.authorizedOperators[buybackEngine] == true");
    } else {
        console2.log("[FAIL] ClaimBond.authorizedOperators[buybackEngine] != true (CRITICAL — Fix #18)");
        failures++;
    }
}
```

The script already has a `failures` accumulator + final revert. Two new checks plug into that flow.

---

## 3. HIGH-3 fix — WireLuminaV5PostDeploy helper

### Problem

If a deploy somehow misses the CRITICAL fix (legacy chain, manual deploy, partial re-run), there was no helper to apply it post-hoc.

### Fix

Add to `WireLuminaV5PostDeploy.s.sol`:

```solidity
function authorizeMarketplaceOperators(address claimBond, address marketplace, address buybackEngine) external {
    vm.startBroadcast();
    IClaimBondAuth(claimBond).setAuthorizedOperator(marketplace, true);
    IClaimBondAuth(claimBond).setAuthorizedOperator(buybackEngine, true);
    vm.stopBroadcast();
}

function checkMarketplaceOperatorsAuthorized(address claimBond, address marketplace, address buybackEngine)
    external view returns (bool mpOk, bool bbOk)
{
    mpOk = IClaimBondAuth(claimBond).authorizedOperators(marketplace);
    bbOk = IClaimBondAuth(claimBond).authorizedOperators(buybackEngine);
}
```

Idempotent — re-running on already-authorized operators is a no-op write. Includes a view-only check for CI dry-runs.

---

## 4. Findings DEFERRED in this fix (with rationale)

### HIGH-2 — Idempotency / resume-from-state

**Status:** DEFERRED.

**Rationale:** Adding JSON parsing to deploy scripts (read prior addresses, skip already-deployed) is a substantial refactor. It would also require establishing a deployment artifacts directory convention. Given that the protocol launches once on mainnet (re-deploy is rare), the operational risk is real but bounded. Re-running the script on a partial-failure state is a procedural concern handled by ops discipline (don't re-run, fix forward).

Recommended for a follow-up audit/fix once Foundry's `vm.exists` + JSON parsing is stable in the project's CI pipeline.

### MEDIUM-1 — Sepolia FounderVesting

**Status:** DEFERRED.

**Rationale:** Changing Sepolia from placeholder→real FounderVesting deploy changes the nonce accounting and forces a re-verification of every existing testnet deploy. That's significant scope creep on a pre-mainnet hot fix. Sepolia using a placeholder is operationally fine — testnet doesn't need the founder-vesting flow tested in-band (we have unit tests for FounderVesting independently).

If Sepolia later needs end-to-end FounderVesting testing, deploy a separate `DeployLuminaV5Sepolia_WithFounder.s.sol` rather than mutating the canonical script.

### MEDIUM-2 — Sepolia ownership transfer

**Status:** DEFERRED with note.

**Rationale:** Adding optional ownership-transfer to Sepolia would benefit ops parity with mainnet, but it's an end-of-script change that depends on env config. Operationally, ops can run `WireLuminaV5PostDeploy.transferOwnershipToMultisig` (which already exists) post-deploy. Adding it inline to the Sepolia script duplicates logic.

Recommended: standardize on running the wire script for ownership transfer in BOTH Sepolia and mainnet contexts as the operational pattern.

### LOW — FounderVesting placement consistency

**Status:** DEFERRED. Cosmetic. Both scripts work with their current placements.

---

## 5. Storage / upgrade impact

**None.** All changes are to off-chain deploy/verify/wire scripts. No on-chain contract code is modified. No storage layout changes. No proxy upgrades required.

The deployed contracts themselves (LuminaTokenV2, ClaimBond, LuminaBondMarketplace, etc.) are unchanged. Only the `script/` directory's deploy/verify/wire utilities are modified.

---

## 6. Files modified

| File | Change |
|---|---|
| `script/deploy/DeployLuminaV5Complete.s.sol` | +2 setAuthorizedOperator calls + console.log |
| `script/deploy/DeployLuminaV5Sepolia.s.sol` | Same +2 calls + log |
| `script/verify/VerifyLuminaV5Deployment.s.sol` | +marketplace env-var, +interface method, +2 verification blocks |
| `script/wire/WireLuminaV5PostDeploy.s.sol` | +interface, +2 helper functions |

---

## 7. Test strategy

`test/audit/v5.1-uups/integration/deploy/FixDeployScripts.t.sol`:

1. **`test_FixDeploy_PreFix_Marketplace_FailsWithoutAuth`** — proves the bug existed (deploy without the call → list reverts).
2. **`test_FixDeploy_Marketplace_AuthorizedAfterDeploy`** — proves the fix works (after fix, both flags true).
3. **`test_FixDeploy_Marketplace_ListWorks_AfterFix`** — end-to-end: list now succeeds.
4. **`test_FixDeploy_Marketplace_BuyWorks_AfterFix`** — end-to-end: buy now succeeds.
5. **`test_FixDeploy_Buyback_ExecuteWorks_AfterFix`** — buyback double-burn flow works.
6. **`test_FixDeploy_WirePostDeploy_*`** — helpers work + are idempotent.
7. **`test_FixDeploy_VerifyScript_*`** — the new verify check passes post-fix and detects the missing wiring on pre-fix.
8. **Sanity** — token distribution + cross-contract wiring unchanged from audit #30.

---

## 8. Mainnet deploy gate

After this fix is merged, the deploy gate is:

1. Run Sepolia deploy → run Verify script → verify exits 0 (all checks pass).
2. Run a smoke test: list → buy → cancel one bond on Sepolia.
3. Same on mainnet.

If any step fails, do NOT proceed. The verify script now catches the previously-missed marketplace wiring.
