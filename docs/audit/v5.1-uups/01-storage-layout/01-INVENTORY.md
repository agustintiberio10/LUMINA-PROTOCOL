# V5.1 UUPS Storage Layout Inventory

**Audit:** V5.1 #1 — Storage Layout Deep Audit
**Branch:** `audit/v5.1-01-storage-layout-deep`
**Date:** 2026-04-22
**Scope:** 24 UUPS upgradeable contracts + 1 abstract parent (`BaseShield`) + 1 immutable (`FounderVesting`, excluded)

---

## Notes on OpenZeppelin 5.x Namespaced Storage

All OZ upgradeable parents in this codebase (`OwnableUpgradeable`, `AccessControlUpgradeable`,
`ReentrancyGuardUpgradeable`, `ERC20Upgradeable`, `ERC1155Upgradeable`, `Initializable`,
`UUPSUpgradeable`, `ERC1155SupplyUpgradeable`, `ERC1155HolderUpgradeable`) use **ERC-7201
namespaced storage**. Consequently, those parents do **not** consume sequential storage
slots (0, 1, 2, …). They each store their state at a fixed keccak-derived namespace slot.

This means the child contract's first declared state variable lives at **slot 0** of the
proxy storage (after deployment), and sequential slots follow thereafter.

Exceptions: `Initializable` and `UUPSUpgradeable` use a namespace too, so they occupy
exactly **zero** sequential slots.

---

## Per-Contract Inventory

### 1. LuminaTokenV2 — `src/token/LuminaTokenV2.sol`
- **Parents (C3 order):** `Initializable`, `UUPSUpgradeable`, `ERC20Upgradeable`,
  `ERC20BurnableUpgradeable`, `AccessControlUpgradeable`
- **Auth:** `AccessControlUpgradeable`
- **Own state vars (declaration order):**
  | Slot | Type | Name | Visibility |
  |------|------|------|------------|
  | 0 | `uint256` | `totalBurned` | public |
- **__gap:** `uint256[50] private __gap` (line 97) — slots 1..50
- **Used slots:** 1 | **Free gap:** 50

### 2. BondVault — `src/bonds/BondVault.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `ReentrancyGuardUpgradeable`, `AccessControlUpgradeable`
- **Auth:** `AccessControlUpgradeable`
- **Own state vars:**
  | Slot | Type | Name | Visibility |
  |------|------|------|------------|
  | 0 | `IERC20` | `lumina` | public |
  | 1 | `IClaimBond` | `claimBond` | public |
  | 2 | `IPriceOracle` | `priceOracle` | public |
  | 3 | `address` | `policyManager` | public |
  | 4 | `address` | `_deployer` | private |
  | 4 (packed) | `bool` | `_policyManagerSet` | private |
  | 5 | `uint256` | `totalCommittedUSD` | public |
  | 6 | `uint256` | `totalReservedUSD` | public |
  | 7 | `mapping(address=>bool)` | `authorizedCallers` | public |
- **__gap:** `uint256[50] private __gap` (line 312)
- **Used slots:** 8 | **Free gap:** 50

### 3. ClaimBond — `src/bonds/ClaimBond.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `ERC1155Upgradeable`, `ERC1155SupplyUpgradeable`, `OwnableUpgradeable`
- **Auth:** `OwnableUpgradeable`
- **Own state vars:**
  | Slot | Type | Name | Visibility |
  |------|------|------|------------|
  | 0 | `address` | `bondVault` | public |
  | 0 (packed) | `bool` | `_bondVaultSet` | private |
  | 1 | `mapping(uint256=>uint256)` | `maturityDate` | public |
  | 2 | `mapping(uint256=>bool)` | `epochExists` | public |
- **__gap:** `uint256[50] private __gap` (line 162)
- **Used slots:** 3 | **Free gap:** 50

