# LUMINA Protocol V5.0 - Code Inventory

> Audit branch: `audit/consistency-check-v5`
> Generated: 2026-04-19
> Total files: 28 .sol files in src/

---

## 1. token/ (3 contracts)

### 1.1 LuminaTokenV2

- **File**: `src/token/LuminaTokenV2.sol`
- **Inheritance**: ERC20, ERC20Burnable, AccessControl
- **Constants/Roles**:
  - `MAX_SUPPLY = 100_000_000 * 1e18`
  - `BURNER_ROLE = keccak256("BURNER_ROLE")`
- **Public/External Functions**:
  - `totalBurned() external view returns (uint256)` -- MAX_SUPPLY - totalSupply()
  - `burnFrom(address account, uint256 amount) public override onlyRole(BURNER_ROLE)` -- burn from any address
  - Inherited: `name()`, `symbol()`, `decimals()`, `totalSupply()`, `balanceOf()`, `transfer()`, `approve()`, `transferFrom()`, `allowance()`, `burn()`, `hasRole()`, `grantRole()`, `revokeRole()`, `renounceRole()`, `supportsInterface()`
- **Events**: Inherited ERC20 (Transfer, Approval) + AccessControl (RoleGranted, RoleRevoked, RoleAdminChanged)
- **Key State Variables**: None beyond inherited (all distribution happens in constructor)

### 1.2 FounderVesting

- **File**: `src/token/FounderVesting.sol`
- **Inheritance**: Ownable
- **Constants**:
  - `ETH_BTC_THRESHOLD = 50e15`
  - `ETH_USD_THRESHOLD = 400_000_000_000`
  - `BORROW_RATE_THRESHOLD = 7e25`
  - `SUSTAINED_DURATION = 7 days`
  - `TRANCHE_INTERVAL = 31 days`
  - `TOTAL_TRANCHES = 3`
  - `FALLBACK_DURATION = 1460 days`
  - `TOTAL_AMOUNT = 8_000_000 * 1e18`
  - `TRANCHE_AMOUNT = TOTAL_AMOUNT / TOTAL_TRANCHES`
- **Immutables**: `oracle`, `aavePool`, `luminaToken`, `usdc`, `deployedAt`
- **Public/External Functions**:
  - `checkAltSeason() external` -- evaluate 2-of-3 conditions, start/reset sustained period, trigger
  - `triggerFallback() external` -- fallback after 4 years
  - `releaseTranche() external` -- release tranche after trigger
  - `updateRecipient(address newRecipient) external onlyOwner` -- change recipient
  - `getConditions() external view returns (bool, bool, bool)` -- view current conditions
  - `getStatus() external view returns (bool, uint256, uint256, uint256, uint256, uint256, uint256)` -- full status view
- **Events**: ConditionsChecked, SustainedPeriodStarted, SustainedPeriodReset, AltSeasonTriggered, TrancheReleased, RecipientUpdated, FallbackTriggered
- **Key State Variables**: `recipient`, `conditionsMetSince`, `altSeasonTriggered`, `triggerTimestamp`, `tranchesReleased`, `totalReleased`

### 1.3 TreasuryVesting

- **File**: `src/token/TreasuryVesting.sol`
- **Inheritance**: Ownable
- **Constants**:
  - `TOTAL_AMOUNT = 3_000_000 * 1e18`
  - `LOCK_DURATION = 180 days`
  - `MAX_MONTHLY_RELEASE = 250_000 * 1e18`
  - `MONTH = 30 days`
- **Immutables**: `luminaToken`, `deployedAt`
- **Public/External Functions**:
  - `release(address to, uint256 amount) external onlyOwner` -- release tokens post-lock
  - `isLocked() external view returns (bool)` -- lock status
  - `available() external view returns (uint256)` -- available to release
  - `getStatus() external view returns (uint256, uint256, uint256, bool, uint256, uint256)` -- full status
- **Events**: Released
- **Key State Variables**: `totalReleased`, `lastReleaseMonth`

---

## 2. bonds/ (2 contracts)

### 2.1 BondVault

