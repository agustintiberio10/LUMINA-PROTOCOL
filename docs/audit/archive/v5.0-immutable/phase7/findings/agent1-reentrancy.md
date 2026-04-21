# Reentrancy Analysis — LUMINA Protocol V5.0

**Auditor:** Agent 1 — Reentrancy Hunter
**Date:** 2026-04-19
**Scope:** All contracts under `src/` (15 primary contracts + BaseShield abstract)
**Methodology:** Manual line-by-line review of every external call, state mutation ordering, callback surface, and ERC-1155 hook exposure.

---

## Contract: BondVault

### External Calls
- `issueBond()` L125: `priceOracle.getLuminaPrice()` (view, untrusted oracle)
- `issueBond()` L132: `lumina.balanceOf(address(this))` (view, trusted ERC-20)
- `issueBond()` L143: `claimBond.mint(to, epochId, usdPayout)` (state-changing, trusted)
- `redeemBond()` L158: `claimBond.isMatured(epochId)` (view, trusted)
- `redeemBond()` L158: `claimBond.balanceOf(msg.sender, epochId)` (view, trusted)
- `redeemBond()` L160: `_getSafePrice() -> priceOracle.getLuminaPrice()` (view)
- `redeemBond()` L169: `lumina.balanceOf(address(this))` (view)
- `redeemBond()` L179: `claimBond.burn(msg.sender, epochId, usdAmount)` (state-changing)
- `redeemBond()` L180: `lumina.transfer(msg.sender, luminaAmount)` (state-changing, LAST)
- `triggerBreaker()` L193: `priceOracle.getLuminaPrice()` (view)
- `resetCircuitBreaker()` L205: `priceOracle.getLuminaPrice()` (view)
- `decreaseObligations()` L282: none (pure state mutation)
- `burnFromReserves()` L291-296: `lumina.balanceOf(address(this))` (view), `IBurnable(lumina).burn(amount)` (state-changing)

### ReentrancyGuard: YES
- `issueBond()`: `nonReentrant`
- `redeemBond()`: `nonReentrant`
- `decreaseObligations()`, `burnFromReserves()`: **NOT protected by nonReentrant** (protected by `onlyAuthorized` modifier instead)

### CEI Pattern: Partially Followed
- `issueBond()`: **VIOLATED** -- `totalCommittedUSD` is updated (Effect) at L141 BEFORE the external call to `claimBond.mint()` at L143. This is actually correct CEI order (Effects before Interactions). SAFE.
- `redeemBond()`: **FOLLOWED** -- `totalCommittedUSD` is decremented (L172-177), then `claimBond.burn()` (L179), then `lumina.transfer()` (L180). State changes happen before external calls. However, `lumina.transfer()` to `msg.sender` is last, which is correct.

### ERC-1155 Hook Risk
- `claimBond.mint()` internally calls `_mint()` which triggers `onERC1155Received` on the recipient (`to`). If `to` is a contract, it could re-enter. However, `issueBond()` is protected by `nonReentrant`, so re-entry into `issueBond()` or `redeemBond()` is blocked. The `to` address is set by PolicyManager (trusted), and the recipient is the policy buyer.
- `claimBond.burn()` in `redeemBond()` does NOT trigger callbacks (ERC-1155 `_burn` has no receiver hook).

### Potential Attack Paths
1. **Oracle manipulation via re-entry**: If `priceOracle` is a malicious contract, it could attempt re-entry during `getLuminaPrice()`. However, the oracle is immutable and set at construction. `nonReentrant` blocks re-entry anyway.
2. **ERC-1155 mint callback**: A malicious contract at `to` could receive the `onERC1155Received` callback during `claimBond.mint()`. Under `nonReentrant`, re-entry into BondVault is blocked. Cross-contract re-entry into other unprotected functions (e.g., `decreaseObligations`) requires `onlyAuthorized` — not exploitable without authorization.
3. **`decreaseObligations` / `burnFromReserves` lack `nonReentrant`**: These are only callable by `authorizedCallers`. If BuybackEngine (the authorized caller) were compromised, it could chain calls — but each call is atomic and idempotent. The `burnFromReserves` 5% cap per TX also limits blast radius.