### 4. PolicyManagerV2 — `src/core/PolicyManagerV2.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `OwnableUpgradeable`
- **Auth:** `OwnableUpgradeable`
- **Own state vars:**
  | Slot | Type | Name | Visibility |
  |------|------|------|------------|
  | 0 | `IBondVault` | `bondVault` | public |
  | 1 | `address` | `router` | public |
  | 2 | `mapping(bytes32=>address)` | `productShield` | public |
  | 3 | `mapping(bytes32=>bool)` | `productActive` | public |
  | 4 | `bytes32[]` | `productIds` | public |
  | 5 | `uint256` | `totalPolicies` | public |
  | 6 | `uint256` | `activePolicies` | public |
  | 7 | `uint256` | `totalTriggers` | public |
  | 8 | `uint256` | `totalBondsIssuedUSD` | public |
  | 9 | `mapping(bytes32=>mapping(uint256=>PolicyRecord))` | `policies` | public |
  | 10 | `mapping(bytes32=>mapping(uint256=>uint256))` | `policyReservedUSD` | public |
- **__gap:** `uint256[50] private __gap` (line 383)
- **Used slots:** 11 | **Free gap:** 50

### 5. CoverRouterV2 — `src/core/CoverRouterV2.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `OwnableUpgradeable`, `ReentrancyGuardUpgradeable`
- **Auth:** `OwnableUpgradeable`
- **Own state vars:**
  | Slot | Type | Name |
  |------|------|------|
  | 0 | `IERC20` | `usdc` |
  | 1 | `IPolicyManagerV2` | `policyManager` |
  | 2 | `ITWAPBurner` | `twapBurner` |
  | 3 | `IPriceOracleForRouter` | `capacityOracle` |
  | 3 (packed) | `bool` | `paused` |
  | 4 | `mapping(address=>bool)` | `authorizedRelayers` |
  | 5 | `mapping(bytes32=>ProductConfig)` | `products` |
  | 6 | `bytes32[]` | `productList` |
- **__gap:** `uint256[50] private __gap` (line 276)
- **Used slots:** 7 | **Free gap:** 50

### 6. TWAPBurner — `src/core/TWAPBurner.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `OwnableUpgradeable`, `ReentrancyGuardUpgradeable`
- **Auth:** `OwnableUpgradeable`
- **Own state vars (declaration order):** `usdc`, `lumina`, `dexRouters`, `capacityOracle`, `poolFee`, `maxSlippageBps`, `minBurnAmount`, `maxBurnAmount`, `burnCooldown`, `feeDistributor`, `adaptiveModeEnabled`, `buybackReserve`, `opsReserve`, `maintenanceReserve`, `lastBurnTimestamp`, `totalUSDCReceived`, `totalUSDCBurned`, `totalLUMINABurned`, `authorizedSenders`
- **__gap:** `uint256[50] private __gap` (line 386)
- **Used slots:** ~18 | **Free gap:** 50

### 7. AdaptiveFeeDistributor — `src/core/AdaptiveFeeDistributor.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `OwnableUpgradeable`
- **Auth:** `OwnableUpgradeable`
- **Own state vars:**
  | Slot | Type | Name |
  |------|------|------|
  | 0 | `ISolvencyOracleForDist` | `solvencyOracle` |
- **__gap:** `uint256[50] private __gap` (line 84)
- **Used slots:** 1 | **Free gap:** 50

### 8. BuybackEngine — `src/marketplace/BuybackEngine.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `AccessControlUpgradeable`, `ReentrancyGuardUpgradeable`, `ERC1155HolderUpgradeable`
- **Auth:** `AccessControlUpgradeable`
- **Own state vars:** `claimBond`, `bondVault`, `solvencyOracle`, `capacityOracle`, `marketplace`, `usdc`, `dailyConfig (struct)`
- **__gap:** `uint256[50] private __gap` (line 183)
- **Used slots:** ~7 | **Free gap:** 50

### 9. LuminaBondMarketplace — `src/marketplace/LuminaBondMarketplace.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `AccessControlUpgradeable`, `ReentrancyGuardUpgradeable`, `ERC1155HolderUpgradeable`
- **Auth:** `AccessControlUpgradeable`
- **Own state vars:** `claimBond`, `usdc`, `twapBurner`, `listings (mapping)`, `nextListingId`
- **__gap:** `uint256[50] private __gap` (line 185)
- **Used slots:** 5 | **Free gap:** 50