- **File**: `src/bonds/BondVault.sol`
- **Inheritance**: ReentrancyGuard, AccessControl
- **Roles/Constants**:
  - `AUTHORIZED_CALLER_ADMIN_ROLE = keccak256("AUTHORIZED_CALLER_ADMIN_ROLE")`
  - `SAFETY_FACTOR_BPS = 5000`
  - `BOND_MATURITY_SECONDS = 730 days`
  - `MIN_PRICE = 0.005e18`
  - `RESET_PRICE = 0.008e18`
  - `MIN_REDEEM_PRICE = 0.001e18`
  - `BREAKER_COOLDOWN = 1 hours`
- **Immutables**: `lumina`, `claimBond`, `priceOracle`, `_deployer`
- **Public/External Functions**:
  - `setPolicyManager(address _pm) external` -- one-shot setter (deployer only)
  - `issueBond(address to, uint256 usdPayout) external nonReentrant` -- issue bonds (PolicyManager only)
  - `redeemBond(uint256 epochId, uint256 usdAmount) external nonReentrant` -- redeem matured bonds
  - `triggerBreaker() external` -- permissionless circuit breaker trigger
  - `resetCircuitBreaker() external` -- permissionless reset with hysteresis
  - `availableCapacityUSD() external view returns (uint256)` -- remaining USD capacity
  - `previewRedemption(uint256 usdAmount) external view returns (uint256)` -- preview LUMINA output
  - `getStatus() external view returns (uint256, uint256, uint256, uint256, uint256, bool)` -- full status
  - `decreaseObligations(uint256 amount) external onlyAuthorized` -- reduce obligations (BuybackEngine)
  - `burnFromReserves(uint256 amount) external onlyAuthorized` -- burn LUMINA from reserves
  - `setAuthorizedCaller(address caller, bool authorized) external onlyRole(AUTHORIZED_CALLER_ADMIN_ROLE)` -- manage callers
- **Events**: BondIssued, BondRedeemed, CircuitBreakerTriggered, CircuitBreakerReset, ObligationsDecreased, ReservesBurned, AuthorizedCallerUpdated, PolicyManagerSet
- **Key State Variables**: `policyManager`, `totalCommittedUSD`, `paused`, `lastBreakerTriggerTime`, `authorizedCallers` (mapping)

### 2.2 ClaimBond

- **File**: `src/bonds/ClaimBond.sol`
- **Inheritance**: ERC1155, ERC1155Supply, Ownable
- **Public/External Functions**:
  - `setBondVault(address _bondVault) external onlyOwner` -- one-shot setter
  - `mint(address to, uint256 epochId, uint256 usdAmount) external onlyBondVault` -- mint bonds
  - `burn(address from, uint256 epochId, uint256 usdAmount) external onlyBondVault` -- burn bonds
  - `burnByHolder(address account, uint256 epochId, uint256 amount) external` -- public burn (V5.0, for BuybackEngine)
  - `getFaceValue(uint256 epochId) external view returns (uint256)` -- returns 1e18
  - `getHolderFaceValue(address holder, uint256 epochId) external view returns (uint256)` -- holder's face value
  - `isMatured(uint256 epochId) external view returns (bool)` -- maturity check
  - `getEpochInfo(uint256 epochId) external view returns (bool, uint256, uint256, bool)` -- epoch details
  - `uri(uint256 epochId) public pure override returns (string)` -- ERC-1155 URI
  - Inherited: `balanceOf()`, `balanceOfBatch()`, `setApprovalForAll()`, `isApprovedForAll()`, `safeTransferFrom()`, `safeBatchTransferFrom()`, `totalSupply()`, `exists()`
- **Events**: EpochCreated, BondsMinted, BondsBurned, BondVaultSet, BondsBurnedByHolder
- **Key State Variables**: `bondVault`, `maturityDate` (mapping), `epochExists` (mapping)

---

## 3. core/ (4 contracts)

### 3.1 AdaptiveFeeDistributor

- **File**: `src/core/AdaptiveFeeDistributor.sol`
- **Inheritance**: None (standalone)
- **Immutables**: `solvencyOracle`
- **Public/External Functions**:
  - `getDistribution() external view returns (uint256, uint256, uint256, uint256)` -- 4-bucket distribution
  - `isHealthy() external view returns (bool)` -- oracle health check
  - `lookupDistribution(uint8 sLevel, uint8 mLevel) external pure returns (uint256, uint256, uint256, uint256)` -- manual lookup
