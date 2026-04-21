# LUMINA V5.0 Deploy Checklist

**Phase**: 7.8 - Mega Deploy Audit  
**Date**: 2026-04-19  
**Branch**: `audit/v5-fase7.8-mega-deploy-audit`

---

## Pre-Deploy Checklist

### Environment Variables Required (Mainnet)
- [ ] `USDC_ADDRESS` - Base mainnet USDC (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
- [ ] `SWAP_ROUTER` - DEX router address (verified on-chain)
- [ ] `MULTISIG` - Gnosis Safe multisig address
- [ ] `LBP_DEPOSIT` - LBP deposit address (5% allocation)
- [ ] `OPS_WALLET` - Operations wallet for fee distribution
- [ ] `FOUNDER_RECIPIENT` - Founder vesting recipient
- [ ] `CHAINLINK_ORACLE` - Chainlink BTC/USD price feed
- [ ] `AAVE_POOL` - Aave V3 Pool for RateShockShield

### Pre-Deploy Verification
- [ ] All 9 shield contracts compile without errors
- [ ] Product IDs in deploy script match shield PRODUCT_ID constants
- [ ] Duration parameters in configureProduct match shield MIN/MAX_DURATION
- [ ] Nonce prediction logic tested (LuminaTokenV2 address precomputation)
- [ ] ClaimBond.setBondVault is one-shot (cannot be re-called)
- [ ] BondVault.setPolicyManager is one-shot (cannot be re-called)
- [ ] Multisig address is a verified Gnosis Safe on Base

---

## Deployment Steps (Mainnet)

### Phase 1: Foundation (Steps 1-2)
- [ ] Step 1: Deploy MaintenanceReserve(USDC, multisig)
- [ ] Step 2: Deploy ClaimBond()

### Phase 2: Address Precomputation (Step 3-7)
- [ ] Precompute LuminaTokenV2 address (currentNonce + 5)
- [ ] Step 3: Deploy CapacityOracle(pool=0, predictedLumina, USDC, 0.036e18)
- [ ] Step 4: Deploy BondVault(predictedLumina, claimBond, capacityOracle, policyManager=0)
- [ ] Step 5: Deploy CEXLiquidityReserve(predictedLumina, multisig)
- [ ] Step 6: Deploy FounderVesting(capacityOracle, aavePool, predictedLumina, usdc, founderRecipient)
- [ ] Step 7: Deploy TreasuryVesting(predictedLumina)

### Phase 3: Token (Step 8)
- [ ] Step 8: Deploy LuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting)
- [ ] VERIFY: deployed address == precomputed address

### Phase 4: One-Shot Wiring (Step 9)
- [ ] Step 9: ClaimBond.setBondVault(bondVault)

### Phase 5: Oracles (Steps 10-11)
- [ ] Step 10: Deploy SolvencyOracle(bondVault, capacityOracle, multisig)
- [ ] Step 11: Deploy AdaptiveFeeDistributor(solvencyOracle)

### Phase 6: Core Engine (Steps 12-16)
- [ ] Step 12: Deploy TWAPBurner(USDC, lumina, swapRouter)
- [ ] Step 13: Deploy PolicyManagerV2(bondVault)
- [ ] Step 14: BondVault.setPolicyManager(policyManager) -- ONE-SHOT
- [ ] Step 15: Deploy CoverRouterV2(USDC, policyManager, twapBurner)
- [ ] Step 16: PolicyManagerV2.setRouter(coverRouter)

### Phase 7: Marketplace (Steps 17-18)
- [ ] Step 17: Deploy LuminaBondMarketplace(claimBond, USDC, twapBurner, multisig)
- [ ] Step 18: Deploy BuybackEngine(claimBond, bondVault, solvencyOracle, capacityOracle, marketplace, USDC, multisig)

### Phase 8: Shields (Step 19)
- [ ] Deploy FlashBTCShield1h(policyManager, chainlinkOracle)
- [ ] Deploy FlashBTCShield4h(policyManager, chainlinkOracle)
- [ ] Deploy FlashBTCShield24h(policyManager, chainlinkOracle)
- [ ] Deploy FlashBTCShield48h(policyManager, chainlinkOracle)
- [ ] Deploy FlashETHShield1h(policyManager, chainlinkOracle)
- [ ] Deploy FlashETHShield24h(policyManager, chainlinkOracle)
- [ ] Deploy FlashETHShield48h(policyManager, chainlinkOracle)
- [ ] Deploy MicroDepegShield(policyManager, chainlinkOracle)
- [ ] Deploy RateShockShield(policyManager, chainlinkOracle, aavePool, USDC)

### Phase 9: Wiring
- [ ] LuminaTokenV2.grantRole(BURNER_ROLE, twapBurner)
- [ ] TWAPBurner.setFeeDistributor(adaptiveFeeDistributor)
- [ ] TWAPBurner.setReserves(buybackEngine, opsWallet, maintenanceReserve)
- [ ] TWAPBurner.setCapacityOracle(capacityOracle)
- [ ] TWAPBurner.setAdaptiveMode(true)
- [ ] TWAPBurner.setAuthorizedSender(coverRouter, true)
- [ ] BondVault.setAuthorizedCaller(buybackEngine, true)
- [ ] CoverRouterV2.setCapacityOracle(capacityOracle)