### 10. ShieldKeeper — `src/automation/ShieldKeeper.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `AutomationCompatibleInterface`, `OwnableUpgradeable`
- **Auth:** `OwnableUpgradeable`
- **Own state vars:**
  | Slot | Type | Name |
  |------|------|------|
  | 0 | `IPolicyManagerKeeper` | `policyManager` |
  | 0 (packed) | `bool` | `paused` |
- **__gap:** `uint256[50] private __gap` (line 130)
- **Used slots:** 1 | **Free gap:** 50

### 11. BaseShield (abstract parent) — `src/products/BaseShield.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `OwnableUpgradeable`, `IShield`
- **Auth:** `OwnableUpgradeable`
- **Own state vars (inherited by every Shield):**
  | Slot | Type | Name |
  |------|------|------|
  | 0 | `address` | `router` |
  | 1 | `address` | `oracle` |
  | 2 | `mapping(uint256=>CorePolicy)` | `_policies` |
  | 3 | `uint256` | `_policyCounter` |
  | 4 | `uint256` | `_activePolicies` |
  | 5 | `uint256` | `_totalActiveCoverage` |
- **__gap:** `uint256[50] private __gap` (line 386) — slots 6..55
- **Used slots (own):** 6 | **Free gap:** 50

### 12–14. FlashBTCShield 1h / 4h / 24h / 48h — `src/products/FlashBTCShield{1h,4h,24h,48h}.sol`
- **Parents:** `BaseShield`
- **BaseShield state (inherited):** slots 0..5 (router, oracle, _policies, _policyCounter, _activePolicies, _totalActiveCoverage)
- **BaseShield __gap:** slots 6..55
- **Own child vars (after parent gap):**
  | Slot | Type | Name |
  |------|------|------|
  | 56 | `mapping(uint256=>BSSData)` | `_bssData` |
- **Child __gap:** `uint256[50] private __gap_shield` — slots 57..106
- **Used slots (total including parent):** 7 | **Free gap (child):** 50

### 15–17. FlashETHShield 1h / 24h / 48h — `src/products/FlashETHShield{1h,24h,48h}.sol`
- Same layout as FlashBTCShield variants.

### 18. MicroDepegShield — `src/products/MicroDepegShield.sol`
- **Parents:** `BaseShield`
- **Own child vars:**
  | Slot | Type | Name |
  |------|------|------|
  | 56 | `mapping(uint256=>DepegData)` | `_depegData` |
- **Child __gap:** `uint256[50] private __gap_shield` (line 149)

### 19. RateShockShield — `src/products/RateShockShield.sol`
- **Parents:** `BaseShield`
- **Own child vars:**
  | Slot | Type | Name |
  |------|------|------|
  | 56 | `IAaveV3Pool` | `aavePool` |
  | 57 | `address` | `usdc` |
  | 58 | `mapping(uint256=>RateShockData)` | `_rateData` |
- **Child __gap:** `uint256[50] private __gap_shield` (line 178)

### 20. CapacityOracle — `src/oracles/CapacityOracle.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `OwnableUpgradeable`
- **Auth:** `OwnableUpgradeable`
- **Own state vars:**
  | Slot | Type | Name |
  |------|------|------|
  | 0 | `address` | `pool` |
  | 1 | `address` | `luminaToken` |
  | 2 | `address` | `usdcToken` |
  | 2 (packed) | `uint32` | `twapWindow` |
  | 3 | `uint256` | `emergencyPrice` |
  | 4 | `bool` | `isToken0Lumina` |
- **__gap:** `uint256[50] private __gap` (line 225)
- **Used slots:** 5 | **Free gap:** 50

### 21. SolvencyOracle — `src/oracles/SolvencyOracle.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `AccessControlUpgradeable`
- **Auth:** `AccessControlUpgradeable`
- **Own state vars:** `bondVault`, `capacityOracle`, `lumina`, `solvencyHistory[3]`, `momentumHistory[3]`, `historyIndex`, `currentSolvencyLevel`, `currentMomentumLevel`, `lastEvaluation`, `lastQuadrantChange`, `emergencyPaused`
- **__gap:** `uint256[50] private __gap` (line 148)
- **Used slots:** ~12 | **Free gap:** 50

