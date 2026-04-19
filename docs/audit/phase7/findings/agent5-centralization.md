# Agent 5: Centralization & Upgrade Path Auditor -- Red Team Analysis

**Protocol:** LUMINA Protocol V5.0
**Date:** 2026-04-19
**Auditor Class:** Centralization & Upgrade Path Auditor (Agent 5)
**Scope:** All contracts in `src/` -- centralization points, admin power analysis, rug pull scenarios, emergency pause analysis, and migration paths.

---

## Table of Contents

1. [Centralization Risk Matrix](#centralization-risk-matrix)
2. [Immutability Analysis](#immutability-analysis)
3. [Multisig Power Inventory](#multisig-power-inventory)
4. [Immutable Parameters (Cannot Change Post-Deploy)](#immutable-parameters-cannot-change-post-deploy)
5. [Rug Pull Scenario Analysis](#rug-pull-scenario-analysis)
6. [Emergency Pause Analysis](#emergency-pause-analysis)
7. [Migration & Upgrade Paths](#migration--upgrade-paths)
8. [Recommendations](#recommendations)

---

## 1. Centralization Risk Matrix

| Contract | Centralization Point | Controller | Timelock? | Max Damage | Recommendation |
|---|---|---|---|---|---|
| **LuminaTokenV2** | `BURNER_ROLE` grant/revoke | `DEFAULT_ADMIN_ROLE` (deployer) | No | Grant BURNER_ROLE to malicious contract that burns all circulating supply | Renounce DEFAULT_ADMIN_ROLE after final TWAPBurner is confirmed |
| **LuminaTokenV2** | `burnFrom()` any address | `BURNER_ROLE` holder | No | Burn tokens from any holder without approval | Restrict to known contract addresses only |
| **TWAPBurner** | `setMaxSlippageBps()`, `setPoolFee()`, all config | `owner` (Gnosis Safe) | No | Set slippage to 10%, redirect reserves via `setReserves()` to attacker wallets | Add timelock on config changes |
| **TWAPBurner** | `setReserves()` | `owner` | No | Redirect buyback/ops/maintenance USDC to attacker-controlled addresses | Add timelock; validate against known contract types |
| **TWAPBurner** | `setAdaptiveMode()` + `setFeeDistributor()` | `owner` | No | Set malicious fee distributor that returns (0,10000,0,0) -- all funds to buybackReserve (attacker) | Validate distribution sums; timelock |
| **TWAPBurner** | `recoverToken()` | `owner` | No | Recover non-USDC/non-LUMINA tokens only | Low risk -- USDC/LUMINA protected |
| **BondVault** | `setAuthorizedCaller()` | `AUTHORIZED_CALLER_ADMIN_ROLE` | No | Authorize attacker to call `burnFromReserves()` (capped at 5% per tx) and `decreaseObligations()` | Timelock; multi-sig with higher threshold |
| **BondVault** | `DEFAULT_ADMIN_ROLE` | Deployer initially | No | Grant arbitrary roles, including AUTHORIZED_CALLER_ADMIN_ROLE | Renounce after setup |
| **ClaimBond** | `setBondVault()` (one-shot) | `owner` | N/A (one-shot) | If set to malicious vault: unlimited mint/burn of bonds | Already mitigated by one-shot pattern |
| **PolicyManagerV2** | `setRouter()`, `registerProduct()` | `owner` | No | Set malicious router that issues bonds without premiums; register malicious shield | Add timelock |
| **PolicyManagerV2** | `deactivateProduct()` | `owner` | No | Deactivate all products -- DoS for new policy purchases | Acceptable emergency power |
| **CoverRouterV2** | `setPolicyManager()`, `setTwapBurner()` | `owner` | No | Redirect premiums to attacker (setTwapBurner) or issue bonds without capacity checks (setPolicyManager) | Add timelock; make one-shot or frozen after setup |
| **CoverRouterV2** | `setPaused()` | `owner` | No | Pause all policy purchases indefinitely | Acceptable emergency power |
| **CoverRouterV2** | `setRelayer()` | `owner` | No | Authorize malicious relayer that buys policies on behalf of victims (requires victim USDC approval) | Low risk |
| **CoverRouterV2** | `configureProduct()` | `owner` | No | Set triggerProbBps to 10000 (100%) -- extreme pricing; or set payoutRatioBps to 0 -- no payouts | Timelock for pricing changes |
| **CapacityOracle** | `setPool()`, `setEmergencyPrice()` | `owner` | No | Set emergency price to extreme value -- inflates/deflates all oracle-dependent calculations | Add bounds on emergencyPrice |
| **CapacityOracle** | `setTwapWindow()` | `owner` | No | Reduce to 5 min -- weakens TWAP manipulation resistance | Enforce higher minimum (15 min) |
| **SolvencyOracle** | `setEmergencyPause()` | `ADMIN_ROLE` | No | Pause evaluations -- stale quadrant data used | Acceptable emergency power |
| **LuminaBondMarketplace** | `setTwapBurner()` | `FEE_MANAGER_ROLE` | No | Redirect marketplace fees to attacker address | Add timelock |
| **BuybackEngine** | `setDailyBuyback()` | `BUYBACK_OPERATOR_ROLE` | No | Set maxPricePercent=95, high budget -- buy overpriced bonds | 365-day activation delay mitigates |
| **MaintenanceReserve** | `spend()` | `SPENDER_ROLE` | No | Drain all USDC from maintenance reserve | Add timelock; enforce monthly cap strictly |
| **MaintenanceReserve** | `setMonthlyCap()` | `DEFAULT_ADMIN_ROLE` | No | Set cap to 0 (blocks spending) or type(uint256).max (unlimited) | Add upper bound on cap |
| **CEXLiquidityReserve** | `allocate()` | `ALLOCATOR_ROLE` | No | Allocate all vested LUMINA to attacker address | Monthly cap (1M LUMINA) limits speed of drain |
| **FounderVesting** | `updateRecipient()` | `owner` | No | Redirect vesting to attacker address | Make immutable after initial set, or add timelock |
| **TreasuryVesting** | `release()` | `owner` | No | Release 250K LUMINA/month to attacker address | Monthly max limits drain rate |

---

## 2. Immutability Analysis

### Contracts with NO Admin Functions (Truly Immutable)

| Contract | Admin Functions | Upgradeable? | Notes |
|---|---|---|---|
| **AdaptiveFeeDistributor** | NONE | No | Fully immutable. Pure lookup table. `solvencyOracle` is immutable. |
| **BaseShield** (and all Shield products) | NONE post-deploy | No | `router` and `oracle` are immutable. No admin setters. No pause. No upgrade path. |

**AdaptiveFeeDistributor** is the only contract in the protocol that is fully trustless and has zero admin surface. The Shield products are also effectively immutable once deployed, with their `router` and `oracle` addresses fixed at construction.

### Contracts with One-Shot Admin Functions (Semi-Immutable)

| Contract | One-Shot Function | Status After |
|---|---|---|
| **ClaimBond** | `setBondVault()` | `_bondVaultSet = true` -- cannot change |
| **BondVault** | `setPolicyManager()` | `_policyManagerSet = true` -- cannot change |

These contracts transition from "configurable" to "immutable" after their one-shot setter is called. The deployer/owner can only call once.

---

## 3. Multisig Power Inventory

Assuming the Gnosis Safe multisig controls the `owner` role on all Ownable contracts and the `DEFAULT_ADMIN_ROLE` on AccessControl contracts, here is the complete inventory of what the multisig can do:

### Token & Supply

| Action | Contract | Function | Impact |
|---|---|---|---|
| Grant BURNER_ROLE | LuminaTokenV2 | `grantRole()` | New address can burn any holder's tokens |
| Revoke BURNER_ROLE | LuminaTokenV2 | `revokeRole()` | Disable TWAPBurner's ability to burn |

### Premium & Fee Flow

| Action | Contract | Function | Impact |
|---|---|---|---|
| Redirect premiums | CoverRouterV2 | `setTwapBurner()` | All future premiums go to new address |
| Redirect marketplace fees | LuminaBondMarketplace | `setTwapBurner()` | All future fees go to new address |
| Redirect reserve distributions | TWAPBurner | `setReserves()` | Buyback/ops/maintenance USDC redirected |
| Change fee distribution | TWAPBurner | `setFeeDistributor()` | New distributor controls the split |
| Toggle adaptive mode | TWAPBurner | `setAdaptiveMode()` | Switch between 100% burn and 4-bucket split |

### Bond System

| Action | Contract | Function | Impact |
|---|---|---|---|
| Authorize bond callers | BondVault | `setAuthorizedCaller()` | New address can burn reserves (5% cap) and reduce obligations |
| Register products | PolicyManagerV2 | `registerProduct()` | New Shield products can issue policies |
| Deactivate products | PolicyManagerV2 | `deactivateProduct()` | Existing products stop accepting policies |
| Change router | PolicyManagerV2 | `setRouter()` | New router can record policies and trigger payouts |

### Treasury

| Action | Contract | Function | Impact |
|---|---|---|---|
| Spend maintenance USDC | MaintenanceReserve | `spend()` | Transfer USDC to any address |
| Allocate CEX LUMINA | CEXLiquidityReserve | `allocate()` | Transfer vested LUMINA to any address |
| Release treasury LUMINA | TreasuryVesting | `release()` | Transfer up to 250K LUMINA/month |
| Change founder recipient | FounderVesting | `updateRecipient()` | Redirect 8M LUMINA vesting |

### Configuration

| Action | Contract | Function | Impact |
|---|---|---|---|
| Pause policy purchases | CoverRouterV2 | `setPaused()` | Block all new policies |
| Change slippage tolerance | TWAPBurner | `setMaxSlippageBps()` | 0.5%--10% range |
| Change burn amount limits | TWAPBurner | `setMinBurnAmount()`, `setMaxBurnAmount()` | Adjust burn sizing |
| Change burn cooldown | TWAPBurner | `setBurnCooldown()` | 1 min -- 24 hr range |
| Change TWAP window | CapacityOracle | `setTwapWindow()` | 5 min -- 2 hr range |
| Set emergency price | CapacityOracle | `setEmergencyPrice()` | Fallback oracle price |
| Change pool address | CapacityOracle | `setPool()` | Point oracle to different pool |
| Pause solvency evaluations | SolvencyOracle | `setEmergencyPause()` | Stale quadrant data |
| Configure product pricing | CoverRouterV2 | `configureProduct()` | Premium/payout parameters |

---

## 4. Immutable Parameters (Cannot Change Post-Deploy)

These values are hardcoded as `constant` or `immutable` and can NEVER be modified:

### Token

| Parameter | Value | Contract |
|---|---|---|
| `MAX_SUPPLY` | 100,000,000 LUMINA | LuminaTokenV2 |
| Token name/symbol | "Lumina Protocol" / "LUMINA" | LuminaTokenV2 |
| Initial distribution | 70M/14M/8M/5M/3M | LuminaTokenV2 constructor |

### Bond System

| Parameter | Value | Contract |
|---|---|---|
| `SAFETY_FACTOR_BPS` | 5000 (50%) | BondVault |
| `BOND_MATURITY_SECONDS` | 730 days | BondVault |
| `MIN_PRICE` | $0.005 | BondVault |
| `RESET_PRICE` | $0.008 | BondVault |
| `MIN_REDEEM_PRICE` | $0.001 | BondVault |
| `BREAKER_COOLDOWN` | 1 hour | BondVault |
| `lumina` token address | Set at deploy | BondVault |
| `claimBond` address | Set at deploy | BondVault |
| `priceOracle` address | Set at deploy | BondVault |

### Marketplace

| Parameter | Value | Contract |
|---|---|---|
| `SELLER_FEE_BPS` | 150 (1.5%) | LuminaBondMarketplace |
| `BUYER_FEE_BPS` | 150 (1.5%) | LuminaBondMarketplace |
| `claimBond` address | Set at deploy | LuminaBondMarketplace |
| `usdc` address | Set at deploy | LuminaBondMarketplace |

### Buyback

| Parameter | Value | Contract |
|---|---|---|
| `ACTIVATION_DELAY` | 365 days | BuybackEngine |
| `MIN_SOLVENCY_FOR_DOUBLE_BURN` | 15000 (150%) | BuybackEngine |
| All dependency addresses | Set at deploy | BuybackEngine |

### Vesting

| Parameter | Value | Contract |
|---|---|---|
| `TOTAL_AMOUNT` (Founder) | 8,000,000 LUMINA | FounderVesting |
| `TRANCHE_INTERVAL` | 31 days | FounderVesting |
| `TOTAL_TRANCHES` | 3 | FounderVesting |
| `FALLBACK_DURATION` | 1460 days (4 years) | FounderVesting |
| `SUSTAINED_DURATION` | 7 days | FounderVesting |
| AltSeason thresholds | ETH/BTC>0.050, ETH>$4K, BorrowRate>7% | FounderVesting |
| `TOTAL_AMOUNT` (Treasury) | 3,000,000 LUMINA | TreasuryVesting |
| `LOCK_DURATION` | 180 days | TreasuryVesting |
| `MAX_MONTHLY_RELEASE` | 250,000 LUMINA | TreasuryVesting |

### CEX Reserve

| Parameter | Value | Contract |
|---|---|---|
| `TOTAL_AMOUNT` | 14,000,000 LUMINA | CEXLiquidityReserve |
| `IMMEDIATE_AMOUNT` | 2,800,000 LUMINA | CEXLiquidityReserve |
| `VESTING_AMOUNT` | 8,400,000 LUMINA | CEXLiquidityReserve |
| `STRATEGIC_AMOUNT` | 2,800,000 LUMINA | CEXLiquidityReserve |
| `VESTING_DURATION` | 730 days | CEXLiquidityReserve |
| `STRATEGIC_LOCK` | 547 days | CEXLiquidityReserve |
| `MONTHLY_CAP` | 1,000,000 LUMINA | CEXLiquidityReserve |

### TWAPBurner Fallbacks

| Parameter | Value | Contract |
|---|---|---|
| `FALLBACK_BURN_BPS` | 8500 (85%) | TWAPBurner |
| `FALLBACK_BUYBACK_BPS` | 800 (8%) | TWAPBurner |
| `FALLBACK_OPS_BPS` | 200 (2%) | TWAPBurner |
| `FALLBACK_MAINTENANCE_BPS` | 500 (5%) | TWAPBurner |

---

## 5. Rug Pull Scenario Analysis

### Scenario 1: Direct Fund Drain via TWAPBurner Reserve Redirect

**Threat Level: HIGH (if no timelock)**

**Attack path:**
1. Multisig calls `TWAPBurner.setReserves(attackerA, attackerB, attackerC)`.
2. Multisig calls `TWAPBurner.setAdaptiveMode(true)`.
3. Multisig calls `TWAPBurner.setFeeDistributor(maliciousDistributor)` where the distributor returns `(0, 10000, 0, 0)` -- 100% to buybackReserve (attackerA).
4. All future premiums and marketplace fees flow to attackerA instead of being burned.

**Maximum damage:** All accumulated USDC in TWAPBurner (up to `maxBurnAmount` per cycle, but new inflows are immediately redirectable). Over time, this captures 100% of protocol revenue.

**Mitigation status:** No timelock. Requires multisig compromise (multiple signers). The `_getDistribution()` function validates `sum <= 10000` but does not prevent extreme allocations.

### Scenario 2: BondVault Reserve Drain via Authorized Caller

**Threat Level: MEDIUM**

**Attack path:**
1. Multisig (with `AUTHORIZED_CALLER_ADMIN_ROLE`) calls `BondVault.setAuthorizedCaller(attacker, true)`.
2. Attacker calls `burnFromReserves(maxBurnPerTx)` repeatedly.
3. Each call burns up to 5% of vault balance. After 14 calls: 0.95^14 = 48.7% remaining. After 50 calls: 0.95^50 = 7.7% remaining.

**Maximum damage:** Near-complete destruction of BondVault reserves. However, tokens are burned (sent to address(0)), not stolen. The attacker gains nothing directly -- this is a griefing/destruction attack, not a theft.

**Note:** `decreaseObligations()` can reduce `totalCommittedUSD` to 0, making the protocol appear solvent even with depleted reserves. This could mask insolvency from external observers.

**Mitigation status:** 5% per-tx cap slows the drain. No cooldown between calls. No total burn limit per epoch.

### Scenario 3: Premium Siphon via CoverRouterV2

**Threat Level: HIGH (if no timelock)**

**Attack path:**
1. Multisig calls `CoverRouterV2.setTwapBurner(attackerContract)`.
2. `attackerContract` implements `receivePremium()` and simply holds the USDC.
3. All future premiums are captured by the attacker.

**Maximum damage:** All future protocol revenue. Past USDC in the real TWAPBurner is safe (cannot be recovered as USDC by the owner due to `require(token != address(usdc))`).

### Scenario 4: Marketplace Fee Redirect

**Threat Level: MEDIUM**

**Attack path:**
1. `FEE_MANAGER_ROLE` holder calls `LuminaBondMarketplace.setTwapBurner(attacker)`.
2. All future marketplace fees (3% of trading volume) go to attacker.

**Maximum damage:** Ongoing fee capture. Limited by marketplace trading volume.

### Scenario 5: Founder Vesting Redirect

**Threat Level: MEDIUM**

**Attack path:**
1. Owner calls `FounderVesting.updateRecipient(attacker)`.
2. When tranches release, 8M LUMINA goes to attacker instead of founder.

**Maximum damage:** 8M LUMINA (~$288K at $0.036). Requires AltSeason trigger or 4-year fallback.

**Mitigation:** Vesting conditions are immutable. Tokens cannot be released faster than the schedule allows.

### Scenario 6: LuminaTokenV2 BURNER_ROLE Abuse

**Threat Level: CRITICAL (if DEFAULT_ADMIN_ROLE not renounced)**

**Attack path:**
1. `DEFAULT_ADMIN_ROLE` holder grants `BURNER_ROLE` to malicious contract.
2. Malicious contract calls `burnFrom(victim, amount)` on any token holder.
3. Tokens are destroyed without holder consent.

**Maximum damage:** Destruction of all circulating LUMINA (not theft, but total value destruction). BondVault reserves, CEX reserve, and all holder balances can be zeroed.

**Mitigation:** `burnFrom()` overrides OpenZeppelin's version and removes the allowance check, relying solely on `onlyRole(BURNER_ROLE)`. If `DEFAULT_ADMIN_ROLE` is renounced, `BURNER_ROLE` cannot be granted to new addresses, and the existing TWAPBurner is the only burner.

**CRITICAL RECOMMENDATION:** Renounce `DEFAULT_ADMIN_ROLE` on LuminaTokenV2 after the final TWAPBurner is deployed and granted `BURNER_ROLE`. Document that this makes the `BURNER_ROLE` permanent and unmodifiable.

### Scenario 7: MaintenanceReserve Full Drain

**Threat Level: MEDIUM**

**Attack path:**
1. `DEFAULT_ADMIN_ROLE` sets `monthlyCap` to `type(uint256).max`.
2. `SPENDER_ROLE` calls `spend()` draining all USDC to attacker address.

**Maximum damage:** All USDC in MaintenanceReserve. Limited by actual balance (inflows from adaptive fee distribution at 2--8% of premiums).

### Summary: Rug Pull Feasibility

| Scenario | Threat Level | Stolen/Destroyed | Requires | Speed |
|---|---|---|---|---|
| TWAPBurner reserve redirect | HIGH | Ongoing revenue | Multisig compromise | Immediate |
| BondVault reserve burn | MEDIUM | Reserves destroyed | Multisig + AUTHORIZED_CALLER_ADMIN | ~50 txs for 90% drain |
| Premium siphon | HIGH | Ongoing revenue | Multisig compromise | Immediate |
| Marketplace fee redirect | MEDIUM | Ongoing fees | FEE_MANAGER_ROLE | Immediate |
| Founder vesting redirect | MEDIUM | 8M LUMINA | Owner | Gated by vesting schedule |
| BURNER_ROLE abuse | CRITICAL | All circulating supply | DEFAULT_ADMIN_ROLE | Immediate |
| Maintenance drain | MEDIUM | Reserve USDC | DEFAULT_ADMIN_ROLE + SPENDER_ROLE | Immediate |

---

## 6. Emergency Pause Analysis

| Contract | Pause Mechanism | Who Can Pause? | What Is Paused? | What Still Works? |
|---|---|---|---|---|
| **BondVault** | `paused` flag + `triggerBreaker()` | **Anyone** (permissionless, if price < $0.005) | New bond issuance (`issueBond()`) | Bond redemption (`redeemBond()`), all views |
| **BondVault** | `resetCircuitBreaker()` | **Anyone** (permissionless, if price >= $0.008 and cooldown elapsed) | N/A (resume) | N/A |
| **CoverRouterV2** | `paused` flag | **Owner** only (`setPaused()`) | Policy purchases (`purchasePolicy`, `purchasePolicyFor`) | Trigger submission, all views |
| **SolvencyOracle** | `emergencyPaused` flag | **ADMIN_ROLE** (`setEmergencyPause()`) | `evaluate()` | All views (return stale data), `getSolvencyRatio()` still computes live |
| **BaseShield** / Products | None | N/A | N/A | All functions always available |
| **TWAPBurner** | None (implicit via cooldown/balance) | N/A | N/A | All functions always available |
| **BondVault** redemption | **NEVER paused** | N/A | N/A | Redemption always available even during circuit breaker |
| **LuminaBondMarketplace** | None | N/A | N/A | All functions always available |
| **BuybackEngine** | Activation delay (365 days) | N/A (time-based) | All buyback operations | Views only |

### Key Design Decision: Redemption Never Pauses

The BondVault circuit breaker (`paused = true`) explicitly does NOT block `redeemBond()`. This is a critical trust property: bond holders can always redeem matured bonds regardless of market conditions or admin actions. The comment in the code is explicit:

> "Redemption is ALWAYS available -- even if circuit breaker is active."

This means even in a worst-case scenario where the multisig is compromised, bond holders can still exit by redeeming matured bonds. The `MIN_REDEEM_PRICE` floor ($0.001) ensures redemption at extremely low prices still works (paying more LUMINA per dollar).

### Pause Cascade Analysis

If multiple pauses activate simultaneously:

1. **Circuit breaker triggered** (price < $0.005): No new policies can be purchased (BondVault rejects issuance). Existing policies still active. Redemption works.
2. **CoverRouter paused** by owner: No new policies. Triggers can still be submitted. Premiums stop flowing to TWAPBurner.
3. **SolvencyOracle paused**: Evaluations stop. AdaptiveFeeDistributor uses stale quadrant data. TWAPBurner falls back to hardcoded distribution (85% burn / 8% buyback / 2% ops / 5% maintenance).

**Worst case:** All three paused + all products deactivated. Protocol is frozen for new business but existing obligations (bonds, policies) continue to function. Marketplace remains open. Redemption works.

---

## 7. Migration & Upgrade Paths

### How to Upgrade If a Bug Is Found

The protocol has NO upgradeable proxies. All contracts are deployed as final implementations. Migration requires deploying new contracts and rewiring dependencies.

### Migration Path by Contract

#### TWAPBurner (Most Likely Upgrade Target)

1. Deploy new TWAPBurner with same USDC/LUMINA/SwapRouter.
2. On CoverRouterV2: call `setTwapBurner(newAddress)`.
3. On LuminaBondMarketplace: call `setTwapBurner(newAddress)` (requires `FEE_MANAGER_ROLE`).
4. On LuminaTokenV2: grant `BURNER_ROLE` to new TWAPBurner (requires `DEFAULT_ADMIN_ROLE` -- ONLY if not renounced).
5. Old TWAPBurner: remaining USDC can be burned via old `executeBurn()` (permissionless). Non-USDC/LUMINA tokens recoverable via `recoverToken()`.

**Risk:** If `DEFAULT_ADMIN_ROLE` is renounced on LuminaTokenV2, step 4 is impossible. The new TWAPBurner cannot burn LUMINA. This is the trade-off between immutability and upgradeability.

**Recommendation:** Do NOT renounce `DEFAULT_ADMIN_ROLE` until the TWAPBurner design is final. Instead, transfer it to a timelock contract with a 7-day delay.

#### CoverRouterV2

1. Deploy new CoverRouterV2.
2. On PolicyManagerV2: call `setRouter(newRouter)`.
3. Old router: no residual state (premiums already forwarded). No stuck funds.

**Straightforward** -- PolicyManagerV2's `setRouter()` allows hot-swap.

#### PolicyManagerV2

1. Deploy new PolicyManagerV2 with same BondVault.
2. On CoverRouterV2: call `setPolicyManager(newPM)`.
3. On all Shield products: **CANNOT change router**. Shield products have `immutable router`.
4. **Must redeploy ALL Shield products** pointing to the new PolicyManagerV2.
5. Re-register all products in the new PolicyManagerV2.

**HIGH cost** -- requires redeploying and reconfiguring the entire product suite.

#### BondVault

1. Deploy new BondVault with same LUMINA, ClaimBond, PriceOracle.
2. On ClaimBond: **CANNOT call `setBondVault()`** -- one-shot already used.
3. **CANNOT migrate BondVault without redeploying ClaimBond.**
4. If ClaimBond is redeployed, all existing bonds are lost (new ERC-1155 contract).
5. **Migration is destructive** -- existing bond holders lose their bonds unless a manual migration mechanism is built.

**CRITICAL** -- BondVault + ClaimBond are effectively non-upgradeable as a pair. A bug in either requires a manual migration with user cooperation.

**Recommendation:** If the BondVault needs migration, deploy a "BondMigrator" contract that reads balances from the old ClaimBond and mints equivalent tokens on the new ClaimBond. This requires the old ClaimBond to remain readable (it will be, as it is on-chain).

#### CapacityOracle

1. Deploy new CapacityOracle.
2. On TWAPBurner: call `setCapacityOracle(newOracle)`.
3. On BondVault: **CANNOT change `priceOracle`** -- it is `immutable`.
4. **BondVault is permanently bound to its oracle.** If the oracle has a bug, BondVault cannot be fixed without redeployment (see BondVault migration above).

**CRITICAL** -- The `priceOracle` immutable binding in BondVault means oracle bugs affect bond issuance and redemption permanently.

#### Shield Products

1. Deploy new Shield (e.g., FlashBTCShield1h_v2) with same router and oracle.
2. On PolicyManagerV2: call `registerProduct(newProductId, newShield)`.
3. On CoverRouterV2: call `configureProduct(newProductId, ...)`.
4. Deactivate old product: `deactivateProduct(oldProductId)`.
5. Existing policies on the old Shield continue to function (trigger, expire, redeem).

**Cleanest migration path** -- products are designed to be replaceable.

### Migration Difficulty Matrix

| Component | Can Hot-Swap? | Requires Redeployment? | User Impact | Difficulty |
|---|---|---|---|---|
| TWAPBurner | Yes (if ADMIN not renounced) | New TWAPBurner only | None | LOW |
| CoverRouterV2 | Yes | New router only | None | LOW |
| Shield Products | Yes | New shield only | Old policies unaffected | LOW |
| PolicyManagerV2 | Partial | New PM + ALL shields | Old policies orphaned | HIGH |
| CapacityOracle (for TWAPBurner) | Yes | New oracle only | None | LOW |
| CapacityOracle (for BondVault) | No | Cannot change | Permanent | CRITICAL |
| BondVault | No | BondVault + ClaimBond | Bond holders affected | CRITICAL |
| ClaimBond | No | ClaimBond + BondVault | Bond holders affected | CRITICAL |
| LuminaTokenV2 | No | Not upgradeable | All holders affected | CRITICAL |
| AdaptiveFeeDistributor | Yes (via TWAPBurner) | New distributor only | None | LOW |
| SolvencyOracle | Partial | Cannot change BondVault/CapacityOracle bindings | Stale data risk | MEDIUM |

---

## 8. Recommendations

### Priority 1: CRITICAL

1. **Transfer `DEFAULT_ADMIN_ROLE` on LuminaTokenV2 to a TimelockController** (e.g., 7-day delay) instead of the deployer EOA. This preserves upgradeability while adding governance delay. Do NOT renounce until TWAPBurner is battle-tested (6+ months on mainnet).

2. **Add a TimelockController** (OpenZeppelin) as the owner of TWAPBurner, CoverRouterV2, PolicyManagerV2, and CapacityOracle. Minimum delay: 48 hours. This mitigates all "immediate redirect" rug pull scenarios.

3. **Review `burnFrom()` override in LuminaTokenV2.** The current implementation removes the allowance check entirely, allowing any `BURNER_ROLE` holder to burn from ANY address. Consider restricting to `burn()` (self-burn only, from the TWAPBurner's own balance) rather than `burnFrom()`.

### Priority 2: HIGH

4. **Add a cooldown to `BondVault.burnFromReserves()`** -- e.g., max 1 call per hour per authorized caller. Currently, 50 rapid calls can drain 92% of reserves.

5. **Add a daily/weekly cap to `BondVault.decreaseObligations()`** to prevent an authorized caller from zeroing out obligations in a single block, masking insolvency.

6. **Make `FounderVesting.updateRecipient()` a two-step process** (propose + accept) or add a timelock, to prevent instant redirection of 8M LUMINA.

### Priority 3: MEDIUM

7. **Emit events on all admin config changes in TWAPBurner** (some are missing, e.g., `setReserves()` does not emit for all reserves).

8. **Consider making `CoverRouterV2.setPolicyManager()` and `setTwapBurner()` one-shot** or adding a governance delay. These functions can completely redirect protocol fund flows.

9. **Add an upper bound to `CapacityOracle.setEmergencyPrice()`** to prevent absurd values (e.g., max $10 per LUMINA = 10e18).

10. **Document the irrecoverable nature of BondVault + ClaimBond** -- a bug in either contract requires manual user migration. Consider a future upgrade to a proxy pattern for ClaimBond only (the ERC-1155 that holds user assets).

---

## Summary

LUMINA Protocol V5.0 has a **moderate centralization profile**. The multisig can redirect fund flows (premiums, fees, reserves) and modify system parameters, but cannot directly steal tokens from user wallets (except via the `BURNER_ROLE` on LuminaTokenV2, which can destroy but not steal). The most critical centralization risks are:

1. **`BURNER_ROLE` on LuminaTokenV2** -- can burn any holder's tokens without consent.
2. **Fund flow redirection** via `setTwapBurner()`, `setReserves()`, and `setPolicyManager()` -- no timelock.
3. **Non-upgradeable core pair** (BondVault + ClaimBond) -- a bug here is irrecoverable without user-cooperative migration.

The protocol's defense-in-depth is strong for the bond system (immutable maturity, always-available redemption, circuit breaker with hysteresis), but the fee/revenue pipeline has insufficient governance delay. Adding a 48-hour TimelockController to all owner roles would convert most HIGH risks to LOW.

---

*End of Agent 5 Centralization & Upgrade Path Analysis*
