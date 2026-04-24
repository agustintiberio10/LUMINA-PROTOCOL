# Audit V5.1 #27 — Admin Operations Inventory

Exhaustive catalogue of every admin-gated function across the 24 UUPS contracts + FounderVesting. Each entry has: signature, access, input validation, emitted event, rollback semantics.

---

## 1. TWAPBurner (`src/core/TWAPBurner.sol`)

| Function | Access | Validation | Event | Rollback |
|---|---|---|---|---|
| `setPoolFee(uint24)` | onlyOwner | `fee ∈ {500, 3000, 10000}` | `ConfigUpdated("poolFee", fee)` | Reversible |
| `setMaxSlippageBps(uint256)` | onlyOwner | `[50, 1000]` | `ConfigUpdated("maxSlippageBps", bps)` | Reversible |
| `setMinBurnAmount(uint256)` | onlyOwner | `>= 0.1e6` | `ConfigUpdated("minBurnAmount", …)` | Reversible |
| `setMaxBurnAmount(uint256)` | onlyOwner | `>= minBurnAmount` | `ConfigUpdated("maxBurnAmount", …)` | Reversible |
| `setBurnCooldown(uint256)` | onlyOwner | `[60, 86400]` | `ConfigUpdated("burnCooldown", …)` | Reversible |
| `setAuthorizedSender(address,bool)` | onlyOwner | — | — (GAP: no event) | Reversible |
| `setCapacityOracle(address)` | onlyOwner | `!= 0` | `ConfigUpdated("capacityOracle", …)` | Reversible |
| `setDexRouters(address[])` | onlyOwner | `length > 0`, non-zero | `ConfigUpdated("dexRouters", count)` | Reversible |
| `addDexRouter(address)` | onlyOwner | `!= 0` | `ConfigUpdated("dexRouterAdded", count)` | Via setDexRouters |
| `setFeeDistributor(address)` | onlyOwner | — (can be 0) | `ConfigUpdated("feeDistributor", …)` | Reversible |
| `setReserves(a,b,c)` | onlyOwner | all `!= 0` | — (GAP: no event) | Reversible |
| `setMaintenanceReserve(address)` | onlyOwner | `!= 0` | `MaintenanceReserveUpdated` | Reversible |
| `setAdaptiveMode(bool)` | onlyOwner | Requires feeDistributor & reserves if enabling | — (GAP: no event) | Reversible |
| `recoverToken(address,uint256)` | onlyOwner | USDC + LUMINA blacklisted | Post fix #26: `TokenRecovered` | N/A |
| `upgradeToAndCall(address,bytes)` | onlyOwner | Standard UUPS | `Upgraded(impl)` | Yes (re-upgrade) |

