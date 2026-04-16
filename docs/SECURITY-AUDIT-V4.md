# Lumina Protocol V2 — Audit Report
## Date: 2026-04-16
## Auditor: Claude Code (automated, Opus 4.6 1M ctx)

### Environment
- `forge` NOT available on this host (Windows Git-Bash). Compilation and Foundry test execution must be run in a Linux/macOS CI or a WSL2 environment. This report is therefore a **static audit**: Slither + manual review only.
- `slither-analyzer 0.11.5` installed; per-file scans were executed against each V2 contract using `--solc-remaps` to resolve OpenZeppelin imports. Foundry remappings (`lib/forge-std`) were not available, so tests were not compiled.

### Summary
- Contracts audited: **14** (9 under `src/v2/` + 4 modified shields in `src/products/` + `BaseShield` as reference)
- Compilation (Slither / solc 0.8.20): **PASS** for all V2 contracts individually.
- Tests: **NOT RUN** (forge unavailable). Tests exist for 8/14 contracts. All code paths were reviewed manually against the test expectations.
- Slither findings (V2 only, low/info excluded): **1 critical, 3 high, 5 medium, many low/info**.

### Risk score: **4/10** (1 = critical, 10 = safe)
Not deployable as-is. One compilation-critical bug (struct mismatch) + several high-severity issues must be fixed. Once the criticals and highs are addressed and an end-to-end Foundry test pass clean, the risk score rises to **7/10**.

---

## CRITICAL findings (must fix before deploy)

### C-1: `IShieldV2.CreatePolicyParams` struct mismatch with real `IShield.CreatePolicyParams`

**Files:** `src/v2/core/PolicyManagerV2.sol:33-43` vs `src/interfaces/IShield.sol:43-52`

`PolicyManagerV2` defines its own `IShieldV2` interface with an inline struct:
```solidity
struct CreatePolicyParams {
    address buyer;
    uint256 coverageAmount;
    uint256 premiumAmount;
    uint32 durationSeconds;
    bytes32 asset;
    bytes32 stablecoin;
    address protocol;
    uint256 deadline;   // ← added by V2
    uint256 nonce;      // ← added by V2
}
```

The real `IShield.CreatePolicyParams` (implemented by every deployed shield including the 5 new V2 shields via `BaseShield`):
```solidity
struct CreatePolicyParams {
    address buyer;
    uint256 coverageAmount;
    uint256 premiumAmount;
    uint32 durationSeconds;
    bytes32 asset;
    bytes32 stablecoin;
    address protocol;
    bytes extraData;    // ← dynamic tail
}
```

**Impact:** `PolicyManagerV2.recordPolicy` at line 149 calls:
```solidity
IShieldV2(shield).createPolicy(IShieldV2.CreatePolicyParams({..., deadline: ..., nonce: ...}))
```
This encodes 8 fixed-size fields (`deadline`/`nonce` as uint256). The shield will ABI-decode as 7 static fields + 1 dynamic `bytes extraData` offset. **The decode reads 4 bytes of the packed `nonce` as the offset pointer into a `bytes` tail that doesn't exist** → revert with "Array slice out of bounds" or silent corruption depending on EVM state. **Every `recordPolicy()` will revert.**

**Fix:** Either (a) align the V2 interface with the real `IShield`:
```solidity
// remove deadline/nonce; add: bytes extraData;
```
and drop them from the struct literal in `recordPolicy`; or (b) modify `BaseShield` to carry a new `CreatePolicyParams2` shape and bump `IShield` to v2. (a) is the minimal-risk path.

---

## HIGH findings (should fix)

### H-1: `BaseShield.router` is `immutable` — shield deploy must pass PolicyManagerV2, not CoverRouterV2

**File:** `src/products/BaseShield.sol:55`, `104-107`