- **Events**: None
- **Key State Variables**: None

### 3.2 CoverRouterV2

- **File**: `src/core/CoverRouterV2.sol`
- **Inheritance**: Ownable, ReentrancyGuard
- **Immutables**: `usdc`
- **Public/External Functions**:
  - `purchasePolicy(bytes32 productId, uint256 coverageAmount, bytes32 asset) external nonReentrant whenNotPaused returns (uint256)` -- direct purchase
  - `purchasePolicyFor(bytes32 productId, uint256 coverageAmount, bytes32 asset, address buyer) external nonReentrant whenNotPaused returns (uint256)` -- relayer purchase
  - `submitTrigger(bytes32 productId, uint256 policyId, bytes calldata oracleProof) external nonReentrant` -- submit trigger proof
  - `configureProduct(...) external onlyOwner` -- configure product pricing
  - `setRelayer(address relayer, bool authorized) external onlyOwner` -- manage relayers
  - `setPaused(bool _paused) external onlyOwner` -- pause/unpause
  - `setPolicyManager(address _pm) external onlyOwner` -- update PM address
  - `setTwapBurner(address _burner) external onlyOwner` -- update TWAPBurner address
  - `quotePremium(bytes32 productId, uint256 coverageAmount) external view returns (uint256, uint256)` -- premium quote
  - `getProductConfig(bytes32 productId) external view returns (ProductConfig)` -- product config
  - `getProductCount() external view returns (uint256)` -- product count
- **Events**: PolicyPurchased, TriggerSubmitted, ProductConfigured, RelayerUpdated, Paused
- **Key State Variables**: `policyManager`, `twapBurner`, `paused`, `authorizedRelayers` (mapping), `products` (mapping), `productList` (array)

### 3.3 PolicyManagerV2

- **File**: `src/core/PolicyManagerV2.sol`
- **Inheritance**: Ownable
- **Immutables**: `bondVault`
- **Public/External Functions**:
  - `setRouter(address _router) external onlyOwner` -- set CoverRouter
  - `registerProduct(bytes32 _productId, address _shield) external onlyOwner` -- register shield
  - `deactivateProduct(bytes32 _productId) external onlyOwner` -- deactivate product
  - `recordPolicy(bytes32, address, uint256, uint256, uint32, bytes32) external onlyRouter returns (uint256)` -- record new policy
  - `triggerPayout(bytes32, uint256, bytes calldata) external onlyRouter` -- process trigger
  - `markExpired(bytes32 productId, uint256 policyId) external` -- mark policy expired (permissionless)
  - `getProductCount() external view returns (uint256)` -- product count
  - `getPolicy(bytes32, uint256) external view returns (PolicyRecord)` -- policy details
  - `getStats() external view returns (uint256, uint256, uint256, uint256, uint256)` -- protocol stats
- **Events**: ProductRegistered, ProductDeactivated, PolicyCreated, PolicyTriggered, PolicyExpired
- **Key State Variables**: `router`, `productShield` (mapping), `productActive` (mapping), `productIds` (array), `totalPolicies`, `activePolicies`, `totalTriggers`, `totalBondsIssuedUSD`, `policies` (nested mapping)

### 3.4 TWAPBurner

- **File**: `src/core/TWAPBurner.sol`
- **Inheritance**: Ownable, ReentrancyGuard
- **Constants**:
  - `FALLBACK_BURN_BPS = 8500`
  - `FALLBACK_BUYBACK_BPS = 800`
  - `FALLBACK_OPS_BPS = 200`
  - `FALLBACK_MAINTENANCE_BPS = 500`
