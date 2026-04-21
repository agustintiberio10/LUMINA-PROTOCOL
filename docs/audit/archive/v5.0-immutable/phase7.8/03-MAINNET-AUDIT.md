# Mainnet Deploy Script - Line-by-Line Audit

**File**: `script/deploy/DeployLuminaV5Complete.s.sol`  
**Date**: 2026-04-19  
**Status**: PASS (with 1 fix applied)

---

## Summary

The mainnet deployment script deploys the complete LUMINA V5.0 protocol in a single atomic broadcast. It uses environment variables for all external addresses, precomputes the LuminaTokenV2 address to break circular dependencies, deploys all 9 shields, and transfers ownership to a multisig.

---

## Line-by-Line Findings

### Configuration Structs (Lines 51-87)
- **L51-60**: `DeploymentConfig` -- 8 external addresses loaded from env vars -- OK
- **L62-87**: `DeploymentResult` -- tracks all 24 deployed addresses -- OK

### Environment Loading (Lines 91-100)
- **L92-100**: All 8 env vars loaded via `vm.envAddress` -- will revert on missing vars -- OK
- **NOTE**: No defaults, script fails-fast if env is incomplete -- GOOD

### Step 1: MaintenanceReserve (Lines 111-113)
- **L111**: `MaintenanceReserve(cfg.usdc, cfg.multisig)` -- admin=multisig from start -- GOOD

### Step 2: ClaimBond (Lines 118-120)
- **L118**: `ClaimBond()` -- no constructor args -- OK

### Steps 3-7: Nonce Precomputation (Lines 131-175)
- **L131**: `vm.getNonce(deployer)` -- captures nonce after 2 deployments
- **L133**: `computeCreateAddress(deployer, currentNonce + 5)` -- **VERIFIED**: 5 contracts before Lumina:
  1. CapacityOracle (nonce+0)
  2. BondVault (nonce+1)
  3. CEXLiquidityReserve (nonce+2)
  4. FounderVesting (nonce+3)
  5. TreasuryVesting (nonce+4)
  6. LuminaTokenV2 (nonce+5) -- CORRECT
- **L139**: CapacityOracle(pool=0, predictedLumina, usdc, 0.036e18) -- emergency price only until LP pool set -- OK
- **L146-151**: BondVault(predictedLumina, claimBond, capacityOracle, address(0)) -- policyManager set later -- OK
- **L158**: CEXLiquidityReserve(predictedLumina, multisig) -- OK
- **L165-166**: FounderVesting(capacityOracle, aavePool, predictedLumina, usdc, founderRecipient) -- OK
- **L173**: TreasuryVesting(predictedLumina) -- OK

### Step 8: LuminaTokenV2 (Lines 180-185)
- **L180-182**: LuminaTokenV2 deployed with 5 recipients -- OK
- **L184**: `require(res.luminaToken == precomputedLumina, "LUMINA address mismatch")` -- **CRITICAL safety check** -- GOOD
- Token distribution verified: 70M/14M/8M/5M/3M to respective addresses

### Step 9: ClaimBond Wiring (Line 190)
- **L190**: `claimBond.setBondVault(bondVault)` -- one-shot, irreversible -- OK

### Step 10: SolvencyOracle (Lines 196-198)
- **L196**: `SolvencyOracle(bondVault, capacityOracle, multisig)` -- admin=multisig -- OK

### Step 11: AdaptiveFeeDistributor (Lines 203-205)
- **L203**: `AdaptiveFeeDistributor(solvencyOracle)` -- OK

### Step 12: TWAPBurner (Lines 210-212)
- **L210**: `TWAPBurner(cfg.usdc, res.luminaToken, cfg.swapRouter)` -- OK

### Step 13: PolicyManagerV2 (Lines 217-219)
- **L217**: `PolicyManagerV2(bondVault)` -- OK

### Step 14: BondVault.setPolicyManager (Line 224)
- **L224**: `bondVault.setPolicyManager(policyManager)` -- **ONE-SHOT**, irreversible -- OK

### Step 15: CoverRouterV2 (Lines 230-232)
- **L230**: `CoverRouterV2(cfg.usdc, policyManager, twapBurner)` -- OK

### Step 16: PolicyManager.setRouter (Line 237)
- **L237**: `policyManager.setRouter(coverRouter)` -- OK

### Step 17: LuminaBondMarketplace (Lines 243-245)
- **L243-244**: `LuminaBondMarketplace(claimBond, usdc, twapBurner, multisig)` -- admin=multisig -- OK

### Step 18: BuybackEngine (Lines 251-260)
- **L251-258**: All 7 constructor args correct -- OK
- **NOTE**: `cfg.multisig` is the operator/admin -- GOOD

### Step 19: Shield Deployment (Lines 266-276)
- **L266**: FlashBTCShield1h(policyManager, chainlinkOracle) -- OK
- **L267**: FlashBTCShield4h(policyManager, chainlinkOracle) -- OK
- **L268**: FlashBTCShield24h(policyManager, chainlinkOracle) -- OK
- **L269**: FlashBTCShield48h(policyManager, chainlinkOracle) -- OK
- **L270**: FlashETHShield1h(policyManager, chainlinkOracle) -- OK
- **L271**: FlashETHShield24h(policyManager, chainlinkOracle) -- OK
- **L272**: FlashETHShield48h(policyManager, chainlinkOracle) -- OK
- **L273**: MicroDepegShield(policyManager, chainlinkOracle) -- OK
- **L274-275**: RateShockShield(policyManager, chainlinkOracle, aavePool, usdc) -- OK