`BaseShield.createPolicy` is gated by `onlyRouter` where `router == BaseShield.router` (set once in constructor). In V2 the caller of `createPolicy` is `PolicyManagerV2`, not `CoverRouterV2`. If a shield is deployed with `router_ = CoverRouterV2`, every `createPolicy` call from PolicyManagerV2 reverts `OnlyRouter`.

**Fix:** Deploy each V2 shield with `router_ = PolicyManagerV2` address, not `CoverRouterV2`. Document this in the V2 deploy script (to be created day 7). Add a constructor event `RouterSet` for on-chain verification.

### H-2: `TWAPBurner.executeBurn` uses `amountOutMinimum: 0` — MEV sandwich vulnerability

**File:** `src/v2/core/TWAPBurner.sol:131-137`

```solidity
amountOutMinimum: 0  // keeper should set via separate function in prod
```
Permissionless `executeBurn()` routes USDC → LUMINA swap with **zero slippage protection**. An MEV bot can sandwich the swap, rebating part of the burn as free LUMINA to themselves, reducing actual burn efficacy.

**Fix (any of):**
1. Require the keeper to pass `amountOutMin` as a parameter (breaks permissionless design but keeper is Gelato-signed anyway).
2. Read the `CapacityOracle.getLuminaPrice()` on-chain at execution and derive `amountOutMin = (amountToSwap × 1e12) × 1e18 / (price × (1 + maxSlippageBps/10_000))`.
3. Batch the swap through a Uniswap V3 `sqrtPriceLimitX96` bound derived from TWAP.

Option 2 is the cleanest and reuses the existing oracle infrastructure. **Critical to fix before post-launch marketplace activates** — fee burns could be up to 5% leaked per swap.

### H-3: `BondVault.resetCircuitBreaker` permissionless circuit-breaker flapping

**File:** `src/v2/bonds/BondVault.sol:151-157`

Anyone can reset the breaker once `price ≥ RESET_PRICE ($0.008)`. An attacker who can briefly move the spot price above $0.008 (small-cap post-LBP, low liquidity) can repeatedly toggle the breaker, causing DoS on new issuance.

**Fix:** Require 2-of-3 conditions:
1. `currentPrice ≥ RESET_PRICE`, AND
2. `twapPrice (30min) ≥ RESET_PRICE`, AND
3. `block.timestamp ≥ lastBreakerTrigger + 1 hours` (cooldown)

This makes spot-price flashes insufficient to reset.

---

## MEDIUM findings (recommended)

### M-1: CEI violation in `PolicyManagerV2.recordPolicy` and `triggerPayout`

**File:** `src/v2/core/PolicyManagerV2.sol:148-180`, `190-217`

Slither (`reentrancy-no-eth`) flags:
- `recordPolicy`: external call `shield.createPolicy(...)` BEFORE state updates `totalPolicies++; activePolicies++`.
- `triggerPayout`: external call `shield.verifyAndCalculate(...)` BEFORE `pr.triggered = true; activePolicies--; totalTriggers++`.

Not directly exploitable because:
- Shields are owner-registered and trusted
- `recordPolicy` returns the shield's `policyId` which is required for the state write

but the pattern is unsafe if a malicious or buggy shield is ever registered. **Prefer CEI**: snapshot needed values, update state, then call external.

### M-2: TWAPBurner reentrancy-balance around swap

**File:** `src/v2/core/TWAPBurner.sol:111-146`

`usdcBalance = usdc.balanceOf(address(this))` is read before `swapRouter.exactInputSingle`. Slither warns the post-swap checks read stale state. `nonReentrant` modifier mitigates but refactor: move the balance read to a local, calculate `amountToSwap` once, and avoid re-reading.

### M-3: `TWAPBurner.recoverToken` unchecked `transfer`

**File:** `src/v2/core/TWAPBurner.sol:237`

```solidity
IERC20(token).transfer(owner(), amount);
```
Return value is ignored. Some ERC-20s return false on failure. Use `SafeERC20.safeTransfer`.

### M-4: `CoverRouterV2.usdc.approve(...)` return value not checked

