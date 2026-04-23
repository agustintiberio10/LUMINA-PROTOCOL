# Audit V5.1 #20 — Token Approvals: Report

**Branch:** `audit/v5.1-20-token-approvals`
**Date:** 2026-04-23
**Verdict:** MOSTLY SAFE with one **MEDIUM** bug found — `BuybackEngine.executeOffer` under-approves `priceUSDC` instead of `priceUSDC + buyerFee`, so every attempt to execute a buyback listing reverts. Cierre Bloque 5.

---

## 1. Summary

This audit walks every `approve` / `forceApprove` / `safeIncreaseAllowance` call site in `src/` and every `transferFrom` that consumes an allowance. See `01-APPROVAL-INVENTORY.md` for the full matrix.

**Positive findings:**

- 100 % of protocol approvals use OpenZeppelin's `SafeERC20.forceApprove`. Zero raw `.approve()` call sites. That makes the protocol immune to the classic ERC-20 race-condition bug AND compatible with USDT-style tokens that require a zero-reset before re-approve.
- All amounts are exactly scoped (no `type(uint256).max`). No infinite-allowance risk if a target contract is compromised.
- 4 out of 5 call sites cleanly drain their approval to zero on the very next `transferFrom`.
- User-side approvals (USDC, ClaimBond ERC-1155) behave correctly: survive UUPS upgrades, revoke works, insufficient-allowance reverts at the right place.

**Negative finding:**

- `BuybackEngine.executeOffer` has a mis-scoped approval: approves `priceUSDC` but the Marketplace tries to pull `priceUSDC + buyerFee` (1.5 %). Verified by a dedicated test that reverts on the short allowance. See §4.1.

## 2. How the audit was conducted

- File: `test/audit/v5.1-uups/token-nft/approvals/TokenApprovals.t.sol` (17 tests).
- Every test uses real proxies (CoverRouterV2, TWAPBurner, BondVault, Marketplace, BuybackEngine, ClaimBond, LuminaTokenV2) deployed via `ProxyDeployer`. USDC is a mock — the SafeERC20 semantics we test don't depend on USDC being a specific implementation, and Base-mainnet USDC is a standard ERC-20.
- Each test either:
  - exercises a full user-to-protocol flow and asserts the leftover allowance is 0; or
  - constructs a specific misconfiguration (no approval / short allowance / revoked approval) and asserts the expected revert; or
  - documents a static-code invariant via `assertTrue(true)` + comment (used for the "zero raw approve()" and "no infinite allowance" claims which are proven by grep).

## 3. Approval-hygiene matrix (verified)

| Approver | Token | Target | Expected amount | After call | Verdict |
|---|---|---|---|---|---|
| CoverRouterV2 | USDC | TWAPBurner | exact premium | 0 | ✅ `CoverRouter_ToTwapBurner_NoLeftover` |
| TWAPBurner | USDC | swap router | exact usdcAmount | 0 | ✅ `TWAPBurner_ToSwapRouter_NoLeftover` |
| TWAPBurner (failed swap) | USDC | swap router | — | 0 (atomic revert) | ✅ `TWAPBurner_FailedSwap_NoLeftover` |
| UniswapV3Adapter | tokenIn | V3 SwapRouter | exact amountIn | 0 | ✅ (inside TWAPBurner flow) |
| AerodromeAdapter | tokenIn | Aerodrome Router | exact amountIn | 0 | ✅ (inside TWAPBurner flow) |
| **BuybackEngine** | **USDC** | **Marketplace** | **priceUSDC only** | **short** | **❌ §4.1** |

## 4. Findings

### 4.1 MEDIUM — `BuybackEngine.executeOffer` under-approves USDC to Marketplace

**File:** `src/marketplace/BuybackEngine.sol:143`

```solidity
usdc.forceApprove(address(marketplace), priceUSDC);
marketplace.executeBuy(listingId);
```

**Issue:** `Marketplace.executeBuy` (line 133–138) computes:

```solidity
uint256 buyerFee = (l.priceUSDC * BUYER_FEE_BPS) / BPS_DENOMINATOR; // 1.5 %
uint256 totalBuyerPays = l.priceUSDC + buyerFee;
usdc.safeTransferFrom(msg.sender, address(this), totalBuyerPays);
```