- **Immutables**: `usdc`, `lumina`, `swapRouter`
- **Public/External Functions**:
  - `receivePremium(uint256 amount) external` -- receive premium USDC
  - `receiveMarketplaceFee(uint256 amount) external` -- receive marketplace fee USDC
  - `executeBurn() external nonReentrant` -- buy & burn (permissionless, cooldown)
  - `setPoolFee(uint24 _fee) external onlyOwner` -- set Uniswap fee tier
  - `setMaxSlippageBps(uint256 _bps) external onlyOwner` -- set max slippage
  - `setMinBurnAmount(uint256 _min) external onlyOwner` -- set min burn
  - `setMaxBurnAmount(uint256 _max) external onlyOwner` -- set max burn
  - `setBurnCooldown(uint256 _cooldown) external onlyOwner` -- set cooldown
  - `setAuthorizedSender(address sender, bool authorized) external onlyOwner` -- manage authorized senders
  - `setCapacityOracle(address _oracle) external onlyOwner` -- set oracle for slippage protection
  - `setFeeDistributor(address _feeDistributor) external onlyOwner` -- set fee distributor
  - `setReserves(address, address, address) external onlyOwner` -- set reserve addresses
  - `setMaintenanceReserve(address) external onlyOwner` -- set maintenance reserve
  - `setAdaptiveMode(bool enabled) external onlyOwner` -- toggle adaptive mode
  - `pendingUSDC() external view returns (uint256)` -- pending balance
  - `canBurn() external view returns (bool)` -- can execute burn
  - `getStats() external view returns (uint256, uint256, uint256, uint256, uint256, bool)` -- stats
  - `recoverToken(address token, uint256 amount) external onlyOwner` -- recover stuck tokens
- **Events**: PremiumReceived, MarketplaceFeeReceived, BurnExecuted, ConfigUpdated, MaintenanceReserveUpdated, AdaptiveDistributionExecuted, LegacyBurnExecuted
- **Key State Variables**: `capacityOracle`, `poolFee`, `maxSlippageBps`, `minBurnAmount`, `maxBurnAmount`, `burnCooldown`, `feeDistributor`, `adaptiveModeEnabled`, `buybackReserve`, `opsReserve`, `maintenanceReserve`, `lastBurnTimestamp`, `totalUSDCReceived`, `totalUSDCBurned`, `totalLUMINABurned`, `authorizedSenders` (mapping)

---

## 4. oracles/ (2 contracts)

### 4.1 CapacityOracle

- **File**: `src/oracles/CapacityOracle.sol`
- **Inheritance**: Ownable
- **Constants**:
  - `BOND_RESERVE = 82_000_000 * 1e18`
  - `SAFETY_FACTOR_BPS = 5000`
  - `AVG_PAYOUT_USD = 500`
  - `MATURITY_DAYS = 730`
  - `AVG_TRIGGER_RATE_BPS = 100`
- **Immutables**: `luminaToken`, `usdcToken`
- **Public/External Functions**:
  - `getLuminaPrice() external view returns (uint256)` -- IPriceOracle interface
  - `_getTwapPrice() external view returns (uint256)` -- TWAP calculation (public for try/catch)
  - `getTWAP(uint32 secondsAgo) external view returns (uint256)` -- custom-period TWAP
  - `maxPoliciesPerDay() external view returns (uint256)` -- estimated capacity
  - `setPool(address _pool) external onlyOwner` -- set Uniswap pool
  - `setTwapWindow(uint32 _window) external onlyOwner` -- set TWAP window
  - `setEmergencyPrice(uint256 _price) external onlyOwner` -- set fallback price
- **Events**: PoolUpdated, TwapWindowUpdated, EmergencyPriceSet
- **Key State Variables**: `pool`, `twapWindow`, `emergencyPrice`, `isToken0Lumina`

### 4.2 SolvencyOracle

- **File**: `src/oracles/SolvencyOracle.sol`
- **Inheritance**: AccessControl
- **Roles/Constants**:
  - `ADMIN_ROLE = keccak256("ADMIN_ROLE")`
  - `EVALUATION_INTERVAL = 1 days`
  - `COOLDOWN_BETWEEN_QUADRANT_CHANGES = 7 days`
  - `SOLVENCY_ULTRA_BPS = 20000`
  - `SOLVENCY_HEALTHY_BPS = 10000`
  - `SOLVENCY_STRESSED_BPS = 7000`
  - `MOMENTUM_RALLY_BPS = 11000`
  - `MOMENTUM_STABLE_LOW_BPS = 9500`
  - `MOMENTUM_DECLINE_BPS = 8500`
- **Immutables**: `bondVault`, `capacityOracle`, `lumina`
- **Public/External Functions**:
  - `evaluate() external returns (bool)` -- run evaluation, update quadrant
  - `setEmergencyPause(bool _paused) external onlyRole(ADMIN_ROLE)` -- toggle pause
  - `getSolvencyRatio() external view returns (uint256)` -- current ratio
  - `getCurrentQuadrant() external view returns (uint8, uint8)` -- current quadrant
  - `isHealthy() external view returns (bool)` -- health check