**File:** `src/v2/core/CoverRouterV2.sol:161`

Same class as M-3. `IERC20.approve` can return false. Use `SafeERC20.forceApprove` or `safeIncreaseAllowance`. Currently imports SafeERC20 for transfer but not approve.

### M-5: Relayer in `CoverRouterV2` can direct any buyer

**File:** `src/v2/core/CoverRouterV2.sol:110-116`

`purchasePolicyFor(..., buyer)` — relayer (msg.sender) pays premium from their own USDC balance, but assigns the policy to arbitrary `buyer`. No theft vector (relayer uses their own funds), but **the user's assumption that "my agent never buys policies I didn't approve" depends on the relayer being fully trusted off-chain**. Document that the relayer is a custodial trust boundary.

### M-6: `PolicyManagerV2.triggerPayout` truncates USDC 6-dec to integer USD for BondVault

**File:** `src/v2/core/PolicyManagerV2.sol:208`

```solidity
uint256 payoutUSD = pr.payoutAmount / 1e6;
```
A policy with `payoutAmount = 499999` (≈ $0.499999 in USDC) truncates to `payoutUSD = 0`. BondVault reverts on zero payout. Enforce a minimum `maxPayout >= 1e6` at shield / CoverRouter level (current min coverage $100 → $80 payout → fine), but document this invariant.

### M-7: `CapacityOracle` state vars should be `immutable`

**File:** `src/v2/oracles/CapacityOracle.sol:38-40`

`luminaToken` and `usdcToken` are set once in constructor and never re-written. Mark `immutable` to save gas and signal intent. (`emergencyPrice` and `pool` ARE re-writable by owner, keep as storage.)

---

## LOW / INFORMATIONAL

| # | File / Location | Finding |
|---|---|---|
| L-1 | `ClaimBond._timestampFromYearMonth` (line 95) | Uses 2,629,746 s/month avg (30.44 d). Drifts vs calendar by ~1 day per 24 months. Acceptable for bond maturity signaling, but not equal to "exact month X". Document. |
| L-2 | `BondVault.claimBond.burn` order (line 281-282) | State already decremented (`totalCommittedUSD`), `claimBond.burn` and `lumina.transfer` after. `nonReentrant` guards. No ERC-1155 callback on burn (OZ v5 `_burn` does not notify holder), so safe. |
| L-3 | `CapacityOracle` owner can swap `pool` | Single-step owner function (`setPool`) can point to an attacker-controlled pool returning arbitrary TWAP. Consider 2-step or timelock. Acceptable if owner = Gnosis Safe + Timelock. |
| L-4 | `RateShockShield` has no oracle proof | Trigger is 100% on-chain Aave read. If Aave oracle is manipulated or rate-strategy contract is malicious, trigger can fire spuriously. Add sanity bounds: `currentRate < 100e25` (100% APY cap). |
| L-5 | `MicroDepegShield.TRIGGER_PRICE` hardcoded 8 dec | If Chainlink USDT/USD ever redeploys with different decimals (unlikely), trigger breaks silently. Read `oracle.decimals()` instead, or add a deploy-time assertion. |
| L-6 | `CoverRouterV2` stores duplicate product metadata | `configureProduct` populates a ProductConfig. Shields already hold their own metadata (`durationRange`, `maxAllocationBps`). Two sources of truth → drift risk. At minimum, assert consistency at `configureProduct` time. |
| L-7 | Slither `divide-before-multiply` on OZ Math (`mulDiv`) | Standard OZ pattern. Not a real finding. |
| L-8 | `solc ^0.8.20` known issues | VerbatimInvalidDeduplication, FullInlinerNonExpressionSplitArgumentEvaluationOrder. Mainly YUL/via-ir edge cases. Foundry config has `via_ir = true` → confirm OZ version pins a patched compiler; else consider bumping to 0.8.24. |
| L-9 | `PolicyManagerV2.bondVault` not immutable | Slither suggests. It's owner-settable via… actually, it's NOT re-writable (no setter). Mark `immutable` to enforce and save gas. |
| L-10 | `LuminaTokenV2` `DEFAULT_ADMIN_ROLE` can be renounced | Renouncing admin permanently locks BURNER_ROLE management. If TWAPBurner is ever replaced, new burner cannot be granted. Document the operational tradeoff. |

