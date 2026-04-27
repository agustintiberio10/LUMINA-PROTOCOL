# 01 — Inventory of relayer-pattern hotspots

Triggered by the CRITICAL bug fixed in PR #86 (`CoverRouterV2.purchasePolicyFor` charged the relayer instead of the buyer). This audit sweeps the rest of the protocol for the same class of "actor confusion" defect.

## Methodology

Five orthogonal greps over `src/`:

1. **A.** Functions with `For`/`OnBehalf`/`forUser`/`forAccount` in the name → relayer-pattern entry points
2. **B.** `permit` / `EIP712` / `ECDSA.recover` → user signatures off-chain
3. **C.** `msg.sender ==` checks → authorization gates that may equate caller with actor
4. **D.** `_mint` / `_safeMint` / `safeTransferFrom` → NFT/ERC-20/ERC-1155 deliveries that pick a recipient
5. **E.** `safeTransfer(...)` → outbound payouts that pick a recipient

For each hit the question is the same: **does the contract pull funds from `msg.sender` or send funds to `msg.sender` when the *actor* is supposed to be a different argument-supplied address?**

## A. `For`-suffix / `OnBehalf` functions

| File | Function | Status |
|---|---|---|
| `src/core/CoverRouterV2.sol:158` | `purchasePolicyFor(productId, coverage, asset, buyer)` | **FIXED in PR #86** — verified post-upgrade on Sepolia (policy ID 3, buyer charged, relayer untouched). |

Only one. No `redeemBondFor`, `buyFor`, `executeOfferFor`, `transferFor`, etc. exist.

This is a deliberate design choice: every other public entry point treats `msg.sender` as the actor, removing the room for the bug class entirely.

## B. EIP-712 / signature recovery

| File | Use site |
|---|---|
| `src/products/BaseShield.sol:314,323` | `_verifyPriceProofEIP712` and `_verifyExploitGovProofEIP712` — call out to `IOracleV2.verifyPriceProofEIP712(...)` |
| `src/products/Flash*Shield*.sol`, `MicroDepegShield.sol` | All inherit `BaseShield`; same path |
| `src/interfaces/IOracleV2.sol` | Interface declaration |

These are **oracle proofs**, not user permits. The signer being recovered is the **oracle's authorized signer** — an off-chain price/exploit feed — not an end user. The oracle holds the auth list. There is no relayer-vs-user separation to confuse here: any caller can submit a valid signed proof and trigger a payout, which is the intended permissionless trigger model.

No EIP-2612-style USDC permit flow exists in the codebase.

## C. `msg.sender ==` authorization checks

61 occurrences in 17 files. The privileged ones (manually verified):

| File | Function | Gate | Verdict |
|---|---|---|---|
| `BondVault.sol:170` | `issueBond(to, usdPayout)` | `msg.sender == policyManager` | OK — `to` flows from `pr.buyer` (recorded at policy creation, see `PolicyManagerV2.sol:210`) |
| `BondVault.sol` | `redeemBond` | `msg.sender == bond holder` (via ERC-1155 burn) | OK — direct flow, no relayer variant |
| `ClaimBond.sol:82` | `mint(to, epochId, amount)` | `onlyBondVault` | OK — `to` always sourced from `pr.buyer` upstream |
| `ClaimBond.sol:113` | `burnByHolder(account, ...)` | `msg.sender == account || isApprovedForAll(account, msg.sender)` | OK — standard ERC-1155 |
| `LuminaBondMarketplace.sol:106-122` | `list` | seller is `msg.sender` (no `For` variant) | OK — direct flow |
| `LuminaBondMarketplace.sol:135-152` | `executeBuy` | buyer is `msg.sender` (no `For` variant) | OK — direct flow |
| `BuybackEngine.sol:143` | `executeOffer` | uses engine's own USDC reserves; no buyer arg | OK — engine pays for itself |
| `TWAPBurner.sol:124,131` | `receivePremium` / `receiveMarketplaceFee` | public | OK — caller voluntarily pushes USDC; no user state being affected |
| `TWAPBurner.sol` | `executeBurn` | `nonReentrant`, but otherwise public | OK — no actor-vs-caller risk |
| `dex/AerodromeAdapter.sol:51` / `dex/UniswapV3Adapter.sol:60` | `swap(tokenIn, tokenOut, ...)` | public, msg.sender pays + receives | OK — stateless DEX wrapper |
| `MaintenanceReserve.sol:88` | `spendUSDC(recipient, ...)` | role-gated (`SPENDER_ROLE`) | OK — role-holder picks recipient |
| `CEXLiquidityReserve.sol:122` | `allocate(recipient, ...)` | role-gated (`ALLOCATOR_ROLE`) | OK — role-holder picks recipient |

