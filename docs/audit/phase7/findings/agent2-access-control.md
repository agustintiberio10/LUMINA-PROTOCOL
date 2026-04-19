# Access Control Matrix — LUMINA Protocol V5.0

**Auditor:** Agent 2 — Access Control Auditor
**Date:** 2026-04-19
**Scope:** All contracts under `src/` (15 primary contracts + BaseShield abstract)
**Methodology:** Exhaustive enumeration of every access-controlled function, role hierarchy analysis, escalation path modeling, and multisig compromise impact assessment.

---

## 1. Complete Access Control Matrix

### 1.1 AccessControl-based Contracts (OpenZeppelin Roles)

| Contract | Function | Required Role / Access | Expected Role Holder | Notes |
|---|---|---|---|---|
| **BondVault** | `issueBond()` | `msg.sender == policyManager` | PolicyManagerV2 | Hardcoded address check, not role-based |
| **BondVault** | `redeemBond()` | Permissionless | Any bond holder | Always available, even during circuit breaker |
| **BondVault** | `triggerBreaker()` | Permissionless | Anyone | Only succeeds if price < MIN_PRICE |
| **BondVault** | `resetCircuitBreaker()` | Permissionless | Anyone | Only succeeds if price >= RESET_PRICE + cooldown |
| **BondVault** | `setPolicyManager()` | `msg.sender == _deployer` | Deployer (one-shot) | Immutable after first call |
| **BondVault** | `setAuthorizedCaller()` | `AUTHORIZED_CALLER_ADMIN_ROLE` | Multisig | Controls BuybackEngine authorization |
| **BondVault** | `decreaseObligations()` | `onlyAuthorized` (mapping) | BuybackEngine | Set via `setAuthorizedCaller()` |
| **BondVault** | `burnFromReserves()` | `onlyAuthorized` (mapping) | BuybackEngine | 5% per-TX cap enforced |
| **BondVault** | `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Deployer/Multisig | Inherited from AccessControl |
| **ClaimBond** | `setBondVault()` | `onlyOwner` | Deployer (one-shot) | `_bondVaultSet` prevents re-call |
| **ClaimBond** | `mint()` | `onlyBondVault` | BondVault | Hardcoded address check |
| **ClaimBond** | `burn()` | `onlyBondVault` | BondVault | Hardcoded address check |
| **ClaimBond** | `burnByHolder()` | `msg.sender == account` or `isApprovedForAll` | Bond holder or approved operator | V5.0 addition for BuybackEngine |
| **ClaimBond** | `transferOwnership()` | `onlyOwner` | Deployer | Inherited from Ownable |
| **LuminaTokenV2** | `burnFrom()` | `BURNER_ROLE` | TWAPBurner | Overrides ERC20Burnable |
| **LuminaTokenV2** | `burn()` | Permissionless (self-burn) | Any token holder | Inherited from ERC20Burnable |
| **LuminaTokenV2** | `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Deployer/Multisig | WARNING: renouncing locks BURNER_ROLE management |
| **SolvencyOracle** | `evaluate()` | Permissionless | Anyone (keeper) | Interval-gated (1 day) |
| **SolvencyOracle** | `setEmergencyPause()` | `ADMIN_ROLE` | Multisig | Can halt evaluations |
| **SolvencyOracle** | `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Multisig | Standard AccessControl |
| **BuybackEngine** | `setDailyBuyback()` | `BUYBACK_OPERATOR_ROLE` | Multisig | Configures daily buyback parameters |
| **BuybackEngine** | `executeOffer()` | Permissionless | Anyone | Activation delay (365 days) + daily config gating |
| **BuybackEngine** | `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Multisig | Standard AccessControl |
| **LuminaBondMarketplace** | `list()` | Permissionless | Any bond holder | Must own bonds to list |
| **LuminaBondMarketplace** | `cancel()` | `msg.sender == l.seller` | Listing creator | Only seller can cancel |
| **LuminaBondMarketplace** | `executeBuy()` | Permissionless | Any buyer | Must have USDC |
| **LuminaBondMarketplace** | `setTwapBurner()` | `FEE_MANAGER_ROLE` | Multisig | Controls fee destination |
| **LuminaBondMarketplace** | `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Multisig | Standard AccessControl |
| **CEXLiquidityReserve** | `allocate()` | `ALLOCATOR_ROLE` | Multisig | Monthly cap: 1M LUMINA |
| **CEXLiquidityReserve** | `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Multisig | Standard AccessControl |
| **MaintenanceReserve** | `spend()` | `SPENDER_ROLE` | Multisig | Optional monthly cap |
| **MaintenanceReserve** | `setMonthlyCap()` | `DEFAULT_ADMIN_ROLE` | Multisig | Can disable cap (set to 0) |
| **MaintenanceReserve** | `recoverToken()` | `DEFAULT_ADMIN_ROLE` | Multisig | Cannot recover USDC |
| **MaintenanceReserve** | `grantRole()` / `revokeRole()` | `DEFAULT_ADMIN_ROLE` | Multisig | Standard AccessControl |

