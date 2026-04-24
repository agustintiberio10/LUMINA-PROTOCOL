# FLOW-03 — End-to-end USDC routing

Traces every $1 USDC that enters the protocol, step by step.

---

## Case A — Premium from a policy purchase

### Step 1. Buyer → CoverRouterV2

`CoverRouterV2._purchase(...)` at `src/core/CoverRouterV2.sol:155`:

```solidity
usdc.safeTransferFrom(payer, address(this), premium);          // line 178
usdc.forceApprove(address(twapBurner), premium);               // line 182
twapBurner.receivePremium(premium);                            // line 183
```

**After step 1:** USDC sits in `CoverRouterV2` for one instruction, immediately approved to TWAPBurner.

### Step 2. CoverRouter → TWAPBurner

`TWAPBurner.receivePremium(amount)` at `src/core/TWAPBurner.sol:114-119`:

```solidity
usdc.safeTransferFrom(msg.sender, address(this), amount);
totalUSDCReceived += amount;
```

**After step 2:** 100% of premium now in `TWAPBurner`. `totalUSDCReceived` counter incremented. Allowance from CoverRouter → TWAPBurner drained to zero.

### Step 3. TWAPBurner.executeBurn (subsequent call — keeper-triggered or anyone)

`TWAPBurner.executeBurn()` at `src/core/TWAPBurner.sol:130-144`:

- Requires `block.timestamp >= lastBurnTimestamp + burnCooldown` (default 900s).
- Takes min of `balance` and `maxBurnAmount` (default 10000 USDC = $10 k).
- Routes to `_executeAdaptive` if `adaptiveModeEnabled`, else `_executeLegacyBurn`.

### Step 4. Adaptive split — `_executeAdaptive(amount)` at line 148-171

Reads `(burnBps, buybackBps, opsBps, maintBps)` from `AdaptiveFeeDistributor.getDistribution()` via `_getDistribution()` (line 178-197) with fallback constants.

Splits `amount` into four sub-amounts:

- `toBurn` → `_swapAndBurn(toBurn)` → USDC sent to DEX, LUMINA received → burned via `lumina.burn`.
- `toBuyback` → `usdc.safeTransfer(buybackReserve, toBuyback)` — goes to BuybackEngine.
- `toOps` → `usdc.safeTransfer(opsReserve, toOps)` — goes to ops EOA.
- `toMaint` → `usdc.safeTransfer(maintenanceReserve, toMaint)` — goes to MaintenanceReserve.

### Final destinations of Case-A USDC

Every $1 of premium ends in ONE of:

- (burn bucket) a DEX's pool (USDC side of the pair). The corresponding LUMINA was burned. **USDC EXITS the protocol**.
- (buyback bucket) BuybackEngine proxy balance. Will later be used to buy bonds on Marketplace (see Case C).
- (ops bucket) ops EOA. **USDC EXITS the protocol** (paid to team).
- (maintenance bucket) MaintenanceReserve proxy balance. Accumulated for admin-spend via `spend()`.

### None of it lands in BondVault.

## Case B — Marketplace fees (3% total)

### Step 1. Buyer → Marketplace

`LuminaBondMarketplace.executeBuy(listingId)` at `src/marketplace/LuminaBondMarketplace.sol:127-144`:

```solidity
uint256 totalBuyerPays  = l.priceUSDC + buyerFee;
uint256 sellerReceives  = l.priceUSDC - sellerFee;
usdc.safeTransferFrom(msg.sender, address(this), totalBuyerPays);
```

**After step 1:** Marketplace holds `totalBuyerPays` USDC.

### Step 2. Split

```solidity
usdc.safeTransfer(l.seller, sellerReceives);          // seller gets price − 1.5%
usdc.safeTransfer(twapBurner, sellerFee + buyerFee);  // 3% goes to TWAPBurner
```

**After step 2:** seller has their USDC net of fee, and TWAPBurner has the 3% fee.

### Step 3. TWAPBurner processing

Marketplace used a plain `safeTransfer`, so `totalUSDCReceived` is NOT updated and no `MarketplaceFeeReceived` event is emitted (see FLOW-01 §3). The fee USDC just sits in TWAPBurner's balance.

On the next `executeBurn`, these USDC get split along with any premium USDC that accumulated — same 16-cell logic.

### Final destinations of Case-B fees

Identical to Case A (DEX / BuybackEngine / ops / MaintenanceReserve).

## Case C — BuybackEngine executes an offer

Initial state: BuybackEngine has USDC from the buyback bucket (Case A step 4).

### Step 1. Engine → Marketplace

`BuybackEngine.executeOffer(listingId)` at `src/marketplace/BuybackEngine.sol:131-149`:

```solidity
uint256 buyerFee = (priceUSDC * marketplace.BUYER_FEE_BPS()) / marketplace.BPS_DENOMINATOR();
uint256 totalRequired = priceUSDC + buyerFee;
...
usdc.forceApprove(address(marketplace), totalRequired);
marketplace.executeBuy(listingId);
usdc.forceApprove(address(marketplace), 0);
```

Marketplace then:
- Pulls `priceUSDC + buyerFee` from BuybackEngine (via the allowance).
- Sends `priceUSDC − sellerFee` to the seller.
- Sends `sellerFee + buyerFee` to TWAPBurner.

### Step 2. _executeDoubleBurn

`src/marketplace/BuybackEngine.sol:151-168`:

```solidity
claimBond.burnByHolder(address(this), epochId, amount);  // burn bonds held
bondVault.decreaseObligations(faceValueUSD);             // reduce obligations
...
bondVault.burnFromReserves(luminaToBurn);                // burn matching LUMINA from BondVault
```

### Final result of Case C

- USDC that started in BuybackEngine → seller (most) + TWAPBurner (fees).
- Bonds redeemed (destroyed).
- Matching LUMINA reserves in BondVault destroyed.
- Net effect: circulating LUMINA supply decreases; protocol obligations decrease.

## Summary of USDC terminal states

Every dollar of USDC that enters this protocol, no matter the path, ends up in one of four end-states:

1. **Exited to DEX pool** (during `_swapAndBurn`). Counterpart LUMINA is burned. The protocol "sold" USDC for the right to destroy LUMINA.
2. **Kept as operating capital** in MaintenanceReserve (awaiting `spend()`).
3. **Paid to ops EOA** (salaries, infrastructure).
4. **Recycled through marketplace**: BuybackEngine → seller + TWAPBurner; the `seller → TWAPBurner fee` fraction eventually goes through the same 16-cell distribution on the next `executeBurn`.

**No amount of USDC ever ends up in BondVault in V5.1.** The 16-cell matrix allocates USDC among buckets; none of those buckets sends to BondVault.