---

## Phase 4 checklist — manual audit

### 4.1 `LuminaTokenV2.sol`
- [x] `totalSupply() == 100M` after constructor — `assert(totalSupply() == MAX_SUPPLY)` enforced at line 30.
- [x] No mint post-constructor — `_mint` is internal, no external wrapper, no function calls it after constructor.
- [x] `burnFrom` requires BURNER_ROLE (override at line 47). `burn()` from `ERC20Burnable` is free for holder.
- [x] `burn(0)` — OZ `_burn` reverts on zero-amount check only if balance insufficient; otherwise emits `Transfer(addr, 0x0, 0)`. Not blocked, but harmless.
- [ ] **DEFAULT_ADMIN_ROLE renounceable** — OZ AccessControl allows `renounceRole(DEFAULT_ADMIN_ROLE, msg.sender)`. Renouncing locks role management forever. See L-10.

### 4.2 `FounderVesting.sol`
- [x] AltSeason thresholds are `constant` — immutable.
- [x] `checkAltSeason` is guarded by `!altSeasonTriggered` at line 114.
- [x] `releaseTranche` gated by `tranchesReleased < TOTAL_TRANCHES` (3) at line 135.
- [x] Oracle reverts are try/catch-handled at lines 206-214 — `condA/B/C` default to false.
- [x] `updateRecipient(address(0))` reverts ("Zero address").
- [ ] **Rounding dust**: `TRANCHE_AMOUNT = 10M / 3 = 3,333,333.333...e18`. Three tranches = 9,999,999.999e18. Last-tranche protection at line 144-146 (`TOTAL_AMOUNT - totalReleased`) ensures exact 10M paid.
- [x] **Tokens stuck**: if someone sends extra LUMINA to vesting, it stays trapped. There's no `sweep()`. Acceptable (no-op loss; intentional immutability).

### 4.3 `TreasuryVesting.sol`
- [x] Lock = `180 days` (exact 180 × 86400 seconds).
- [x] Monthly cap: `require(amount <= MAX_MONTHLY_RELEASE)` at line 51.
- [x] Double-release prevented: `currentMonth > lastReleaseMonth || lastReleaseMonth == 0` at line 57.
- [ ] **Month 0 edge**: right after lock ends, `currentMonth = 0` and `lastReleaseMonth = 0` → condition `lastReleaseMonth == 0` allows the first release. Subsequent call in same month: `currentMonth (0) > lastReleaseMonth (0)` is false → revert. Correct.
- [x] `release(address(0))` reverts.
- [x] `totalReleased + amount <= TOTAL_AMOUNT` at line 54 enforces cap.

### 4.4 `ClaimBond.sol`
- [x] `setBondVault` once-only via `_bondVaultSet` flag.
- [x] Mint before setBondVault reverts: modifier `onlyBondVault` requires `_bondVaultSet`.
- [x] Epoch validation: `epochId >= 202600 && epochId <= 210012` at line 60, `month >= 1 && month <= 12` at line 63. Correct.
- [x] `isMatured` returns false for missing epochs (line 80).
- [x] User cannot `burn()` — external `burn` is `onlyBondVault`. ERC1155 has no user-facing `burn`, only internal `_burn`.
- [x] Transfer via `safeTransferFrom` works — ERC1155 standard, no override in ClaimBond.
- [ ] `_timestampFromYearMonth` — see L-1 (drift).
- [x] Month 13 reverts ("Invalid month").

