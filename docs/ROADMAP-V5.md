# LUMINA Protocol V5.0 — Implementation Roadmap

Complete checklist from current state (Phase 0) to mainnet launch (Phase 10) and post-deployment operations (Phase 11).

## Status

- **Phase 0**: Cleanup completed
- **Phase 0.3**: Audit pending
- **Phases 1-11**: Not started

## Token Distribution (V5.0)

| Bucket | Amount | % | Lock |
|---|---|---|---|
| BondVault | 70,000,000 | 70% | Immutable |
| CEX/DEX Liquidity Reserve | 14,000,000 | 14% | Multisig 2-of-3 |
| Founder (AltSeasonVesting) | 8,000,000 | 8% | Conditional 2-of-3 × 7d × 3 tranches |
| LBP (Fjord Foundry) | 5,000,000 | 5% | Released at LBP close |
| Treasury | 3,000,000 | 3% | 180d lock + 250K/month |

## Product Catalog (9 Shields V5.0)

| # | Product | Multiplier |
|---|---|---|
| 1 | Flash BTC 1h | 333x |
| 2 | Flash BTC 4h | 190x |
| 3 | Flash BTC 24h | 44x |
| 4 | Flash BTC 48h | 83x |
| 5 | Flash ETH 1h | 266x |
| 6 | Flash ETH 24h | 33x |
| 7 | Flash ETH 48h | 74x |
| 8 | Micro Depeg USDT | 19x |
| 9 | Rate Shock | TBD |

---

## PHASE 0 — Cleanup and Audit

### 0.1 — GitHub Cleanup
- [x] Create branch legacy/v1-archive
- [x] Identify A/B/C category files
- [x] Archive V1 files
- [x] Reorganize folders
- [x] Update README
- [x] Verify forge build passes
- [x] Verify forge test passes
- [x] Create cleanup PR
- [x] Add ROADMAP-V5.md
- [ ] Merge PR to main

### 0.2 — Local PC Cleanup
- [ ] Archive old V1 folders

### 0.3 — V5.0 Audit
- [ ] Execute audit prompt on clean repo
- [ ] Receive complete report on 12 areas
- [ ] Review identified gaps
- [ ] Validate proposed change plan

---

## PHASE 1 — Infrastructure Setup

### 1.1 — Gnosis Safe Multisig
- [ ] Get technical advisor address
- [ ] Deploy Gnosis Safe 2-of-3 on Base
- [ ] Verify configuration
- [ ] Test transaction

### 1.2 — Environment Variables
- [ ] Set BASE_RPC_URL in GitHub Secrets
- [ ] Set BASE_SEPOLIA_RPC_URL
- [ ] Set DEPLOYER_PRIVATE_KEY
- [ ] Set BASESCAN_API_KEY

### 1.3 — CI/CD
- [ ] Configure GitHub Actions
- [ ] forge fmt check on each PR
- [ ] forge test on each PR
- [ ] Slither on each PR
- [ ] Configure fork tests

### 1.4 — Deploy Wallets
- [ ] Deployer Wallet
- [ ] Owner Wallet (founder hot)
- [ ] Cold Storage Wallet
- [ ] Technical Advisor Wallet

### 1.5 — Aerodrome Setup
- [ ] Research listing process
- [ ] Identify optimal tick spacing
- [ ] Contact Aerodrome team

### 1.6 — Fjord Foundry Setup
- [ ] Create account
- [ ] Founder KYC
- [ ] Configure LBP parameters
- [ ] Coordinate launch date

---

## PHASE 2 — Core Contract Modifications

### 2.1 — LuminaTokenV2.sol
- [ ] New 70/14/8/5/3 distribution
- [ ] Add cexLiquidityReserve parameter
- [ ] Reduce BondVault to 70M
- [ ] Reduce Founder to 8M
- [ ] Update unit tests

