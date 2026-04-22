# V5.1 Race Condition Inventory

**Audit:** V5.1 #8 — Race Conditions Deep Re-audit
**Branch:** `audit/v5.1-08-race-conditions-deep`
**Date:** 2026-04-22

---

## Race surface catalogue

For each scenario, we document:
- How it could go wrong (the hazard).
- What the code prevents it from going wrong (the mitigation).
- Where the test coverage lives.

### 1. Concurrent capacity reservation (PR #37 fix)
- **Hazard:** two policyholders reserving in the same block could both see
  `availableCapacityUSD()` > 0 and commit beyond the 50% safety cap.
- **Mitigation:** `totalReservedUSD` is incremented BEFORE the check, and
  `availableCapacityUSD` subtracts both `committed + reserved`.
- **Test:** `test_Race_Reservation_SameBlock_DoesNotDoubleCount`,
  `test_Race_Reservation_ExceedsCap_Reverts`.

### 2. Capacity release vs commit
- **Hazard:** reserved → commit path reduces `totalReservedUSD` but does
  not increase `totalCommittedUSD` (that's `issueBond`'s job). A race could
  cause reservation accounting drift.
- **Mitigation:** Solidity sequential execution; each step is atomic.
- **Test:** `test_Race_Reservation_CommitThenIssueBond_IndependentCounters`.

### 3. BondVault burn cap (same-block repeated burns)
- **Hazard:** two authorised burners could each try to burn 5% of balance
  in the same block and together exceed 5%.
- **Mitigation:** The check `amount <= (currentBalance × 5) / 100` is
  evaluated against the CURRENT balance at each call — after the first
  burn, `currentBalance` is already reduced.
- **Test:** `test_Race_BurnCap_SequentialBurnsHonorUpdatedBalance`.

### 4. TWAPBurner cooldown
- **Hazard:** two `executeBurn` calls in the same block.
- **Mitigation:** `block.timestamp >= lastBurnTimestamp + burnCooldown` —
  after first burn, `lastBurnTimestamp == block.timestamp`, so second call
  can only succeed once `block.timestamp` moves forward.
- **Test:** documented via `canBurn()` invariant; practical same-block
  re-entry would require USDC funding which is out of scope for a
  standalone UUPS audit.

### 5. BuybackEngine daily budget exhaustion
- **Hazard:** multiple `executeOffer` in same day exceed daily budget.
- **Mitigation:** `dailyConfig.spentToday + priceUSDC <= dailyBudget`
  check before each execute.
- **Test:** `test_Race_Buyback_DailyBudget_SecondExecuteReverts`.

### 6. CEX allocate bucket exhaustion
- **Hazard:** two `allocateTokens` calls in same block exhaust a bucket.
- **Mitigation:** per-bucket monotonically-increasing counters
  (`allocatedFromImmediate`, `allocatedFromVesting`, etc.) with ceiling checks.
- **Test:** exercised via the allocation flow — the state counters are
  updated before the transfer, so second call with insufficient balance
  reverts.

### 7. PolicyManager deactivate + register concurrency
- **Hazard:** admin deactivates while a buyer's tx is queued.
- **Mitigation:** `productActive[pid]` flag checked at each `recordPolicy`.
  Deactivated → reverts even though buyer paid the premium. (Note: the
  premium is held by CoverRouter which refunds or rejects.)
- **Test:** `test_Race_DeactivateProduct_BetweenPurchases`.

### 8. Marketplace list-cancel-buy
- **Hazard:** seller lists, then cancels, then buyer tries to buy stale
  listing.
- **Mitigation:** `Listing.active` flag toggled on cancel; `executeBuy`
  checks `active`.
- **Test:** documented as INFO — marketplace integration-level test
  already in the broader test suite.

### 9. UUPS upgrade during operations
- **Hazard:** upgrade racing with a pending operation.
- **Mitigation:** EVM serialisation — each tx executes fully against the
  impl in effect at its start; post-upgrade txs use the new impl. Storage
  layout audit (#1) guarantees state preservation.
- **Test:** covered by audits #1 and #3; re-verified via
  `test_Race_Upgrade_StatePreservedAndOperationsContinue`.

### 10. Multiple holders redeem same epoch
- **Hazard:** five holders of epoch 202912 redeem in the same block;
  `lumina.balanceOf(vault)` changes across calls.
- **Mitigation:** Each `redeemBond` is a complete atomic call that deducts
  from the vault's LUMINA balance immediately. Sequential calls see
  the updated balance.
- **Test:** `test_Race_Redeem_MultipleHolders_SameEpoch`.

### 11. Admin pause vs operation
- **Hazard:** admin pauses CoverRouter during an in-flight policy purchase.
- **Mitigation:** the pause flag is checked inside the priced function; if
  paused before the tx executes, the tx reverts.
- **Test:** `test_Race_Admin_SetPaused_BlocksSubsequentOps`.

### 12. Settlement vs purchase same block
- **Hazard:** expired policy settles + new policy purchased same block
  for same product.
- **Mitigation:** each is an independent PolicyManager tx; policyIds are
  monotonically incrementing so no collision.
- **Test:** documented as covered indirectly by audit #3 lifecycle test.

---

## Reality check for "same-block" races in Foundry

Foundry tests execute transactions sequentially within a single logical
block unless `vm.roll` is used. This is the same model the EVM uses —
transactions in the same block run in miner-chosen order, each seeing the
state changes from prior txs in that block. Our tests therefore naturally
exercise the same-block race surface when they call multiple functions
without `vm.warp` between them.

All the mitigations above are state-transition invariants that hold
regardless of block position — they rely on proper ordering inside each
transaction, not on block-level coordination.

See `REPORT.md` for the verdict and full raw test output.
