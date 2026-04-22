# V5.1 UUPS Admin Powers Inventory

**Audit:** V5.1 #4 — Admin Key Risk
**Branch:** `audit/v5.1-04-admin-key-risk`
**Date:** 2026-04-22

This document catalogues **every admin-only function** on every UUPS
upgradeable contract, the **worst-case impact** if the admin key is
compromised or behaves maliciously, and the **existing + recommended
mitigations**.

---

## Per-Contract Breakdown

### 1. LuminaTokenV2
- **Auth model:** AccessControlUpgradeable. `msg.sender` (deployer) receives
  `DEFAULT_ADMIN_ROLE`. `BURNER_ROLE` is granted to TWAPBurner only.
- **Admin-only functions:**
  - `_authorizeUpgrade(newImpl)` — `DEFAULT_ADMIN_ROLE`
  - `grantRole / revokeRole / renounceRole` — role admin
  - `burnFrom` — `BURNER_ROLE`
- **Max risk:**
  - Upgrade to malicious impl that mints unlimited LUMINA → dilution to zero.
  - Grant `BURNER_ROLE` to arbitrary address → burn user balances.
- **Impact:** CRITICAL — $LUMINA supply is the monetary anchor of the
  protocol. Total affected supply: 100M LUMINA.
- **Existing mitigations:** `constructor { _disableInitializers(); }`; roles
  are namespaced; `BURNER_ROLE` separate from admin.
- **Recommended mitigations (pre-mainnet):** 48h timelock on upgrade; 3-of-5
  multisig for admin; on-chain monitoring of `Upgraded` and `RoleGranted`
  events; eventual `renounceRole(DEFAULT_ADMIN_ROLE)` once burner is stable.

### 2. BondVault
- **Auth:** AccessControlUpgradeable. `msg.sender` receives
  `DEFAULT_ADMIN_ROLE` and `AUTHORIZED_CALLER_ADMIN_ROLE`.
- **Admin-only functions:**
  - `_authorizeUpgrade` — `DEFAULT_ADMIN_ROLE`
  - `setAuthorizedCaller(address, bool)` — `AUTHORIZED_CALLER_ADMIN_ROLE`
  - `grantRole / revokeRole / renounceRole`
- **Max risk:**
  - Authorize an attacker address as caller → attacker invokes
    `burnFromReserves()` or `decreaseObligations()` and drains the 70M LUMINA
    reserve.
  - Upgrade to drain-impl.
- **Impact:** CRITICAL — $70M LUMINA at 100% reserve ratio.
- **Existing mitigations:** 5% cap per burn; ReentrancyGuard; only authorized
  callers can reduce obligations.
- **Recommended:** 48h timelock; multisig; monitor `AuthorizedCallerSet`.

### 3. ClaimBond (ERC-1155)
- **Auth:** OwnableUpgradeable. Owner = deployer.
- **Admin-only functions:**
  - `_authorizeUpgrade` — owner
  - `setBondVault(address)` — owner (one-shot; `_bondVaultSet` gate)
- **Max risk:** Upgrade to malicious impl that re-mints NFT claims for
  attackers. `setBondVault` is gated to single use so it cannot be changed
  once set.
- **Impact:** HIGH — attackers could mint claim tokens and redeem them
  against BondVault.
- **Existing mitigations:** `_bondVaultSet` one-shot; ERC-1155 namespace.
- **Recommended:** Same as BondVault.

### 4. PolicyManagerV2
- **Auth:** OwnableUpgradeable. Owner = deployer.
- **Admin-only functions:**
  - `_authorizeUpgrade` — owner
  - `setRouter(address)` — owner
  - `registerProduct(bytes32, address)` — owner
  - `deactivateProduct(bytes32)` — owner
- **Max risk:** Register malicious shield that mints claims; deactivate
  legitimate products to halt user claims; set router to attacker EOA.
- **Impact:** HIGH — policy lifecycle can be hijacked.
- **Existing mitigations:** `productActive` flag; event emissions.
- **Recommended:** Multisig + 48h timelock on `setRouter` and
  `registerProduct`.

### 5. CoverRouterV2
- **Auth:** OwnableUpgradeable. Owner = deployer.
- **Admin-only functions:**
  - `_authorizeUpgrade` — owner
  - `setRelayer(address, bool)` — owner
  - `setPaused(bool)` — owner
  - `setPolicyManager(address)` — owner
  - `setTwapBurner(address)` — owner
  - `setCapacityOracle(address)` — owner
  - `configureProduct(...)` — owner (with `active` flag)
