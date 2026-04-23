# Fix M-03 — BuybackEngine Approval Includes Buyer Fee — Design

**Resolves:** audit V5.1 #20 §4.1 MEDIUM. `BuybackEngine.executeOffer` always reverted with insufficient allowance because it approved only `priceUSDC` but `Marketplace.executeBuy` pulls `priceUSDC + buyerFee` (1.5 %).
**Branch:** `fix/v5.1-buyback-approval-fee`

---

## 1. Problem

```solidity
usdc.forceApprove(address(marketplace), priceUSDC);
marketplace.executeBuy(listingId);
```

Marketplace executes:

```solidity
uint256 buyerFee = (priceUSDC * BUYER_FEE_BPS) / BPS_DENOMINATOR; // 1.5 %
uint256 totalBuyerPays = priceUSDC + buyerFee;
usdc.safeTransferFrom(msg.sender, address(this), totalBuyerPays);
```

`safeTransferFrom` fails because the approval (`priceUSDC`) is short by `buyerFee`.

## 2. Fix

1. Extend `IBuybackMarketplace` interface to expose `BUYER_FEE_BPS()` and `BPS_DENOMINATOR()` — auto-generated getters on Marketplace's public constants. No storage or signature change to Marketplace itself.

2. In `BuybackEngine.executeOffer`:
   - Read `BUYER_FEE_BPS` and `BPS_DENOMINATOR` from Marketplace.
   - Compute `buyerFee = priceUSDC * BUYER_FEE_BPS / BPS_DENOMINATOR`.
   - Compute `totalRequired = priceUSDC + buyerFee`.
   - Check `dailyConfig.spentToday + totalRequired <= dailyConfig.dailyBudget` (fee counts against budget — the engine's USDC actually spent is `totalRequired`).
   - CEI: `dailyConfig.spentToday += totalRequired` BEFORE the external call (was after).
   - `usdc.forceApprove(address(marketplace), totalRequired)` instead of `priceUSDC`.
   - Post-call `usdc.forceApprove(address(marketplace), 0)` as defense-in-depth.

3. No storage-layout change to BuybackEngine (only function body edits and interface extension — the interface is not storage).

## 3. Storage and upgrade safety

Interface extension adds view functions only — no new storage, no modified function signatures for existing calls. BuybackEngine's storage layout is untouched.

Both `BUYER_FEE_BPS` and `BPS_DENOMINATOR` are already `public constant` on Marketplace (lines 38 and 39) — so the auto-generated getters exist. No Marketplace code changes required.

## 4. Why include the fee in daily budget

The BuybackEngine's USDC wallet actually spends `priceUSDC + buyerFee`:

- `priceUSDC − sellerFee` goes to seller
- `sellerFee + buyerFee` goes to twapBurner

So the engine's outflow is `priceUSDC + buyerFee` = `totalRequired`. The "daily budget" bounds exactly this outflow, so it should count the fee. This is the semantically correct cap.

## 5. Test plan

New file: `test/audit/v5.1-uups/token-nft/approvals/FixM03BuybackApproval.t.sol`.

- `test_FixM03_ExecuteOffer_NowWorks` — the happy path. Previously reverted; now succeeds.
- `test_FixM03_ExecuteOffer_BondsTransferredThenBurned` — asserts bonds end up burned (double-burn path).
- `test_FixM03_ExecuteOffer_UsdcOutflow_IsPricePlusFee` — engine's USDC balance delta equals `priceUSDC + buyerFee`.
- `test_FixM03_DailyBudget_IncludesFee` — `dailyConfig.spentToday` after one buy is `priceUSDC + buyerFee`, not just `priceUSDC`.
- `test_FixM03_DailyBudget_ExactLimitWithFee_Succeeds` — budget exactly covers `priceUSDC + buyerFee`.
- `test_FixM03_DailyBudget_JustOverWithFee_Reverts` — budget short of the fee-inclusive total reverts with "Daily budget exceeded" BEFORE external call.
- `test_FixM03_MultipleOffers_ConsumeBudgetWithFees` — sequence of offers consume proper budget, next-over-limit reverts.
- `test_FixM03_Approval_ResetToZero_AfterExecution` — post-call allowance is zero.
- `test_FixM03_CEI_SpentTodayUpdatedBeforeExternalCall` — verified via spent-today snapshot pre-call vs post-call (or by checking a reentrant receiver scenario — the `nonReentrant` guard already handles reentry, but a belt-and-suspenders test is cheap).
- `test_FixM03_InsufficientEngineBalance_RevertsCleanly` — engine without enough USDC reverts without dangling approval.
- `test_FixM03_HighFee_StillApprovesCorrectly` — hypothetical BUYER_FEE_BPS change (tested by deploying a Marketplace with a different fee).
- `test_FixM03_ZeroFee_OnlyApprovesPrice` — BUYER_FEE_BPS=0 path.
- Update `test_Appr_UUPS_BuybackEngine_ShortApproval_RevealsBug` in `TokenApprovals.t.sol` to assert the fix: the same setup now SUCCEEDS instead of reverting.

Target: 12 new tests in the fix file + 1 flipped test in the audit file = 13 total changes.

## 6. Risk

**Low.**

- Only `BuybackEngine.executeOffer` body + `IBuybackMarketplace` interface change.
- No storage-layout modifications.
- Fee reading is defensive (reads from the actual marketplace at call time, so no drift if fees are ever reconfigured via a Marketplace upgrade).
- CEI pattern strictly improves reentrancy posture; `nonReentrant` modifier remains in place.
- Post-call `forceApprove(0)` is a defense-in-depth.
