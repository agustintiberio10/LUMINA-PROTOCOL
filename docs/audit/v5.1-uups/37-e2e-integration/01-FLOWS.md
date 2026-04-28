# 01 — End-to-end flows (V5.1 reality check)

Inventory of the four user journeys requested for audit #37, each cross-referenced with what V5.1 actually exposes on Sepolia. Where the spec assumes a primitive that V5.1 does not implement, the gap is flagged so it can be tracked rather than silently mis-tested.

## Flow 1 — AI agent: buy → trigger → bond → redeem

| Step | Actor | Surface | Status |
|---|---|---|---|
| 1 | Founder / admin | `POST /api/v1/keys/generate` (web → API admin) | ✅ implemented |
| 2 | Agent owner | Agent wallet funded with USDC + Sepolia ETH | manual / out-of-band |
| 3 | Agent | `POST /api/v1/policies` (API auth) | ✅ implemented (post-PR #86, buyer pays) |
| 4 | API relayer | `CoverRouterV2.purchasePolicyFor(productId, coverage, asset, buyer)` | ✅ on-chain, V5.1 |
| 5 | Agent | `GET /api/v1/policies?owner=<self>` | ✅ post-INV-1 fix (PR #2) — only own wallet |
| 6 | Off-chain | Oracle reports price drop | ✅ `MockChainlinkOracle.setPrice` on testnet |
| 7 | `ShieldKeeper` | `checkAndSettlePolicy(policyId)` | ✅ on-chain |
| 8 | `BondVault` | `issueBond(buyer, payoutUSD)` → `ClaimBond.mint(buyer, epoch, amount)` | ✅ on-chain |
| 9 | Agent | `GET /policies/:productId/:policyId` | ✅ public read |
| 10 | Agent | `BondVault.redeemBond(epoch, amount)` (direct on-chain) at maturity | ✅ on-chain |

**Coverage:** Foundry test `test_E2E_AIAgent_FullLifecycle` (this audit) + live API test `tests/e2e/full-lifecycle.test.ts` (RUN_LIVE_TESTS-gated).

## Flow 2 — Human LP: deposit → yield → withdraw

| Step | Actor | Surface | Status |
|---|---|---|---|
| 1 | Human | Connect wallet at lumina-org.com | ✅ post audit-35 fix |
| 2 | Human | Switch chain to Base Sepolia | ✅ |
| 3 | Human | View vaults | ⚠️ `CONTRACTS.vaults.*` keys are aliased to `BondVault` (post audit-35 fix); no real LP vault exists |
| 4 | Human | `IERC20(USDC).approve(BondVault, amount)` | ✅ ERC-20 standard |
| 5 | Human | `BondVault.deposit(amount, ...)` | ❌ **does not exist** in V5.1 |
| 6 | Aave / yield | Yield accrues | ❌ V5.1 has no Aave integration (`AAVE.pool = 0x0…0`) |
| 7 | Human | `BondVault.initiateWithdrawal(...)` | ❌ does not exist |
| 8 | Human | `BondVault.completeWithdrawal(...)` post-cooldown | ❌ does not exist |

**Status:** **CRITICAL GAP** for LP UX, but not a security finding. V5.1's `BondVault` has only `issueBond` (called by `PolicyManager`) and `redeemBond` (called by claim-bond holders post-maturity). The "deposit USDC, earn yield, withdraw" model the frontend was built around does not exist on the V5.1 chain.

The audit-35 fix wired the legacy 5-vault keys (`VolatileShort`, `VolatileLong`, `StableShort`, `StableLong`, `FlashVault`) all to the same `BondVault` address so existing UI components compile, but no `deposit()` call will succeed against that contract. The "My Vaults" tab is non-functional under V5.1 until the protocol grows real vault primitives or the frontend is restructured around bond issuance + redemption (which is what V5.1 actually does).

**Action item for the protocol roadmap (out of audit scope):** decide whether
- (a) V5.1's economic design relies entirely on policy-trigger-driven bond issuance (no LP yield) and the UI should be rewritten, or
- (b) a future contract release adds a `deposit/withdraw` path, in which case the frontend already has the pattern stubbed.

## Flow 3 — Human bond trader: buy listing → hold → redeem

| Step | Actor | Surface | Status |
|---|---|---|---|
| 1 | Human | Connect wallet | ✅ |
| 2 | Human | View Marketplace listings | ✅ `Marketplace.getListing` + UI |
| 3 | Human (buyer) | `IERC20(USDC).approve(Marketplace, amount)` | ✅ |
| 4 | Human | `Marketplace.executeBuy(listingId)` | ✅ on-chain |
| 5 | Human (buyer holds bond NFT) | wait until maturity | — |
| 6 | Human | `BondVault.redeemBond(epoch, amount)` | ✅ on-chain |

**Coverage:** Foundry test `test_E2E_BondTrader_BuyHoldRedeem` (this audit).

## Flow 4 — Cross-component: agent buys → trigger → bond → list → 3rd-party buys → redeem

| Step | Actor | Surface |
|---|---|---|
| 1 | API relayer | `CoverRouterV2.purchasePolicyFor(...)` for agent |
| 2 | Off-chain | Oracle price drop |
| 3 | `ShieldKeeper` | `checkAndSettlePolicy` |
| 4 | `BondVault` | `issueBond` → `ClaimBond.mint(agent, epoch, amount)` |
| 5 | Agent (or its owner) | `claimBond.setApprovalForAll(Marketplace, true)` then `Marketplace.list(epoch, amount, priceUSDC)` |
| 6 | Other human | `IERC20(USDC).approve(Marketplace, ...)` then `Marketplace.executeBuy(listingId)` |
| 7 | Agent | receives USDC; other human holds bond |
| 8 | Other human | `BondVault.redeemBond(epoch, amount)` at maturity |

**Coverage:** Foundry test `test_E2E_CrossComponent_AgentSellsBonds` (this audit).

## Global invariants (Foundry-checkable)

| # | Invariant |
|---|---|
| INV-1 | `LuminaTokenV2.totalSupply() == 100_000_000 * 1e18` post-init (no further mints possible) |
| INV-2 | `BondVault.totalCommittedUSD()` is non-decreasing across `issueBond` calls and decreases only via `BuybackEngine.decreaseObligations` |
| INV-3 | After `purchasePolicyFor`, `pr.buyer == buyer` (PR #86 fix locked-in) |
| INV-4 | `usdc.balanceOf(BondVault)` reflects deposited collateral; never goes negative |
| INV-5 | `ClaimBond.balanceOf(holder, epoch)` is conserved across `Marketplace.list` + `Marketplace.executeBuy` (escrow accounting) |

Foundry test `test_E2E_GlobalInvariants_HoldAfterFullLifecycle` exercises 1, 3, 5 (the others are protected by access control, not arithmetic).

## What this audit does NOT cover

- **Web manual flows** beyond what the existing audit-35 inventory documented. Browser interaction is captured as a checklist in `02-WEB-MANUAL-CHECKLIST.md`; running it requires the operator.
- **Live Sepolia E2E from the API repo's CI** — the `tests/e2e/full-lifecycle.test.ts` is RUN_LIVE_TESTS-gated. Don't ship to production without running it manually first.
- **Performance / load** — captured as a documented baseline (`/health` p95 < 500 ms, single-origin sustained 60 req/min/IP under the new auth limiter), not exercised exhaustively.
- **Virtuals integration** — explicitly out-of-scope per the audit spec ("#34 PENDIENTE").