### 2.2 — BondVault.sol
- [ ] Adjust constructor for 70M
- [ ] Add totalOutstandingObligationsUSD
- [ ] Add authorizedCallers mapping
- [ ] Implement decreaseObligations()
- [ ] Implement burnFromReserves()
- [ ] Implement getBondVaultHealth()
- [ ] Update tracking on mint/redeem
- [ ] Events
- [ ] Verify immutability
- [ ] Complete tests

### 2.3 — TWAPBurner.sol
- [ ] Refactor for AdaptiveFeeDistributor delegation
- [ ] Maintain TWAP buy logic
- [ ] Implement fallback 88/10/2
- [ ] Events
- [ ] Tests

### 2.4 — FounderVesting.sol
- [ ] Change to 8M
- [ ] Verify conditional mechanics
- [ ] Tests

### 2.5 — TreasuryVesting.sol
- [ ] Confirm 3M
- [ ] Verify lock 180d + 250K/month
- [ ] Tests

### 2.6 — ClaimBond.sol
- [ ] Public burn() by token owner
- [ ] getFaceValue, maturityDate, getMetadata
- [ ] Fractional amounts support
- [ ] Events
- [ ] Tests

### 2.7 — CapacityOracle.sol
- [ ] Functional capacity calculation
- [ ] Uniswap V3 TWAP integration
- [ ] Tests

### 2.8 — PolicyManagerV2 and CoverRouterV2
- [ ] Verify integrations
- [ ] Tests

---

## PHASE 3 — New Contract Development

### 3.1 — CEXLiquidityReserve.sol
- [x] ~~3 sub-buckets structure~~ **RETIRED in Tier-1 redesign** — replaced
      by a single flat 14M reserve. V1 storage slots 2/3/4 preserved as
      `__deprecated_allocatedFrom*` for upgrade safety; `totalAllocated`
      consolidates the three counters.
- [ ] Owner: Gnosis Safe 2-of-3
- [ ] `allocate(recipient, amount, purpose, description)` function — no
      SubBucket parameter (Tier-1 redesign).
- [ ] View functions (`getMonthlyCapRemaining`, `getCurrentMonth`,
      `getTotalAllocated`, `getAllocationHistoryLength`)
- [ ] Purpose enum
- [ ] Events: `Allocated`, `MonthlyCapWarning`, `MonthlyCapUpdated` (per
      [Fix H-2]), `TokenRecovered`
- [ ] Monthly cap (mutable storage, default `DEFAULT_MONTHLY_CAP = 1M`,
      ceiling `MAX_MONTHLY_CAP = TOTAL_AMOUNT = 14M`; `setMonthlyCap` gated
      by `DEFAULT_ADMIN_ROLE` — [Fix H-2])
- [ ] Lifetime ceiling: `totalAllocated <= TOTAL_AMOUNT (=14M)` enforced
      in `allocate()` (Tier-1 redesign).
- [ ] `initializeV2()` reinitializer(2), `DEFAULT_ADMIN_ROLE`-gated, for
      upgrades of pre-existing V5.1 proxies — sets default cap and seeds
      `totalAllocated` from the deprecated buckets.
- [ ] Tests

### 3.2 — SolvencyOracle.sol
- [ ] getSolvencyRatio()
- [ ] getPriceMomentum()
- [ ] detectQuadrant()
- [ ] getCurrentDistribution()
- [ ] Cooldown 7 days
- [ ] Smoothing 3-day moving average
- [ ] Events
- [ ] Tests including manipulation tests

### 3.3 — AdaptiveFeeDistributor.sol
- [ ] Hardcoded 4x4 matrix
- [ ] getDistribution function
- [ ] distribute function
- [ ] Fallback 88/10/2
- [ ] Events
- [ ] Tests for all 16 quadrants

### 3.4 — BuybackEngine.sol
- [ ] DailyBuybackConfig struct
- [ ] setDailyBuyback() onlyMultisig
- [ ] executeOffer()
- [ ] All validations
- [ ] Double Burn implementation
- [ ] Per-tx cap 5%
- [ ] Circuit breaker 150% solvency
- [ ] Activation month 12+
- [ ] Events
- [ ] Tests

