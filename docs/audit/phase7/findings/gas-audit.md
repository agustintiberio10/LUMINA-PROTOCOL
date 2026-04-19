# LUMINA V5.0 -- Gas Audit Report

**Phase:** 7 (Security Audit)
**Date:** 2026-04-19
**Source:** `test/stress/GasOptimizationStress.t.sol` + manual analysis
**Network Target:** Base L2 (30M block gas limit)

---

## 1. Critical Function Gas Measurements

Gas measurements from `GasOptimizationStress.t.sol` using Foundry's `gasleft()` instrumentation:

| Function | Measured Gas | Target | Status | Notes |
|----------|-------------|--------|--------|-------|
| `BondVault.issueBond()` | ~175,000 | < 300,000 | PASS | Includes oracle read + ClaimBond mint + epoch creation |
| `BondVault.redeemBond()` | ~179,000 | < 500,000 | PASS | Includes oracle read + ClaimBond burn + LUMINA transfer |
| `Marketplace.list()` | ~140,000 | < 200,000 | PASS | Includes ERC-1155 transfer to escrow |
| `Marketplace.executeBuy()` | ~185,000 | < 300,000 | PASS | Includes USDC transfers (3) + ERC-1155 transfer |

### Gas Breakdown: issueBond (~175K)

| Operation | Estimated Gas | Percentage |
|-----------|--------------|------------|
| Access control check (`msg.sender == policyManager`) | ~2,600 | 1.5% |
| `ReentrancyGuard` status check + set | ~5,200 | 3.0% |
| Oracle price read (`priceOracle.getLuminaPrice()`) | ~26,000 | 14.9% |
| `lumina.balanceOf(address(this))` | ~2,600 | 1.5% |
| Capacity arithmetic (3 multiplications, 1 division) | ~200 | 0.1% |
| `totalCommittedUSD` SSTORE (warm) | ~5,000 | 2.9% |
| `_timestampToEpoch()` computation | ~300 | 0.2% |
| `claimBond.mint()` external call + epoch creation | ~120,000 | 68.6% |
| Event emission (`BondIssued`) | ~3,500 | 2.0% |
| `ReentrancyGuard` reset | ~2,900 | 1.7% |

The dominant cost is the `ClaimBond.mint()` external call, which includes ERC-1155 minting and potential epoch initialization (first mint for a given epoch creates the epoch record).

### Gas Breakdown: redeemBond (~179K)

| Operation | Estimated Gas | Percentage |
|-----------|--------------|------------|
| `ReentrancyGuard` check + set | ~5,200 | 2.9% |
| `claimBond.isMatured()` external call | ~8,000 | 4.5% |
| `claimBond.balanceOf()` external call | ~5,000 | 2.8% |
| `_getSafePrice()` with try/catch | ~28,000 | 15.6% |
| Payout arithmetic | ~300 | 0.2% |
| `totalCommittedUSD` SSTORE (warm) | ~5,000 | 2.8% |
| `claimBond.burn()` external call | ~45,000 | 25.1% |
| `lumina.transfer()` | ~52,000 | 29.1% |
| Event emission (`BondRedeemed`) | ~5,000 | 2.8% |
| `ReentrancyGuard` reset | ~2,900 | 1.6% |

---

## 2. Unbounded Array Analysis

### 2.1 spendHistory in MaintenanceReserve

**Location:** `MaintenanceReserve.sol`, line 52: `SpendRecord[] public spendHistory`

**Growth Pattern:** One entry per `spend()` call. Each `SpendRecord` contains:
- `address recipient` (20 bytes)
- `uint256 amount` (32 bytes)
- `SpendCategory category` (1 byte, stored as uint8)
- `string memo` (variable length, max 200 chars enforced upstream)
- `uint256 timestamp` (32 bytes)

**Access Control:** Only `SPENDER_ROLE` can call `spend()`, which is restricted to the multisig admin.

**Gas per append:** ~45,000-65,000 gas (new storage slot allocation + string storage).

**Max iterations before 30M limit:** The array is append-only. No function iterates over `spendHistory`. The `spendCount()` view function returns `spendHistory.length` (O(1)). Individual records are accessed via `spendHistory[index]` (O(1)).

**DoS Risk: LOW**

Justification:
- No function iterates over the array, so array size does not affect transaction gas.
- Only admin-controlled `SPENDER_ROLE` can append entries.
- Even at 1 entry per day for 10 years, the array would have ~3,650 entries -- negligible storage cost.
- No external user can trigger growth.

### 2.2 allocationHistory in CEXLiquidityReserve

**Location:** `CEXLiquidityReserve.sol`, line 46: `Allocation[] public allocationHistory`

**Growth Pattern:** One entry per `allocate()` call. Each `Allocation` contains:
- `address recipient` (20 bytes)
- `uint256 amount` (32 bytes)
- `SubBucket subBucket` (1 byte)
- `Purpose purpose` (1 byte)
- `string description` (variable, max 200 chars enforced by `require(bytes(description).length <= 200)`)
- `uint256 timestamp` (32 bytes)
- `address allocator` (20 bytes)

**Access Control:** Only `ALLOCATOR_ROLE` (multisig admin) can call `allocate()`.

**Gas per append:** ~50,000-70,000 gas (new storage slots + string storage).

**Max iterations before 30M limit:** Same as spendHistory -- no function iterates over the array. `getAllocationHistoryLength()` is O(1). Individual access via `allocationHistory[index]` is O(1).

**DoS Risk: LOW**

Justification:
- No iteration over the array in any function.
- Admin-only access; monthly cap of 1M LUMINA further limits frequency.
- Total LUMINA available is 14M, so maximum possible allocations are bounded by token supply even if done in minimum increments.
- The `monthlyAllocations` mapping is also unbounded in theory but keyed by month index, so grows at most 1 entry per 30 days.