### 22. CEXLiquidityReserve — `src/treasury/CEXLiquidityReserve.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `AccessControlUpgradeable`, `ReentrancyGuardUpgradeable`
- **Auth:** `AccessControlUpgradeable`
- **Own state vars:** `lumina`, `deploymentTimestamp`, `allocatedFromImmediate`, `allocatedFromVesting`, `allocatedFromStrategic`, `monthlyAllocations (mapping)`, `allocationHistory (array)`
- **__gap:** `uint256[50] private __gap` (line 161)
- **Used slots:** 7 | **Free gap:** 50

### 23. MaintenanceReserve — `src/treasury/MaintenanceReserve.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `AccessControlUpgradeable`, `ReentrancyGuardUpgradeable`
- **Auth:** `AccessControlUpgradeable`
- **Own state vars:** `usdc`, `monthlyCap`, `currentMonthSpent`, `currentMonth`, `totalSpent`, `spendHistory (array)`
- **__gap:** `uint256[50] private __gap` (line 138)
- **Used slots:** 6 | **Free gap:** 50

### 24. TreasuryVesting — `src/token/TreasuryVesting.sol`
- **Parents:** `Initializable`, `UUPSUpgradeable`, `OwnableUpgradeable`
- **Auth:** `OwnableUpgradeable`
- **Own state vars:**
  | Slot | Type | Name |
  |------|------|------|
  | 0 | `IERC20` | `luminaToken` |
  | 1 | `uint256` | `deployedAt` |
  | 2 | `uint256` | `totalReleased` |
  | 3 | `uint256` | `lastReleaseMonth` |
- **__gap:** `uint256[50] private __gap` (line 90)
- **Used slots:** 4 | **Free gap:** 50

---

## Summary Table

| # | Contract | Auth | Used slots (own) | __gap size | Shape |
|---|----------|------|------------------|-----------|-------|
| 1 | LuminaTokenV2 | AccessControl | 1 | 50 | Trivial |
| 2 | BondVault | AccessControl | 8 | 50 | Small |
| 3 | ClaimBond | Ownable | 3 | 50 | Small |
| 4 | PolicyManagerV2 | Ownable | 11 | 50 | Medium |
| 5 | CoverRouterV2 | Ownable | 7 | 50 | Small |
| 6 | TWAPBurner | Ownable | 18 | 50 | Medium |
| 7 | AdaptiveFeeDistributor | Ownable | 1 | 50 | Trivial |
| 8 | BuybackEngine | AccessControl | 7 | 50 | Small |
| 9 | LuminaBondMarketplace | AccessControl | 5 | 50 | Small |
| 10 | ShieldKeeper | Ownable | 1 | 50 | Trivial |
| 11 | BaseShield (abstract) | Ownable | 6 | 50 | Parent |
| 12 | FlashBTCShield1h | Ownable (inh) | 6 + 1 | 50 (child) | Shield |
| 13 | FlashBTCShield4h | Ownable (inh) | 6 + 1 | 50 (child) | Shield |
| 14 | FlashBTCShield24h | Ownable (inh) | 6 + 1 | 50 (child) | Shield |
| 15 | FlashBTCShield48h | Ownable (inh) | 6 + 1 | 50 (child) | Shield |
| 16 | FlashETHShield1h | Ownable (inh) | 6 + 1 | 50 (child) | Shield |
| 17 | FlashETHShield24h | Ownable (inh) | 6 + 1 | 50 (child) | Shield |
| 18 | FlashETHShield48h | Ownable (inh) | 6 + 1 | 50 (child) | Shield |
| 19 | MicroDepegShield | Ownable (inh) | 6 + 1 | 50 (child) | Shield |
| 20 | RateShockShield | Ownable (inh) | 6 + 3 | 50 (child) | Shield |
| 21 | CapacityOracle | Ownable | 5 | 50 | Small |
| 22 | SolvencyOracle | AccessControl | 12 | 50 | Medium |
| 23 | CEXLiquidityReserve | AccessControl | 7 | 50 | Small |
| 24 | MaintenanceReserve | AccessControl | 6 | 50 | Small |
| 25 | TreasuryVesting | Ownable | 4 | 50 | Small |

**Average slots used (non-shield):** ~7 | **Largest consumer:** TWAPBurner (~18).
**Free growth headroom:** every contract has at least 32 unused gap slots even if it doubled in size.