---

## PHASE 4 — 9 Shields Development

### 4.1 — BaseShield.sol
- [ ] Common functions
- [ ] checkTrigger interface
- [ ] executePayout emits ClaimBond
- [ ] registerPolicy updates BondVault
- [ ] Tests

### 4.2-4.10 — Individual Shields

For each of: Flash BTC 1h/4h/24h/48h, Flash ETH 1h/24h/48h, Micro Depeg USDT, Rate Shock:
- [ ] Contract created
- [ ] Trigger logic
- [ ] Multiplier hardcoded
- [ ] Threshold defined
- [ ] Oracle integrated
- [ ] checkTrigger and executePayout
- [ ] Tests

### 4.11 — Cross-shield Validation
- [ ] No double-spending
- [ ] Payouts within capacity
- [ ] Premium covers expected payout
- [ ] Integration tests

---

## PHASE 5 — Integration and Wiring

### 5.1 — Roles and Permissions
- [ ] BURNER_ROLE to TWAPBurner
- [ ] OBLIGATION_REDUCER_ROLE to BuybackEngine
- [ ] RESERVES_BURNER_ROLE to BuybackEngine
- [ ] POLICY_MANAGER_ROLE to CoverRouterV2
- [ ] SHIELD_ROLE to 9 shields
- [ ] Multisig as owner of CEXLiquidityReserve
- [ ] Multisig as owner of BuybackEngine
- [ ] TimelockController for upgrades

### 5.2 — Product Configuration
- [ ] Register 9 products in CoverRouterV2

### 5.3 — Oracle Integration
- [ ] LuminaOracle for LUMINA prices
- [ ] Chainlink BTC/USD on Base
- [ ] Chainlink ETH/USD on Base
- [ ] Chainlink USDT/USD
- [ ] CapacityOracle integration
- [ ] SolvencyOracle integration
- [ ] Emergency fallbacks

### 5.4 — NFT Marketplace
- [ ] Decide own vs external
- [ ] Deploy or integrate
- [ ] Configure fees 3%
- [ ] BuybackEngine integration
- [ ] Tests

### 5.5 — Frontend Integration
- [ ] Update landing page
- [ ] Connect new contracts
- [ ] Treasury dashboard
- [ ] Marketplace UI
- [ ] E2E tests

### 5.6 — API Integration
- [ ] Update API for AI agents
- [ ] /api/v3/purchase endpoint
- [ ] API key system
- [ ] Documentation

---

## PHASE 6 — Exhaustive Testing

### 6.1 — Unit Tests
- [ ] Coverage >85% on critical contracts
- [ ] 100% on each individually

### 6.2 — Invariant Tests
- [ ] BondVault solvency 5 invariants
- [ ] TWAPBurner distribution
- [ ] BuybackEngine cap
- [ ] CEXLiquidityReserve vesting
- [ ] AdaptiveFeeDistributor matrix

### 6.3 — Fuzz Tests
- [ ] BondVault mint/redeem
- [ ] BuybackEngine executeOffer
- [ ] AdaptiveFeeDistributor distribute
- [ ] Each shield checkTrigger

### 6.4 — Fork Tests on Base Mainnet
- [ ] CapacityOracle vs real Uniswap V3
- [ ] SolvencyOracle simulated
- [ ] AdaptiveFeeDistributor real prices
- [ ] Aerodrome integration
- [ ] Each Chainlink oracle

### 6.5 — End-to-End Tests
- [ ] Complete purchase flow
- [ ] Premium distribution flow
- [ ] Buyback flow
- [ ] CEX allocation flow

### 6.6 — Stress Tests
- [ ] 100 simultaneous policies
- [ ] 1000 bonds in system
- [ ] Massive simultaneous trigger
- [ ] Aggressive buyback

### 6.7 — Gas Optimization
- [ ] Gas report critical functions
- [ ] Optimize where >$5 USD per tx
- [ ] Benchmark comparison

---

