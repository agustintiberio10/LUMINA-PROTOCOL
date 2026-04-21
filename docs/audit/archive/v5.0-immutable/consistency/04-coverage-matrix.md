# LUMINA Protocol V5.0 - Test Coverage Matrix

> Audit branch: `audit/consistency-check-v5`
> Generated: 2026-04-19
> Scope: 15 non-interface contracts (excludes IOracle, IOracleV2, IShield)
> Method: grep of function names across test/ directory

Legend: YES = at least 1 test calls this function | NO = no test found

---

## 1. LuminaTokenV2

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| LuminaTokenV2 | `totalBurned()` | YES | LuminaTokenV2Test, AdversarialAuditTest | |
| LuminaTokenV2 | `burnFrom(address,uint256)` | YES | LuminaTokenV2Test, AccessControlAttacks, CertiKSimulation | |
| LuminaTokenV2 | `burn(uint256)` (inherited) | YES | LuminaTokenV2Test, BondVaultFuzzV2 | via ERC20Burnable |

## 2. FounderVesting

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| FounderVesting | `checkAltSeason()` | YES | FounderVestingTest, AdversarialAuditTest | |
| FounderVesting | `triggerFallback()` | YES | FounderVestingTest | |
| FounderVesting | `releaseTranche()` | YES | FounderVestingTest | |
| FounderVesting | `updateRecipient(address)` | YES | FounderVestingTest | |
| FounderVesting | `getConditions()` | YES | FounderVestingTest | |
| FounderVesting | `getStatus()` | YES | FounderVestingTest | |

## 3. TreasuryVesting

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| TreasuryVesting | `release(address,uint256)` | YES | TreasuryVestingTest, AdversarialAuditTest | |
| TreasuryVesting | `isLocked()` | YES | TreasuryVestingTest | |
| TreasuryVesting | `available()` | YES | TreasuryVestingTest | |
| TreasuryVesting | `getStatus()` | YES | TreasuryVestingTest | |

## 4. BondVault

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| BondVault | `setPolicyManager(address)` | YES | BondVaultTest, DeployV5Test, PolicyManagerV2Test | |
| BondVault | `issueBond(address,uint256)` | YES | BondVaultTest, BondVaultFuzz, BondVaultFuzzV2, PolicyManagerV2Test, FullPolicyLifecycle, CertiKSimulation | |
| BondVault | `redeemBond(uint256,uint256)` | YES | BondVaultTest, BondVaultFuzz, BondVaultFuzzV2, ReentrancyAttacks, EconomicExploits | |
| BondVault | `triggerBreaker()` | YES | BondVaultTest, EmergencyResponse, EconomicExploits | |
| BondVault | `resetCircuitBreaker()` | YES | BondVaultTest, EmergencyResponse | |
| BondVault | `availableCapacityUSD()` | YES | BondVaultTest, BondVaultFuzz, PolicyManagerV2Test | |
| BondVault | `previewRedemption(uint256)` | YES | BondVaultTest | |
| BondVault | `getStatus()` | YES | BondVaultTest, BondVaultFuzz | |
| BondVault | `decreaseObligations(uint256)` | YES | BondVaultTest, EconomicExploits, AccessControlAttacks | |
| BondVault | `burnFromReserves(uint256)` | YES | BondVaultTest, EconomicExploits, AccessControlAttacks | |
| BondVault | `setAuthorizedCaller(address,bool)` | YES | BondVaultTest, DeployV5Test, AccessControlAttacks | |

## 5. ClaimBond

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| ClaimBond | `setBondVault(address)` | YES | ClaimBondTest, DeployV5Test, DeploymentFlow | |
| ClaimBond | `mint(address,uint256,uint256)` | YES | ClaimBondTest, BondVaultTest, FullPolicyLifecycle | |
| ClaimBond | `burn(address,uint256,uint256)` | YES | ClaimBondTest, BondVaultTest | |
| ClaimBond | `burnByHolder(address,uint256,uint256)` | YES | ClaimBondTest, BuybackEngineTest, EconomicExploits | |
| ClaimBond | `getFaceValue(uint256)` | YES | ClaimBondTest, BuybackEngineTest | |
| ClaimBond | `getHolderFaceValue(address,uint256)` | YES | ClaimBondTest | |
| ClaimBond | `isMatured(uint256)` | YES | ClaimBondTest, BondVaultTest | |
| ClaimBond | `getEpochInfo(uint256)` | YES | ClaimBondTest | |
| ClaimBond | `uri(uint256)` | YES | ClaimBondTest | |

