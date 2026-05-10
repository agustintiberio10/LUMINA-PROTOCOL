# Audit V5.1 #24 — Disaster Scenarios: Inventory

**Target:** LUMINA Protocol V5.1 — operational crisis response.
**Date:** 2026-04-23

---

## 1. Scenarios covered

| # | Scenario | Covered by test? | Existing mitigation |
|---|---|---|---|
| 1 | BondVault LUMINA insufficient | `BondVault_Insufficient_Reverts` | `Insufficient reserve` revert; `burnFromReserves` 5%/tx cap |
| 2 | Oracle extreme price (manipulation) | `Oracle_ExtremePrice_RejectedByM01Bounds` | M-01 price sanity bounds (BTC min $10k / max $1M) |
| 3 | Oracle zero price | `Oracle_ZeroPrice_Rejected` | `require price > 0` in shield |
| 4 | Oracle revert (feed paused / deprecated) | `Oracle_Reverts_RecoverableWhenRestored` | clean revert; recovers when oracle restored |
| 5 | LUMINA price collapse → auto-pause | `LuminaCrash_AutoPause_BlocksNewPolicies`, `_AdminRestoresPrice_ResumeOps` | `MIN_PRICE_FOR_NEW_POLICIES = $0.005` in CoverRouter |
| 6 | Auto-pause visibility | `CircuitBreaker_GetterReflectsBlocked` | `isProtocolAutoPaused()` view |
| 7 | CapacityOracle emergency price admin path | `CapacityOracle_EmergencyPrice_AdminOnly` | `setEmergencyPrice` onlyOwner |
| 8 | Pause mid-redemption | `CoverRouter_Paused_BondRedemption_StillWorks`, `_NewPurchases_Reverted` | BondVault is independent of CoverRouter; only new policies blocked |
| 9 | Keeper failure (manual settle) | `KeeperDown_AnyoneCanSettle` | `checkAndSettlePolicy` is permissionless |
| 10 | Mass redemption — vault sufficient | `MassRedemption_100Holders_AllSucceedIfVaultSufficient` | per-call independence, no global lock |
| 11 | Mass redemption — vault insufficient | `MassRedemption_Insufficient_LaterRevert_EarlierKeptFunds` | clean per-call revert; earlier holders keep funds |
| 12 | MaintenanceReserve recover USDC | `MaintenanceReserve_RecoverToken_BlocksUSDC` | explicit `Cannot recover USDC` |
| 13 | MaintenanceReserve recover other tokens | `_OtherTokens_Allowed` | admin can rescue stranded ERC-20s |
| 14 | TWAPBurner recover (USDC / LUMINA blocked) | `TWAPBurner_RecoverToken_BlocksUSDC_AndLUMINA` | explicit blocks on the two core tokens |
| 15 | Admin rotation / ownership transfer | `Admin_Rotation_TransferOwnership` | standard OZ Ownable |
| 16 | Triple simultaneous disaster | `TripleDisaster_FailsSafe` | fails-safe: new policies blocked, redemptions still possible |

## 2. Recovery primitives inventory

### Admin (per-contract)

| Contract | Admin action | Role |
|---|---|---|
| `CoverRouterV2` | `setPaused(bool)` | onlyOwner |
| `CoverRouterV2` | `transferOwnership` | onlyOwner |
| `CoverRouterV2` | `configureProduct` | onlyOwner |
| `CoverRouterV2` | `upgradeToAndCall` | onlyOwner (UUPS) |
| `CapacityOracle` | `setEmergencyPrice` | onlyOwner |
| `CapacityOracle` | `upgradeToAndCall` | onlyOwner |
| `TWAPBurner` | `recoverToken` (not USDC/LUMINA) | onlyOwner |
| `TWAPBurner` | `setMaxSlippageBps` / `setMinBurnAmount` / … | onlyOwner |
| `MaintenanceReserve` | `recoverToken` (not USDC) | DEFAULT_ADMIN_ROLE |
| `BondVault` | `setAuthorizedCaller` | DEFAULT_ADMIN_ROLE |
| `ShieldKeeper` | `pause` / `unpause` | onlyOwner |
| `ClaimBond` | `setBaseURI`, `setAuthorizedOperator` (fix #18) | onlyOwner |

### Auto (always-on)

| Primitive | Where | Trigger |
|---|---|---|
| `MIN_PRICE_FOR_NEW_POLICIES` auto-pause | `CoverRouterV2._purchase` | `getLuminaPrice() < 5e15` |
| `SAFETY_FACTOR_BPS = 5000` vault cap | `BondVault.issueBond` | always (50% over-collateralisation) |
| `burnFromReserves` 5%/tx cap | `BondVault` | always |
| `MIN_REDEEM_PRICE = 0.001e18` redeem floor | `BondVault.redeemBond` | always |
| Sequencer-downtime cleanup-window extension | `BaseShield._validateStatusForTrigger` | reads oracle.getSequencerDowntime |
| ClaimBond epoch cap (year 2100) | `ClaimBond.mint` | always |

### Permissionless (holder safety)

| Action | Contract | Notes |
|---|---|---|
| `redeemBond` | `BondVault` | Works even when CoverRouter paused |
| `checkAndSettlePolicy` | `BaseShield` | Anyone can call — keeper-independent |
| `burnByHolder` | `ClaimBond` | Holder can burn own bonds (post-fix-#18) |

## 3. Gap analysis (see REPORT §5 for recommendations)

- **No "rescue fund" from MaintenanceReserve → BondVault automated path.** Admin would need to:
  1. Recover USDC from MaintenanceReserve (not possible via `recoverToken`; explicitly blocked).
  2. OR the MaintenanceReserve's USDC is earmarked for a different purpose.
  Effective rescue would need a new admin function on MaintenanceReserve: "send USDC to buyback engine for LUMINA acquisition, then deposit LUMINA to BondVault".
- **No timelock on UUPS upgrades.** Admin can upgrade immediately. Recommend 48h timelock for mainnet.
- **No guardian role distinct from admin.** A compromised admin has full power. Recommend separate "pause-only" guardian role.
- **No multisig required at the contract level.** Admin is a single address. Mainnet should have a 3-of-5 multisig with HW wallets.