- **Events**: QuadrantChanged, EvaluationExecuted, EmergencyPauseToggled
- **Key State Variables**: `solvencyHistory[3]`, `momentumHistory[3]`, `historyIndex`, `currentSolvencyLevel`, `currentMomentumLevel`, `lastEvaluation`, `lastQuadrantChange`, `emergencyPaused`

---

## 5. treasury/ (2 contracts)

### 5.1 CEXLiquidityReserve

- **File**: `src/treasury/CEXLiquidityReserve.sol`
- **Inheritance**: AccessControl, ReentrancyGuard
- **Roles/Constants**:
  - `ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE")`
  - `TOTAL_AMOUNT = 14_000_000 * 1e18`
  - `IMMEDIATE_AMOUNT = 2_800_000 * 1e18`
  - `VESTING_AMOUNT = 8_400_000 * 1e18`
  - `STRATEGIC_AMOUNT = 2_800_000 * 1e18`
  - `VESTING_DURATION = 730 days`
  - `STRATEGIC_LOCK = 547 days`
  - `MONTHLY_CAP = 1_000_000 * 1e18`
- **Immutables**: `lumina`, `deploymentTimestamp`
- **Public/External Functions**:
  - `allocate(address, uint256, SubBucket, Purpose, string calldata) external onlyRole(ALLOCATOR_ROLE) nonReentrant` -- allocate tokens
  - `getAvailableInBucket(SubBucket) public view returns (uint256)` -- available per bucket
  - `getVestedAmount() public view returns (uint256)` -- vested linear amount
  - `getTotalAllocated() external view returns (uint256)` -- total allocated
  - `getAllocationHistoryLength() external view returns (uint256)` -- history count
  - `getCurrentMonth() public view returns (uint256)` -- current month number
  - `getMonthlyCapRemaining() external view returns (uint256)` -- remaining monthly cap
- **Events**: AllocationExecuted, MonthlyCapWarning
- **Key State Variables**: `allocatedFromImmediate`, `allocatedFromVesting`, `allocatedFromStrategic`, `monthlyAllocations` (mapping), `allocationHistory` (array)

### 5.2 MaintenanceReserve

- **File**: `src/treasury/MaintenanceReserve.sol`
- **Inheritance**: AccessControl, ReentrancyGuard
- **Roles/Constants**:
  - `SPENDER_ROLE = keccak256("SPENDER_ROLE")`
- **Immutables**: `usdc`
- **Public/External Functions**:
  - `spend(address, uint256, SpendCategory, string calldata) external onlyRole(SPENDER_ROLE) nonReentrant` -- spend USDC
  - `setMonthlyCap(uint256 _cap) external onlyRole(DEFAULT_ADMIN_ROLE)` -- set monthly cap
  - `spendCount() external view returns (uint256)` -- number of spend records
  - `balance() external view returns (uint256)` -- current USDC balance
  - `monthlyRemaining() external view returns (uint256)` -- remaining monthly budget
  - `recoverToken(address, uint256) external onlyRole(DEFAULT_ADMIN_ROLE)` -- recover non-USDC tokens
- **Events**: FundsSpent, MonthlyCapUpdated, TokenRecovered
- **Key State Variables**: `monthlyCap`, `currentMonthSpent`, `currentMonth`, `totalSpent`, `spendHistory` (array)

---

## 6. marketplace/ (2 contracts)

### 6.1 BuybackEngine

- **File**: `src/marketplace/BuybackEngine.sol`
- **Inheritance**: AccessControl, ReentrancyGuard, ERC1155Holder
- **Roles/Constants**:
  - `BUYBACK_OPERATOR_ROLE = keccak256("BUYBACK_OPERATOR_ROLE")`
  - `ACTIVATION_DELAY = 365 days`
  - `MIN_SOLVENCY_FOR_DOUBLE_BURN = 15000`