## 2. CoverRouterV2 (`src/core/CoverRouterV2.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `configureProduct(bytes32, uint, uint, uint, uint32, bool)` | onlyOwner | `durationSeconds > 0` | `ProductConfigured(id)` |
| `setRelayer(address, bool)` | onlyOwner | — | `RelayerUpdated(relayer, authorized)` |
| `setPaused(bool)` | onlyOwner | — | `Paused(state)` |
| `setPolicyManager(address)` | onlyOwner | `!= 0` | — (GAP) |
| `setTwapBurner(address)` | onlyOwner | `!= 0` | — (GAP) |
| `setCapacityOracle(address)` | onlyOwner | `!= 0` | — (GAP) |
| `recoverToken(address,uint256,address)` (post fix #26) | onlyOwner | core-token blacklist (USDC), non-zero | `TokenRecovered` |
| `upgradeToAndCall` | onlyOwner | Standard UUPS | `Upgraded` |
| `transferOwnership(address)` | onlyOwner | OZ v5 1-step | `OwnershipTransferred` |
| `renounceOwnership()` | onlyOwner | — | `OwnershipTransferred(prev, 0)` |

## 3. BondVault (`src/bonds/BondVault.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `setPolicyManager(address)` | onlyDeployer (one-shot) | `!= 0`, `!_policyManagerSet` | `PolicyManagerSet` |
| `setAuthorizedCaller(address, bool)` | `AUTHORIZED_CALLER_ADMIN_ROLE` | `!= 0` | `AuthorizedCallerUpdated` |
| `grantRole(role, account)` | role's admin role | Standard OZ | `RoleGranted` |
| `revokeRole(role, account)` | role's admin role | Standard OZ | `RoleRevoked` |
| `renounceRole(role, caller)` | `caller == account` | — | `RoleRevoked` |
| `recoverToken(address,uint256,address)` (post fix #26) | `DEFAULT_ADMIN_ROLE` | blacklist LUMINA + ClaimBond, non-zero | `TokenRecovered` |
| `recoverERC1155(address,uint256,uint256,address)` (post fix #26) | `DEFAULT_ADMIN_ROLE` | same | `TokenRecovered` |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | Standard UUPS | `Upgraded` |

Note: `SAFETY_FACTOR_BPS`, `BOND_MATURITY_SECONDS`, `MIN_REDEEM_PRICE` are `constant` — admin CANNOT modify them without full upgrade.

## 4. PolicyManagerV2 (`src/core/PolicyManagerV2.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `setRouter(address)` | onlyOwner | `!= 0` | — (GAP) |
| `registerProduct(bytes32, address)` | onlyOwner | `shield != 0` | `ProductRegistered(id, shield)` |
| `deactivateProduct(bytes32)` | onlyOwner | — | `ProductDeactivated(id)` |
| `upgradeToAndCall` | onlyOwner | Standard UUPS | `Upgraded` |
| `transferOwnership` | onlyOwner | OZ v5 1-step | `OwnershipTransferred` |

## 5. ClaimBond (`src/bonds/ClaimBond.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `setBondVault(address)` | onlyOwner | one-shot; `!= 0` | `BondVaultSet` |
| `setAuthorizedOperator(address, bool)` | onlyOwner | — | `AuthorizedOperatorSet` |
| `setBaseURI(string)` | onlyOwner | — | `URI(…, 0)` |
| `reinitializeURI(uint64)` | reinitializer | version gating | — |
| `upgradeToAndCall` | onlyOwner | Standard UUPS | `Upgraded` |

## 6. LuminaBondMarketplace (`src/marketplace/LuminaBondMarketplace.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `setTwapBurner(address)` | `FEE_MANAGER_ROLE` | `!= 0` | `TwapBurnerUpdated` |
| `recoverToken` (post fix #26) | `DEFAULT_ADMIN_ROLE` | USDC + ClaimBond blacklist | `TokenRecovered` |
| `recoverERC1155` (post fix #26) | `DEFAULT_ADMIN_ROLE` | same | `TokenRecovered` |
| `grantRole / revokeRole / renounceRole` | role admin | OZ standard | `Role*` |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | Standard UUPS | `Upgraded` |

## 7. BuybackEngine (`src/marketplace/BuybackEngine.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `configureDailyBuyback(uint256, uint256, uint256)` | `BUYBACK_OPERATOR_ROLE` | `maxPercent ∈ [1,95]`, `durationHours > 0` | `DailyBuybackConfigured` |
| `executeOffer(uint256)` | `BUYBACK_OPERATOR_ROLE` | daily budget, price limits | `OfferExecuted`, `DoubleBurnExecuted` |
| `recoverToken / recoverERC1155` (post fix #26) | `DEFAULT_ADMIN_ROLE` | USDC + ClaimBond blacklist | `TokenRecovered` |
| `grantRole / revokeRole / renounceRole` | role admin | OZ standard | `Role*` |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | Standard UUPS | `Upgraded` |

## 8. AdaptiveFeeDistributor (`src/core/AdaptiveFeeDistributor.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `recoverToken` (post fix #26) | onlyOwner | non-zero address + amount | `TokenRecovered` |
| `upgradeToAndCall` | onlyOwner | Standard UUPS | `Upgraded` |
| `transferOwnership / renounceOwnership` | onlyOwner | OZ v5 1-step | `OwnershipTransferred` |

## 9. CapacityOracle (`src/oracles/CapacityOracle.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `setEmergencyPrice(uint256)` | onlyOwner | `> 0` | `EmergencyPriceUpdated` |
| `setTwapPeriod(uint32)` | onlyOwner | `[60, 1 hour]` (approx) | `TwapPeriodUpdated` |
| `setFallbackTolerance(uint256)` | onlyOwner | — | `FallbackToleranceUpdated` |
| `upgradeToAndCall` | onlyOwner | Standard UUPS | `Upgraded` |

## 10. SolvencyOracle (`src/oracles/SolvencyOracle.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `setEmergencyPause(bool)` | `ADMIN_ROLE` | — | `EmergencyPauseToggled` |
| `grantRole / revokeRole / renounceRole` | role admin | OZ standard | `Role*` |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | Standard UUPS | `Upgraded` |

## 11. ShieldKeeper (`src/automation/ShieldKeeper.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `pause()` | onlyOwner | not-already-paused | `Paused(sender)` |
| `unpause()` | onlyOwner | not-already-unpaused | `Unpaused(sender)` |
| `upgradeToAndCall` | onlyOwner | Standard UUPS | `Upgraded` |

## 12. BaseShield + 9 Shields

Per-shield admin surface (via BaseShield.sol):
| Function | Access | Validation | Event |
|---|---|---|---|
| `setBeneficiary(address)` | onlyOwner | `!= 0` | `BeneficiaryUpdated` |
| `setOracle(address)` | onlyOwner | `!= 0` | `OracleUpdated` |
| `upgradeToAndCall` | onlyOwner | Standard UUPS | `Upgraded` |

## 13. LuminaTokenV2 (`src/token/LuminaTokenV2.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `grantRole(MINTER_ROLE, account)` | `DEFAULT_ADMIN_ROLE` | — | `RoleGranted` |
| `grantRole(BURNER_ROLE, account)` | `DEFAULT_ADMIN_ROLE` | — | `RoleGranted` |
| `setRestrictedTransferMode(bool)` (if present) | `DEFAULT_ADMIN_ROLE` | — | — |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | Standard UUPS | `Upgraded` |

## 14. TreasuryVesting (`src/token/TreasuryVesting.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `release(address, uint256)` | onlyOwner | post-lock, `<= MAX_MONTHLY_RELEASE`, `<= TOTAL_AMOUNT - released`, once-per-month | `Released` |
| `transferOwnership` | onlyOwner | OZ v5 1-step | `OwnershipTransferred` |
| `renounceOwnership` | onlyOwner | — | `OwnershipTransferred(prev, 0)` |
| `recoverToken` (post fix #26) | onlyOwner | LUMINA blacklist | `TokenRecovered` |
| `upgradeToAndCall` | onlyOwner | Standard UUPS | `Upgraded` |

## 15. CEXLiquidityReserve (`src/treasury/CEXLiquidityReserve.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `allocate(…)` | `ALLOCATOR_ROLE` | bucket capacity, monthly cap, ≤200-char description | `AllocationExecuted`, optional `MonthlyCapWarning` |
| `recoverToken` (post fix #26) | `DEFAULT_ADMIN_ROLE` | LUMINA blacklist | `TokenRecovered` |
| `grantRole / revokeRole / renounceRole` | role admin | OZ standard | `Role*` |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | Standard UUPS | `Upgraded` |

## 16. MaintenanceReserve (`src/treasury/MaintenanceReserve.sol`)

| Function | Access | Validation | Event |
|---|---|---|---|
| `spend(address, uint256, SpendCategory, string)` | `SPENDER_ROLE` | non-zero recipient/amount, monthlyCap respected | `FundsSpent` |
| `setMonthlyCap(uint256)` | `DEFAULT_ADMIN_ROLE` | — | `MonthlyCapUpdated(old, new)` |
| `recoverToken(address, uint256)` | `DEFAULT_ADMIN_ROLE` | USDC blacklist | `TokenRecovered` |
| `grantRole / revokeRole / renounceRole` | role admin | OZ standard | `Role*` |
| `upgradeToAndCall` | `DEFAULT_ADMIN_ROLE` | Standard UUPS | `Upgraded` |

## 17. FounderVesting (immutable)

**No admin operations.** Constructor-only configuration; no setters; no upgrade.

The only caller-gated functions are `claimVested(amount)` (onlyRecipient) and `claimFallback()` (onlyRecipient after FALLBACK_DURATION).

---

## Capability matrix

| Admin action | Affects funds? | Affects active users? | Rollback-able? | Should be timelocked in prod? |
|---|---|---|---|---|
| pause / setPaused | No | Yes (blocks ops) | Yes (unpause) | No (emergency) |
| setMaxSlippageBps | No | Yes (new swaps) | Yes | Yes (economic) |
| setBurnCooldown | No | Yes (new burns) | Yes | Yes |
| setAuthorizedCaller | Potentially | No | Yes | Yes |
| configureProduct | No | Yes (new policies) | Yes | Yes |
| setEmergencyPrice | Indirect | Yes (oracle price) | Yes | **YES — HIGH leverage** |
| setReserves (TWAPBurner) | Indirect | Yes | Yes | Yes |
| setAdaptiveMode | Indirect | Yes | Yes | Yes |
| grantRole / revokeRole | Potentially | Yes (role holders) | Yes (re-grant) | Yes |
| renounceRole / renounceOwnership | CRITICAL | Yes | **NO — permanent** | Yes (but usually never done) |
| upgradeToAndCall | **TOTAL** | **TOTAL** | Yes (re-upgrade) | **YES — mandatory** |
| recoverToken / recoverERC1155 | Non-core funds only | No | N/A | Optional |
| spend (MaintenanceReserve) | Yes (USDC) | No | No (spent is spent) | Yes |
| allocate (CEX) | Yes (LUMINA) | No | No | Yes |
| release (TreasuryVesting) | Yes (LUMINA) | No | No | Built-in monthly cap |

## Gaps identified (LOW severity)

| Gap | Contract | Fix |
|---|---|---|
| `setAuthorizedSender` emits no event | TWAPBurner | Add `AuthorizedSenderUpdated` event |
| `setReserves` emits no event | TWAPBurner | Add event |
| `setAdaptiveMode` emits no event | TWAPBurner | Add event |
| `setPolicyManager / setTwapBurner / setCapacityOracle` emit no events | CoverRouterV2 | Add events |
| `setRouter` emits no event | PolicyManagerV2 | Add event |

All are observability gaps, not security issues. Fix via UUPS minor upgrade.
