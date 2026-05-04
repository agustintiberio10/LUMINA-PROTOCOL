# LUMINA Protocol V5.0 -- Deploy Checklist

> Use this checklist for every deployment (testnet or mainnet).
> Do not skip steps. Mark each item only after it is independently verified.

---

## Pre-requisites

- [ ] Gnosis Safe 2-of-3 multisig created on Base
- [ ] Signer addresses confirmed and verified
- [ ] LBP deposit address confirmed (Fjord Foundry)
- [ ] USDC address verified: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (Base)
- [ ] Uniswap V3 Router verified: `0x2626664c2603336E57B271c5C0b26F421741e481` (Base SwapRouter02)
- [ ] Uniswap V3 LUMINA/USDC pool created (or `address(0)` for initial deploy)
- [ ] Chainlink oracles verified on Base:
  - [ ] BTC/USD
  - [ ] ETH/USD
  - [ ] USDT/USD
- [ ] Aave V3 pool address on Base confirmed (READ-ONLY oracle for RateShockShield + FounderVesting Condition C; not used for yield)

---

## Environment

- [ ] `.env` file populated with all required variables (see [ENV-VARIABLES.md](./ENV-VARIABLES.md))
- [ ] `DEPLOYER_PRIVATE_KEY` secured (NOT committed to git)
- [ ] `BASE_RPC_URL` configured
- [ ] `BASESCAN_API_KEY` for contract verification
- [ ] Deployer wallet funded (~0.1 ETH for gas on Base)

---

## Pre-deploy Testing

- [ ] All 360+ tests passing: `forge test --no-match-contract Fork`
- [ ] Deploy script tested on Anvil: `forge script ... --fork-url http://localhost:8545`
- [ ] Verify script tested on Anvil
- [ ] Slither analysis clean: 0 HIGH findings
- [ ] External audit completed (Phase 7)

---

## Deploy Execution

Follow the exact order in [DEPLOY-V5-ORDER.md](./DEPLOY-V5-ORDER.md).

### Phase 1 -- Independent Contracts
- [ ] Step 1: Deploy `MaintenanceReserve(USDC, multisig)`
- [ ] Step 2: Deploy `ClaimBond()`

### Phase 2 -- Pre-compute & LUMINA-dependent Contracts
- [ ] Step 3: Pre-compute `LuminaTokenV2` address (CREATE2 / nonce prediction)
- [ ] Step 4: Deploy `CapacityOracle(pool=0x0, luminaToken=precomputed, usdcToken=USDC, emergencyPrice=0.036e18)`
- [ ] Step 5: Deploy `BondVault(lumina=precomputed, claimBond, capacityOracle, policyManager=0x0)`
- [ ] Step 6: Deploy `CEXLiquidityReserve(lumina=precomputed, admin=multisig)`
- [ ] Step 7: Deploy `FounderVesting(chainlinkOracle, aavePool, luminaToken=precomputed, usdc, recipient)`
- [ ] Step 8: Deploy `TreasuryVesting(luminaToken=precomputed)`

### Phase 3 -- Deploy LUMINA Token
- [ ] Step 9: Deploy `LuminaTokenV2(bondVault, cexReserve, founderVesting, lbpDeposit, treasuryVesting)`
- [ ] Step 9a: Verify deployed address matches pre-computed value from Step 3

### Phase 4 -- Oracle & Adaptive Layers
- [ ] Step 10: Call `ClaimBond.setBondVault(bondVault)` (one-shot)
- [ ] Step 11: Deploy `SolvencyOracle(bondVault, capacityOracle, admin=multisig)`
- [ ] Step 12: Deploy `AdaptiveFeeDistributor(solvencyOracle)`

### Phase 5 -- Core Protocol
- [ ] Step 13: Deploy `TWAPBurner(usdc, lumina, uniswapRouter)`
- [ ] Step 14: Deploy `PolicyManagerV2(bondVault)`
- [ ] Step 15: Call `BondVault.setPolicyManager(policyManager)` (one-shot)
- [ ] Step 16: Deploy `CoverRouterV2(usdc, policyManager, twapBurner)`
- [ ] Step 17: Call `PolicyManagerV2.setRouter(coverRouter)`

### Phase 6 -- Marketplace
- [ ] Step 18: Deploy `LuminaBondMarketplace(claimBond, usdc, twapBurner, admin=multisig)`
- [ ] Step 19: Deploy `BuybackEngine(claimBond, bondVault, solvencyOracle, capacityOracle, marketplace, usdc, multisig)`

### Phase 7 -- Shields
- [ ] Step 20: Deploy `FlashBTC_1h` Shield and register in PolicyManagerV2 + CoverRouterV2
- [ ] Step 21: Deploy `FlashBTC_4h` Shield and register
- [ ] Step 22: Deploy `FlashBTC_24h` Shield and register
- [ ] Step 23: Deploy `FlashBTC_48h` Shield and register
- [ ] Step 24: Deploy `FlashETH_1h` Shield and register
- [ ] Step 25: Deploy `FlashETH_24h` Shield and register
- [ ] Step 26: Deploy `FlashETH_48h` Shield and register
- [ ] Step 27: Deploy `MicroDepeg` Shield and register
- [ ] Step 28: Deploy `RateShock` Shield and register