- **Max risk:** Set `policyManager`/`twapBurner` to attacker contracts;
  configure products with zero payout; pause forever.
- **Impact:** HIGH — user-facing router can be misdirected.
- **Existing mitigations:** Event emissions on every setter.
- **Recommended:** Timelock + multisig.

### 6. TWAPBurner
- **Auth:** OwnableUpgradeable. Owner = deployer.
- **Admin-only functions:** `_authorizeUpgrade`, `setPoolFee`, `setMaxSlippageBps`, `setMinBurnAmount`, `setMaxBurnAmount`, `setBurnCooldown`, `setAuthorizedSender`, `setCapacityOracle`, `setDexRouters`, `addDexRouter`, `setFeeDistributor`, `setReserves`, `setMaintenanceReserve`, `setAdaptiveMode`, `recoverToken`.
- **Max risk:** `recoverToken(lumina, MAX)` could drain pre-burn balance;
  set `maxSlippageBps` very high so burns accept bad prices; point DEX
  routers to attacker contracts.
- **Impact:** HIGH — protocol fees pass through this contract.
- **Existing mitigations:** Ranges on slippage/cooldown; ReentrancyGuard;
  `setReserves` zero-address checks.
- **Recommended:** Disable `recoverToken` for LUMINA via timelock hook;
  governance-only `setDexRouters`.

### 7. AdaptiveFeeDistributor
- **Auth:** OwnableUpgradeable.
- **Admin-only:** `_authorizeUpgrade`.
- **Max risk:** Upgrade to malicious distribution logic.
- **Impact:** MEDIUM — affects only fee-split ratios.
- **Existing:** Trivial layout; no setters beyond upgrade.
- **Recommended:** Timelock.

### 8. BuybackEngine
- **Auth:** AccessControlUpgradeable. `_multisigOwner` param receives
  `DEFAULT_ADMIN_ROLE` + `BUYBACK_OPERATOR_ROLE`.
- **Admin-only functions:**
  - `_authorizeUpgrade` — `DEFAULT_ADMIN_ROLE`
  - `setDailyBuyback(budget, maxPct, hours)` — `BUYBACK_OPERATOR_ROLE`
  - `grantRole / revokeRole / renounceRole`
- **Max risk:** Operator sets absurdly high `maxPricePercent` (capped at 95%)
  and large `dailyBudget` → overpays for claim bonds relative to face value.
- **Impact:** HIGH — drains USDC budget.
- **Existing:** `maxPct ≤ 95`, `duration ≤ 72h`, nonReentrant execution.
- **Recommended:** Hard per-day USDC ceiling; multisig for `setDailyBuyback`.

### 9. LuminaBondMarketplace
- **Auth:** AccessControl. `_admin` param receives
  `DEFAULT_ADMIN_ROLE` + `FEE_MANAGER_ROLE`.
- **Admin-only:** `_authorizeUpgrade` (DAR), `setTwapBurner` (FEE_MANAGER).
- **Max risk:** Redirect fee flow by pointing `twapBurner` at attacker.
- **Impact:** MEDIUM — affects burn stream only; doesn't drain listings.
- **Recommended:** Timelock on `setTwapBurner`.

### 10. ShieldKeeper
- **Auth:** OwnableUpgradeable.
- **Admin-only:** `_authorizeUpgrade`, `pause`, `unpause`.
- **Max risk:** Pause indefinitely — blocks automated policy settlement.
- **Impact:** LOW — does not lose funds, just freezes ops.
- **Recommended:** Emergency-guardian pattern (pause-only role separate from
  admin).

### 11. BaseShield (abstract) + 9 concrete Shield products
- **Auth:** OwnableUpgradeable on each child.
- **Admin-only:** `_authorizeUpgrade` on every shield.
- **Max risk:** Upgrade shield to impl that mis-computes triggers (false
  positives drain BondVault via PolicyManager; false negatives deny users).
- **Impact:** HIGH — payouts go through shields.
- **Existing:** onlyRouter gate on policy-lifecycle functions; Oracle-
  anchored triggers.
- **Recommended:** Timelock + multisig for shield upgrades specifically.