### Verdict: SAFE
The combination of `nonReentrant` on user-facing functions and `onlyAuthorized` on admin functions provides adequate protection. CEI is followed on critical paths.

---

## Contract: ClaimBond

### External Calls
- `mint()` L65: `_mint(to, epochId, usdAmount, "")` — internal ERC-1155 mint, triggers `onERC1155Received` on `to` if `to` is a contract
- `burn()` L71: `_burn(from, epochId, usdAmount)` — internal, no callback
- `burnByHolder()` L82: `_burn(account, epochId, amount)` — internal, no callback
- No external calls to other contracts

### ReentrancyGuard: NO
- ClaimBond relies on `onlyBondVault` modifier for mint/burn. The BondVault itself has `nonReentrant`.

### CEI Pattern: Followed
- `mint()`: epoch creation (Effect) happens before `_mint()` (Interaction). Correct.
- `burnByHolder()`: balance check (Check) before `_burn()` (Interaction). Correct.

### ERC-1155 Hook Risk
- **`_mint()` triggers `onERC1155Received`** on the recipient. Since only BondVault can call `mint()`, and BondVault's `issueBond()` is `nonReentrant`, re-entry into the BondVault is blocked. However, there is NO re-entry guard on ClaimBond itself. A re-entrant `onERC1155Received` callback could call `burnByHolder()` on the just-minted tokens — but since this is the holder burning their own tokens, the impact is self-harm only (the holder destroys their own bonds).
- **`safeTransferFrom`** (inherited from ERC-1155) also triggers `onERC1155Received`. LuminaBondMarketplace calls this. The marketplace has its own `nonReentrant`.

### Potential Attack Paths
1. **Frontrunning `setBondVault()`**: Mitigated by `onlyOwner` modifier (documented as [V1/SR2]).
2. **Re-entrant `burnByHolder` via mint callback**: Self-harm only; no protocol impact.

### Verdict: SAFE

---

## Contract: LuminaTokenV2

### External Calls
- None beyond inherited ERC-20 `_transfer`, `_burn`, `_approve` (all internal)

### ReentrancyGuard: NO
- Not needed: no external calls, no callbacks. Pure ERC-20 + AccessControl.

### CEI Pattern: N/A
- No external interactions.

### ERC-1155 Hook Risk: N/A
- This is ERC-20, not ERC-1155.

### Potential Attack Paths
- `burnFrom()` is `onlyRole(BURNER_ROLE)`. No re-entry surface.
- Standard ERC-20 approve/transferFrom race condition exists but is inherent to ERC-20 and not a re-entry issue.

### Verdict: SAFE

---

## Contract: TWAPBurner

### External Calls
- `receivePremium()` L118: `usdc.safeTransferFrom(msg.sender, ...)` (ERC-20, no callback)
- `receiveMarketplaceFee()` L125: `usdc.safeTransferFrom(msg.sender, ...)` (ERC-20, no callback)
- `executeBurn()` calls `_executeAdaptive()` or `_executeLegacyBurn()`:
  - `_executeAdaptive()` L163-170: `usdc.safeTransfer()` to buybackReserve, opsReserve, maintenanceReserve
  - `_swapAndBurn()` L208: `usdc.forceApprove(swapRouter, ...)`
  - `_swapAndBurn()` L220: `swapRouter.exactInputSingle(...)` — **external call to Uniswap V3 router** (untrusted in theory but immutable)
  - `_swapAndBurn()` L233: `IBurnable(lumina).burn(luminaReceived)` — state-changing
  - `_getDistribution()` L191-199: `IAdaptiveFeeDistributor.isHealthy()` and `getDistribution()` — view calls
  - `_swapAndBurn()` L212: `IPriceOracle(capacityOracle).getLuminaPrice()` — view call
- `recoverToken()` L359: `IERC20(token).safeTransfer(owner(), amount)` — transfers arbitrary ERC-20