- **Immutables**: `claimBond`, `bondVault`, `solvencyOracle`, `capacityOracle`, `marketplace`, `usdc`, `deploymentTimestamp`
- **Public/External Functions**:
  - `setDailyBuyback(uint256, uint256, uint256) external onlyRole(BUYBACK_OPERATOR_ROLE)` -- configure daily buyback
  - `executeOffer(uint256 listingId) external nonReentrant` -- buy and double-burn
  - `isActivated() external view returns (bool)` -- activation status
  - `timeUntilActivation() external view returns (uint256)` -- time until active
  - `supportsInterface(bytes4) public view override returns (bool)` -- ERC165
- **Events**: DailyBuybackConfigured, OfferExecuted, DoubleBurnExecuted, CircuitBreakerTriggered
- **Key State Variables**: `dailyConfig` (DailyConfig struct)

### 6.2 LuminaBondMarketplace

- **File**: `src/marketplace/LuminaBondMarketplace.sol`
- **Inheritance**: AccessControl, ReentrancyGuard, ERC1155Holder
- **Roles/Constants**:
  - `FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE")`
  - `SELLER_FEE_BPS = 150`
  - `BUYER_FEE_BPS = 150`
  - `BPS_DENOMINATOR = 10000`
- **Immutables**: `claimBond`, `usdc`
- **Public/External Functions**:
  - `list(uint256 epochId, uint256 amount, uint256 priceUSDC) external nonReentrant returns (uint256)` -- list bonds for sale
  - `cancel(uint256 listingId) external nonReentrant` -- cancel listing
  - `executeBuy(uint256 listingId) external nonReentrant` -- buy bonds
  - `setTwapBurner(address _new) external onlyRole(FEE_MANAGER_ROLE)` -- update TWAPBurner
  - `getListing(uint256) external view returns (address, uint256, uint256, uint256, bool)` -- listing details
  - `calculateFees(uint256 priceUSDC) external pure returns (uint256, uint256, uint256)` -- fee calculation
  - `supportsInterface(bytes4) public view override returns (bool)` -- ERC165
- **Events**: Listed, Cancelled, Bought, TwapBurnerUpdated
- **Key State Variables**: `twapBurner`, `listings` (mapping), `nextListingId`

---

## 7. products/ (10 contracts)

### 7.1 BaseShield (abstract)

- **File**: `src/products/BaseShield.sol`
- **Inheritance**: IShield (abstract implementation)
- **Constants**: `CLAIM_GRACE_PERIOD = 24 hours`
- **Immutables**: `router`, `oracle`
- **Public/External Functions** (from IShield):
  - `createPolicy(CreatePolicyParams calldata) external onlyRouter returns (uint256)` -- create policy
  - `verifyAndCalculate(uint256, bytes calldata) external onlyRouter returns (PayoutResult)` -- verify trigger
  - `markPaidOut(uint256) external onlyRouter` -- mark paid out
  - `markExpired(uint256) external onlyRouter` -- mark expired
  - `getPolicyInfo(uint256) external view returns (PolicyInfo)` -- policy info
  - `getPolicyStatus(uint256) public view returns (PolicyStatus)` -- policy status
  - `totalPolicies() external view returns (uint256)` -- total count
  - `activePolicies() external view returns (uint256)` -- active count
  - `totalActiveCoverage() external view returns (uint256)` -- total coverage
- **Abstract functions** (overridden by each shield):
  - `productId()`, `riskType()`, `maxAllocationBps()`, `durationRange()`, `waitingPeriod()`
  - `_doCreatePolicy()`, `_doVerifyAndCalculate()`, `_calculateMaxPayout()`

### 7.2-7.10 Shield Products (9 contracts, grouped)

All 9 shields extend `BaseShield` with the **same pattern**: constructor(router, oracle), same set of overridden functions (productId, riskType, maxAllocationBps, durationRange, waitingPeriod, getBSSData/getDepegData/getRateShockData).