### 4.5 `BondVault.sol`
- [x] **NO withdraw, NO owner, NO upgrade, NO admin** — confirmed by grep: no `Ownable`, no `owner`, no `withdraw`, no `upgrade`, no `selfdestruct`. Only exit: `redeemBond`.
- [x] Price read at redemption via `_getSafePrice()` (line 238).
- [x] Redeem works when paused — `paused` is only checked in `issueBond`.
- [x] SAFETY_FACTOR check at line 99: `totalCommittedUSD + usdPayout <= maxCommitUSD`.
- [x] Oracle zero → floor to `MIN_REDEEM_PRICE` via try/catch (line 238-243).
- [x] Reentrancy guarded by `nonReentrant` on both `issueBond` and `redeemBond`. OZ `_burn` emits TransferSingle to 0x0 and does NOT call `onERC1155Received` on the from address.
- [x] `totalCommittedUSD` underflow protected (lines 101-105).
- [ ] **Reserve empties**: when 82M LUMINA all redeemed, `lumina.balanceOf(this) = 0` → `require(balance >= luminaAmount)` reverts. Remaining bond holders cannot redeem. **This is a protocol-level failure mode**, not a contract bug, but worth documenting: the vault CAN technically run out if price collapses far below expectations. The `SAFETY_FACTOR_BPS = 5000` (50%) is the primary mitigation.
- [x] Circuit breaker gates ONLY issuance.
- [ ] `resetCircuitBreaker` permissionless — see H-3.
- [x] Precision loss on `luminaAmount = (usdAmount * 1e18) / currentPrice`. For `usdAmount = 1, price = 1e18`: result = 1. For `price > 1e18`: result = 0 (only for LUMINA > $1.00). Bond minimum is $100 → $80 payout → luminaAmount always > 0. OK.

### 4.6 `CapacityOracle.sol`
- [x] `pool == address(0)` → `getLuminaPrice` returns `emergencyPrice` (line 62).
- [ ] TWAP window = 30 min — resistant to single-block flash loans but NOT to sustained manipulation. Attacker with large capital could hold a price for 30+ min. Base mainnet LUMINA liquidity post-LBP will be low — 30 min TWAP on a thin pool is vulnerable. Consider 1-2h window post-launch.
- [x] `setEmergencyPrice(0)` reverts.
- [x] `setPool` is `onlyOwner`.
- [ ] `maxPoliciesPerDay` at extreme prices: if `price = 0`, returns 0. If `price = 1e30` (extreme), `reserveValueUSD = 82e24 × 1e30 / 1e18 = 82e36` — still fits uint256. `maxCommitUSD / (730 × 5)` = `82e36 / 3650` = `~2.2e34` policies. Absurd but not overflow. Mostly informational.
- [x] TickMath overflow: magic-number approximation follows Uniswap V3 standard. Safe for tick ∈ [-887272, 887272]. Asserts implicit via bitmask check. Tested pattern.

### 4.7 `TWAPBurner.sol`
- [x] `receivePremium` — callable by anyone. **Not a problem** because the caller is also the one sending USDC (via `transferFrom`). Worst case someone donates USDC — accelerates burn. No fund loss.
- [ ] `executeBurn` permissionless — front-runnable. See H-2.
- [ ] `amountOutMin = 0` — see H-2.
- [ ] Swap reverts on zero liquidity: entire tx reverts, USDC stays in contract. Not stuck; next call retries. OK.
- [x] `recoverToken` blocks USDC and LUMINA explicitly.
- [ ] Malicious token drain via `recoverToken`: any non-USDC/LUMINA token sent can be swept by owner. Acceptable.
- [ ] Cooldown = 15 min. Not sandwich-prevention (cooldown is between burns, not between swap and claim). See H-2.