### Wiring Block (Lines 280-318)

#### Roles (Lines 284-297)
- **L284**: `luminaToken.grantRole(BURNER_ROLE, twapBurner)` -- OK
- **L288**: `twapBurner.setFeeDistributor(adaptiveFeeDistributor)` -- OK
- **L289**: `twapBurner.setReserves(buybackEngine, opsWallet, maintenanceReserve)` -- OK
- **L290**: `twapBurner.setCapacityOracle(capacityOracle)` -- OK
- **L291**: `twapBurner.setAdaptiveMode(true)` -- OK
- **L292**: `twapBurner.setAuthorizedSender(coverRouter, true)` -- OK
- **L296**: `bondVault.setAuthorizedCaller(buybackEngine, true)` -- OK

#### Product Registration (Lines 301-309)
- **L301**: `registerProduct(keccak256("FLASHBTC1H-001"), flashBTCShield1h)` -- **CORRECT** ID
- **L302**: `registerProduct(keccak256("FLASHBTC4H-001"), flashBTCShield4h)` -- **CORRECT** ID
- **L303**: `registerProduct(keccak256("FLASHBTC24-001"), flashBTCShield24h)` -- **CORRECT** ID
- **L304**: `registerProduct(keccak256("FLASHBTC48-001"), flashBTCShield48h)` -- **CORRECT** ID
- **L305**: `registerProduct(keccak256("FLASHETH1H-001"), flashETHShield1h)` -- **CORRECT** ID
- **L306**: `registerProduct(keccak256("FLASHETH24-001"), flashETHShield24h)` -- **CORRECT** ID
- **L307**: `registerProduct(keccak256("FLASHETH48-001"), flashETHShield48h)` -- **CORRECT** ID
- **L308**: `registerProduct(keccak256("MICRODEPEG-001"), microDepegShield)` -- **CORRECT** ID
- **L309**: `registerProduct(keccak256("RATESHOCK-001"), rateShockShield)` -- **CORRECT** ID

#### CoverRouter Configuration (Lines 313-318 / _configureProducts)
- **L314**: `coverRouter.setCapacityOracle(capacityOracle)` -- OK
- **L384**: FLASHBTC1H: 8000, 200, 2000, 3600 -- OK (1h duration matches shield)
- **L385**: FLASHBTC4H: 8000, 150, 2000, 14400 -- OK (4h duration matches shield)
- **L386**: FLASHBTC24: 8000, 100, 2000, 86400 -- OK (24h duration matches shield)
- **L387**: FLASHBTC48: 8000, 80, 2000, 172800 -- OK (48h duration matches shield)
- **L388**: FLASHETH1H: 8000, 200, 2000, 3600 -- OK (1h duration matches shield)
- **L389**: FLASHETH24: 8000, 100, 2000, 86400 -- OK (24h duration matches shield)
- **L390**: FLASHETH48: 8000, 80, 2000, 172800 -- OK (48h duration matches shield)
- **L391**: MICRODEPEG: 8000, 50, 2500, 604800 -- **FIXED** (was 86400, now 7 days)
- **L392**: RATESHOCK: 8000, 30, 3000, 604800 -- **FIXED** (was 86400, now 7 days)

### Ownership Transfer (Lines 326-343)
- **L326**: twapBurner.transferOwnership(multisig) -- OK
- **L327**: coverRouter.transferOwnership(multisig) -- OK
- **L328**: policyManager.transferOwnership(multisig) -- OK
- **L329**: capacityOracle.transferOwnership(multisig) -- OK
- **L330**: founderVesting.transferOwnership(multisig) -- OK
- **L331**: treasuryVesting.transferOwnership(multisig) -- OK
- **L332**: claimBond.transferOwnership(multisig) -- OK
- **L335-338**: BondVault role transfer (grant to multisig, revoke from deployer) -- OK
- **L341-342**: LuminaTokenV2 role transfer (grant to multisig, revoke from deployer) -- OK

---

## Findings Summary

| # | Severity | Line | Finding | Status |
|---|----------|------|---------|--------|
| 1 | HIGH | 391 | MicroDepeg configureProduct duration was 86400, shield requires 604800 | FIXED |
| 2 | HIGH | 392 | RateShock configureProduct duration was 86400, shield requires 604800 | FIXED |
| 3 | INFO | -- | No ShieldKeeper deployment (present in Sepolia script) | ACKNOWLEDGED |
| 4 | INFO | 379 | `_configureProducts` second param `DeploymentResult memory` unnamed | Cosmetic |

---

## Security Observations

1. **Nonce Precomputation**: Relies on exactly 5 contracts being deployed between nonce capture and LuminaTokenV2. Any inserted deployment would break this. The `require` on L184 catches this.

2. **One-Shot Functions**: `ClaimBond.setBondVault` and `BondVault.setPolicyManager` are both irreversible. If wrong addresses are passed, the contracts cannot be fixed -- new deployment required.

3. **Deployer Privilege Window**: Between deployment start and ownership transfer, the deployer has full control. This window exists within a single atomic broadcast, minimizing exposure.

4. **Missing**: No event emission for deployment completion. Consider adding an event for indexer consumption.

---

## Conclusion

The mainnet script is correctly structured with proper nonce precomputation, correct product IDs, and complete ownership transfer. The duration bug for MicroDepeg and RateShock has been fixed. Script is ready for mainnet deployment.
