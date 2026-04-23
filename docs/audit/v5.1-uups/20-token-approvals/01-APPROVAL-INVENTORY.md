# Audit V5.1 #20 — Token Approvals: Inventory

**Target:** LUMINA Protocol V5.1 — ERC-20 and ERC-1155 approval surface
**Date:** 2026-04-23

---

## 1. Every `approve` / `forceApprove` in `src/`

Grep result (`\.approve\(|\.forceApprove\(|safeIncreaseAllowance|safeDecreaseAllowance`):

| File | Line | Call | Token | Target | Amount |
|---|---|---|---|---|---|
| `src/core/TWAPBurner.sol` | 235 | `usdc.forceApprove(address(bestRouter), usdcAmount)` | USDC | best DEX router | exact `usdcAmount` |
| `src/core/CoverRouterV2.sol` | 182 | `usdc.forceApprove(address(twapBurner), premium)` | USDC | TWAPBurner | exact `premium` |
| `src/dex/UniswapV3Adapter.sol` | 61 | `IERC20(tokenIn).forceApprove(address(router), amountIn)` | `tokenIn` | Uniswap V3 SwapRouter | exact `amountIn` |
| `src/dex/AerodromeAdapter.sol` | 52 | `IERC20(tokenIn).forceApprove(address(router), amountIn)` | `tokenIn` | Aerodrome Router | exact `amountIn` |
| `src/marketplace/BuybackEngine.sol` | 143 | `usdc.forceApprove(address(marketplace), priceUSDC)` | USDC | LuminaBondMarketplace | **`priceUSDC` only — short of `priceUSDC + buyerFee`** |

**Zero raw `approve()` call sites.** All approvals go through OpenZeppelin's `SafeERC20.forceApprove`, which handles USDT-style zero-reset tokens and atomic approve-over-nonzero.

## 2. Every `transferFrom` call that consumes allowance

| Site | Caller | `from` | allowance consumer |
|---|---|---|---|
| `TWAPBurner.receivePremium` (line 116) | msg.sender (CoverRouter) | msg.sender | CoverRouter → TWAPBurner allowance |
| `BondVault.redeemBond` | msg.sender | internal transfer via `_burn` (no transferFrom needed) | — |
| DEX router `.swap(...)` | router | TWAPBurner / Adapter | TWAPBurner/Adapter → router allowance |
| `Marketplace.executeBuy` (line 138) | msg.sender (buyer) | msg.sender | buyer → Marketplace allowance |
| `Marketplace.list` (line 113) | msg.sender (seller) | `claimBond.safeTransferFrom` — ERC-1155 approval | — |

## 3. Summary table

| Approver | Token | Target | Amount | Pattern | Drained | Safe |
|---|---|---|---|---|---|---|
| CoverRouterV2 | USDC | TWAPBurner | exact premium | forceApprove | ✅ exact | ✅ |
| TWAPBurner | USDC | best DEX router | exact usdcAmount | forceApprove | ✅ exact | ✅ |
| UniswapV3Adapter | tokenIn | V3 SwapRouter | exact amountIn | forceApprove | ✅ exact | ✅ |
| AerodromeAdapter | tokenIn | Aerodrome Router | exact amountIn | forceApprove | ✅ exact | ✅ |
| **BuybackEngine** | **USDC** | **Marketplace** | **priceUSDC only** | **forceApprove** | **❌ short** | **❌ §4.1** |

## 4. User-side approvals required

| User action | Token | Approver | Target | Pattern |
|---|---|---|---|---|
| Buy policy | USDC | buyer | CoverRouterV2 | standard `approve(premium)` — no-reset-needed because USDC (Base) is standard |
| Relayer buy (purchasePolicyFor) | USDC | relayer | CoverRouterV2 | same |
| Buy bond on marketplace | USDC | buyer | LuminaBondMarketplace | standard `approve(priceUSDC + buyerFee)` |
| List bond on marketplace | ClaimBond (ERC-1155) | seller | LuminaBondMarketplace | `setApprovalForAll(marketplace, true)` |
| Redeem matured bond | none | — | — | no allowance needed — BondVault burns directly |

## 5. Findings summary

- **MEDIUM §4.1** — BuybackEngine.executeOffer is functionally broken: it approves only `priceUSDC` but Marketplace.executeBuy pulls `priceUSDC + buyerFee`. Every `executeOffer` attempt reverts on the marketplace's `safeTransferFrom`. Tests confirm this (`test_Appr_UUPS_BuybackEngine_ShortApproval_RevealsBug`). Fix: approve `priceUSDC + buyerFee` before `marketplace.executeBuy`, OR pre-compute the fee and reset approval after.

- **INFO**: No infinite allowances anywhere in `src/`.
- **INFO**: All protocol approvals are drained to zero by the immediate next `transferFrom` — no leftover.
- **INFO**: `BondVault.redeemBond` uses plain `lumina.transfer` (not `safeTransfer`). Safe today because LUMINA is our own compliant ERC-20, but flagged for awareness if the payout token is ever swapped.