### 4.8 `PolicyManagerV2.sol`
- [x] Only router via `onlyRouter` modifier (line 97). ✅
- [x] Double-trigger blocked: `require(!pr.triggered)` at line 195.
- [x] Expired policy cannot trigger: `require(!pr.expired)`. But `expired` is only set via `markExpired` which requires `block.timestamp > expiresAt`. An un-expired but past-window policy could still trigger. Shield's `verifyAndCalculate` should enforce `verifiedAt <= expiresAt` (BaseShield does via `EventAfterExpiry`).
- [x] `markExpired` gated by `block.timestamp > pr.expiresAt`.
- [ ] `payoutAmount / 1e6` truncation — see M-6.
- [x] `BondVault.issueBond` revert bubbles up — entire trigger reverts, bond not minted, policy not marked triggered. Atomic.
- [x] `activePolicies--` is safe: only decremented when confirmed >0 by invariant (each policy adds +1 in recordPolicy, only -1 in triggerPayout or markExpired, not both). But no explicit guard — underflow would revert in Solidity 0.8.x.

### 4.9 `CoverRouterV2.sol`
- [x] 100% to burner: `usdc.safeTransferFrom(payer, address(this), premium); twapBurner.receivePremium(premium);` — exact amount routed, nothing retained.
- [x] Formula correctness: `coverage × 8000 × 20 × 15000 / 10000^3` for 1000e6 coverage = `1000e6 × 2_400_000_000_000 / 10^12 = 2_400_000_000` → oops. Let me recompute: `1000e6 × 8000 × 20 × 15000 = 1000e6 × 2.4e12 = 2.4e21`. Divided by `10^12 = 1e12`: `2.4e9`. That's 2,400,000,000 = $2,400 — NOT $2.40. **BUG** in test expectation or formula? Wait: `1e6 = 10^6`. `1000e6 = 1000 × 10^6 = 10^9 = 1,000,000,000`. `10^9 × 8000 × 20 × 15000 = 10^9 × 2.4e12 = 2.4e21`. `/ 10^12 = 2.4e9`. That's 2,400,000,000 USDC units = $2,400 — wrong. But the test asserts `premium == 2_400_000` ($2.40). **Let me recheck** — `8000 × 20 × 15000 = 2,400,000,000 = 2.4e9`. `10^9 (coverage) × 2.4e9 = 2.4e18`. `/ 10^12 = 2.4e6`. OK so test expectation is correct. **I miscalculated above.** Formula is: `(coverage × 8000 × 20 × 15000) / (10^4)^3 = (10^9 × 2.4e9) / 10^12 = 2.4e18 / 10^12 = 2.4e6` = $2.40. ✅
- [x] Overflow: max realistic is `coverage = 10^24 (1 quintillion USDC) × 2.4e9 = 2.4e33`. Fits in uint256 (max ~1.16e77). Safe.
- [x] Relayer — see M-5.
- [x] `coverage = 0` reverts: `coverage < 100e6` check at line 136.
- [x] `SafeERC20.safeTransferFrom` handles silent failures.
- [ ] `approve` — see M-4.
- [x] `configureProduct` with `durationSeconds = 0` — the `if (products[pid].durationSeconds == 0) productList.push(...)` logic means a zero-duration config is indistinguishable from "unconfigured", and every re-config would add duplicate entries. Add explicit `require(_durationSeconds > 0)`.
- [x] Paused → `_purchase` reverts via `whenNotPaused` modifier.

---

## Phase 5 — Commercial flow verification

### Flow 1: Purchase without trigger — **PASS** (after C-1 fix)
Every step reviewed in code; with C-1 resolved, `recordPolicy → shield.createPolicy → shield.storeStrike → markExpired` works. Premium burn happens immediately via TWAPBurner. No silent failures found.

### Flow 2: Trigger → bond → redemption — **FAIL until C-1 + H-1 fixed**
After fixes: `submitTrigger → PolicyManagerV2.triggerPayout → shield.verifyAndCalculate → bondVault.issueBond → claimBond.mint`. At maturity: `bondVault.redeemBond → claimBond.burn → lumina.transfer`. Math verified: $800 bond × $0.50/LUMINA = 1,600 LUMINA ✅. Note M-6 on USDC 6-dec truncation.

