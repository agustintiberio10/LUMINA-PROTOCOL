# Audit V5.1 #31 — Deploy Flow (Complete Script)

Step-by-step sequence observed in `DeployLuminaV5Complete.s.sol`. Every step verified against `DeployScripts.t.sol`.

---

## Phase 1 — Infrastructure with no deps

| # | Action | Contract | Notes |
|---|---|---|---|
| 1 | Deploy MaintenanceReserve proxy | `MaintenanceReserve` | init(usdc, multisig) — admin + spender both = multisig |
| 2 | Deploy ClaimBond proxy | `ClaimBond` | init() — no args, deployer owns |

## Phase 2 — Address prediction

| # | Action | Detail |
|---|---|---|
| 3 | Compute predicted LUMINA proxy address | `vm.computeCreateAddress(deployer, nonce + 10)` — mainnet script |
|   | | `vm.computeCreateAddress(deployer, nonce + 9)` — Sepolia script |

## Phase 3 — Contracts that reference LUMINA address

| # | Action | Contract | Notes |
|---|---|---|---|
| 4 | Deploy CapacityOracle proxy | `CapacityOracle` | pool=address(0), lumina=predicted, usdc, emergencyPrice=0.036e18 |
| 5 | Deploy BondVault proxy | `BondVault` | init(lumina=predicted, cb, capacityOracle, pm=address(0)) — 2-step init |
| 6 | Deploy CEXLiquidityReserve proxy | `CEXLiquidityReserve` | init(lumina=predicted, multisig) |
| 7 | Deploy FounderVesting | `FounderVesting` | CONSTRUCTOR ONLY — non-upgradeable. Mainnet script deploys it; Sepolia uses placeholder |
| 8 | Deploy TreasuryVesting proxy | `TreasuryVesting` | init(lumina=predicted) |

## Phase 4 — LUMINA deployment

| # | Action | Contract | Notes |
|---|---|---|---|
| 9 | Deploy LUMINA proxy | `LuminaTokenV2` | init(bondVault, cex, founderVesting, lbpDeposit, treasuryVesting) — **mints 70/14/8/5/3 split** |
|   | **Sanity check** | | `require(actual == predicted)` — fails fast on nonce drift |

## Phase 5 — Cross-wiring (pt 1)

| # | Action | Notes |
|---|---|---|
| 10 | `claimBond.setBondVault(bondVault)` | one-shot |

## Phase 6 — Adaptive infrastructure

| # | Action | Contract |
|---|---|---|
| 11 | Deploy SolvencyOracle proxy | init(bondVault, capacityOracle, multisig) |
| 12 | Deploy AdaptiveFeeDistributor proxy | init(solvencyOracle) |

## Phase 7 — Core routing

| # | Action | Contract |
|---|---|---|
| 13 | Deploy TWAPBurner proxy | init(usdc, lumina, dexRouter) |
| 14 | Deploy PolicyManagerV2 proxy | init(bondVault) |
| 15 | `bondVault.setPolicyManager(pm)` | completes 2-step |
| 16 | Deploy CoverRouterV2 proxy | init(usdc, pm, twapBurner) |
| 17 | `policyManager.setRouter(coverRouter)` | wires user purchase path |

## Phase 8 — Marketplace + buyback

| # | Action | Contract |
|---|---|---|
| 18 | Deploy LuminaBondMarketplace proxy | init(cb, usdc, twapBurner, multisig) |
| 19 | Deploy BuybackEngine proxy | init(cb, vault, solOracle, capOracle, marketplace, usdc, multisig) |

## Phase 9 — Shields (9 contracts)

| # | Action | Contract |
|---|---|---|
| 20-28 | Deploy 9 shield proxies | FlashBTC 1h/4h/24h/48h, FlashETH 1h/24h/48h, MicroDepeg, RateShock |
|   | Each init(router_=pm, oracle_=chainlinkOracle) |  |
|   | RateShock init also passes aavePool + usdc |  |

## Phase 10 — Wiring (pt 2 — post all-deploys)