## 6. AdaptiveFeeDistributor

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| AdaptiveFeeDistributor | `getDistribution()` | YES | AdaptiveFeeDistributorTest, AdaptiveFeeDistributorFuzz, EmergencyResponse | |
| AdaptiveFeeDistributor | `isHealthy()` | YES | AdaptiveFeeDistributorTest, SolvencyOracleTest | |
| AdaptiveFeeDistributor | `lookupDistribution(uint8,uint8)` | YES | AdaptiveFeeDistributorTest, AdaptiveFeeDistributorFuzz | |

## 7. CoverRouterV2

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| CoverRouterV2 | `purchasePolicy(bytes32,uint256,bytes32)` | YES | CoverRouterV2Test, FullPolicyLifecycle, CertiKSimulation, AdversarialAuditTest | |
| CoverRouterV2 | `purchasePolicyFor(bytes32,uint256,bytes32,address)` | YES | CoverRouterV2Test, AdversarialAuditTest | |
| CoverRouterV2 | `submitTrigger(bytes32,uint256,bytes)` | YES | FullPolicyLifecycle, CertiKSimulation | |
| CoverRouterV2 | `configureProduct(...)` | YES | CoverRouterV2Test, DeployV5Test, FullPolicyLifecycle | |
| CoverRouterV2 | `setRelayer(address,bool)` | YES | CoverRouterV2Test, AdversarialAuditTest | |
| CoverRouterV2 | `setPaused(bool)` | YES | CoverRouterV2Test, EmergencyResponse | |
| CoverRouterV2 | `setPolicyManager(address)` | YES | CoverRouterV2Test, DeployV5Test | |
| CoverRouterV2 | `setTwapBurner(address)` | YES | CoverRouterV2Test, UpgradePaths | |
| CoverRouterV2 | `quotePremium(bytes32,uint256)` | YES | CoverRouterV2Test, DeployV5Test | |
| CoverRouterV2 | `getProductConfig(bytes32)` | YES | CoverRouterV2Test, DeployV5Test | |
| CoverRouterV2 | `getProductCount()` | YES | CoverRouterV2Test, DeployV5Test | |

## 8. PolicyManagerV2

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| PolicyManagerV2 | `setRouter(address)` | YES | PolicyManagerV2Test, DeployV5Test, DeploymentFlow, FullPolicyLifecycle | |
| PolicyManagerV2 | `registerProduct(bytes32,address)` | YES | PolicyManagerV2Test, DeployV5Test, FullPolicyLifecycle, CertiKSimulation | |
| PolicyManagerV2 | `deactivateProduct(bytes32)` | **NO** | -- | RED FLAG: no test for product deactivation |
| PolicyManagerV2 | `recordPolicy(...)` | YES | PolicyManagerV2Test, FullPolicyLifecycle, CertiKSimulation | |
| PolicyManagerV2 | `triggerPayout(bytes32,uint256,bytes)` | YES | PolicyManagerV2Test, FullPolicyLifecycle, CertiKSimulation | |
| PolicyManagerV2 | `markExpired(bytes32,uint256)` | YES | PolicyManagerV2Test | |
| PolicyManagerV2 | `getProductCount()` | YES | PolicyManagerV2Test, DeployV5Test | |
| PolicyManagerV2 | `getPolicy(bytes32,uint256)` | YES | PolicyManagerV2Test | |
| PolicyManagerV2 | `getStats()` | YES | PolicyManagerV2Test, TWAPBurnerTest | |