Other occurrences of `msg.sender` are inside admin-gated rescue functions or routine self-checks. None mismatch the actor.

## D. NFT mints / ERC-1155 transfers

All `_mint` / `_safeMint` calls in `src/`:

| File | Site | Recipient comes from |
|---|---|---|
| `LuminaTokenV2.sol:71-75` | `_mint` × 5 | Initialize-time hardcoded distribution targets (BondVault, CEX reserve, FounderVesting, LBPDeposit, TreasuryVesting) — one-shot, no later mint authority |
| `ClaimBond.sol:98` | `_mint(to, epochId, usdAmount, "")` | `to` = parameter; gated `onlyBondVault`; vault always passes `pr.buyer` |

Outbound `safeTransferFrom(address(this), to, ...)`:

- `BondVault:352`, `BuybackEngine:234`, `Marketplace:222` — admin-gated `recover*` rescue
- `Marketplace:131` — `cancel` returns NFT to seller (`l.seller == msg.sender` enforced)
- `Marketplace:121, 150` — list/buy flows; both direct

No NFT can be minted to or transferred away under a relayer/actor confusion.

## E. Outbound `safeTransfer`

| File:line | Recipient | Source authority |
|---|---|---|
| `BondVault.sol:336` | `to` (admin-rescue) | `DEFAULT_ADMIN_ROLE` |
| `AdaptiveFeeDistributor.sol:108` | `to` (admin-rescue) | `DEFAULT_ADMIN_ROLE` |
| `CoverRouterV2.sol:348` | `to` (admin-rescue) | `onlyOwner` |
| `TWAPBurner.sol:168,171,174` | hardcoded reserves (buyback / ops / maintenance) | internal routing |
| `TWAPBurner.sol:398` | `owner()` (admin-rescue) | `onlyOwner` |
| `BuybackEngine.sol:219` | `to` (admin-rescue) | `DEFAULT_ADMIN_ROLE` |
| `Marketplace.sol:147` | `l.seller` (recorded at list-time) | seller-trusted |
| `Marketplace.sol:148` | `twapBurner` | hardcoded |
| `Marketplace.sol:206` | `to` (admin-rescue) | `DEFAULT_ADMIN_ROLE` |
| `MaintenanceReserve.sol:88` | `recipient` (parameter) | `SPENDER_ROLE` |
| `MaintenanceReserve.sol:132` | `msg.sender` (admin-rescue) | `DEFAULT_ADMIN_ROLE` |
| `CEXLiquidityReserve.sol:122` | `recipient` (parameter) | `ALLOCATOR_ROLE` |
| `CEXLiquidityReserve.sol:181` | `to` (admin-rescue) | `DEFAULT_ADMIN_ROLE` |
| `TreasuryVesting.sol:113` | `to` (admin-rescue) | `DEFAULT_ADMIN_ROLE` |

No payout can be redirected to a non-intended recipient by a non-privileged actor.

## End-to-end actor flow (post-fix)

```
API request          buyer (in body)
   │
   ▼
CoverRouterV2.purchasePolicyFor(productId, coverage, asset, buyer)
   │
   │ msg.sender = relayer (must be in authorizedRelayers)
   │ usdc.safeTransferFrom(buyer, ...)        ← FIX: buyer pays, not msg.sender
   ▼
PolicyManagerV2.recordPolicy(productId, buyer, ...)
   │ pr.buyer = buyer                          ← stored
   ▼
IShield.createPolicy(CreatePolicyParams { buyer, ... })
   │ insuredAgent = buyer                      ← stored on shield
   ▼
... time passes, oracle triggers ...
   ▼
PolicyManagerV2.triggerPayout(productId, policyId, oracleProof)
   │ bondVault.issueBond(pr.buyer, payoutUSD)  ← uses stored buyer
   ▼
BondVault.issueBond(to=pr.buyer, usdPayout)
   │ claimBond.mint(to=pr.buyer, ...)          ← uses stored buyer
   ▼
Buyer holds the ClaimBond NFT
   │
   ▼ (at maturity)
BondVault.redeemBond(epoch, amount)
   │ msg.sender == claim-bond-holder           ← ERC-1155 ownership check
   ▼ Buyer redeems for LUMINA
```

The `buyer` argument is carried unchanged from API call all the way to bond redemption. There is no point at which `msg.sender` substitutes for the actor.

## Verdict

**No additional bugs of the same class.** The codebase has a single relayer-pattern entry point (`purchasePolicyFor`), and it has been fixed and verified on Sepolia. Adversarial tests in `test/audit/v5.1-uups/adversarial-relayer/` exercise the remaining edge cases (malicious relayer, non-zero buyer with zero approval, two relayers same buyer, idempotency, etc.) to lock in the contract-level guarantees behind the API.
