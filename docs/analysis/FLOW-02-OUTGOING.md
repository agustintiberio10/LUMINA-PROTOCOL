# FLOW-02 — Outgoing Fund Destinations

Every path by which USDC or LUMINA leaves the protocol's contracts.

---

## 1. Bond redemption (LUMINA → holder)

| Field | Value |
|---|---|
| Recipient | Bond holder |
| Token | LUMINA |
| Source contract | `BondVault` |
| Function | `redeemBond(epochId, usdAmount)` |
| Amount formula | `luminaAmount = usdAmount × 1e36 / currentPrice` |

**Evidence:** `src/bonds/BondVault.sol:187-211`:
```solidity
function redeemBond(uint256 epochId, uint256 usdAmount) external nonReentrant {
    require(usdAmount > 0, "Zero amount");
    require(claimBond.isMatured(epochId), "Not matured");
    require(claimBond.balanceOf(msg.sender, epochId) >= usdAmount, "Insufficient bonds");
    uint256 currentPrice = _getSafePrice();
    require(currentPrice >= MIN_REDEEM_PRICE, "Price too low");
    uint256 luminaAmount = (usdAmount * 1e36) / currentPrice;
    require(lumina.balanceOf(address(this)) >= luminaAmount, "Insufficient reserve");
    ...
    require(lumina.transfer(msg.sender, luminaAmount), "Transfer failed");
}
```

## 2. Policy-trigger payout (ERC-1155 bond mint, no LUMINA movement)

When a policy triggers, the protocol mints ERC-1155 ClaimBond tokens to the insured agent — **NOT** an immediate LUMINA transfer. The holder must wait until maturity (730 days) to redeem LUMINA.

**Evidence:** `src/bonds/BondVault.sol:159-180` (`issueBond`): only modifies `totalCommittedUSD` and calls `claimBond.mint`. No LUMINA leaves BondVault until `redeemBond` is called.

## 3. Marketplace-buy payouts

Two simultaneous outflows per `executeBuy`:

- Seller receives `price − sellerFee` USDC (from Marketplace balance, paid by buyer upfront).
- TWAPBurner receives `sellerFee + buyerFee` USDC (3% total).
- Bond NFT transfers from Marketplace custody → buyer.

**Evidence:** `src/marketplace/LuminaBondMarketplace.sol:138-142`:
```solidity
usdc.safeTransferFrom(msg.sender, address(this), totalBuyerPays);
usdc.safeTransfer(l.seller, sellerReceives);
usdc.safeTransfer(twapBurner, sellerFee + buyerFee);
claimBond.safeTransferFrom(address(this), msg.sender, l.epochId, l.amount, "");
```

## 4. Marketplace-cancel refund

Seller reclaims their escrowed bonds.

**Evidence:** `src/marketplace/LuminaBondMarketplace.sol:117-125` (`cancel`): `claimBond.safeTransferFrom(address(this), l.seller, l.epochId, l.amount, "")`.

## 5. BurnFromReserves (LUMINA destroyed)

LUMINA leaves BondVault and is burned from totalSupply — this is the "double burn" mechanism.

| Field | Value |
|---|---|
| Recipient | N/A (tokens burned via `lumina.burn`) |
| Token | LUMINA |
| Source contract | `BondVault` |
| Function | `burnFromReserves(amount)` — only authorized callers |
| Amount | ≤ 5% of current vault balance per call |

**Evidence:** `src/bonds/BondVault.sol:288-298`:
```solidity
function burnFromReserves(uint256 amount) external onlyAuthorized {
    require(amount > 0, "Amount must be > 0");
    uint256 currentBalance = lumina.balanceOf(address(this));
    require(currentBalance >= amount, "Insufficient reserves");
    uint256 maxBurnPerTx = (currentBalance * 5) / 100;
    require(amount <= maxBurnPerTx, "Exceeds 5% per-tx cap");
    IBurnable(address(lumina)).burn(amount);
    emit ReservesBurned(amount, currentBalance - amount);
}
```

## 6. TWAPBurner swap-and-burn

`_swapAndBurn` swaps USDC → LUMINA on a DEX, then burns the LUMINA.

| Field | Value |
|---|---|
| Recipient | DEX (for USDC); then `lumina.burn` (destroys LUMINA) |
| Token | USDC out (to DEX); LUMINA destroyed |
| Source contract | `TWAPBurner` |
| Function | `_swapAndBurn(usdcAmount)` |

