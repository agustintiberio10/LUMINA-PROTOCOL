# FLOW-01 — Incoming Fund Sources

All places where USDC or LUMINA enter the protocol's contract surface.

---

## 1. Policy premium (primary source)

| Field | Value |
|---|---|
| Payer | Policy buyer (AI agent / human) or relayer on their behalf |
| Token | USDC |
| Entry contract | `CoverRouterV2` then forwarded to `TWAPBurner` |
| Function | `purchasePolicy` / `purchasePolicyFor` → `_purchase` |
| Trigger | User transaction |
| Amount | `premium = coverageAmount × payoutRatioBps × triggerProbBps × marginBps / 10000^3` (minimum 1 wei) |

**Evidence:**

- `src/core/CoverRouterV2.sol:178` — `usdc.safeTransferFrom(payer, address(this), premium);` (USDC enters CoverRouter).
- `src/core/CoverRouterV2.sol:182-183` — `usdc.forceApprove(twapBurner, premium); twapBurner.receivePremium(premium);` — 100% forwarded to TWAPBurner.
- `src/core/TWAPBurner.sol:114-119` — `receivePremium` pulls the `amount` via `safeTransferFrom(msg.sender, …)`, increments `totalUSDCReceived`, emits event.

**Net effect:** every dollar of premium ends up in the TWAPBurner contract, ready to be split by the 16-cell matrix on the next `executeBurn`.

## 2. Marketplace fees (secondary source)

| Field | Value |
|---|---|
| Payer | Bond buyer on marketplace |
| Token | USDC |
| Entry contract | `LuminaBondMarketplace` — forwarded to `twapBurner` address |
| Function | `executeBuy` |
| Trigger | Marketplace buy transaction |
| Amount | `sellerFee = price × 1.5%` + `buyerFee = price × 1.5%` = `3%` total |

**Evidence:**

- `src/marketplace/LuminaBondMarketplace.sol:37-39`:
  ```
  uint256 public constant SELLER_FEE_BPS = 150;  // 1.5%
  uint256 public constant BUYER_FEE_BPS  = 150;  // 1.5%
  uint256 public constant BPS_DENOMINATOR = 10000;
  ```
- `src/marketplace/LuminaBondMarketplace.sol:133-140`:
  ```solidity
  uint256 sellerFee = (l.priceUSDC * SELLER_FEE_BPS) / BPS_DENOMINATOR;
  uint256 buyerFee  = (l.priceUSDC * BUYER_FEE_BPS)  / BPS_DENOMINATOR;
  uint256 totalBuyerPays  = l.priceUSDC + buyerFee;
  uint256 sellerReceives  = l.priceUSDC - sellerFee;
  usdc.safeTransferFrom(msg.sender, address(this), totalBuyerPays);
  usdc.safeTransfer(l.seller, sellerReceives);
  usdc.safeTransfer(twapBurner, sellerFee + buyerFee);
  ```

**Important:** Marketplace sends fees DIRECTLY to `twapBurner` address via `safeTransfer` (line 140). It does NOT call `twapBurner.receiveMarketplaceFee()`. So `totalUSDCReceived` counter in TWAPBurner is NOT incremented for marketplace fees — they simply land in the contract balance and will be processed by the next `executeBurn`.

## 3. receiveMarketplaceFee (present but unused)

`src/core/TWAPBurner.sol:121-126` exposes:
```solidity
function receiveMarketplaceFee(uint256 amount) external {
    require(amount > 0, "Zero amount");
    usdc.safeTransferFrom(msg.sender, address(this), amount);
    totalUSDCReceived += amount;
    emit MarketplaceFeeReceived(msg.sender, amount);
}
```

This function exists but `LuminaBondMarketplace.executeBuy` (line 140) does NOT use it. Marketplace-fees arrival is via direct `safeTransfer` — which means:
- `totalUSDCReceived` counter in TWAPBurner does NOT reflect marketplace fees.
- `MarketplaceFeeReceived` event is never emitted.

This is not a bug per se (funds still arrive), but it's an accounting inconsistency worth flagging.

## 4. Buyback-engine inflow (USDC only — self-funded)

| Field | Value |
|---|---|
| Payer | TWAPBurner distribution (buybackBps bucket) |
| Token | USDC |
| Entry contract | `BuybackEngine` (as `buybackReserve`) |
| Function | TWAPBurner._executeAdaptive → `usdc.safeTransfer(buybackReserve, toBuyback)` |
| Amount | `executeBurn amount × buybackBps / 10000` |

**Evidence:** `src/core/TWAPBurner.sol:157-159`:
```solidity
if (toBuyback > 0 && buybackReserve != address(0)) {
    usdc.safeTransfer(buybackReserve, toBuyback);
}
```

## 5. Ops wallet inflow

| Field | Value |
|---|---|
| Payer | TWAPBurner distribution (opsBps bucket) |
| Token | USDC |
| Entry contract | `opsReserve` (any EOA, configured by admin) |
| Function | TWAPBurner._executeAdaptive |
| Amount | `executeBurn amount × opsBps / 10000` |

**Evidence:** `src/core/TWAPBurner.sol:160-162`.

## 6. MaintenanceReserve inflow

| Field | Value |
|---|---|
| Payer | TWAPBurner distribution (maintBps bucket) |
| Token | USDC |
| Entry contract | `MaintenanceReserve` (as `maintenanceReserve`) |
| Function | TWAPBurner._executeAdaptive |
| Amount | `executeBurn amount × maintBps / 10000` |

**Evidence:** `src/core/TWAPBurner.sol:163-165`.

## 7. LUMINA inflows

There is no ongoing LUMINA inflow. All LUMINA exists from token deploy:

- `src/token/LuminaTokenV2.sol` `initialize()`: 70M → BondVault; 14M → CEXLiquidityReserve; 8M → founderVesting; 5M → lbpDeposit; 3M → TreasuryVesting. Total 100M.
- BondVault never receives LUMINA after the initial mint. There is no deposit function for LUMINA.

## 8. ERC-1155 ClaimBond mints

Not a USDC/LUMINA inflow, but a commitment: `BondVault.issueBond` → `claimBond.mint(to, epochId, usdAmount)` mints ERC-1155 bond tokens to the holder. These represent USD obligations.

**Evidence:** `src/bonds/BondVault.sol:159-180`.

## Summary table

| Source | Token | Landing contract | Via function |
|---|---|---|---|
| Policy premium | USDC | TWAPBurner | `purchasePolicy` → `receivePremium` |
| Marketplace fees (3%) | USDC | TWAPBurner (direct transfer) | `executeBuy` |
| Ops/Buyback/Maintenance distribution | USDC | respective contracts | `executeBurn` → `_executeAdaptive` |
| Initial token mint (LUMINA) | LUMINA | BondVault, CEXReserve, TreasuryVesting, founder, lbpDeposit | `LuminaTokenV2.initialize` (one-time) |
| ERC-1155 bond issuance | — | ClaimBond (token mint) | `BondVault.issueBond` |

**Critical observation:** every ongoing USDC inflow lands in `TWAPBurner` first. The 16-cell matrix re-distributes it from there.
