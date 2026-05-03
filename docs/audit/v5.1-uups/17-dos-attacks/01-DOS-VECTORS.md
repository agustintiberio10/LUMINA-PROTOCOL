# Audit V5.1 #17 — DOS Attack Vectors: Inventory

**Target:** LUMINA Protocol V5.1 (UUPS upgradeable) on Base L2
**Scope:** Map every plausible DOS attack vector and the protocol's mitigation.
**Date:** 2026-04-23

---

## 1. Vector classes covered

### 1.1 Griefing
- **Dust policies**: attacker buys many tiny policies hoping to inflate gas / saturate state for legitimate users.
- **Marketplace spam**: attacker creates many bogus listings at absurd prices.
- **List+cancel spam**: attacker thrashes the listing storage with rapid create/cancel cycles.

### 1.2 Gas exhaustion
- **Keeper batch with reverts**: attacker submits many invalid policy IDs to `performUpkeep` hoping each `try/catch` revert wastes gas.
- **Over-cap batch**: attacker submits >`MAX_POLICIES_PER_UPKEEP` IDs hoping for OOG.

### 1.3 State lock
- **Redemption blocking**: one holder reverting on a redemption attempt could in theory affect others.
- **Burn lock**: attacker triggers `executeBurn` rapidly hoping to lock real burns.
- **Below-min burn**: attacker tries to drip USDC into TWAPBurner just below the min threshold to keep burns blocked.

### 1.4 Economic DOS
- **Buyback budget drain**: attacker lists at maximum allowable price to consume the day's buyback budget.
- **Oracle manipulation**: attacker tries to read stale / extreme prices to break invariants.

### 1.5 Upgrade DOS
- **Unauthorised upgrade**: attacker tries to call `upgradeToAndCall` on UUPS proxies (BondVault, TWAPBurner, CoverRouterV2) hoping for missing access control.

### 1.6 State bomb
- **Many epochs**: bonds spread across many maturity epochs → does any view / write degrade?

### 1.7 Static loop hygiene
- No on-chain `for`-loop over an unbounded set in any user-callable function (verified by manual grep + audit #16's static analysis).

## 2. Test → vector mapping (`DOSAttacks.t.sol`)

| Vector | Test | Asserts |
|---|---|---|
| Dust policies | `DustPolicies_DontInflateLegitGas` | legit gas < 700 k after 200 dust |
| Coverage min | `BelowMinCoverage_Reverts` | < $100 reverts |
| Marketplace spam | `MarketplaceSpam_DoesntInflateLegitListing` | legit listing < 250 k after 500 spam |
| List+cancel | `MarketplaceListCancelSpam_BoundedGas` | per pair < 250 k |
| Keeper revert-bomb | `KeeperBatchWithReverts_BoundedAndContinues` | < 5 M gas, valid still settles |
| Keeper over-cap | `KeeperOverCap_Truncates_NotOOG` | < 10 M gas |
| Redemption isolation | `OneFailedRedemption_DoesntBlockOthers` | other holders still redeem |
| Burn cooldown | `BurnSpam_BlockedByCooldown` | second burn reverts |
| Burn min | `BurnBelowMin_Reverts` | < $1 reverts |
| Buyback budget | `BuybackOverBudget_Rejected` | over-budget reverts |
| Upgrade DOS × 3 | `Upgrade_*_NonOwnerReverts` | unauthorised reverts |
| Oracle revert | `OracleRevert_PurchaseFails_RecoversWhenRestored` | clean fail, recovers |
| Emergency price | `CapacityOracle_EmergencyPriceFallback_Works` | fallback works |
| State bomb | `ManyEpochs_GasStaysFlat` | per-issue gas bounded |
| Static loops | `NoUnboundedPublicLoops_Documented` | code-level invariant |

## 3. Built-in mitigations (verified by tests)

| Mechanism | Purpose | Where |
|---|---|---|
| `coverageAmount >= 100e6` | Anti-dust on policy purchase | `CoverRouterV2._purchase` |
| `MAX_POLICIES_PER_UPKEEP` | Anti-OOG on keeper batch | `ShieldKeeper.performUpkeep` |
| `try/catch` around `checkAndSettlePolicy` | Single bad policy doesn't kill batch | `ShieldKeeper.performUpkeep` |
| `burnCooldown ≥ 60` (default 900s) | Anti-spam on burns | `TWAPBurner.executeBurn` |
| `minBurnAmount` (default 1e6) | Anti-dust on burns | `TWAPBurner.executeBurn` |
| `dailyBudget` cap | Anti-drain on buyback | `BuybackEngine.executeOffer` |
| `maxPricePercent` cap | Anti-overpay on buyback | `BuybackEngine.executeOffer` |
| `validUntil` window | Buyback expiration | `BuybackEngine.executeOffer` |
| Capacity reservation (`reserveCapacity` / `commitReservation`) | Race-free capacity accounting | `BondVault` + `PolicyManager` |
| `SAFETY_FACTOR_BPS = 5000` | Reserve never < 50 % committed | `BondVault.issueBond` |
| `MIN_REDEEM_PRICE = 5e15` ([Fix C-3] raised from 0.001e18) | Anti-low-price redeem (aligned with CoverRouter floor) | `BondVault.redeemBond` |
| `MAX_REDEEM_PRICE = 1000e18` ([F-REVERSE-1] new) | Anti-anomalous-high-price (silent loss prevention) | `BondVault._getSafePrice` |
| `MIN_PRICE_FOR_NEW_POLICIES = 5e15` | Auto-pause at depressed price | `CoverRouterV2._purchase` |
| `_authorizeUpgrade` access control | Anti-unauthorised upgrade | every UUPS contract |
| Mappings instead of iterable arrays | No O(N) blow-up | architecture-wide |

## 4. Findings summary (full detail in REPORT.md)

- 0 HIGH / MEDIUM / LOW issues identified.
- All 14 documented mitigations verified by at least one test.
- No new attack vectors uncovered by this audit beyond what the existing test suite (#1–#16) already covered.