**Evidence:** `src/core/TWAPBurner.sol:199-247`:
```solidity
usdc.forceApprove(address(bestRouter), usdcAmount);
uint256 luminaReceived = bestRouter.swap(address(usdc), address(lumina), usdcAmount, minOut);
IBurnable(address(lumina)).burn(luminaReceived);
```

**Critical:** LUMINA purchased this way is **burned immediately**, NOT deposited into BondVault.

## 7. Adaptive distribution — buyback bucket

USDC sent to `buybackReserve` address (expected to be BuybackEngine proxy).

**Evidence:** `src/core/TWAPBurner.sol:157-159`:
```solidity
if (toBuyback > 0 && buybackReserve != address(0)) {
    usdc.safeTransfer(buybackReserve, toBuyback);
}
```

## 8. Adaptive distribution — ops bucket

USDC sent to `opsReserve` EOA.

**Evidence:** `src/core/TWAPBurner.sol:160-162`.

## 9. Adaptive distribution — maintenance bucket

USDC sent to `MaintenanceReserve` proxy.

**Evidence:** `src/core/TWAPBurner.sol:163-165`.

## 10. MaintenanceReserve.spend

Admin-controlled outflow from MaintenanceReserve to an arbitrary recipient.

| Field | Value |
|---|---|
| Recipient | Arbitrary `recipient` (admin chooses) |
| Token | USDC |
| Source contract | `MaintenanceReserve` |
| Function | `spend(recipient, amount, category, memo)` — onlyRole(SPENDER_ROLE) |
| Cap | `monthlyCap` (configurable) |

**Evidence:** `src/treasury/MaintenanceReserve.sol:69-91`:
```solidity
function spend(address recipient, uint256 amount, SpendCategory category, string calldata memo)
    external
    onlyRole(SPENDER_ROLE)
    nonReentrant
{
    ...
    usdc.safeTransfer(recipient, amount);
    emit FundsSpent(recipient, amount, category, memo, block.timestamp);
}
```

## 11. BuybackEngine.executeOffer — bond purchase + double-burn

BuybackEngine spends its USDC balance to buy bonds from the marketplace, then burns those bonds AND matching LUMINA from BondVault (via authorized `burnFromReserves`).

**Evidence:**
- `src/marketplace/BuybackEngine.sol:131-149` (executeOffer).
- `src/marketplace/BuybackEngine.sol:151-168` (`_executeDoubleBurn`): burns bonds then calls `bondVault.burnFromReserves(luminaToBurn)`.

## 12. TreasuryVesting release

LUMINA released from vesting schedule.

**Evidence:** `src/token/TreasuryVesting.sol` — monthly cap-based release.

## 13. CEXLiquidityReserve withdraw

LUMINA managed by the CEX-allocation admin for exchange listings.

**Evidence:** `src/treasury/CEXLiquidityReserve.sol`.

## 14. RecoverToken (admin rescue for stranded tokens)

Three separate recoverToken functions:

- `MaintenanceReserve.recoverToken` — blocks USDC, allows anything else.
- `TWAPBurner.recoverToken` — blocks USDC and LUMINA.
- (ClaimBond has no recoverToken.)

**Evidence:**
- `src/treasury/MaintenanceReserve.sol:130-134`.
- `src/core/TWAPBurner.sol:382-386`.

## Summary

| Outflow | Token | From contract | Triggered by |
|---|---|---|---|
| Bond redemption | LUMINA → holder | BondVault | User (post-maturity) |
| Marketplace sale | USDC → seller | Marketplace | Buyer executeBuy |
| Marketplace fee | USDC → twapBurner | Marketplace | Buyer executeBuy |
| Marketplace cancel | Bond → seller | Marketplace | Seller cancel |
| Burn-from-reserves | LUMINA destroyed | BondVault | authorized (BuybackEngine) |
| Swap-and-burn | LUMINA destroyed (via DEX) | TWAPBurner | executeBurn |
| Adaptive → buyback | USDC → BuybackEngine | TWAPBurner | executeBurn |
| Adaptive → ops | USDC → ops EOA | TWAPBurner | executeBurn |
| Adaptive → maint | USDC → MaintenanceReserve | TWAPBurner | executeBurn |
| Maintenance spend | USDC → arbitrary | MaintenanceReserve | admin |
| Vesting release | LUMINA → vesting recipient | TreasuryVesting | monthly |
| RecoverToken | stranded ERC-20 → admin | Maint/TWAP | admin |

**Critical observation:** NO outflow path ever sends USDC or LUMINA INTO the BondVault. The vault is a drain-only contract once the initial mint lands there.