## PHASE 7 — Security Audits

### 7.1 — Internal Automated
- [ ] Slither
- [ ] Mythril
- [ ] Echidna
- [ ] Manticore

### 7.2 — Multi-agent Red Team
- [ ] Re-run 5-agent system
- [ ] Target risk score 8.5+/10
- [ ] Resolve all critical and high findings

### 7.3 — Manual Internal
- [ ] Line-by-line of 4 new contracts
- [ ] BondVault modifications
- [ ] TWAPBurner refactor
- [ ] Roles and permissions
- [ ] Emitted events

### 7.4 — Tier 1 External (optional)
- [ ] CertiK quote
- [ ] OpenZeppelin quote
- [ ] Trail of Bits quote
- [ ] Decision based on budget

### 7.5 — Bug Bounty
- [ ] Setup on Immunefi or Hats
- [ ] Tier 1: $5K-$50K
- [ ] Tier 2: $1K-$10K
- [ ] Activate 1 week before deploy

### 7.6 — Attack Vector Analysis
- [ ] Reentrancy
- [ ] Front-running TWAPBurner
- [ ] Oracle manipulation
- [ ] Flash loan attacks
- [ ] Sandwich attacks LBP
- [ ] DoS via gas
- [ ] Privilege escalation
- [ ] Time-based attacks

---

## PHASE 8 — Pre-Deploy on Testnet

### 8.1 — Testnet Preparation
- [ ] Base Sepolia ETH
- [ ] Mock USDC
- [ ] Verify Aerodrome on Sepolia
- [ ] Verify Chainlink on Sepolia

### 8.2 — Complete Sepolia Deploy
- [ ] Salt mining
- [ ] Deploy 23 contracts in order
- [ ] Verify on Sepolia BaseScan
- [ ] Complete wiring
- [ ] Product configuration
- [ ] Initial balances

### 8.3 — Sepolia Smoke Tests
- [ ] 1 policy of each shield
- [ ] Verify ClaimBonds
- [ ] Simulate triggers
- [ ] Verify payouts
- [ ] TWAPBurner execution
- [ ] AdaptiveFeeDistributor
- [ ] Manual buyback
- [ ] Double Burn

### 8.4 — Frontend Sepolia
- [ ] Connect to Sepolia
- [ ] Buy from UI
- [ ] Treasury dashboard
- [ ] Marketplace UI
- [ ] Bug reports

### 8.5 — Public Beta on Sepolia
- [ ] Announcement
- [ ] 10-20 beta testers
- [ ] 1-2 weeks feedback
- [ ] Fix bugs

---

## PHASE 9 — Testnet Validation

### 9.1 — Functional
- [ ] All 9 shields work
- [ ] BondVault solvency under all scenarios
- [ ] BuybackEngine no errors
- [ ] AdaptiveFeeDistributor responds correctly
- [ ] Multisig works

### 9.2 — Security
- [ ] Zero exploits in bug bounty
- [ ] Slither clean
- [ ] Risk score >8.5/10
- [ ] No pending critical findings

### 9.3 — Operational
- [ ] Documentation published
- [ ] Frontend polished
- [ ] API documented
- [ ] Telemetry dashboard live

### 9.4 — Legal and Communication
- [ ] Legal disclaimer
- [ ] Terms and conditions
- [ ] Privacy policy
- [ ] Risk disclosures
- [ ] Launch communication plan

### 9.5 — Final Approval
- [ ] Founder ready for mainnet sign-off
- [ ] Technical advisor sign-off
- [ ] Backup plan documented

---

## PHASE 10 — Mainnet Deploy

### 10.1 — Pre-deploy
- [ ] BASE_RPC_URL working
- [ ] Deployer Wallet funded
- [ ] Salt mining validated
- [ ] Gnosis Safe tested
- [ ] Advisor available

