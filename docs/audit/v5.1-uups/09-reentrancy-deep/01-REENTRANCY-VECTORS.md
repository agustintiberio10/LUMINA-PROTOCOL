# V5.1 Reentrancy Vectors Inventory

**Audit:** V5.1 #9 — Reentrancy Deep
**Branch:** `audit/v5.1-09-reentrancy-deep`
**Date:** 2026-04-22

---

## 1. External call surface

Every external call in the V5.1 codebase, with its reentrancy exposure:

| Contract.Function | External call | Callback possible? | Vector |
|-------------------|---------------|--------------------|--------|
| BondVault.issueBond | `claimBond.mint` (ERC-1155, `_doSafeTransferAcceptanceCheck`) | **YES** — `onERC1155Received` | Cross-contract reentrancy |
| BondVault.redeemBond | `lumina.transfer` (ERC-20) | NO — LuminaTokenV2 is ERC-20, no hooks | — |
| CoverRouterV2.buyPolicy | USDC `safeTransferFrom` + `forceApprove` + `safeTransfer` | NO for USDC | — |
| CoverRouterV2.submitTrigger | Shield.verifyAndCalculate + PolicyManager | NO (internal only) | — |
| TWAPBurner.executeBurn | DEX router `swapExactTokensForTokens` | NO (Uniswap V3 / Aerodrome do NOT call back) | — |
| BuybackEngine.executeOffer | Marketplace.executeBuy → ClaimBond.safeTransferFrom + USDC transfer | **YES** — `onERC1155Received` | Cross-contract reentrancy |
| LuminaBondMarketplace.list/executeBuy/cancel | ClaimBond.safeTransferFrom + USDC transfers | **YES** — on buyer/seller side | Cross-contract reentrancy |
| CEXLiquidityReserve.allocateTokens | `lumina.transfer` | NO | — |
| MaintenanceReserve.spend | `usdc.safeTransfer` | NO | — |

---

## 2. Functions protected by `nonReentrant`

Complete enumeration from source grep:

| Contract | Function | Guard |
|----------|----------|-------|
| BondVault | `issueBond` | ✅ |
| BondVault | `redeemBond` | ✅ |
| CoverRouterV2 | `buyPolicy` | ✅ |
| CoverRouterV2 | `buyPolicyFor` | ✅ |
| CoverRouterV2 | `submitTrigger` | ✅ |
| TWAPBurner | `executeBurn` | ✅ |
| LuminaBondMarketplace | `list` | ✅ |
| LuminaBondMarketplace | `cancel` | ✅ |
| LuminaBondMarketplace | `executeBuy` | ✅ |
| BuybackEngine | `executeOffer` | ✅ |
| CEXLiquidityReserve | `allocateTokens` | ✅ |
| MaintenanceReserve | `spend` | ✅ |

---

## 3. Token properties

- **LUMINA (LuminaTokenV2):** ERC-20 + ERC-20Burnable. **NO** ERC-777 hooks,
  **NO** transfer callbacks. Safe against reentrancy via token transfers.
- **ClaimBond:** ERC-1155 + ERC1155Supply. Safe transfers DO call
  `onERC1155Received(Batch)` on contract recipients. This is the main
  reentrancy vector in the protocol.
- **USDC (external):** Standard ERC-20 no hooks.

---

## 4. Read-only reentrancy surface

During a state-mutating call where the attacker gets callback (e.g.
`onERC1155Received`), the attacker can call view functions. The views we
expose that could return intermediate state:

| View | Backing storage | Risk if read mid-op |
|------|-----------------|---------------------|
| `BondVault.totalCommittedUSD` | counter, updated before external transfer | Attacker reads the NEW value — consistent |
| `BondVault.availableCapacityUSD` | derived from counters + oracle | Consistent (same block state) |
| `BondVault.previewRedemption` | derived from price | Consistent |
| `CapacityOracle.getLuminaPrice` | derived from Uniswap V3 pool | Pool state is atomic — consistent |
| `SolvencyOracle.getSolvencyRatio` | derived from BondVault counter + LUMINA balance + capacity oracle | Consistent — no intermediate state |
| `LuminaBondMarketplace.listings` | struct in storage, modified in executeBuy | Modified BEFORE external calls in executeBuy, so reads see post-state |

All state mutations in nonReentrant functions write storage BEFORE external
calls that could trigger callbacks. This follows the Checks-Effects-Interactions
pattern correctly.

---

## 5. Attack graphs considered

### 5.1 ERC-1155 receiver in BondVault.issueBond
- Attacker is the `to` address.
- issueBond triggers `claimBond.mint(to, ...)` → receiver's `onERC1155Received`.
- Attacker tries to re-enter BondVault.issueBond → **BLOCKED** by nonReentrant.

### 5.2 ERC-1155 receiver in Marketplace.executeBuy
- Attacker is the buyer.
- executeBuy transfers bonds to buyer → `onERC1155Received`.
- Attacker tries to re-enter Marketplace.executeBuy / list / cancel → **BLOCKED**.

### 5.3 ERC-1155 receiver in BuybackEngine.executeOffer
- Attacker is the seller of the listing.
- executeOffer → Marketplace.executeBuy → ClaimBond transfer to BuybackEngine
  (which has its own `onERC1155Received`). BuybackEngine is NOT attacker-
  controlled.
- Attacker's only callback is via USDC transfer to seller — USDC has no hooks.

### 5.4 Multi-hop via cross-contract
- A → B → C → A loop requires A to not hold the lock OR to be a different
  contract. Each contract has its own `ReentrancyGuard` state so cross-
  contract reentrancy into the SAME function on the SAME contract is
  blocked by that contract's guard.
- Cross-contract into a DIFFERENT function relies on the target's own
  nonReentrant/guard. All state-mutating externals are guarded.

See `REPORT.md` for test-level verification.