### 1.2 Ownable-based Contracts

| Contract | Function | Required Access | Expected Holder | Notes |
|---|---|---|---|---|
| **TWAPBurner** | `setPoolFee()` | `onlyOwner` | Multisig | Valid fee tiers: 500, 3000, 10000 |
| **TWAPBurner** | `setMaxSlippageBps()` | `onlyOwner` | Multisig | Range: 50-1000 bps |
| **TWAPBurner** | `setMinBurnAmount()` | `onlyOwner` | Multisig | Min: $0.10 |
| **TWAPBurner** | `setMaxBurnAmount()` | `onlyOwner` | Multisig | Must be >= minBurnAmount |
| **TWAPBurner** | `setBurnCooldown()` | `onlyOwner` | Multisig | Range: 60s-86400s |
| **TWAPBurner** | `setAuthorizedSender()` | `onlyOwner` | Multisig | Controls keeper authorization |
| **TWAPBurner** | `setCapacityOracle()` | `onlyOwner` | Multisig | Non-zero address required |
| **TWAPBurner** | `setFeeDistributor()` | `onlyOwner` | Multisig | Can be set to address(0) to disable |
| **TWAPBurner** | `setReserves()` | `onlyOwner` | Multisig | Sets buyback/ops/maintenance addresses |
| **TWAPBurner** | `setMaintenanceReserve()` | `onlyOwner` | Multisig | Individual setter |
| **TWAPBurner** | `setAdaptiveMode()` | `onlyOwner` | Multisig | Requires distributor + reserves set |
| **TWAPBurner** | `recoverToken()` | `onlyOwner` | Multisig | Cannot recover USDC or LUMINA |
| **TWAPBurner** | `transferOwnership()` | `onlyOwner` | Multisig | Inherited from Ownable |
| **CoverRouterV2** | `configureProduct()` | `onlyOwner` | Multisig | Sets pricing parameters |
| **CoverRouterV2** | `setRelayer()` | `onlyOwner` | Multisig | Authorize/revoke relayers |
| **CoverRouterV2** | `setPaused()` | `onlyOwner` | Multisig | Emergency pause |
| **CoverRouterV2** | `setPolicyManager()` | `onlyOwner` | Multisig | Can change PM address (no one-shot) |
| **CoverRouterV2** | `setTwapBurner()` | `onlyOwner` | Multisig | Can change burner address (no one-shot) |
| **CoverRouterV2** | `transferOwnership()` | `onlyOwner` | Multisig | Inherited from Ownable |
| **PolicyManagerV2** | `setRouter()` | `onlyOwner` | Multisig | Can change router (no one-shot) |
| **PolicyManagerV2** | `registerProduct()` | `onlyOwner` | Multisig | Register new Shield products |
| **PolicyManagerV2** | `deactivateProduct()` | `onlyOwner` | Multisig | Deactivate products |
| **PolicyManagerV2** | `transferOwnership()` | `onlyOwner` | Multisig | Inherited from Ownable |
| **CapacityOracle** | `setPool()` | `onlyOwner` | Multisig | Change Uniswap pool |
| **CapacityOracle** | `setTwapWindow()` | `onlyOwner` | Multisig | Range: 300-7200 seconds |
| **CapacityOracle** | `setEmergencyPrice()` | `onlyOwner` | Multisig | Fallback price (must be > 0) |
| **CapacityOracle** | `transferOwnership()` | `onlyOwner` | Multisig | Inherited from Ownable |
| **FounderVesting** | `updateRecipient()` | `onlyOwner` | Multisig/Founder | Change vesting recipient |
| **FounderVesting** | `checkAltSeason()` | Permissionless | Anyone | Oracle-gated conditions |
| **FounderVesting** | `triggerFallback()` | Permissionless | Anyone | Time-gated (4 years) |
| **FounderVesting** | `releaseTranche()` | Permissionless | Anyone | Time-gated (31-day intervals) |
| **FounderVesting** | `transferOwnership()` | `onlyOwner` | Multisig/Founder | Inherited from Ownable |
| **TreasuryVesting** | `release()` | `onlyOwner` | Multisig | 6-month lock, 250K/month cap |
| **TreasuryVesting** | `transferOwnership()` | `onlyOwner` | Multisig | Inherited from Ownable |

