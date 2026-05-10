# Audit V5.1 #24 — Recovery Procedures

**Date:** 2026-04-23

Step-by-step playbook for each disaster scenario. Use in conjunction with the on-chain primitives documented in `01-DISASTER-SCENARIOS.md` §2.

---

## Scenario 1: BondVault insufficient for redemptions

**Trigger:** A holder's `bondVault.redeemBond(...)` reverts with `"Insufficient reserve"`.
**Impact:** Bonds are temporarily unredeemable. No loss of state. `totalCommittedUSD` and claim-bond balances are preserved.

**Immediate actions:**

1. Admin calls `coverRouter.setPaused(true)` — stops new policies (which would worsen the deficit via triggers).
2. Analyse the deficit:
   - Required LUMINA ≈ `totalCommittedUSD / capacityOracle.getLuminaPrice()`.
   - Current LUMINA balance of BondVault.
   - Gap = required − current.
3. Choose a replenishment path:
   - **(a) Buy LUMINA from market** using MaintenanceReserve USDC (needs a new admin function — see §5 recommendations).
   - **(b) Community capital raise** — admin opens a CEX deposit / OTC channel to acquire LUMINA and sends to BondVault.
   - **(c) Let burn mechanics replenish organically** — TWAPBurner keeps burning LUMINA via premiums. Over time, LUMINA supply shrinks → price per unit rises → less LUMINA needed per redemption.
4. Once vault has sufficient LUMINA, admin calls `coverRouter.setPaused(false)` and announces resume.

## Scenario 2: Oracle compromise

**Trigger:** Shield oracle returns manipulated prices (e.g., $6 M BTC price causing mass false triggers).
**Impact:** M-01 sanity bounds reject the manipulated price at `createPolicy` or `verifyAndCalculate` → no false policies or triggers.

**Immediate actions:**

1. Confirm the oracle is compromised (compare to independent source).
2. Admin calls `coverRouter.setPaused(true)` as a precaution.
3. Coordinate with Chainlink / oracle provider to restore correct prices.
4. Once restored, admin calls `coverRouter.setPaused(false)`.

## Scenario 3: Oracle permanently unavailable

**Trigger:** Chainlink deprecates the feed or pauses it indefinitely.
**Impact:** `createPolicy` and trigger-verification revert. Redemptions still work (BondVault uses `CapacityOracle`, not the shield oracle).

**Immediate actions:**

1. Admin upgrades the shield to read from a replacement oracle address (via UUPS `upgradeToAndCall`).
2. Or: admin upgrades `CoverRouterV2` / shields to use a new oracle contract with the same interface.
3. Tests the upgrade in staging before prod.

## Scenario 4: LUMINA price collapse (99%)

**Trigger:** LUMINA trading price drops to < $0.005.
**Impact:** `isProtocolAutoPaused()` returns `true`; new policy purchases revert.

**Immediate actions:**

1. Circuit breaker has already activated — no admin action needed to halt new policies.
2. Assess whether the price drop is temporary (flash crash) or structural.
3. If structural, admin may:
   - Wait for price recovery (protocol resumes when > $0.005).
   - Manually set `capacityOracle.setEmergencyPrice(newStableValue)` if TWAP is broken.
4. Bond redemption still works at the minimum redemption floor (`MIN_REDEEM_PRICE = 0.001e18`).

## Scenario 5: Sequencer extended downtime (> 24h)

**Trigger:** Base sequencer down for > 24 hours.
**Impact:** No transactions mined; however, cleanup windows extend automatically per `BaseShield._validateStatusForTrigger`.

**Immediate actions:**

1. No on-chain action possible (sequencer is down).
2. Once sequencer restores, backlogged `checkAndSettlePolicy` calls succeed thanks to the extended cleanup window.
3. Community / keeper triggers settlement for affected policies.

## Scenario 6: Keeper (ShieldKeeper) goes offline

**Trigger:** `performUpkeep` not being called.
**Impact:** Expired policies accumulate in a pending state until someone settles them.

**Immediate actions:**

1. `checkAndSettlePolicy` is permissionless — anyone can call it. Verified by `test_DR_UUPS_KeeperDown_AnyoneCanSettle`.
2. Multisig / community posts a bot to sweep pending policies.
3. Deploy a new keeper or restart the old one.

## Scenario 7: Mass redemption (bank run)

**Trigger:** Large fraction of bond holders redeem within a short window.
**Impact:** As long as vault has enough LUMINA, all succeed; if not, later redeemers revert with `Insufficient reserve` while earlier ones kept their LUMINA.

**Immediate actions:**

1. Admin may pause new policies if the run indicates a crisis.
2. Monitor vault balance in real time.
3. If insufficient, follow Scenario 1 to replenish.

## Scenario 8: Admin key compromise

**Trigger:** Attacker gains admin private key.
**Impact:** Attacker can pause, upgrade, recover tokens (with restrictions — USDC and LUMINA cannot be recovered from MaintenanceReserve / TWAPBurner).

**Immediate actions:**

1. **CRITICAL — this is why a multisig with timelock is mandatory for mainnet.**
2. If attacker has not executed malicious action yet: rotate admin via `transferOwnership` + `grantRole` paths.
3. If attacker has initiated an upgrade (no timelock): community fork decision.

## Scenario 9: Accidental permanent pause

**Trigger:** Admin accidentally calls `coverRouter.setPaused(true)` and loses the key.
**Impact:** No new policies. **Redemptions still work** — the BondVault is independent.

**Immediate actions:**

1. Transfer ownership to a backup admin address.
2. Call `setPaused(false)`.

## Scenario 10: Triple / combined disaster

**Verified behaviour** (`test_DR_UUPS_TripleDisaster_FailsSafe`): oracle reverts + LUMINA crash + admin pause simultaneously → new policies blocked on three independent grounds; redemptions still possible. The protocol fails safely, preserving funds.

---

## Runbook coverage

Every scenario listed has:
- An on-chain primitive that implements the defense OR a documented admin path.
- A passing test that verifies the primitive / path works.
- A fallback if the first-line mitigation fails.

See REPORT.md §5 for outstanding recommendations (multisig, timelock, guardian role, automated rescue function).