### Flow 3: Marketplace (future) — **COMPATIBLE**
- `ClaimBond` is standard ERC-1155 with `safeTransferFrom` → marketplace can hold/transfer. ✅
- `TWAPBurner.receiveMarketplaceFee(amount)` exists (line 86) and accepts from any caller that does `transferFrom`. ✅
- `BondVault.redeemBond` is caller-addressed via `claimBond.balanceOf(msg.sender, id)` — a buyer on the secondary market can redeem without additional permissions. ✅

---

## Phase 6 — Edge cases and attacks

### 6.1 Flash loan on CapacityOracle
30-min TWAP mitigates single-block flash loans. Multi-block sustained manipulation remains possible on thin pools. **Risk medium post-launch**; consider 2-hr TWAP or Chainlink LUMINA feed when available.

### 6.2 Oracle replay
`MAX_PROOF_AGE = 900s` limits freshness. The EIP-712 domain (chainId + verifyingContract from LuminaOracleV2 audit work) pins proofs to specific contract. **Cross-contract replay across shields**: the `proofAsset` check in `_doVerifyAndCalculate` limits to same-asset; a proof for BTC at $40k cannot trigger an ETH policy. However, **same-asset cross-policy replay** is possible: two concurrent BTC policies with overlapping windows can be triggered by the same proof. Usually fine (they both should trigger), but verify no double-spend of oracle capacity.

### 6.3 Reentrancy in `BondVault.redeemBond`
Protected by `nonReentrant` + state update BEFORE external calls (`totalCommittedUSD -= usdAmount` at line 278, `claimBond.burn` at line 287, `lumina.transfer` at line 288). OZ ERC-1155 `_burn` does NOT notify from-address. Safe.

### 6.4 Griefing via min-policy spam
$100 coverage → $0.24 premium → $80 bond commitment. Gas per tx on Base ~$0.01-0.03. Economically not griefing (attacker loses more in premium than bond value received). But **capacity consumption** — 10,000 spam policies = $800K committed of $1.5M max → DoS. **Recommend** minimum premium of $1 USDC equivalent, OR increase min coverage to $500.

### 6.5 Circuit breaker flapping — see H-3.

### 6.6 BondVault drain scenario
If LUMINA drops 90% post-deploy to $0.0036, and 100% of bonds redeem at once:
- `reserveValueUSD = 82M × 0.0036 = $295K`
- Committed at issuance (during peak): up to $1.5M (at $0.036 spot)
- Vault owes ~$1.5M in USD value but has only $295K of LUMINA value → each bond holder gets **less LUMINA than expected** mathematically (since price is in denominator, lower price → more LUMINA per bond), so this is actually FINE: lower price means vault gives MORE LUMINA per $1 bond, potentially draining the vault's token balance.
- At extreme: `luminaAmount = usdAmount * 1e18 / 0.0036e18 = usdAmount × 278`. 1.5M × 278 = 417M LUMINA needed but only 82M available → **reserve insufficient** revert. Remaining holders cannot redeem until price recovers.

**Verdict:** The SAFETY_FACTOR (50%) + circuit breaker ($0.005 floor) + 24-month maturity smoothing jointly mitigate this. The most serious remaining scenario is a slow 90% drawdown AND simultaneous mass-redemption. Unlikely but not impossible. Flag as **protocol risk**, not contract bug.

### 6.7 Precision loss
`luminaAmount = usdAmount * 1e18 / currentPrice`
- `usdAmount = 1` (min unit), `currentPrice = 1e18` → `luminaAmount = 1` wei of LUMINA (= $1.00 if LUMINA = $1.00).
- `usdAmount = 1`, `currentPrice = 2e18` → `luminaAmount = 0` (truncation). But this requires LUMINA to exceed $2.00 AND a $1 bond, which is below protocol min ($100 → $80 payout → 80 bonds × ≥0.5 LUMINA = safe).
- **No meaningful precision loss** within the minimum coverage bounds.