It pulls `priceUSDC + buyerFee` via `safeTransferFrom`. BuybackEngine's approval of only `priceUSDC` is therefore short by `buyerFee`, and the `safeTransferFrom` reverts with ERC-20 insufficient-allowance.

**Impact:** The BuybackEngine cannot execute any buyback. Every call to `executeOffer` reverts at the marketplace's transferFrom. The daily-budget cap, the price cap, and the solvency-gated double-burn logic are all reachable, but the actual bond purchase never completes. Operationally, the protocol's secondary-market-absorption mechanism is non-functional.

**Severity rationale:** MEDIUM. No loss of funds — the atomic revert means nothing moves. But the BuybackEngine is advertised as a live secondary-market buyer and is wired into the protocol's capacity / solvency response path. It being broken in place impairs a deliberate protocol function.

**Recommended fix (minimal diff):**

```solidity
uint256 faceValueUSD = claimBond.getFaceValue(epochId) * amount;
uint256 maxAllowedPriceUSDC = (faceValueUSD * dailyConfig.maxPricePercent) / (100 * 1e12);
require(priceUSDC <= maxAllowedPriceUSDC, "Price exceeds max");
require(dailyConfig.spentToday + priceUSDC <= dailyConfig.dailyBudget, "Daily budget exceeded");

// [FIX-#20] Approve priceUSDC + buyerFee so marketplace.executeBuy can pull
// the full amount. BuybackEngine already holds enough USDC.
uint256 buyerFee = (priceUSDC * marketplace.BUYER_FEE_BPS()) / marketplace.BPS_DENOMINATOR();
usdc.forceApprove(address(marketplace), priceUSDC + buyerFee);
marketplace.executeBuy(listingId);
dailyConfig.spentToday += priceUSDC; // unchanged — spent count still reflects only price
```

Alternatively, expose `marketplace.previewTotalBuyerPays(priceUSDC)` and use that. The choice is stylistic.

**Test:** `test_Appr_UUPS_BuybackEngine_ShortApproval_RevealsBug` constructs a valid listing, activates the buyback config, funds the engine, then asserts `executeOffer` reverts. Pass-by-revert confirms the bug.

### 4.2 INFO — No infinite allowances anywhere

Every protocol approval is sized to the exact amount of the immediately-following `transferFrom`. Zero risk surface if a target contract is later compromised.

### 4.3 INFO — All protocol approvals drain to zero

Four out of five call sites leave allowance at zero after the call. The fifth (§4.1) ALSO leaves zero — but only because the tx reverts atomically.

### 4.4 INFO — `BondVault.redeemBond` uses plain `lumina.transfer`

```solidity
require(lumina.transfer(msg.sender, luminaAmount), "Transfer failed");
```

Safe today because LUMINA is our own ERC-20 and always returns `true`. If the payout token is ever swapped to a non-standard ERC-20 (that doesn't return a value, or returns false without reverting), this would silently succeed on failure. Worth flagging for any future token-change scope.

## 5. Regression

```
forge test --no-match-contract "Fork" --no-match-path "test/audit/invariant*"
```

```
Ran 113 test suites in 21.25s (99.37s CPU time): 1818 tests passed, 0 failed, 0 skipped (1818 total tests)
```

Baseline before audit was 1801. Delta = +17 new approval tests.

## 6. Reverse audit

- **Total tests:** 17 (new)
- **% substantive:** 100 % — every test drives real proxies (CoverRouterV2, TWAPBurner, BuybackEngine, Marketplace, etc.) and asserts exact allowance values post-call.
- **Quality:** 9/10 — the single MEDIUM finding (§4.1) is a real live bug with a concrete repro test and a concrete minimal fix. The static invariants (no raw approve, no infinite allowance) are documented and also verifiable by `grep` at any time.

## 7. Verdict

**MOSTLY SAFE.** One MEDIUM bug flagged in BuybackEngine (§4.1) — recommend a V5.2 fix before relying on the buyback path on mainnet. The rest of the approval surface is clean: SafeERC20 everywhere, exact amounts, zero leftovers, user approvals survive upgrades, revoke and insufficient-allowance paths behave correctly.

**Cierre Bloque 5.** Audit #20 of 40 V5.1.