### 10.2 — Deploy in Strict Order
- [ ] 1. LuminaTokenV2 with mined salt
- [ ] 2. CEXLiquidityReserve
- [ ] 3. BondVault
- [ ] 4. ClaimBond
- [ ] 5. CapacityOracle
- [ ] 6. SolvencyOracle
- [ ] 7. AdaptiveFeeDistributor
- [ ] 8. TWAPBurner
- [ ] 9. BuybackEngine
- [ ] 10. PolicyManagerV2
- [ ] 11. CoverRouterV2
- [ ] 12. FounderVesting
- [ ] 13. TreasuryVesting
- [ ] 14. BaseShield
- [ ] 15-23. The 9 individual shields

### 10.3 — BaseScan Verification
- [ ] Source code each contract
- [ ] Confirm addresses
- [ ] Confirm address(LUMINA) < USDC

### 10.4 — Post-deploy Wiring
- [ ] Grant all roles
- [ ] Configure products
- [ ] Configure oracles
- [ ] Configure marketplace
- [ ] Transfer ownership to Multisig
- [ ] Verify no EOA owners

### 10.5 — Post-deploy Validation
- [ ] Smoke test suite
- [ ] 1 test policy
- [ ] Verify ClaimBond
- [ ] Verify TWAPBurner
- [ ] Dashboard working

### 10.6 — V1 Hard Deprecation
- [ ] Pause 14 V1 contracts
- [ ] RenounceOwnership of 14 V1 contracts
- [ ] On-chain confirmation
- [ ] BaseScan deprecated tags

---

## PHASE 11 — Post-Deploy

### 11.1 — LBP Setup
- [ ] Configure Fjord LBP
- [ ] Announcement 24h before
- [ ] Launch 96h
- [ ] Monitor raise
- [ ] Close LBP
- [ ] Verify target $180K

### 11.2 — Aerodrome Pool
- [ ] Create pool LUMINA/USDC
- [ ] Seed with USDC from LBP
- [ ] Seed with LUMINA
- [ ] Verify 1% fee tier
- [ ] Verify +/-25% range
- [ ] Tick spacing correct

### 11.3 — Public Announcement
- [ ] Tweet V5.0 LIVE + V1 deprecated
- [ ] Discord post
- [ ] Medium article
- [ ] Website update
- [ ] Influencer outreach
- [ ] DeFiLlama listing

### 11.4 — Initial Monitoring
- [ ] Telemetry dashboard
- [ ] TVL monitoring
- [ ] Policies monitoring
- [ ] TWAPBurner monitoring
- [ ] Solvency Ratio monitoring
- [ ] Weekly reports

### 11.5 — Support and Community
- [ ] Discord active
- [ ] FAQ
- [ ] Tutorial humans
- [ ] Tutorial AI agents
- [ ] Partner onboarding

### 11.6 — Future Roadmap
- [ ] Month 12: activate BuybackEngine
- [ ] Month 12-18: CEX Tier 3 listing
- [ ] Month 18-24: Uniswap V3 secondary pool
- [ ] Month 24+: CEX Tier 2
- [ ] Year 2-3: CEX Tier 1

---

## Estimated Timeline

| Phase | Duration | Key Outputs |
|---|---|---|
| 0. Cleanup + Audit | 1-2 weeks | Clean repo + gap report |
| 1. Infrastructure | 1 week | Multisig, CI/CD, accounts |
| 2. Core mods | 2 weeks | Updated core contracts |
| 3. New contracts | 3-4 weeks | 4 new contracts |
| 4. Shields | 3-4 weeks | 9 functional shields |
| 5. Integration | 1-2 weeks | Complete wiring |
| 6. Testing | 3-4 weeks | 85%+ coverage |
| 7. Audits | 2-6 weeks | Risk score 8.5+/10 |
| 8. Pre-deploy testnet | 1-2 weeks | Sepolia deploy |
| 9. Testnet validation | 2 weeks | Beta testing |
| 10. Mainnet deploy | 2-3 days | 23 contracts on Base |
| 11. Post-deploy | 1 week + ongoing | LBP, pool, announcement |

**Total estimated: 4-6 months from today to mainnet.**