## 9. TWAPBurner

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| TWAPBurner | `receivePremium(uint256)` | YES | TWAPBurnerTest, TWAPBurnerFuzz, CoverRouterV2Test, FullPolicyLifecycle | |
| TWAPBurner | `receiveMarketplaceFee(uint256)` | YES | TWAPBurnerTest | |
| TWAPBurner | `executeBurn()` | YES | TWAPBurnerTest, TWAPBurnerFuzz, FullPolicyLifecycle, CertiKSimulation | |
| TWAPBurner | `setPoolFee(uint24)` | **NO** | -- | RED FLAG: no test for fee tier change |
| TWAPBurner | `setMaxSlippageBps(uint256)` | **NO** | -- | RED FLAG: no test for slippage config |
| TWAPBurner | `setMinBurnAmount(uint256)` | YES | TWAPBurnerTest | |
| TWAPBurner | `setMaxBurnAmount(uint256)` | YES | TWAPBurnerTest | |
| TWAPBurner | `setBurnCooldown(uint256)` | YES | TWAPBurnerTest | |
| TWAPBurner | `setAuthorizedSender(address,bool)` | YES | DeployV5Test | |
| TWAPBurner | `setCapacityOracle(address)` | YES | TWAPBurnerTest, UpgradePaths | |
| TWAPBurner | `setFeeDistributor(address)` | YES | TWAPBurnerTest, UpgradePaths, EmergencyResponse, AccessControlAttacks | |
| TWAPBurner | `setReserves(address,address,address)` | YES | TWAPBurnerTest, UpgradePaths, EmergencyResponse | |
| TWAPBurner | `setMaintenanceReserve(address)` | YES | TWAPBurnerTest, EmergencyResponse | |
| TWAPBurner | `setAdaptiveMode(bool)` | YES | TWAPBurnerTest, UpgradePaths, EmergencyResponse | |
| TWAPBurner | `pendingUSDC()` | YES | TWAPBurnerTest | |
| TWAPBurner | `canBurn()` | YES | TWAPBurnerTest | |
| TWAPBurner | `getStats()` | YES | TWAPBurnerTest | |
| TWAPBurner | `recoverToken(address,uint256)` | YES | TWAPBurnerTest | |

## 10. CapacityOracle

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| CapacityOracle | `getLuminaPrice()` | YES | CapacityOracleTest, BondVaultTest, BondVaultFuzz, CapacityOracleFork, many more | |
| CapacityOracle | `_getTwapPrice()` | YES | CapacityOracleTest, CapacityOracleFork | Public for try/catch |
| CapacityOracle | `getTWAP(uint32)` | YES | CapacityOracleTest | |
| CapacityOracle | `maxPoliciesPerDay()` | YES | CapacityOracleTest, CapacityOracleFork | |
| CapacityOracle | `setPool(address)` | **NO** | -- | RED FLAG: no direct test for pool migration. (Used in constructor setup but no explicit setPool test) |
| CapacityOracle | `setTwapWindow(uint32)` | YES | CapacityOracleTest | |
| CapacityOracle | `setEmergencyPrice(uint256)` | YES | CapacityOracleTest | |

## 11. SolvencyOracle

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| SolvencyOracle | `evaluate()` | YES | SolvencyOracleTest, OracleEvaluationStress, EmergencyResponse, TimingAttacks, EconomicExploits | |
| SolvencyOracle | `setEmergencyPause(bool)` | YES | SolvencyOracleTest, EmergencyResponse, AccessControlAttacks | |
| SolvencyOracle | `getSolvencyRatio()` | YES | SolvencyOracleTest, EconomicExploits | |
| SolvencyOracle | `getCurrentQuadrant()` | YES | SolvencyOracleTest, AdaptiveFeeDistributorFuzz | |
| SolvencyOracle | `isHealthy()` | YES | SolvencyOracleTest, EmergencyResponse | |

## 12. CEXLiquidityReserve

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| CEXLiquidityReserve | `allocate(...)` | YES | CEXLiquidityReserveTest, CEXReserveFuzz, EconomicAttacks, TimingAttacks | |
| CEXLiquidityReserve | `getAvailableInBucket(SubBucket)` | YES | CEXLiquidityReserveTest, CEXReserveFuzz | |
| CEXLiquidityReserve | `getVestedAmount()` | YES | CEXLiquidityReserveTest, CEXReserveFuzz | |
| CEXLiquidityReserve | `getTotalAllocated()` | YES | CEXLiquidityReserveTest | |
| CEXLiquidityReserve | `getAllocationHistoryLength()` | YES | CEXLiquidityReserveTest | |
| CEXLiquidityReserve | `getCurrentMonth()` | YES | CEXLiquidityReserveTest | |
| CEXLiquidityReserve | `getMonthlyCapRemaining()` | YES | CEXLiquidityReserveTest | |