### Phase 8 -- Wire Roles & Permissions
- [ ] Step 29: `LuminaTokenV2.grantRole(BURNER_ROLE, twapBurner)`
- [ ] Step 30: `TWAPBurner.setFeeDistributor(adaptiveFeeDistributor)`
- [ ] Step 31: `TWAPBurner.setReserves(buybackEngine, opsWallet, maintenanceReserve)`
- [ ] Step 32: `TWAPBurner.setCapacityOracle(capacityOracle)`
- [ ] Step 33: `TWAPBurner.setAdaptiveMode(true)`
- [ ] Step 34: `TWAPBurner.setAuthorizedSender(coverRouter, true)`
- [ ] Step 35: `policyManager.setAuthorizedCaller(buybackEngine, true)` on BondVault

### Phase 9 -- Transfer Ownership to Multisig (2-of-3)
- [ ] Step 36a: `TWAPBurner.transferOwnership(multisig)`
- [ ] Step 36b: `CoverRouterV2.transferOwnership(multisig)`
- [ ] Step 36c: `PolicyManagerV2.transferOwnership(multisig)`
- [ ] Step 36d: `CapacityOracle.transferOwnership(multisig)`
- [ ] Step 36e: `FounderVesting.transferOwnership(multisig)`
- [ ] Step 36f: `TreasuryVesting.transferOwnership(multisig)`
- [ ] Step 36g: `ClaimBond.transferOwnership(multisig)`

---

## Post-deploy Verification

- [ ] Run `VerifyLuminaV5Deployment.s.sol` against the deployed addresses
- [ ] Verify all contracts on Basescan (`forge verify-contract ...`)
- [ ] Confirm token balances match expected distribution:
  - [ ] `BondVault`: 70,000,000 LUMINA
  - [ ] `CEXLiquidityReserve`: 14,000,000 LUMINA
  - [ ] `FounderVesting`: 8,000,000 LUMINA
  - [ ] `LBP Deposit`: 5,000,000 LUMINA
  - [ ] `TreasuryVesting`: 3,000,000 LUMINA
- [ ] Confirm roles are correctly assigned:
  - [ ] `BURNER_ROLE` -> `TWAPBurner`
  - [ ] `ALLOCATOR_ROLE` -> expected holder
  - [ ] `SPENDER_ROLE` -> expected holder
  - [ ] `BUYBACK_OPERATOR_ROLE` -> expected holder
- [ ] Confirm wiring: all cross-contract references are correct
  - [ ] `BondVault.policyManager()` == `PolicyManagerV2`
  - [ ] `PolicyManagerV2.router()` == `CoverRouterV2`
  - [ ] `TWAPBurner.feeDistributor()` == `AdaptiveFeeDistributor`
  - [ ] `TWAPBurner.capacityOracle()` == `CapacityOracle`
  - [ ] `TWAPBurner.adaptiveMode()` == `true`
  - [ ] `ClaimBond.bondVault()` == `BondVault`
- [ ] Confirm ownership: all Ownable contracts point to Multisig
- [ ] Test a small policy purchase end-to-end on mainnet

---

## Post-deploy Security

- [ ] Immunefi bug bounty program launched
  - [ ] $5K tier for Low/Medium
  - [ ] $50K tier for Critical
- [ ] Monitoring dashboards set up (Grafana / Tenderly)
- [ ] Alert rules configured for circuit breaker events
  - [ ] BondVault solvency ratio drops below threshold
  - [ ] Unusual claim volume spike
  - [ ] Oracle staleness / deviation
- [ ] Emergency response plan documented and distributed to signers

---

## Rollback Plan

- [ ] Document: "If deploy fails at step X, impact is Y, recovery is Z" for each phase
- [ ] **Immutable contracts** -- No rollback possible. If a contract is deployed with wrong params, it stays on-chain but is simply not wired into the protocol. Deploy a corrected version and continue.
- [ ] **Wiring mistakes** -- Re-run `WireLuminaV5PostDeploy.s.sol` with corrected addresses. All setter functions (except one-shots) can be called again by the owner.
- [ ] **One-shot functions already called** (`setBondVault`, `setPolicyManager`) -- If called with wrong values, the affected contract must be redeployed. The one-shot prevents correction.
- [ ] **Ownership already transferred** -- If ownership is transferred to multisig before wiring is complete, remaining wiring must be executed via multisig transactions (slower but still possible).

### Phase-specific recovery notes

| Failed At | Impact | Recovery |
|-----------|--------|----------|
| Phase 1   | None -- independent contracts | Redeploy the failed contract |
| Phase 2   | Pre-computed address may shift | Recompute nonce, redeploy Phase 2 contracts |
| Phase 3   | Token not minted | Fix issue, redeploy token (Phase 2 contracts may need redeployment if nonce shifted) |
| Phase 4   | Oracle layer incomplete | Redeploy failed oracle contract |
| Phase 5   | Core protocol non-functional | Redeploy failed contract, re-wire |
| Phase 6   | Marketplace unavailable | Redeploy; protocol still functional without marketplace |
| Phase 7   | Missing shields | Deploy remaining shields later; protocol works with partial shield set |
| Phase 8   | Permissions incomplete | Re-run wiring script |
| Phase 9   | Deployer retains ownership | Re-run ownership transfer (not urgent, but do promptly) |