### Phase 10: Register & Configure 9 Products
- [ ] registerProduct(keccak256("FLASHBTC1H-001"), flashBTCShield1h)
- [ ] registerProduct(keccak256("FLASHBTC4H-001"), flashBTCShield4h)
- [ ] registerProduct(keccak256("FLASHBTC24-001"), flashBTCShield24h)
- [ ] registerProduct(keccak256("FLASHBTC48-001"), flashBTCShield48h)
- [ ] registerProduct(keccak256("FLASHETH1H-001"), flashETHShield1h)
- [ ] registerProduct(keccak256("FLASHETH24-001"), flashETHShield24h)
- [ ] registerProduct(keccak256("FLASHETH48-001"), flashETHShield48h)
- [ ] registerProduct(keccak256("MICRODEPEG-001"), microDepegShield)
- [ ] registerProduct(keccak256("RATESHOCK-001"), rateShockShield)
- [ ] configureProduct(FLASHBTC1H-001, 8000, 200, 2000, 3600, true)
- [ ] configureProduct(FLASHBTC4H-001, 8000, 150, 2000, 14400, true)
- [ ] configureProduct(FLASHBTC24-001, 8000, 100, 2000, 86400, true)
- [ ] configureProduct(FLASHBTC48-001, 8000, 80, 2000, 172800, true)
- [ ] configureProduct(FLASHETH1H-001, 8000, 200, 2000, 3600, true)
- [ ] configureProduct(FLASHETH24-001, 8000, 100, 2000, 86400, true)
- [ ] configureProduct(FLASHETH48-001, 8000, 80, 2000, 172800, true)
- [ ] configureProduct(MICRODEPEG-001, 8000, 50, 2500, 604800, true)
- [ ] configureProduct(RATESHOCK-001, 8000, 30, 3000, 604800, true)

### Phase 11: Ownership Transfer
- [ ] twapBurner.transferOwnership(multisig)
- [ ] coverRouter.transferOwnership(multisig)
- [ ] policyManager.transferOwnership(multisig)
- [ ] capacityOracle.transferOwnership(multisig)
- [ ] founderVesting.transferOwnership(multisig)
- [ ] treasuryVesting.transferOwnership(multisig)
- [ ] claimBond.transferOwnership(multisig)
- [ ] bondVault.grantRole(AUTHORIZED_CALLER_ADMIN_ROLE, multisig)
- [ ] bondVault.grantRole(DEFAULT_ADMIN_ROLE, multisig)
- [ ] bondVault.revokeRole(AUTHORIZED_CALLER_ADMIN_ROLE, deployer)
- [ ] bondVault.revokeRole(DEFAULT_ADMIN_ROLE, deployer)
- [ ] luminaToken.grantRole(DEFAULT_ADMIN_ROLE, multisig)
- [ ] luminaToken.revokeRole(DEFAULT_ADMIN_ROLE, deployer)

---

## Post-Deploy Verification

### Token Distribution
- [ ] totalSupply == 100,000,000e18
- [ ] BondVault balance == 70,000,000e18 (70%)
- [ ] CEXLiquidityReserve balance == 14,000,000e18 (14%)
- [ ] FounderVesting balance == 8,000,000e18 (8%)
- [ ] LBP Deposit balance == 5,000,000e18 (5%)
- [ ] TreasuryVesting balance == 3,000,000e18 (3%)
- [ ] Deployer balance == 0

### Wiring Verification
- [ ] PolicyManager.router() == coverRouter
- [ ] BondVault.policyManager() == policyManager
- [ ] ClaimBond.bondVault() == bondVault
- [ ] TWAPBurner.feeDistributor() == adaptiveFeeDistributor
- [ ] TWAPBurner.adaptiveModeEnabled() == true
- [ ] CoverRouter.capacityOracle() == capacityOracle
- [ ] CapacityOracle.getLuminaPrice() == 0.036e18 (emergency price)

### Ownership Verification
- [ ] Deployer has ZERO admin roles on all contracts
- [ ] Multisig has DEFAULT_ADMIN_ROLE on LuminaTokenV2
- [ ] Multisig owns PolicyManager, CoverRouter, TWAPBurner, CapacityOracle
- [ ] Multisig has AUTHORIZED_CALLER_ADMIN_ROLE on BondVault

### Functional Verification
- [ ] Can purchase each of 9 shields (end-to-end)
- [ ] ClaimBond.setBondVault reverts with "Already set"
- [ ] BondVault.setPolicyManager reverts with "PolicyManager already set"
- [ ] Pausing via multisig works (blocks purchases)
- [ ] Unpausing via multisig works (resumes purchases)

---

## Critical Bugs Found & Fixed

| # | Bug | Impact | Fix |
|---|-----|--------|-----|
| 1 | MicroDepeg/RateShock configureProduct duration=86400 but shields require 604800 | Purchases revert with DurationOutOfRange | Changed to 604800 in both mainnet + sepolia scripts |
| 2 | (Historical) Product IDs used wrong format (FLASH_BTC_1H vs FLASHBTC1H-001) | Shields unreachable | Fixed in prior commit, verified correct now |

---

## Sign-Off

- [ ] Deployer: _______________
- [ ] Auditor: _______________
- [ ] Multisig Signers (3/5): _______________