| # | Action | Status |
|---|---|---|
| 29 | `lumina.grantRole(BURNER_ROLE, twapBurner)` | ✅ Present |
| 30 | `twapBurner.setFeeDistributor(adp)` | ✅ Present |
| 31 | `twapBurner.setReserves(buyback, ops, maintenance)` | ✅ Present |
| 32 | `twapBurner.setCapacityOracle(capacityOracle)` | ✅ Present |
| 33 | `twapBurner.setAdaptiveMode(true)` | ✅ Present |
| 34 | `twapBurner.setAuthorizedSender(coverRouter, true)` | ✅ Present |
| 35 | `bondVault.setAuthorizedCaller(buyback, true)` | ✅ Present |
| 36 | `policyManager.registerProduct(id, shield)` × 9 | ✅ Present |
| 37 | `coverRouter.setCapacityOracle(capacityOracle)` | ✅ Present |
| 38 | `coverRouter.configureProduct(id, payoutRatio, triggerProb, margin, duration, active)` × 9 | ✅ Present |
| **39** | **`claimBond.setAuthorizedOperator(marketplace, true)`** | **❌ MISSING — CRITICAL** |
| **40** | **`claimBond.setAuthorizedOperator(buybackEngine, true)` (if needed)** | **❌ MISSING — HIGH (unclear if needed)** |

## Phase 11 — Ownership transfer (Complete script only)

| # | Action | Status |
|---|---|---|
| 41 | `twapBurner.transferOwnership(multisig)` | ✅ Present |
| 42 | `coverRouter.transferOwnership(multisig)` | ✅ Present |
| 43 | `policyManager.transferOwnership(multisig)` | ✅ Present |
| 44 | `capacityOracle.transferOwnership(multisig)` | ✅ Present |
| 45 | `founderVesting.transferOwnership(multisig)` | ✅ Present |
| 46 | `treasuryVesting.transferOwnership(multisig)` | ✅ Present |
| 47 | `claimBond.transferOwnership(multisig)` | ✅ Present |
| 48 | `bondVault.grantRole(DEFAULT_ADMIN, multisig)` + revoke deployer | ✅ Present |
| 49 | `bondVault.grantRole(AUTHORIZED_CALLER_ADMIN, multisig)` + revoke | ✅ Present |
| 50 | `lumina.grantRole(DEFAULT_ADMIN, multisig)` + revoke | ✅ Present |

## Phase 12 — Summary log

Script logs all 24+ addresses. No automated verification — manual inspection required.

---

## Nonce accounting

The nonce prediction at Phase 2 assumes a specific deploy order. If Phase 3-4 is reordered, the `require(actual == predicted)` check at Phase 4 catches drift and reverts the script. This is good defense.

**Count for Complete script (msg.sender = deployer nonce):**
```
+1 capacityOracleImpl
+2 capacityOracleProxy
+3 bondVaultImpl
+4 bondVaultProxy
+5 cexReserveImpl
+6 cexReserveProxy
+7 FounderVesting                 <-- non-proxy, +1 not +2
+8 treasuryVestingImpl
+9 treasuryVestingProxy
+10 luminaImpl                     <-- proxy at +11
+11 luminaProxy == precomputed
```
So `computeCreateAddress(deployer, currentNonce + 10)` targets the proxy at slot 11. ✅ matches code.

**Count for Sepolia script:**
```
+1 capacityOracleImpl
+2 capacityOracleProxy
+3 bondVaultImpl
+4 bondVaultProxy
+5 cexReserveImpl
+6 cexReserveProxy
+7 treasuryVestingImpl             <-- no FounderVesting in Sepolia
+8 treasuryVestingProxy
+9 luminaImpl                      <-- proxy at +10
+10 luminaProxy == precomputed
```
So `currentNonce + 9` targets the proxy at slot 10. ✅ matches code.

---

## Post-deploy checklist (manual steps required BEFORE protocol is usable)

Per this audit, the following MUST be done post-deploy (automated in current scripts only partially):

1. ✅ LUMINA BURNER_ROLE to TWAPBurner (script handles).
2. ✅ TWAPBurner reserves wiring (script handles).
3. ✅ BuybackEngine authorized in BondVault (script handles).
4. ✅ Products registered in PM (script handles).
5. ✅ Products configured in CoverRouter (script handles).
6. ✅ Ownership transfer to multisig (Complete only).
7. ❌ **`claimBond.setAuthorizedOperator(marketplace, true)` — MISSING in both scripts**.
8. ❌ **Possibly `setAuthorizedOperator(buybackEngine, true)` — investigate.**
9. ⚠️ Transfer FounderVesting ownership on mainnet (done).
10. ⚠️ Fund BuybackEngine budget (admin's responsibility).
11. ⚠️ Deploy Chainlink Automation subscription for ShieldKeeper.

The 2 ❌ items must be addressed before production deploy.