### 1.3 No-Admin Contracts

| Contract | Admin Functions | Notes |
|---|---|---|
| **AdaptiveFeeDistributor** | NONE | Fully immutable. No owner, no roles, no setters. |
| **BaseShield** (and all concrete Shields) | NONE (post-deploy) | `router` and `oracle` are immutable. No admin functions. |

---

## 2. Role Hierarchy and Escalation Paths

### 2.1 Role Hierarchy Diagram

```
DEFAULT_ADMIN_ROLE (per-contract)
    |
    +-- BondVault.AUTHORIZED_CALLER_ADMIN_ROLE
    |       +-- controls authorizedCallers mapping
    |
    +-- LuminaTokenV2.BURNER_ROLE
    |       +-- can burn any address's LUMINA (burnFrom)
    |
    +-- SolvencyOracle.ADMIN_ROLE
    |       +-- can pause/unpause evaluations
    |
    +-- BuybackEngine.BUYBACK_OPERATOR_ROLE
    |       +-- can configure daily buyback parameters
    |
    +-- LuminaBondMarketplace.FEE_MANAGER_ROLE
    |       +-- can redirect fee destination (twapBurner)
    |
    +-- CEXLiquidityReserve.ALLOCATOR_ROLE
    |       +-- can allocate LUMINA from sub-buckets
    |
    +-- MaintenanceReserve.SPENDER_ROLE
            +-- can spend USDC from reserve
```

### 2.2 Escalation Paths

**Path 1: DEFAULT_ADMIN_ROLE -> BURNER_ROLE (LuminaTokenV2)**
- Holder of `DEFAULT_ADMIN_ROLE` on LuminaTokenV2 can grant `BURNER_ROLE` to any address.
- `BURNER_ROLE` can call `burnFrom(account, amount)` on ANY address without allowance.
- **Impact:** Can burn any holder's LUMINA tokens. CRITICAL escalation.
- **Mitigation:** `DEFAULT_ADMIN_ROLE` should be the multisig. If the admin role is renounced (as suggested in the code comments), this path is permanently closed.

**Path 2: DEFAULT_ADMIN_ROLE -> AUTHORIZED_CALLER_ADMIN_ROLE -> authorizedCallers (BondVault)**
- Admin can grant `AUTHORIZED_CALLER_ADMIN_ROLE` to any address.
- That address can add arbitrary `authorizedCallers`.
- Authorized callers can call `decreaseObligations()` (reduce committed USD) and `burnFromReserves()` (burn vault LUMINA, 5% cap per TX).
- **Impact:** Can manipulate vault solvency accounting and slowly burn vault reserves.