### ReentrancyGuard: YES
- `executeBurn()`: `nonReentrant`
- `receivePremium()`, `receiveMarketplaceFee()`: **NOT protected by nonReentrant**

### CEI Pattern: Partially Followed
- `executeBurn()`: `lastBurnTimestamp` updated (Effect, L141) BEFORE external calls (Interactions in `_swapAndBurn`). Correct CEI.
- `_swapAndBurn()`: `totalUSDCBurned` and `totalLUMINABurned` updated AFTER `swapRouter.exactInputSingle()` and `burn()`. This is technically Effects-after-Interactions, **BUT** the function is within a `nonReentrant` guard, so re-entry is blocked.
- `receivePremium()` / `receiveMarketplaceFee()`: `totalUSDCReceived` updated AFTER `safeTransferFrom()`. Since USDC is not an ERC-777 (no callbacks), this is safe. However, if a non-standard ERC-20 with transfer hooks were used in place of USDC, this could be vulnerable. Mitigated by USDC being immutable.

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
1. **Uniswap router callback**: The Uniswap V3 `exactInputSingle` does not have a user-controlled callback in the single-hop path. No re-entry vector.
2. **Flash loan + `executeBurn` sandwich**: An attacker could sandwich the `executeBurn()` call to extract MEV from the swap. The `maxSlippageBps` (5%) and oracle-based `amountOutMinimum` mitigate this. Not a re-entry issue.
3. **`receivePremium` lacks `nonReentrant`**: If called with a token that has transfer hooks (not USDC), re-entry into `receivePremium` could inflate `totalUSDCReceived`. Mitigated by `usdc` being immutable and standard USDC having no hooks.

### Verdict: SAFE (with note on `receivePremium`/`receiveMarketplaceFee` lacking `nonReentrant` — low risk given USDC immutability)

---

## Contract: CoverRouterV2

### External Calls
- `_purchase()` L154: `usdc.safeTransferFrom(payer, address(this), premium)` (ERC-20)
- `_purchase()` L158: `usdc.forceApprove(address(twapBurner), premium)` (ERC-20)
- `_purchase()` L159: `twapBurner.receivePremium(premium)` — external call to TWAPBurner
- `_purchase()` L162: `policyManager.recordPolicy(...)` — external call to PolicyManagerV2
- `submitTrigger()` L133: `policyManager.triggerPayout(...)` — external call to PolicyManagerV2

### ReentrancyGuard: YES
- `purchasePolicy()`: `nonReentrant`
- `purchasePolicyFor()`: `nonReentrant`
- `submitTrigger()`: `nonReentrant`

