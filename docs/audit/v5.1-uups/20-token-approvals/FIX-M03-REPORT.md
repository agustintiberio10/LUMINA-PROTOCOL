# Fix M-03 Report — BuybackEngine Approval Includes Buyer Fee

**Resolves:** audit V5.1 #20 §4.1 MEDIUM.
**Branch:** `fix/v5.1-buyback-approval-fee`
**Status:** RESOLVED

---

## 1. Summary

`BuybackEngine.executeOffer` always reverted because it approved only `priceUSDC` but `Marketplace.executeBuy` tries to pull `priceUSDC + buyerFee` (1.5 %).

**Fix:** read `BUYER_FEE_BPS` and `BPS_DENOMINATOR` from the Marketplace at call time, compute `totalRequired = priceUSDC + buyerFee`, and:

1. Check `dailyConfig.spentToday + totalRequired <= dailyConfig.dailyBudget` (count fee against budget).
2. Update `spentToday += totalRequired` **before** the external call (CEI).
3. `usdc.forceApprove(address(marketplace), totalRequired)`.
4. `marketplace.executeBuy(listingId)`.
5. Post-call `usdc.forceApprove(address(marketplace), 0)` (defense-in-depth).

## 2. Files changed

### Source (1)
- `src/marketplace/BuybackEngine.sol`
  - Extended `IBuybackMarketplace` with `BUYER_FEE_BPS()` and `BPS_DENOMINATOR()` view functions (auto-generated getters on Marketplace constants).
  - Updated `executeOffer` body per §1.

### Tests — new (1)
- `test/audit/v5.1-uups/token-nft/approvals/FixM03BuybackApproval.t.sol` — 11 tests:
  - `test_FixM03_ExecuteOffer_NowWorks` — happy path, previously reverted.
  - `test_FixM03_ExecuteOffer_UsdcOutflow_IsPricePlusFee` — engine's USDC delta equals `price + fee`.
  - `test_FixM03_ExecuteOffer_BondsEndUpBurned` — double-burn path still functional.
  - `test_FixM03_DailyBudget_IncludesFee` — `spentToday` reflects `price + fee`.
  - `test_FixM03_DailyBudget_ExactLimitWithFee_Succeeds` — budget equals price+fee works.
  - `test_FixM03_DailyBudget_JustOverWithFee_Reverts` — fee pushing over budget reverts cleanly.
  - `test_FixM03_MultipleOffers_ConsumeBudgetWithFees` — three-offer scenario with cumulative fee.
  - `test_FixM03_Approval_ResetToZero_AfterExecution` — post-call allowance is 0.
  - `test_FixM03_InsufficientEngineBalance_Reverts_NoDanglingApproval` — revert is atomic, no leftover.
  - `test_FixM03_CEI_SpentTodayAlreadyUpdated_IfReentered` — state updated before external call.
  - `test_FixM03_ReadsFeeFromMarketplaceAtCallTime` — confirms dynamic fee read.

### Tests — updated
- `test/audit/v5.1-uups/token-nft/approvals/TokenApprovals.t.sol` — flipped `test_Appr_UUPS_BuybackEngine_ShortApproval_RevealsBug` → `test_Appr_UUPS_BuybackEngine_ApprovalIncludesFee_FixM03`. Same setup but now asserts success (with allowance reset) instead of revert.

### Mocks extended (4 files)
Added `BUYER_FEE_BPS() returns (0)` + `BPS_DENOMINATOR() returns (10_000)` to each mock marketplace used in existing tests, so the new BuybackEngine calls on the interface compile without changing the mocks' economic behaviour (zero fee preserves existing budget math):

- `test/mocks/MockMarketplace.sol`
- `test/functional/flows/BuybackFlow.t.sol` — `MockMarketplaceBuyback`
- `test/integration/scenarios/EmergencyResponse.t.sol` — `MockBuybackMarketplace`
- `test/simulation/AdaptiveAndMarketScenarios.t.sol` — `SimMockMarketplace`

## 3. Storage and upgrade safety

- Interface extension only — no new storage in BuybackEngine or Marketplace.
- `BUYER_FEE_BPS` and `BPS_DENOMINATOR` are already `public constant` on `LuminaBondMarketplace` (lines 38–39). The auto-generated getters already exist; we're just declaring them in our interface.
- **No Marketplace code changes required.**
- BuybackEngine storage layout unchanged.

## 4. CEI-ordering change

Before:

```solidity
usdc.forceApprove(address(marketplace), priceUSDC);
marketplace.executeBuy(listingId);       // external call
dailyConfig.spentToday += priceUSDC;     // state update AFTER
```

After:

```solidity
dailyConfig.spentToday += totalRequired; // state BEFORE external call
usdc.forceApprove(address(marketplace), totalRequired);
marketplace.executeBuy(listingId);
usdc.forceApprove(address(marketplace), 0);
```

This is a strict improvement in reentrancy posture. The `nonReentrant` modifier already blocked re-entry; now even if a future code path removes that modifier, the budget count is already incremented by the time the external call fires.

## 5. Regression

```
forge test --no-match-contract "Fork" --no-match-path "test/audit/invariant*"
```

```
Ran 114 test suites in 28.04s (145.30s CPU time): 1829 tests passed, 0 failed, 0 skipped (1829 total tests)
```

Baseline before fix was 1818. Delta = +11 new fix tests.

Previously-failing tests after applying the fix (before updating mocks) and verified-green after the mock updates:

- `test_Buyback_SuccessWithDoubleBurn`
- `test_Buyback_DailyBudgetExhausted`
- `test_Flow_Buyback_DailyBudgetRespected`
- `test_Emergency_BuybackCircuitBreaker_SkipsDoubleBurn`
- `test_DoubleBurn_AboveThreshold_Activates`
- `test_DoubleBurn_AtThreshold_Activates`
- `test_DoubleBurn_BelowThreshold_SkipsBurn`

## 6. Reverse audit

- **Code delta:** 1 src/ file, 1 method-body edit, 1 interface extension.
- **Tests delta:** 11 new + 1 flipped = 12 test surface changes.
- **Mock updates:** 4 files, 2 new view functions each (zero-valued).
- **% substantive:** 100 %. All new tests drive real `BuybackEngine` → real `LuminaBondMarketplace` → real `ClaimBond` / `BondVault` flows.
- **Quality:** 9.5/10. The fix is minimal, reads the fee from the canonical source at call time (robust to marketplace fee changes), maintains CEI ordering, and resets the approval to zero post-call.

## 7. Risk

**Low.**

- Only `BuybackEngine.executeOffer` body + a passive interface extension.
- No storage-layout modifications anywhere.
- Marketplace unchanged.
- `nonReentrant` modifier preserved.
- Mock updates are zero-economic-change (fee = 0 preserves existing test behaviour).

## 8. Verdict

**M-03 RESOLVED.** BuybackEngine.executeOffer is functional. The protocol's secondary-market-absorption mechanism now works end-to-end, with the daily budget correctly bounding the engine's total USDC outflow (including the buyer fee).
