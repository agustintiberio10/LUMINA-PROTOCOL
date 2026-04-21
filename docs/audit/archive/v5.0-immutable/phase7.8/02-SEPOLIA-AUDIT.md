# Sepolia Deploy Script - Line-by-Line Audit

**File**: `script/deploy/DeployLuminaV5Sepolia.s.sol`  
**Date**: 2026-04-19  
**Status**: PASS (with 1 fix applied)

---

## Summary

The Sepolia deployment script deploys the full LUMINA V5.0 protocol with mock externals (USDC, Chainlink, Aave, DEX router). It includes all 9 shields, correct product ID registration, and configureProduct calls.

---

## Line-by-Line Findings

### Phase 1: Mocks (Lines 171-185)
- **L171**: `MockERC20_USDC` deployed inline -- OK for testnet
- **L174-175**: Separate BTC/ETH mock oracles deployed but unused (shields use MockShieldOracle) -- **INFO**: Dead deployment, no harm
- **L180**: `MockDexRouterSepolia` implements IDexRouter -- OK
- **L184**: Mints 1M USDC to deployer -- OK for testnet

### Phase 2: No-dep contracts (Lines 190-193)
- **L190**: `MaintenanceReserve(usdc, deployer)` -- admin=deployer (OK for testnet)
- **L193**: `ClaimBond()` -- no constructor args, deploys clean

### Phase 3: Address Precomputation (Lines 200-225)
- **L202**: `vm.getNonce(deployer)` -- correctly captures nonce after mock deployments
- **L203**: `predictedLumina = computeCreateAddress(deployer, currentNonce + 4)` -- **VERIFIED**: 4 contracts deployed before Lumina (capacityOracle, bondVault, cexReserve, treasuryVesting)
- **L206-209**: CapacityOracle with pool=address(0) and EMERGENCY_PRICE=0.036e18 -- OK
- **L214-219**: BondVault with policyManager=address(0) -- OK, set later via one-shot
- **L222**: CEXLiquidityReserve admin=deployer -- OK for testnet
- **L225**: TreasuryVesting(predictedLumina) -- OK

### Phase 4: Token (Lines 230-238)
- **L231-232**: founderVesting and lbpDeposit generated via `_labelToAddress` -- deterministic placeholders, OK for testnet
- **L234-236**: LuminaTokenV2 deployed with correct 5 recipients
- **L237**: `require(address(lumina) == predictedLumina)` -- critical safety check, PASS

### Phase 5: Wire ClaimBond (Line 243)
- **L243**: `claimBond.setBondVault(address(bondVault))` -- one-shot wire, OK

### Phase 6: Oracles (Lines 249-253)
- **L249**: SolvencyOracle admin=deployer -- OK for testnet
- **L252**: AdaptiveFeeDistributor(solvencyOracle) -- OK

### Phase 7: TWAPBurner (Line 258)
- **L258**: `TWAPBurner(usdc, lumina, dexRouter)` -- OK

### Phase 8: PolicyManager + CoverRouter (Lines 264-280)
- **L264**: PolicyManagerV2(bondVault) -- OK
- **L267**: CoverRouterV2(usdc, policyManager, twapBurner) -- OK
- **L271**: `policyManager.setRouter(coverRouter)` -- OK
- **L275**: `coverRouter.setCapacityOracle(capacityOracle)` -- OK
- **L279**: `bondVault.setPolicyManager(policyManager)` -- one-shot, OK

### Phase 9: Marketplace + BuybackEngine (Lines 285-298)
- **L285-286**: Marketplace(claimBond, usdc, twapBurner, deployer) -- admin=deployer, OK for testnet
- **L289-297**: BuybackEngine with all 7 constructor args -- OK

### Phase 9b: ShieldKeeper (Line 303)
- **L303**: `ShieldKeeper(policyManager)` -- Chainlink Automation keeper, OK
- **NOTE**: Not present in mainnet script -- **INFO**: May need to be added for mainnet

### Phase 9c: Shields (Lines 309-359)
- **L309-310**: MockShieldOracle and MockAavePool deployed -- OK for testnet
- **L315-325**: All 9 shields deployed with (policyManager, shieldOracle) -- OK
- **L338-346**: `registerProduct` with correct IDs -- **VERIFIED** all 9 match shield PRODUCT_ID constants
- **L351-359**: `configureProduct` with correct IDs -- **VERIFIED**
  - **BUG FOUND (L358)**: MicroDepeg duration was 86400 but shield requires 604800 -- **FIXED**
  - **BUG FOUND (L359)**: RateShock duration was 86400 but shield requires 604800 -- **FIXED**

### Phase 10: TWAPBurner Wiring (Lines 369-377)
- **L369**: setFeeDistributor -- OK
- **L370-373**: setReserves(buybackEngine, deployer, maintenanceReserve) -- opsReserve=deployer (OK for testnet)
- **L375**: setCapacityOracle -- OK
- **L376**: setAuthorizedSender(coverRouter, true) -- OK
- **L377**: setAdaptiveMode(true) -- OK

### Phase 10 cont: Roles (Lines 381)
- **L381**: `lumina.grantRole(BURNER_ROLE, twapBurner)` -- OK

---

## Findings Summary

| # | Severity | Line | Finding | Status |
|---|----------|------|---------|--------|
| 1 | HIGH | 358 | MicroDepeg configureProduct duration=86400, shield requires 604800 | FIXED |
| 2 | HIGH | 359 | RateShock configureProduct duration=86400, shield requires 604800 | FIXED |
| 3 | INFO | 174-175 | MockBTCOracle/MockETHOracle deployed but never used by shields | ACKNOWLEDGED |
| 4 | INFO | 303 | ShieldKeeper deployed on Sepolia but not in mainnet script | ACKNOWLEDGED |
| 5 | INFO | -- | No ownership transfer to multisig (deployer retains control) | OK for testnet |

---

## Conclusion

The Sepolia script correctly deploys the full protocol with all 9 shields, correct product IDs, and proper wiring. The duration bug for MicroDepeg and RateShock has been fixed. The script is ready for testnet deployment.