**Path 3: CoverRouterV2 Owner -> PolicyManagerV2 Owner -> BondVault**
- CoverRouterV2 owner can change `policyManager` and `twapBurner`.
- PolicyManagerV2 owner can change `router` and register arbitrary shields.
- A malicious shield could produce fraudulent trigger results, causing `bondVault.issueBond()` to issue bonds to attacker-controlled addresses.
- **Impact:** Drain BondVault by issuing fraudulent bonds. CRITICAL.

**Path 4: CapacityOracle Owner -> Price Manipulation -> BondVault**
- Owner can set `emergencyPrice` to an artificially low value.
- This inflates the LUMINA-per-USD payout in `redeemBond()`, draining the vault faster.
- Alternatively, setting `emergencyPrice` very high inflates capacity, allowing over-issuance.
- **Impact:** Economic manipulation of the entire bond system.

**Path 5: TWAPBurner Owner -> Fee Redirection**
- Owner can change `buybackReserve`, `opsReserve`, `maintenanceReserve` to attacker-controlled addresses.
- Owner can enable adaptive mode and redirect all USDC fees away from burning.
- **Impact:** All protocol revenue can be siphoned. Burns stop permanently.

**Path 6: LuminaBondMarketplace FEE_MANAGER_ROLE -> Fee Theft**
- Can change `twapBurner` to an attacker-controlled address, redirecting all marketplace fees.
- **Impact:** Marketplace fee revenue theft.

---

## 3. Single Points of Failure

### 3.1 Critical Single Points

| SPOF | Contracts Affected | Impact if Compromised |
|---|---|---|
| Multisig (Ownable owner) | TWAPBurner, CoverRouterV2, PolicyManagerV2, CapacityOracle, FounderVesting, TreasuryVesting | Full protocol takeover |
| Multisig (DEFAULT_ADMIN_ROLE) | BondVault, LuminaTokenV2, SolvencyOracle, BuybackEngine, LuminaBondMarketplace, CEXLiquidityReserve, MaintenanceReserve | Full protocol takeover |
| Deployer private key | BondVault (`setPolicyManager` one-shot) | Limited: only if not yet called |
| PolicyManager address (hardcoded in BondVault) | BondVault | If PM is compromised, bonds can be issued fraudulently |

### 3.2 No Timelock

**CRITICAL OBSERVATION:** None of the contracts implement a timelock or delay for admin operations. All admin changes take effect immediately. This means:
- The multisig can change critical addresses (policyManager, router, twapBurner, pool, oracle) without any notice period.
- Users have no time to react to malicious governance actions.
- **Recommendation:** Deploy a TimelockController (OpenZeppelin) as the owner/admin of all contracts with a minimum 48-hour delay for critical operations.

---

## 4. One-Shot Initialization Functions

| Contract | Function | Sentinel | Reversible? | Notes |
|---|---|---|---|---|
| BondVault | `setPolicyManager()` | `_policyManagerSet` (bool) | NO | Only deployer can call, once. If wrong address is set, BondVault is permanently misconfigured. |
| ClaimBond | `setBondVault()` | `_bondVaultSet` (bool) | NO | Only owner can call, once. If wrong address is set, all mint/burn is permanently routed to wrong vault. |

**Risk Assessment:**
- Both one-shot setters are correctly restricted (deployer/owner only) and protect against frontrunning.
- However, if the deployer makes an error during initialization, there is NO recovery path. The entire contract must be redeployed.
- **Recommendation:** Consider adding a brief initialization window (e.g., 1 hour) during which the setter can be called again by the deployer, then permanently locks.

---

## 5. Unused Roles Analysis