## 13. MaintenanceReserve

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| MaintenanceReserve | `spend(...)` | YES | MaintenanceReserveTest, MaintenanceReserveFuzz | |
| MaintenanceReserve | `setMonthlyCap(uint256)` | YES | MaintenanceReserveTest | |
| MaintenanceReserve | `spendCount()` | YES | MaintenanceReserveTest | |
| MaintenanceReserve | `balance()` | YES | MaintenanceReserveTest | |
| MaintenanceReserve | `monthlyRemaining()` | YES | MaintenanceReserveTest | |
| MaintenanceReserve | `recoverToken(address,uint256)` | YES | MaintenanceReserveTest | |

## 14. BuybackEngine

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| BuybackEngine | `setDailyBuyback(uint256,uint256,uint256)` | YES | BuybackEngineTest, AccessControlAttacks, TimingAttacks, EmergencyResponse | |
| BuybackEngine | `executeOffer(uint256)` | YES | BuybackEngineTest, EconomicExploits | |
| BuybackEngine | `isActivated()` | YES | BuybackEngineTest, TimingAttacks | |
| BuybackEngine | `timeUntilActivation()` | YES | BuybackEngineTest | |
| BuybackEngine | `supportsInterface(bytes4)` | YES | ReentrancyAttacks (indirect) | |

## 15. LuminaBondMarketplace

| Contract | Function | Has Test? | Test File(s) | Notes |
|---|---|---|---|---|
| LuminaBondMarketplace | `list(uint256,uint256,uint256)` | YES | LuminaBondMarketplaceTest, MarketplaceStress, MarketplaceFuzz, EconomicExploits | |
| LuminaBondMarketplace | `cancel(uint256)` | YES | LuminaBondMarketplaceTest, EconomicExploits | |
| LuminaBondMarketplace | `executeBuy(uint256)` | YES | LuminaBondMarketplaceTest, MarketplaceStress, BuybackEngineTest, EconomicExploits | |
| LuminaBondMarketplace | `setTwapBurner(address)` | YES | LuminaBondMarketplaceTest, UpgradePaths | |
| LuminaBondMarketplace | `getListing(uint256)` | YES | LuminaBondMarketplaceTest, BuybackEngineTest | |
| LuminaBondMarketplace | `calculateFees(uint256)` | YES | LuminaBondMarketplaceTest | |
| LuminaBondMarketplace | `supportsInterface(bytes4)` | YES | ReentrancyAttacks (indirect) | |

---

## Shield Products (BaseShield + 9 concrete shields)

All shield functions are tested via the BaseShield interface (createPolicy, verifyAndCalculate, markPaidOut, markExpired, getPolicyInfo, getPolicyStatus, totalPolicies, activePolicies, totalActiveCoverage). The product-specific metadata functions (productId, riskType, maxAllocationBps, durationRange, waitingPeriod) and data getters (getBSSData, getDepegData, getRateShockData) are covered per-shield.

| Shield | Dedicated Test File | Has Integration Test? | Notes |
|---|---|---|---|
| BaseShield (abstract) | N/A (tested through concrete shields) | YES | |
| FlashBTCShield1h | FlashShieldsTest | YES | Grouped test; also in DeployV5Test |
| FlashBTCShield4h | FlashShieldsTest | YES | Grouped test |
| FlashBTCShield24h | FlashBTCShield24hTest | YES | Dedicated + grouped test |
| FlashBTCShield48h | FlashBTCShield48hTest | YES | Dedicated + grouped test |
| FlashETHShield1h | FlashShieldsTest | YES | Grouped test; also in DeployV5Test |
| FlashETHShield24h | FlashETHShield24hTest | YES | Dedicated + grouped test |
| FlashETHShield48h | FlashETHShield48hTest | YES | Dedicated + grouped test |
| MicroDepegShield | MicroDepegShieldTest | YES | Dedicated test |
| RateShockShield | RateShockShieldTest | YES | Dedicated test; currentBorrowRate() tested |