| # | Contract | File | PRODUCT_ID | Asset | Duration | Trigger Drop | Unique Getter |
|---|---|---|---|---|---|---|---|
| 7.2 | FlashBTCShield1h | `products/FlashBTCShield1h.sol` | `keccak256("FLASHBTC1H-001")` | BTC | 1h (3600s) | >5% | `getBSSData()` |
| 7.3 | FlashBTCShield4h | `products/FlashBTCShield4h.sol` | `keccak256("FLASHBTC4H-001")` | BTC | 4h (14400s) | >8% | `getBSSData()` |
| 7.4 | FlashBTCShield24h | `products/FlashBTCShield24h.sol` | `keccak256("FLASHBTC24-001")` | BTC | 24h (86400s) | >10% | `getBSSData()` |
| 7.5 | FlashBTCShield48h | `products/FlashBTCShield48h.sol` | `keccak256("FLASHBTC48-001")` | BTC | 48h (172800s) | >15% | `getBSSData()` |
| 7.6 | FlashETHShield1h | `products/FlashETHShield1h.sol` | `keccak256("FLASHETH1H-001")` | ETH | 1h (3600s) | >7% | `getBSSData()` |
| 7.7 | FlashETHShield24h | `products/FlashETHShield24h.sol` | `keccak256("FLASHETH24-001")` | ETH | 24h (86400s) | >12% | `getBSSData()` |
| 7.8 | FlashETHShield48h | `products/FlashETHShield48h.sol` | `keccak256("FLASHETH48-001")` | ETH | 48h (172800s) | >18% | `getBSSData()` |
| 7.9 | MicroDepegShield | `products/MicroDepegShield.sol` | `keccak256("MICRODEPEG-001")` | USDT | 7d (604800s) | <$0.995 (absolute) | `getDepegData()` |
| 7.10 | RateShockShield | `products/RateShockShield.sol` | `keccak256("RATESHOCK-001")` | USDC | 7d (604800s) | >10% APY (on-chain Aave) | `getRateShockData()`, `currentBorrowRate()` |

**Common constants across all 9 shields:**
- `RISK_TYPE = keccak256("VOLATILE")` (Flash shields) or `keccak256("STABLE")` (MicroDepeg) or `keccak256("RATE")` (RateShock)
- `MAX_ALLOCATION_BPS = 3000` (30%)
- `WAITING_PERIOD = 0`
- `DEDUCTIBLE_BPS = 2000` (20% deductible, 80% payout)
- `MAX_PROOF_AGE = 900` (15 min) -- except RateShockShield (no oracle proof, reads Aave on-chain)

**RateShockShield unique features:**
- Additional immutables: `aavePool`, `usdc`
- Additional view function: `currentBorrowRate() external view returns (uint256)`
- No oracle proof needed -- reads Aave V3 on-chain data directly

---

## 8. interfaces/ (3 interfaces)

### 8.1 IOracle

- **File**: `src/interfaces/IOracle.sol`
- **Functions**: `getLatestPrice(bytes32)`, `getSequencerDowntime(uint256)`, `verifySignature(bytes32, bytes)`, `oracleKey()`

### 8.2 IOracleV2

- **File**: `src/interfaces/IOracleV2.sol`
- **Inheritance**: IOracle
- **Functions**: `verifyPriceProofEIP712(int256, bytes32, uint256, bytes)`, `verifyExploitGovProofEIP712(int256, int256, bytes32, uint256, bytes)`, `priceProofDigest(int256, bytes32, uint256)`, `exploitReceiptProofDigest(bool, bool, bytes32, uint256)`, `DOMAIN_SEPARATOR()`

### 8.3 IShield

- **File**: `src/interfaces/IShield.sol`
- **Enums**: PolicyStatus (NONEXISTENT, WAITING, ACTIVE, EXPIRED, SETTLEMENT, PAID_OUT, CANCELLED)
- **Structs**: PolicyInfo, CreatePolicyParams, PayoutResult
- **Functions**: productId, riskType, maxAllocationBps, durationRange, waitingPeriod, createPolicy, verifyAndCalculate, markPaidOut, markExpired, getPolicyInfo, getPolicyStatus, totalPolicies, activePolicies, totalActiveCoverage

---

## Summary Statistics

| Category | Contract Count | Interface Count |
|---|---|---|
| token/ | 3 | 0 |
| bonds/ | 2 | 0 |
| core/ | 4 | 0 |
| oracles/ | 2 | 0 |
| treasury/ | 2 | 0 |
| marketplace/ | 2 | 0 |
| products/ | 10 (1 abstract + 9 concrete) | 0 |
| interfaces/ | 0 | 3 |
| **Total** | **25 contracts** | **3 interfaces** |
| **Grand Total** | **28 .sol files** | |