| Role | Contract | Granted To | Used By | Status |
|---|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | All AccessControl contracts | Deployer/Multisig | `grantRole()`, `revokeRole()` | **ACTIVE** |
| `AUTHORIZED_CALLER_ADMIN_ROLE` | BondVault | Deployer | `setAuthorizedCaller()` | **ACTIVE** — used to authorize BuybackEngine |
| `BURNER_ROLE` | LuminaTokenV2 | TWAPBurner (expected) | `burnFrom()` | **MUST BE GRANTED POST-DEPLOY** — not granted in constructor. If forgotten, TWAPBurner cannot burn. |
| `ADMIN_ROLE` | SolvencyOracle | Multisig | `setEmergencyPause()` | **ACTIVE** |
| `BUYBACK_OPERATOR_ROLE` | BuybackEngine | Multisig | `setDailyBuyback()` | **ACTIVE** |
| `FEE_MANAGER_ROLE` | LuminaBondMarketplace | Admin | `setTwapBurner()` | **ACTIVE** |
| `ALLOCATOR_ROLE` | CEXLiquidityReserve | Multisig | `allocate()` | **ACTIVE** |
| `SPENDER_ROLE` | MaintenanceReserve | Admin | `spend()` | **ACTIVE** |

**Key Finding:** `BURNER_ROLE` on LuminaTokenV2 is NOT granted in the constructor. It must be granted post-deployment by the `DEFAULT_ADMIN_ROLE` holder. If this step is missed, the TWAPBurner contract will be unable to call `burnFrom()`. The `burn()` function (self-burn) is available to the TWAPBurner but requires it to hold the tokens — and in the current flow, `_swapAndBurn()` calls `IBurnable(lumina).burn(luminaReceived)` which is the self-burn path (tokens are in TWAPBurner's balance). This works without `BURNER_ROLE`. However, the `burnFrom()` override is unusable until the role is granted.

---

## 6. Role Transfer Mechanisms

### 6.1 Ownable Contracts
- **Transfer:** `transferOwnership(newOwner)` — immediate, single-step transfer.
- **Renounce:** `renounceOwnership()` — permanently removes owner. Irreversible.
- **Risk:** Single-step transfer means a typo in the new owner address permanently locks the contract. OpenZeppelin's `Ownable2Step` is NOT used.
- **Affected:** TWAPBurner, CoverRouterV2, PolicyManagerV2, CapacityOracle, ClaimBond, FounderVesting, TreasuryVesting.
- **Recommendation:** Migrate to `Ownable2Step` for all Ownable contracts. This requires the new owner to accept ownership, preventing accidental lockout.

### 6.2 AccessControl Contracts
- **Grant:** `grantRole(role, account)` — only callable by the role's admin (default: `DEFAULT_ADMIN_ROLE`).
- **Revoke:** `revokeRole(role, account)` — same access as grant.
- **Renounce:** `renounceRole(role, account)` — only the role holder can renounce their own role.
- **Admin role of admin role:** `DEFAULT_ADMIN_ROLE` is its own admin. If all holders renounce it, ALL role management is permanently locked.
- **Affected:** BondVault, LuminaTokenV2, SolvencyOracle, BuybackEngine, LuminaBondMarketplace, CEXLiquidityReserve, MaintenanceReserve.

---

## 7. Multisig Compromise Scenarios

**Assumption:** The protocol uses a 2-of-3 Gnosis Safe multisig as the owner/admin of all contracts. Two signers are compromised (or collude).

### Scenario A: Maximum Value Extraction (Immediate)

**Step 1 — Redirect all revenue:**
- Call `TWAPBurner.setReserves(attacker, attacker, attacker)` to redirect buyback, ops, and maintenance USDC.
- Call `TWAPBurner.setAdaptiveMode(true)` if not already enabled.
- Call `LuminaBondMarketplace.setTwapBurner(attacker)` to redirect marketplace fees.
- **Immediate yield:** All future USDC revenue flows to attacker.

**Step 2 — Drain CEXLiquidityReserve:**
- Call `CEXLiquidityReserve.allocate(attacker, available, ImmediateUse, ...)` to extract up to 2.8M LUMINA immediately.
- Call `CEXLiquidityReserve.allocate(attacker, vestedAmount, VestingLinear, ...)` for additional vested tokens.
- Monthly cap of 1M LUMINA limits extraction rate.
- **Yield:** Up to 1M LUMINA per month (immediate sub-bucket plus vested).

**Step 3 — Drain MaintenanceReserve:**
- Call `MaintenanceReserve.setMonthlyCap(0)` to remove monthly cap.
- Call `MaintenanceReserve.spend(attacker, balance, ...)` to extract all USDC.
- **Yield:** Entire USDC balance of MaintenanceReserve.

**Step 4 — Drain TreasuryVesting:**
- Call `TreasuryVesting.release(attacker, 250_000e18)` — 250K LUMINA per month.
- **Yield:** 250K LUMINA (if past 6-month lock).

**Step 5 — Manipulate bond system:**
- Call `PolicyManagerV2.registerProduct(maliciousProductId, maliciousShield)`.
- Call `PolicyManagerV2.setRouter(attacker)`.
- Directly call `PolicyManagerV2.recordPolicy()` and `triggerPayout()` with crafted data.
- `triggerPayout()` calls `bondVault.issueBond()` — issues bonds to attacker.
- Wait 24 months for maturity, redeem for LUMINA from the 70M vault.
- **Yield:** Potentially unlimited bonds (up to 50% of vault value in USD).

**Step 6 — Burn arbitrary tokens:**
- Grant `BURNER_ROLE` to attacker on LuminaTokenV2.
- Call `burnFrom(victim, amount)` to burn any holder's LUMINA.
- **Impact:** Destruction of user tokens. No direct financial gain, but massive reputational damage.

**Step 7 — Manipulate pricing:**
- Call `CapacityOracle.setEmergencyPrice(1)` to set price to near-zero.
- Existing bond holders now get astronomically more LUMINA per dollar when redeeming.
- Could drain the entire 70M BondVault reserve on a single redemption.
- **Yield:** Up to 70M LUMINA from BondVault.

### Scenario A Total Worst-Case Impact

| Asset | Amount | Timeframe |
|---|---|---|
| BondVault LUMINA (via price manipulation) | Up to 70M LUMINA | Immediate (any matured bonds) |
| CEXLiquidityReserve LUMINA | Up to 1M LUMINA/month | Monthly |
| TreasuryVesting LUMINA | 250K LUMINA/month | Monthly (post-lock) |
| MaintenanceReserve USDC | Entire balance | Immediate |
| All future revenue (USDC) | 100% of premiums + fees | Ongoing |
| Third-party LUMINA (burnFrom) | Unlimited | Immediate |

### Scenario B: Stealthy Long-Term Extraction

A more sophisticated attacker might:
1. Slightly increase `maxSlippageBps` on TWAPBurner to 10% (within valid range) — extracting MEV from every burn.
2. Set `emergencyPrice` on CapacityOracle slightly off-market to slowly over-issue bonds.
3. Allocate CEXLiquidityReserve to shell addresses under plausible purposes (e.g., "CEX_LISTING_TIER_3").
4. Gradually redirect maintenance funds.

This would be harder to detect and could persist for months.

### Scenario C: Protocol Destruction (Griefing)

1. Pause CoverRouterV2 — no new policies.
2. Pause SolvencyOracle — AdaptiveFeeDistributor reports unhealthy, falls back to hardcoded ratios.
3. Deactivate all products in PolicyManagerV2.
4. Set CapacityOracle pool to address(0) — forces emergency price.
5. Renounce all `DEFAULT_ADMIN_ROLE` and `owner()` across all contracts.
6. **Result:** Protocol is permanently bricked. No admin can fix anything. Bond redemptions still work (BondVault has no admin shutdown), but no new policies can be created.

---

## 8. Mitigations and Recommendations

### 8.1 Critical (Must Fix)

| ID | Finding | Recommendation |
|---|---|---|
| AC-1 | No timelock on any admin operation | Deploy TimelockController with 48h+ delay as owner/admin of all contracts |
| AC-2 | Single-step ownership transfer (Ownable) | Migrate all Ownable contracts to Ownable2Step |
| AC-3 | `BURNER_ROLE` allows burning ANY address's tokens without allowance | Consider restricting `burnFrom` to only burn from addresses that have approved the burner, or add a whitelist of burnable addresses |
| AC-4 | `CapacityOracle.setEmergencyPrice()` can manipulate all bond redemptions | Add bounds: `require(_price >= MIN_PRICE && _price <= MAX_PRICE)` with reasonable constants |

### 8.2 High (Should Fix)

| ID | Finding | Recommendation |
|---|---|---|
| AC-5 | `CoverRouterV2.setPolicyManager()` and `setTwapBurner()` are not one-shot | Consider making these one-shot or adding a timelock. Currently the owner can swap these at any time. |
| AC-6 | `PolicyManagerV2.setRouter()` is not one-shot | Same as AC-5. A compromised multisig can inject a rogue router to issue fraudulent bonds. |
| AC-7 | `MaintenanceReserve.setMonthlyCap(0)` disables all spending limits | Consider a minimum cap floor or requiring multi-step approval to disable caps |
| AC-8 | `TWAPBurner.setFeeDistributor(address(0))` can disable adaptive mode silently | Consider emitting a specific event or requiring explicit `setAdaptiveMode(false)` first |

### 8.3 Medium (Nice to Have)

| ID | Finding | Recommendation |
|---|---|---|
| AC-9 | One-shot setters have no recovery mechanism | Add a brief initialization window or 2-step setter pattern |
| AC-10 | `BuybackEngine.executeOffer()` is permissionless after activation | Consider restricting to `BUYBACK_OPERATOR_ROLE` or at minimum authorized keepers |
| AC-11 | `TWAPBurner.setAuthorizedSender()` has no event emission | Add event for off-chain monitoring |
| AC-12 | No role separation between "operational" and "governance" actions | Consider 2-tier admin: operational (pause, config tweaks) with short timelock; governance (address changes, role grants) with longer timelock |

### 8.4 Informational

| ID | Finding | Notes |
|---|---|---|
| AC-13 | `FounderVesting.updateRecipient()` can redirect 8M LUMINA | By design: founder controls their own vesting recipient. Document that this is intentional. |
| AC-14 | `LuminaTokenV2` warns about renouncing `DEFAULT_ADMIN_ROLE` ([L-10]) | Good documentation. Ensure this is part of the deployment checklist. |
| AC-15 | `BondVault._deployer` is stored but `DEFAULT_ADMIN_ROLE` is also granted to deployer | After initialization, deployer should renounce `DEFAULT_ADMIN_ROLE` and transfer to multisig. |
| AC-16 | `AdaptiveFeeDistributor` has zero admin surface | Excellent security posture. If the distribution matrix needs updating, a new contract must be deployed and TWAPBurner reconfigured. This is the correct trade-off. |

---

## 9. Deployment Checklist (Access Control)

The following steps MUST be completed during deployment in the correct order:

1. Deploy LuminaTokenV2 with all recipient addresses.
2. Deploy ClaimBond. Call `setBondVault(bondVaultAddress)` — ONE SHOT.
3. Deploy BondVault. Call `setPolicyManager(policyManagerAddress)` — ONE SHOT.
4. Grant `BURNER_ROLE` to TWAPBurner on LuminaTokenV2.
5. Grant `AUTHORIZED_CALLER_ADMIN_ROLE` and add BuybackEngine as authorized caller on BondVault.
6. Transfer `DEFAULT_ADMIN_ROLE` on all AccessControl contracts from deployer to multisig.
7. Transfer ownership on all Ownable contracts from deployer to multisig.
8. Verify deployer has renounced all roles (optional but recommended for trust minimization).
9. Deploy TimelockController and transfer all ownership/admin to it (RECOMMENDED).

**Failure to complete steps 2-3 correctly results in permanently bricked contracts with no recovery path.**