### Shield Function Coverage Detail

| Function (via BaseShield) | Has Test? | Notes |
|---|---|---|
| `createPolicy(...)` | YES | All shield tests create policies |
| `verifyAndCalculate(uint256,bytes)` | YES | All shield tests verify triggers |
| `markPaidOut(uint256)` | YES | DeployV5Test (limited) |
| `markExpired(uint256)` | YES | PolicyManagerV2Test, CertiKSimulation |
| `getPolicyInfo(uint256)` | YES | Shield tests, PolicyManagerV2Test |
| `getPolicyStatus(uint256)` | YES | Shield tests |
| `totalPolicies()` | YES | CertiKSimulation, DeployV5Test |
| `activePolicies()` | YES | CertiKSimulation, DeployV5Test |
| `totalActiveCoverage()` | YES | CertiKSimulation |
| `productId()` | YES | All shield tests, DeployV5Test |
| `riskType()` | YES | Shield tests |
| `maxAllocationBps()` | YES | Shield tests |
| `durationRange()` | YES | Shield tests |
| `waitingPeriod()` | YES | Shield tests |
| `getBSSData(uint256)` | YES | FlashBTC/ETH shield tests |
| `getDepegData(uint256)` | YES | MicroDepegShieldTest |
| `getRateShockData(uint256)` | YES | RateShockShieldTest |
| `currentBorrowRate()` (RateShock only) | YES | RateShockShieldTest |

---

## RED FLAGS: Functions WITHOUT Tests

| # | Contract | Function | Severity | Risk |
|---|---|---|---|---|
| 1 | PolicyManagerV2 | `deactivateProduct(bytes32)` | **HIGH** | Admin function to disable a product. No test verifies deactivation prevents new policies or that already-active policies remain valid. |
| 2 | TWAPBurner | `setPoolFee(uint24)` | **MEDIUM** | Admin function to change Uniswap fee tier (500/3000/10000). No test validates fee tier switching or revert on invalid values. |
| 3 | TWAPBurner | `setMaxSlippageBps(uint256)` | **MEDIUM** | Admin function to change max slippage tolerance. No test validates bounds (50-1000 bps) or effect on executeBurn. |
| 4 | CapacityOracle | `setPool(address)` | **MEDIUM** | Admin function for Uniswap pool migration. Constructor uses it internally, but no explicit test calls setPool() after deployment with token0/token1 validation. |

### Additional Observations

1. **markPaidOut()** has very limited direct testing (only in DeployV5Test). The full trigger-to-payout flow is mostly tested through PolicyManagerV2's triggerPayout(), which calls it indirectly.

2. **FlashBTCShield1h and FlashBTCShield4h** lack dedicated test files -- they are only tested via the grouped FlashShieldsTest.t.sol. Consider adding dedicated files for completeness, especially for edge cases unique to their shorter durations.

3. **FlashETHShield1h** also lacks a dedicated test file (only in FlashShieldsTest.t.sol).

4. **No test file exists for BaseShield directly** -- it is always tested through concrete shields, which is architecturally correct but means base-level edge cases (CLAIM_GRACE_PERIOD, _validateStatusForTrigger with sequencer downtime) may not be thoroughly unit-tested.

---

## Test File Inventory (by type)

| Type | Count | Files |
|---|---|---|
| Unit tests | 16 | token/*, bonds/*, core/*, oracles/*, treasury/*, marketplace/*, products/* |
| Fuzz tests | 8 | fuzz/* |
| Integration tests | 8 | integration/scenarios/*, integration/attacks/* |
| Stress tests | 5 | stress/* |
| Invariant tests | 2 | invariant/*, invariants/* |
| Audit tests | 4 | audit/*, audit/phase7/* |
| Fork tests | 3 | fork/*, integration/CapacityOracleFork |
| Deploy tests | 1 | deploy/DeployV5Test |
| Helpers/Mocks | 7 | handlers/*, mocks/* |
| Other | 1 | SaltMining.t.sol |
| **Total** | **55** | |