### 12. CapacityOracle
- **Auth:** OwnableUpgradeable.
- **Admin-only:** `_authorizeUpgrade`, `setPool`, `setTwapWindow`,
  `setEmergencyPrice`.
- **Max risk:** Set `emergencyPrice` to attacker-chosen value (e.g. 0) to
  manipulate `capacity` calculation in BondVault; point pool to manipulated
  Uniswap V3 pool.
- **Impact:** HIGH — governs available capacity for new policies.
- **Existing:** Range `twapWindow ∈ [5min, 2h]`; emergency price non-zero at
  init.
- **Recommended:** Timelock on `setEmergencyPrice` and `setPool`.

### 13. SolvencyOracle
- **Auth:** AccessControl. `_admin` param receives `DEFAULT_ADMIN_ROLE`
  and `ADMIN_ROLE`.
- **Admin-only:** `_authorizeUpgrade` (DAR), `setEmergencyPause`
  (`ADMIN_ROLE`).
- **Max risk:** Pause solvency oracle indefinitely; upgrade to force a
  specific solvency quadrant.
- **Impact:** HIGH — affects adaptive fee distribution and upgrade
  sequencing.
- **Recommended:** Timelock; pause separated into guardian role.

### 14. CEXLiquidityReserve
- **Auth:** AccessControl. `_multisigOwner` receives `DEFAULT_ADMIN_ROLE` +
  `ALLOCATOR_ROLE`.
- **Admin-only:** `_authorizeUpgrade` (DAR), `allocateTokens(...)`
  (`ALLOCATOR_ROLE`).
- **Max risk:** Allocate tokens to attacker address before multisig is
  finalized.
- **Impact:** HIGH — CEX reserve (14M LUMINA).
- **Existing:** Vesting schedule bucket limits; monthly caps; nonReentrant.
- **Recommended:** Multisig at deploy; timelock on `allocateTokens`.

### 15. MaintenanceReserve
- **Auth:** AccessControl. `_admin` param receives `DEFAULT_ADMIN_ROLE` +
  `SPENDER_ROLE`.
- **Admin-only:** `_authorizeUpgrade` (DAR), `setMonthlyCap(uint256)` (DAR),
  `recoverToken(...)` (DAR), `spend(...)` (`SPENDER_ROLE`).
- **Max risk:** `recoverToken` drain + `setMonthlyCap(MAX)` + spend → drain
  entire maintenance balance.
- **Impact:** MEDIUM — USDC maintenance budget.
- **Existing:** Monthly cap enforcement; nonReentrant.
- **Recommended:** Timelock on `recoverToken`; hardcoded cap of last-resort.

### 16. TreasuryVesting
- **Auth:** OwnableUpgradeable.
- **Admin-only:** `_authorizeUpgrade`, `release(address, uint256)`.
- **Max risk:** Release all vested tokens to attacker in a single call.
- **Impact:** HIGH — 3M LUMINA vest pool.
- **Existing:** Monotonic `lastReleaseMonth`; schedule-based release.
- **Recommended:** Timelock on `release`; multisig.

---

## Role Inventory (by role)

| Role | Contracts | Deployed grantees |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | LuminaTokenV2, BondVault, BuybackEngine, LuminaBondMarketplace, SolvencyOracle, CEXLiquidityReserve, MaintenanceReserve | deployer or `_admin` param |
| `AUTHORIZED_CALLER_ADMIN_ROLE` | BondVault | deployer |
| `BURNER_ROLE` | LuminaTokenV2 | TWAPBurner only (set post-deploy) |
| `BUYBACK_OPERATOR_ROLE` | BuybackEngine | `_multisigOwner` param |
| `FEE_MANAGER_ROLE` | LuminaBondMarketplace | `_admin` param |
| `ADMIN_ROLE` | SolvencyOracle | `_admin` param |
| `ALLOCATOR_ROLE` | CEXLiquidityReserve | `_multisigOwner` param |
| `SPENDER_ROLE` | MaintenanceReserve | `_admin` param |
| `Ownable.owner` | ClaimBond, PolicyManagerV2, CoverRouterV2, TWAPBurner, AdaptiveFeeDistributor, ShieldKeeper, 9 Shields, CapacityOracle, TreasuryVesting | deployer |

See `02-RISK-MATRIX.md` for the consolidated risk ranking.