### 2.3 productIds in PolicyManagerV2

**Location:** `PolicyManagerV2.sol`, line 63: `bytes32[] public productIds`

**Growth Pattern:** One entry per `registerProduct()` call.

**Access Control:** `onlyOwner` (Gnosis Safe / TimelockController).

**Bounded by design:** The system has 9 shield products:
- FlashBTCShield1h, FlashBTCShield4h, FlashBTCShield24h, FlashBTCShield48h
- FlashETHShield1h, FlashETHShield24h, FlashETHShield48h
- MicroDepegShield
- RateShockShield

Even with future product additions, the realistic upper bound is ~20-50 products. At 32 bytes per entry, this array occupies at most 2 storage slots at the current 9-product count.

**DoS Risk: LOW**

Justification:
- Bounded to number of distinct shield contracts (currently 9).
- No function iterates over `productIds` in any write path.
- `getProductCount()` is O(1).
- Even at 100 products, total storage would be ~3,200 bytes (trivial).

### 2.4 productList in CoverRouterV2

**Location:** `CoverRouterV2.sol`, line 57: `bytes32[] public productList`

**Growth Pattern:** One entry per `configureProduct()` call (only if product is new).

**Access Control:** `onlyOwner`.

**DoS Risk: LOW**

Same reasoning as productIds -- bounded by realistic product count, no iteration in write paths.

---

## 3. Loop Analysis

### 3.1 _update() in ClaimBond (ERC1155Supply)

**Location:** Inherited from OpenZeppelin `ERC1155Supply._update()`.

**Loop:** Iterates over `ids` and `values` arrays in batch operations.

**In LUMINA context:** `mint()` and `burn()` in `ClaimBond` operate on single IDs (not batch). The `ids` array always has length 1. No batch operations are exposed.

**Max iterations before 30M:** For batch transfers (user-initiated via ERC-1155 `safeBatchTransferFrom`), approximately 150-200 IDs per batch before hitting the gas limit. However, this is a standard ERC-1155 batch transfer that users control for their own tokens.

**DoS Risk: LOW** -- Single-ID operations only in protocol functions.

### 3.2 _getSqrtPriceFromTick() in CapacityOracle

**Location:** `CapacityOracle.sol`, lines 206-237.

**Loop:** Not a loop -- sequential bitwise checks (19 conditional multiplications). This is the standard Uniswap V3 TickMath implementation.

**Gas:** Fixed ~3,000-5,000 gas regardless of input. Deterministic execution path.

**DoS Risk: LOW** -- Constant-time computation.

### 3.3 observe() in Uniswap V3 Pool (external)

**Location:** Called by `CapacityOracle._getTwapPrice()` and `CapacityOracle.getTWAP()`.

**Loop:** The Uniswap V3 pool's `observe()` function iterates over its observation ring buffer. For a 2-element `secondsAgos` array, this is effectively O(1) per element (binary search over observation array).

**DoS Risk: LOW** -- Fixed 2-element query, controlled by the protocol.

---

## 4. Storage Access Patterns

### Hot Path Functions (user-facing, frequent calls)

| Function | SLOAD Count | SSTORE Count | Cold/Warm |
|----------|------------|-------------|-----------|
| `issueBond()` | 4 | 2 | Mostly warm after first call |
| `redeemBond()` | 5 | 2 | Warm (vault state accessed regularly) |
| `executeBuy()` | 4 | 3 | Mixed (listing may be cold) |
| `list()` | 2 | 2 | Cold (new listing slot) |

### Cold Path Functions (admin-only, infrequent)

| Function | SLOAD Count | SSTORE Count | Notes |
|----------|------------|-------------|-------|
| `allocate()` | 5 | 4 | Acceptable for admin operation |
| `spend()` | 4 | 3 | Acceptable for admin operation |
| `evaluate()` | 8 | 5 | Daily cadence, gas cost irrelevant |

---

## 5. Gas Optimization Opportunities (Informational)

These are noted for completeness but are NOT recommended changes pre-audit:

1. **Pack structs in PolicyManagerV2.PolicyRecord:** `triggered` and `expired` bools could share a slot with `premiumPaid` if reordered. Saves ~2,100 gas per policy creation. Risk: Code clarity reduction.

2. **Use `unchecked` for counter increments:** `_policyCounter++` in BaseShield already uses `unchecked` (line 121-123). Other counters like `totalPolicies++` in PolicyManagerV2 could also use unchecked. Saves ~50 gas per call.

3. **Cache storage reads in redeemBond():** `totalCommittedUSD` is read and written. Currently efficient (single SLOAD + SSTORE).

None of these optimizations are critical. Current gas usage is well within acceptable bounds for all functions.

---

## 6. Summary

| Category | Risk Level | Justification |
|----------|-----------|---------------|
| Core function gas (issueBond, redeemBond) | LOW | Both well under targets (175K/300K, 179K/500K) |
| Unbounded arrays (spendHistory) | LOW | Admin-only, no iteration |
| Unbounded arrays (allocationHistory) | LOW | Admin-only, no iteration |
| Bounded arrays (productIds) | LOW | Max ~9-50 entries |
| Loop-based DoS | LOW | No user-controllable loops in protocol functions |
| Storage bloat | LOW | Growth rate bounded by admin actions and token supply |

**Overall Gas DoS Risk: LOW**

No function in the protocol is susceptible to gas-based denial of service attacks. All unbounded arrays are admin-controlled, all loops operate on fixed-size or single-element inputs, and critical path gas usage is well within block gas limits.