### CEI Pattern: Followed
- `_purchase()`: No state mutations in CoverRouterV2 — all state is managed by TWAPBurner and PolicyManager. The function is essentially a pass-through router. No Effects to order.
- `submitTrigger()`: Pure pass-through to PolicyManager. No state.

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
1. **Cross-contract re-entry via `policyManager.recordPolicy()`**: `recordPolicy()` calls `IShieldV2.createPolicy()` which calls `_mint()` on BaseShield (no ERC-1155 mint — it's internal storage). No callback surface.
2. **Premium manipulation**: Premium is calculated deterministically from on-chain config. No oracle dependency here.

### Verdict: SAFE

---

## Contract: PolicyManagerV2

### External Calls
- `recordPolicy()` L158: `bondVault.availableCapacityUSD()` — view call
- `recordPolicy()` L168: `IShieldV2(shield).createPolicy(...)` — state-changing, external to Shield
- `triggerPayout()` L225: `IShieldV2(shield).verifyAndCalculate(policyId, oracleProof)` — state-changing
- `triggerPayout()` L228: `bondVault.issueBond(pr.buyer, payoutUSD)` — state-changing
- `markExpired()`: No external calls

### ReentrancyGuard: **NO**
- PolicyManagerV2 does NOT inherit ReentrancyGuard.

### CEI Pattern: Partially Followed
- `recordPolicy()` L163-164: Counters incremented (Effect) BEFORE `shield.createPolicy()` (Interaction). Comment at L161 explicitly notes this as "[M-1] CEI". However, `policies[productId][policyId]` mapping is written AFTER the external call (L184), which is an Effect after Interaction. This is documented: "must happen after external call to obtain policyId". This is acceptable because the `policyId` is needed as a key.
- `triggerPayout()` L214-221: Effects (`pr.triggered = true`, counter updates) happen BEFORE Interactions (`shield.verifyAndCalculate`, `bondVault.issueBond`). Explicitly noted as "[M-1] CEI: effects BEFORE interactions". Correct.

### ERC-1155 Hook Risk: Indirect
- `bondVault.issueBond()` leads to `claimBond.mint()` which triggers `onERC1155Received`. However, PolicyManagerV2's functions are gated by `onlyRouter`, so even if re-entry occurred, the attacker would need to call through CoverRouterV2 (which has `nonReentrant`).

### Potential Attack Paths
1. **Missing `nonReentrant` on PolicyManagerV2**: If a malicious Shield contract were registered, its `createPolicy()` or `verifyAndCalculate()` could re-enter `PolicyManagerV2`. However, shield registration is `onlyOwner`, and re-entry into `recordPolicy`/`triggerPayout` requires `onlyRouter` (CoverRouterV2 which is `nonReentrant`). Cross-function re-entry (e.g., `recordPolicy` -> malicious shield -> `markExpired`) is theoretically possible if the Shield calls back, but `markExpired()` is permissionless and checks `block.timestamp > expiresAt`, which would fail for a just-created policy.
2. **`markExpired` is permissionless**: Anyone can call it for any policy past expiry. This is by design and not an attack vector (it only decrements `activePolicies`). However, double-call is prevented by `require(!pr.expired)`.

### Verdict: **LOW RISK** — Missing `nonReentrant` is mitigated by `onlyRouter` gating (CoverRouterV2 has `nonReentrant`). A malicious registered Shield could theoretically exploit cross-function re-entry, but Shield registration is owner-only.

---

## Contract: BuybackEngine

### External Calls
- `executeOffer()` L118: `marketplace.getListing(listingId)` — view call
- `executeOffer()` L123: `claimBond.getFaceValue(epochId)` — view call
- `executeOffer()` L127: `usdc.forceApprove(marketplace, priceUSDC)` — ERC-20
- `executeOffer()` L128: `marketplace.executeBuy(listingId)` — **state-changing, external**. This triggers ERC-1155 `safeTransferFrom` which calls `onERC1155Received` on BuybackEngine.
- `_executeDoubleBurn()` L136: `claimBond.burnByHolder(address(this), epochId, amount)` — state-changing
- `_executeDoubleBurn()` L137: `bondVault.decreaseObligations(faceValueUSD)` — state-changing
- `_executeDoubleBurn()` L139: `solvencyOracle.getSolvencyRatio()` — view call
- `_executeDoubleBurn()` L141: `capacityOracle.getLuminaPrice()` — view call
- `_executeDoubleBurn()` L143: `bondVault.burnFromReserves(luminaToBurn)` — state-changing

### ReentrancyGuard: YES
- `executeOffer()`: `nonReentrant`

### CEI Pattern: Partially Followed
- `executeOffer()`: `dailyConfig.spentToday` is updated (L129, Effect) AFTER `marketplace.executeBuy()` (L128, Interaction). This is **Effects after Interactions**. However, `nonReentrant` prevents re-entry.
- `_executeDoubleBurn()`: Multiple external calls in sequence. No state variables in BuybackEngine are mutated within `_executeDoubleBurn` — all mutations are in external contracts (BondVault). Safe within `nonReentrant`.

### ERC-1155 Hook Risk: **PRESENT BUT MITIGATED**
- BuybackEngine extends `ERC1155Holder`, so it receives `onERC1155Received` callbacks. When `marketplace.executeBuy()` transfers bonds to BuybackEngine, the `onERC1155Received` is called. If the marketplace or ClaimBond contract were malicious, this callback could attempt re-entry. However, `nonReentrant` on `executeOffer()` blocks this.

### Potential Attack Paths
1. **Cross-contract re-entry via marketplace**: `marketplace.executeBuy()` calls `claimBond.safeTransferFrom()` which calls `onERC1155Received` on BuybackEngine. Under `nonReentrant`, this cannot re-enter `executeOffer`. However, it could call other BuybackEngine functions — but all state-changing functions require `BUYBACK_OPERATOR_ROLE` or `nonReentrant`.
2. **`dailyConfig.spentToday` updated after external call**: If `nonReentrant` were absent, an attacker could re-enter `executeOffer` before `spentToday` is incremented, bypassing the daily budget. The `nonReentrant` modifier prevents this.

### Verdict: SAFE (relies on `nonReentrant` for correctness of `spentToday` accounting)

---

## Contract: LuminaBondMarketplace

### External Calls
- `list()` L92: `claimBond.safeTransferFrom(msg.sender, address(this), ...)` — ERC-1155 transfer IN (triggers `onERC1155Received` on marketplace — marketplace extends `ERC1155Holder`)
- `cancel()` L102: `claimBond.safeTransferFrom(address(this), l.seller, ...)` — ERC-1155 transfer OUT (triggers `onERC1155Received` on `l.seller` if contract)
- `executeBuy()` L117: `usdc.safeTransferFrom(msg.sender, address(this), totalBuyerPays)` — ERC-20
- `executeBuy()` L118: `usdc.safeTransfer(l.seller, sellerReceives)` — ERC-20
- `executeBuy()` L119: `usdc.safeTransfer(twapBurner, sellerFee + buyerFee)` — ERC-20
- `executeBuy()` L121: `claimBond.safeTransferFrom(address(this), msg.sender, ...)` — ERC-1155 transfer OUT

### ReentrancyGuard: YES
- `list()`: `nonReentrant`
- `cancel()`: `nonReentrant`
- `executeBuy()`: `nonReentrant`

### CEI Pattern: Followed
- `list()`: Listing created in storage (Effect, L83-89) BEFORE `claimBond.safeTransferFrom` (Interaction, L92). Correct.
- `cancel()`: `l.active = false` (Effect, L101) BEFORE `claimBond.safeTransferFrom` (Interaction, L102). Correct.
- `executeBuy()`: `l.active = false` (Effect, L110) BEFORE all transfers (Interactions, L117-121). Correct.

### ERC-1155 Hook Risk: **PRESENT BUT MITIGATED**
- `list()`: `safeTransferFrom` triggers `onERC1155Received` on the marketplace itself (since marketplace extends `ERC1155Holder`). The default `ERC1155Holder` implementation just returns the selector. No re-entry vector.
- `cancel()` and `executeBuy()`: `safeTransferFrom` to `l.seller` or `msg.sender`. If the buyer/seller is a contract, `onERC1155Received` fires. Under `nonReentrant`, re-entry into marketplace functions is blocked.
- **CEI + nonReentrant double protection**: `l.active = false` before transfers means even without `nonReentrant`, a re-entrant call to `cancel()` or `executeBuy()` for the same listing would fail at `require(l.active)`.

### Potential Attack Paths
1. **Listing manipulation via re-entry**: A seller contract could receive the `onERC1155Received` callback during `cancel()` and attempt to re-list or call `executeBuy`. Blocked by `nonReentrant`.
2. **USDC transfer to malicious seller**: `usdc.safeTransfer(l.seller, ...)` could fail if seller is a blacklisted USDC address. This is not re-entry but a DoS — seller's listing becomes unexecutable. The seller can still `cancel()`.

### Verdict: SAFE

---

## Contract: CapacityOracle

### External Calls
- `getLuminaPrice()` L76: `this._getTwapPrice()` — self-call (try/catch pattern)
- `_getTwapPrice()` L89: `IUniswapV3Pool(pool).observe(secondsAgos)` — view call to Uniswap pool
- `getTWAP()` L136: `IUniswapV3Pool(pool).observe(sAgos)` — view call
- `_setPool()` L201: `IUniswapV3Pool(_pool).token0()` — view call
- `maxPoliciesPerDay()` L166: `this.getLuminaPrice()` — self-call

### ReentrancyGuard: NO
- Not needed: all external calls are view-only. No state mutations depend on external return values in an exploitable way.

### CEI Pattern: N/A
- No state mutations interleaved with external calls (admin setters are simple assignments).

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
- `pool` is mutable (owner can change it). A malicious pool could return manipulated tick data, affecting TWAP price. This is an oracle manipulation risk, not a re-entry risk.

### Verdict: SAFE

---

## Contract: SolvencyOracle

### External Calls
- `evaluate()` L61: `_calculateSolvencyRatio()` which calls:
  - L111: `bondVault.totalCommittedUSD()` — view
  - L113: `lumina.balanceOf(address(bondVault))` — view
  - L114: `capacityOracle.getLuminaPrice()` — view
- `isHealthy()` L103: `capacityOracle.getLuminaPrice()` — view

### ReentrancyGuard: NO
- Not needed: `evaluate()` mutates internal state only (history arrays, quadrant levels). All external calls are view-only and happen within `_calculateSolvencyRatio()` (internal).

### CEI Pattern: Followed
- `evaluate()`: External view calls first, then state mutations. All state writes happen after the view calls.

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
- Manipulated oracle prices could cause incorrect quadrant transitions. Cooldown of 7 days between quadrant changes mitigates rapid flipping.

### Verdict: SAFE

---

## Contract: CEXLiquidityReserve

### External Calls
- `allocate()` L98: `lumina.safeTransfer(recipient, amount)` — ERC-20 transfer (LAST operation)

### ReentrancyGuard: YES
- `allocate()`: `nonReentrant`

### CEI Pattern: Followed
- `allocate()`: All state mutations (sub-bucket tracking, monthly allocations, history push) happen at L82-97 (Effects) BEFORE `lumina.safeTransfer` at L98 (Interaction). Correct CEI.

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
- None. `onlyRole(ALLOCATOR_ROLE)` + `nonReentrant` + CEI = comprehensive protection.

### Verdict: SAFE

---

## Contract: MaintenanceReserve

### External Calls
- `spend()` L98: `usdc.safeTransfer(recipient, amount)` — ERC-20 transfer (LAST operation)
- `recoverToken()` L154: `IERC20(token).safeTransfer(msg.sender, amount)` — arbitrary ERC-20

### ReentrancyGuard: YES
- `spend()`: `nonReentrant`
- `recoverToken()`: NOT protected by `nonReentrant` (but gated by `DEFAULT_ADMIN_ROLE`)

### CEI Pattern: Followed
- `spend()`: State mutations (`currentMonthSpent`, `totalSpent`, `spendHistory.push`) at L89-96 (Effects) BEFORE `usdc.safeTransfer` at L98 (Interaction). Correct CEI.

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
1. **`recoverToken` with malicious ERC-20**: A token with transfer hooks could re-enter `recoverToken`. However, `onlyRole(DEFAULT_ADMIN_ROLE)` limits this to the multisig. Re-entering `recoverToken` with the same token would transfer more tokens — bounded by the contract's actual balance. Low risk.

### Verdict: SAFE

---

## Contract: AdaptiveFeeDistributor

### External Calls
- `getDistribution()` L24: `solvencyOracle.getCurrentQuadrant()` — view call
- `isHealthy()` L29: `solvencyOracle.isHealthy()` — view call

### ReentrancyGuard: NO
- Not needed: pure view functions with no state mutations.

### CEI Pattern: N/A
- No state mutations. No admin functions. Fully immutable after deployment.

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
- None. This contract has zero mutable state and no admin surface.

### Verdict: SAFE

---

## Contract: FounderVesting

### External Calls
- `checkAltSeason()` L98: `_evaluateConditions()` which calls:
  - L189: `oracle.getLatestPrice(bytes32("ETH"))` — view
  - L190: `oracle.getLatestPrice(bytes32("BTC"))` — view
  - L199: `IAaveV3PoolReader(aavePool).getReserveData(usdc)` — view
- `releaseTranche()` L145: `luminaToken.transfer(recipient, amount)` — ERC-20 transfer

### ReentrancyGuard: NO

### CEI Pattern: Followed
- `checkAltSeason()`: View calls first, then state mutations (`conditionsMetSince`, `altSeasonTriggered`, `triggerTimestamp`). Correct.
- `releaseTranche()`: State mutations (`tranchesReleased++`, `totalReleased += amount`) at L139-142 BEFORE `luminaToken.transfer()` at L145. Correct CEI.

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
1. **Missing `nonReentrant` on `releaseTranche()`**: If `luminaToken` were a token with transfer hooks, a re-entrant call could invoke `releaseTranche()` again. However, CEI is followed: `tranchesReleased` is incremented before the transfer, so the re-entrant call would attempt the next tranche (or fail if `block.timestamp < releaseTime`). The tranche timing requirement (`triggerTimestamp + (nextTranche * 31 days)`) prevents immediate re-entry exploitation.
2. **Permissionless `checkAltSeason()`**: Anyone can call. By design — it only reads oracle prices and updates internal state. Cannot be exploited via re-entry.

### Verdict: SAFE (CEI ordering prevents exploitation despite missing `nonReentrant`)

---

## Contract: TreasuryVesting

### External Calls
- `release()` L52: `luminaToken.transfer(to, amount)` — ERC-20 transfer

### ReentrancyGuard: NO

### CEI Pattern: Followed
- `release()`: `lastReleaseMonth` and `totalReleased` updated (L49-50, Effects) BEFORE `luminaToken.transfer()` (L52, Interaction). Correct CEI.

### ERC-1155 Hook Risk: N/A

### Potential Attack Paths
1. **Missing `nonReentrant` on `release()`**: Similar to FounderVesting — if the token had transfer hooks, re-entry could occur. CEI is followed: `totalReleased` and `lastReleaseMonth` are updated before transfer. A re-entrant call would fail at `require(currentMonth > lastReleaseMonth || totalReleased == 0)` since `lastReleaseMonth` was just set to `currentMonth`.
2. **`onlyOwner` gate**: Owner is the Gnosis Safe. Only the multisig can call `release()`.

### Verdict: SAFE

---

## Contract: BaseShield (Abstract — inherited by all Shield products)

### External Calls
- `createPolicy()` L110: `this.durationRange()` — self-call (external to read immutable)
- `createPolicy()` L150: `_doCreatePolicy()` — internal virtual, no external call
- `verifyAndCalculate()` L185: `_doVerifyAndCalculate()` — internal virtual, MAY make external oracle calls in concrete implementations
- `_verifyOracleSignature()` L329-330: `IOracle(oracle).verifySignature()`, `IOracle(oracle).oracleKey()` — view calls
- `_verifyPriceProofEIP712()` L352: `IOracleV2(oracle).verifyPriceProofEIP712()` — view call
- `_validateStatusForTrigger()` L443: `IOracle(oracle).getSequencerDowntime()` — view call

### ReentrancyGuard: NO
- BaseShield relies on CoverRouterV2's `nonReentrant` (since only the router can call lifecycle functions via `onlyRouter`).

### CEI Pattern: Followed
- `createPolicy()`: Counter increment and storage write (L121-147, Effects) BEFORE emitting event. No state-dependent external call.
- `verifyAndCalculate()`: No state mutations in BaseShield — only reads. `_doVerifyAndCalculate` is delegated to concrete shields.
- `markPaidOut()` / `markExpired()`: State mutations (`finalized`, `finalStatus`, counter decrements) happen before the `_afterFinalize` hook (which is a no-op in base). Correct CEI.

### ERC-1155 Hook Risk: N/A
- BaseShield does not use ERC-1155. Policies are stored in internal mappings.

### Potential Attack Paths
- None from BaseShield itself. Concrete Shield implementations that override `_doVerifyAndCalculate()` could introduce re-entry if they make external calls, but the `onlyRouter` guard (backed by CoverRouterV2's `nonReentrant`) prevents this.

### Verdict: SAFE

---

# Summary Matrix

| Contract | ReentrancyGuard | CEI | ERC-1155 Hooks | Verdict |
|---|---|---|---|---|
| BondVault | YES (partial) | Followed | Indirect via ClaimBond.mint | SAFE |
| ClaimBond | NO | Followed | YES (mint callback) | SAFE |
| LuminaTokenV2 | NO | N/A | N/A | SAFE |
| TWAPBurner | YES (partial) | Partially | N/A | SAFE |
| CoverRouterV2 | YES | Followed | N/A | SAFE |
| PolicyManagerV2 | **NO** | Partially | Indirect | **LOW RISK** |
| BuybackEngine | YES | Partially | YES (ERC1155Holder) | SAFE |
| LuminaBondMarketplace | YES | Followed | YES (ERC1155Holder) | SAFE |
| CapacityOracle | NO | N/A | N/A | SAFE |
| SolvencyOracle | NO | Followed | N/A | SAFE |
| CEXLiquidityReserve | YES | Followed | N/A | SAFE |
| MaintenanceReserve | YES (partial) | Followed | N/A | SAFE |
| AdaptiveFeeDistributor | NO | N/A | N/A | SAFE |
| FounderVesting | NO | Followed | N/A | SAFE |
| TreasuryVesting | NO | Followed | N/A | SAFE |
| BaseShield | NO | Followed | N/A | SAFE |

---

# Key Findings

### Finding R-1: PolicyManagerV2 Missing ReentrancyGuard (LOW)
**Severity:** Low
**Location:** `src/core/PolicyManagerV2.sol`
**Description:** PolicyManagerV2 has no `ReentrancyGuard`. It makes external calls to Shield contracts (`createPolicy`, `verifyAndCalculate`) and BondVault (`issueBond`, `availableCapacityUSD`). While all entry points are gated by `onlyRouter` (backed by CoverRouterV2's `nonReentrant`), a malicious registered Shield could theoretically exploit cross-function re-entry into `markExpired()` (which is permissionless).
**Recommendation:** Add `ReentrancyGuard` to PolicyManagerV2 or add `nonReentrant` to `markExpired()`. Alternatively, restrict `markExpired()` to `onlyRouter`.

### Finding R-2: BondVault `decreaseObligations` / `burnFromReserves` Lack nonReentrant (INFO)
**Severity:** Informational
**Location:** `src/bonds/BondVault.sol` L279, L288
**Description:** These functions lack `nonReentrant` but are protected by `onlyAuthorized`. If the authorized caller (BuybackEngine) were to be exploited, chained calls are possible but bounded by the 5% per-TX cap on `burnFromReserves`.
**Recommendation:** Consider adding `nonReentrant` for defense-in-depth.

### Finding R-3: TWAPBurner `receivePremium`/`receiveMarketplaceFee` Lack nonReentrant (INFO)
**Severity:** Informational
**Location:** `src/core/TWAPBurner.sol` L113, L122
**Description:** These functions update `totalUSDCReceived` after `safeTransferFrom`. Since USDC has no transfer hooks, this is safe. However, if the protocol ever migrates to a different payment token with hooks, this could become exploitable.
**Recommendation:** Add `nonReentrant` for future-proofing, or document the USDC-only assumption.

### Finding R-4: CEI Violation in BuybackEngine `executeOffer` (INFO)
**Severity:** Informational
**Location:** `src/marketplace/BuybackEngine.sol` L129
**Description:** `dailyConfig.spentToday` is updated after the external call to `marketplace.executeBuy()`. This is protected by `nonReentrant`, making it unexploitable, but violates the CEI principle.
**Recommendation:** Move `dailyConfig.spentToday += priceUSDC` before `marketplace.executeBuy(listingId)`.