---

## Phase 7 — Gas optimization opportunities

| Contract | Optimization |
|---|---|
| `BondVault.getStatus` | Recomputes same values as `availableCapacityUSD`. Cache or inline if hot path. |
| `CoverRouterV2._purchase` | `config.payoutRatioBps` used twice (premium + emit). Cache into local. |
| `PolicyManagerV2.recordPolicy` | `bondVault` is set-once → mark `immutable`. Save ~2.1K gas/call (SLOAD → PUSH32). |
| `CapacityOracle` | `luminaToken`, `usdcToken` → `immutable`. |
| `TWAPBurner.executeBurn` | `usdc.balanceOf` read once, then recompute `amountToSwap` from local. Already done. |
| `ClaimBond._update` | Inherits ERC1155 + ERC1155Supply `super._update` — minimal overhead. No action. |
| `LuminaTokenV2.burnFrom` | Override bypasses the `_spendAllowance` check from OZ ERC20Burnable. Correct for BURNER_ROLE but holder `burnFrom` path (which ISN'T used here since override gates to BURNER_ROLE only) is lost. Document that holders must use `burn(amount)`. |

---

## Recommendations (ordered by priority)

1. **Fix C-1** (struct mismatch). Align `IShieldV2.CreatePolicyParams` with `IShield.CreatePolicyParams`. Drop `deadline`/`nonce`; use `bytes extraData` (pass `""` from PolicyManagerV2 if unused).
2. **Document H-1** in V2 deploy script: shields must be constructed with `router_ = PolicyManagerV2 address`.
3. **Fix H-2**: Feed `amountOutMin` into `executeBurn` from CapacityOracle (5 min of work).
4. **Implement Foundry CI** on Linux runner. Install forge + forge-std, run `forge test -vvv` and fail CI on errors. Block all merges to `main` on green CI.
5. **Fix M-3, M-4**: Adopt `SafeERC20.safeTransfer` / `forceApprove` across V2.
6. **Fix H-3**: Add hysteresis + cooldown to `resetCircuitBreaker`.
7. **Fix M-6**: Document and unit-test the `payoutAmount / 1e6` truncation boundary.
8. **Reorder CEI** in PolicyManagerV2 (M-1). Low exploitability but cheap to fix.
9. **External audit** pre-mainnet (Zellic, Spearbit, or similar). This internal audit surfaces structural issues; does not replace adversarial review.
10. **Formal verification** of `BondVault` invariants: `totalCommittedUSD ≤ reserveValueUSD × SAFETY_FACTOR_BPS / 10_000` at all times, `SUM(bonds) = totalCommittedUSD`.

---

## Slither raw output (per file)

| File | Findings (after excluding low/info) |
|---|---|
| `LuminaTokenV2.sol` | 0 medium/high (dead-code in OZ lib, solc-version notes only) |
| `FounderVesting.sol` | 0 |
| `TreasuryVesting.sol` | 0 |
| `ClaimBond.sol` | 0 (all hits are in OZ Math `mulDiv` — library, accepted) |
| `BondVault.sol` | 1 medium (weak-prng in block.timestamp usage for epoch math — not a real finding, it's deterministic mapping) + divide-before-multiply (same reserveValueUSD pattern, false positive per capacity design) |
| `CapacityOracle.sol` | Many divide-before-multiply (all in TickMath, standard Uniswap pattern). 1 unused-return (try/catch success path). `immutable-states` suggestion (L-9). |
| `TWAPBurner.sol` | reentrancy-balance, reentrancy-no-eth, unchecked-transfer (M-3) |
| `PolicyManagerV2.sol` | reentrancy-no-eth (M-1), immutable-states (L-9) |
| `CoverRouterV2.sol` | unused-return on `approve` (M-4) |

---

*End of report. Generated by Claude Code Opus 4.6 (1M ctx). Static audit only — a full Foundry test pass on Linux + external audit are REQUIRED before any mainnet deployment.*
