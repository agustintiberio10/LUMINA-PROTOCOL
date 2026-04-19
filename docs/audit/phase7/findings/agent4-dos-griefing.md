# Agent 4: DoS & Griefing Expert -- Red Team Analysis

**Protocol:** LUMINA Protocol V5.0
**Date:** 2026-04-19
**Auditor Class:** DoS & Griefing Expert (Agent 4)
**Scope:** All contracts in `src/` -- unbounded arrays, gas griefing, dust attacks, front-running griefing, and block gas limit vectors.

---

## Table of Contents

1. [D-01: Unbounded Arrays -- spendHistory in MaintenanceReserve](#d-01-unbounded-arrays----spendhistory-in-maintenancereserve)
2. [D-02: Unbounded Arrays -- allocationHistory in CEXLiquidityReserve](#d-02-unbounded-arrays----allocationhistory-in-cexliquidityreserve)
3. [D-03: Unbounded Arrays -- productList and productIds](#d-03-unbounded-arrays----productlist-and-productids)
4. [D-04: Gas Griefing via External State Reverts](#d-04-gas-griefing-via-external-state-reverts)
5. [D-05: Zero/Dust Amount Attacks](#d-05-zerodust-amount-attacks)
6. [D-06: Front-Running Griefing on Marketplace Listings](#d-06-front-running-griefing-on-marketplace-listings)
7. [D-07: Block Gas Limit Exhaustion](#d-07-block-gas-limit-exhaustion)

---

## D-01: Unbounded Arrays -- spendHistory in MaintenanceReserve

### Description

`MaintenanceReserve.spendHistory` is a `SpendRecord[]` that grows with every `spend()` call. Each `SpendRecord` contains:

```solidity
struct SpendRecord {
    address recipient;    // 20 bytes (1 slot)
    uint256 amount;       // 32 bytes (1 slot)
    SpendCategory category; // 1 byte (packed with recipient above)
    string memo;          // dynamic (1 slot for length + N slots for data)
    uint256 timestamp;    // 32 bytes (1 slot)
}
```

**Storage cost per record:** ~3--5 storage slots (depending on memo length). At 20,000 gas per new SSTORE, each record costs ~60,000--100,000 gas.

**Is this a DoS vector?**

The `spend()` function is protected by `SPENDER_ROLE` (AccessControl). Only authorized spenders can add records. An external attacker **cannot** grow this array. The DoS vector is purely self-inflicted -- if the multisig makes thousands of spend transactions, the array grows but:

- `spend()` only appends (O(1)), it never iterates.
- `spendCount()` returns `spendHistory.length` (O(1)).
- Individual records are accessed via `spendHistory[index]` (O(1)).

**No on-chain function iterates over `spendHistory`.** The array is append-only and index-accessible. It would only cause issues if a view function iterated over it, which does not exist.

### Gas Per Iteration

N/A -- no function iterates over the array.

### Max Items Before DoS

**Unlimited for on-chain operations.** Off-chain indexers reading the full array via RPC may experience timeouts after ~100K records, but this is an infrastructure concern, not a contract DoS.

### Severity

**LOW** -- Append-only array with access-controlled writes. No iteration. Off-chain tooling may need pagination for very large histories.

### Recommendation

Add a paginated view function for off-chain consumption:

```solidity
function getSpendHistory(uint256 offset, uint256 limit) external view returns (SpendRecord[] memory)
```

---

## D-02: Unbounded Arrays -- allocationHistory in CEXLiquidityReserve

### Description

`CEXLiquidityReserve.allocationHistory` is an `Allocation[]` that grows with each `allocate()` call. Each `Allocation` struct:

```solidity
struct Allocation {
    address recipient;     // 1 slot
    uint256 amount;        // 1 slot
    SubBucket subBucket;   // packed with recipient
    Purpose purpose;       // packed with recipient
    string description;    // dynamic (max 200 chars = ~7 slots)
    uint256 timestamp;     // 1 slot
    address allocator;     // 1 slot
}
```

**Storage cost per record:** ~4--11 slots depending on description length. ~80,000--220,000 gas per append.

**Access control:** `ALLOCATOR_ROLE` required. External attackers cannot grow this array.

**Growth constraints:**
- `MONTHLY_CAP = 1,000,000 LUMINA` per month.
- `TOTAL_AMOUNT = 14,000,000 LUMINA` total.
- Even with minimum-sized allocations (1 wei each), the monthly cap limits growth.
- Maximum theoretical allocations: 14,000,000 * 1e18 if allocating 1 wei per tx (infeasible -- gas cost exceeds value).
- Realistic maximum: ~100--200 allocations over the protocol's lifetime.

**Iteration:** No on-chain function iterates over this array. `getAllocationHistoryLength()` is O(1). Individual records are accessed by index.

### Gas Per Iteration

N/A -- no function iterates.

### Max Items Before DoS

**Effectively unlimited for on-chain operations.** Practically capped at ~200 by the total supply constraint.

### Severity

**NONE** -- Access-controlled, total-supply-bounded, no iteration. Not exploitable.

---

## D-03: Unbounded Arrays -- productList and productIds

### Description

Two separate product registries exist:

1. **`CoverRouterV2.productList`** (`bytes32[]`): Appended in `configureProduct()`. Protected by `onlyOwner`.
2. **`PolicyManagerV2.productIds`** (`bytes32[]`): Appended in `registerProduct()`. Protected by `onlyOwner`.

**Critical issue with `productList`:** The `configureProduct()` function checks `products[_productId].durationSeconds == 0` to determine if a product is new. If the same product is reconfigured (updating pricing parameters), it does NOT re-append to the list. This is correct behavior -- no duplicates.

However, there is **no way to remove products from either array.** Products can be deactivated but the arrays only grow. Both arrays are only written to by the owner.

**Iteration:** No on-chain function iterates over these arrays. `getProductCount()` returns length (O(1)). Products are typically <50 in any reasonable protocol.

### Gas Per Iteration

~2,100 gas per SLOAD of a bytes32 array element.

### Max Items Before DoS

No DoS possible on-chain. Even iterating over 1,000 products in a view function would cost ~2.1M gas (well within limits). Realistic product count: 10--50.

### Severity

**NONE** -- Owner-controlled, realistically small, no iteration in state-changing functions.

---

## D-04: Gas Griefing via External State Reverts

### Description

Several functions can revert based on external contract state, potentially causing gas grief to callers:

### D-04a: `TWAPBurner.executeBurn()` Reverts

`executeBurn()` is permissionless. It can revert due to:
- Cooldown not elapsed: `require(block.timestamp >= lastBurnTimestamp + burnCooldown)`
- Insufficient balance: `require(usdcBalance >= minBurnAmount)`
- Uniswap swap failure (pool empty, tick out of range)
- `amountOutMin` not met (oracle price vs. spot divergence)
- `require(luminaReceived > 0)` -- zero output from swap

**Gas cost of revert:** ~30,000--50,000 gas for early reverts (balance/cooldown checks), up to ~200,000 gas if the swap call fails mid-execution.

**Griefing vector:** A keeper (Gelato/Chainlink Automation) calls `executeBurn()` and pays gas. If the function reverts, the keeper wastes gas. An attacker could monitor `canBurn()` returning true, then front-run the keeper with a small swap that causes the slippage check to fail. This costs the keeper ~200K gas (~$0.50 at typical L2 prices) per attempt.

**Impact:** Minor annoyance to keepers. The burn will succeed on the next attempt if the attacker doesn't continuously grief.

### D-04b: `BondVault.issueBond()` Reverts

`issueBond()` is called by `PolicyManager`, which is called by `CoverRouter`. The revert chain:
- Oracle call fails (try/catch in `_getSafePrice()` handles this -- returns `MIN_REDEEM_PRICE`)
- Circuit breaker active: `require(!paused)` -- **the user's policy purchase reverts**
- Capacity exceeded: `require(totalCommittedUSD + payout <= maxCommitUSD)`
- Price below floor: `require(currentPrice >= MIN_PRICE)`

**Griefing vector:** An attacker triggers the circuit breaker (permissionless `triggerBreaker()` when price < $0.005), pausing all new issuance. Users attempting to buy policies will have their transactions revert, wasting gas. However, this is a legitimate safety mechanism, not a grief.

### D-04c: `SolvencyOracle.evaluate()` Reverts

- `emergencyPaused` set by admin
- `EVALUATION_INTERVAL` not reached
- External call to `bondVault.totalCommittedUSD()` or `capacityOracle.getLuminaPrice()` fails

The `evaluate()` function does NOT use try/catch on external calls to `capacityOracle.getLuminaPrice()`. If the oracle reverts, `evaluate()` reverts. This could DoS the solvency evaluation system.

**Impact:** If `CapacityOracle` is broken, `SolvencyOracle` cannot evaluate, which means the `AdaptiveFeeDistributor` uses stale quadrant data. The `TWAPBurner` falls back to hardcoded distribution constants.

### Gas Per Iteration

| Function | Gas on revert | Frequency |
|---|---|---|
| `executeBurn()` early revert | ~30K--50K | Every 15 min max |
| `executeBurn()` swap revert | ~150K--200K | Depends on pool state |
| `issueBond()` revert | ~100K--150K | Per policy attempt |
| `evaluate()` revert | ~50K--80K | Once per day |

### Max Items Before DoS

N/A -- these are not array-based but external-state-based reverts.

### Severity

**LOW** -- Most reverts are legitimate safety mechanisms. The `SolvencyOracle.evaluate()` lacking try/catch on `capacityOracle.getLuminaPrice()` is a real concern (D-04c) but the fallback mechanism in `TWAPBurner._getDistribution()` provides defense in depth.

### Recommendation

1. Wrap `capacityOracle.getLuminaPrice()` in try/catch within `SolvencyOracle._calculateSolvencyRatio()`, returning a safe default (e.g., 0 or `type(uint256).max`) on failure.
2. Add a `lastSuccessfulEvaluation` timestamp to `SolvencyOracle` so callers can detect stale data.

---

## D-05: Zero/Dust Amount Attacks

### Description

Systematic analysis of what happens with `amount = 1 wei` across all contracts:

### D-05a: `TWAPBurner.receivePremium(1)`

- `require(amount > 0)` passes (1 > 0).
- `safeTransferFrom` transfers 1 wei USDC ($0.000001).
- `totalUSDCReceived += 1` -- accumulated counter, no issue.
- **Impact:** Negligible. Requires the sender to have USDC approval. Does not affect burn mechanics since `minBurnAmount = 1e6` ($1) prevents burning dust.

### D-05b: `LuminaBondMarketplace.list(epochId, 1, 1)`

- `amount = 1` (1 bond token = $1 face value).
- `priceUSDC = 1` (0.000001 USDC).
- Both pass `> 0` checks.
- Listing is created. Bond is transferred to marketplace.
- **Impact:** The listing is valid but at a nonsensical price. A buyer pays 1 wei USDC + 0 buyer fee (1 * 150 / 10000 = 0). Seller receives 1 - 0 = 1 wei USDC. No fee collected.
- **Fee rounding:** `sellerFee = (1 * 150) / 10000 = 0`. `buyerFee = 0`. Total fees sent to TWAPBurner: 0.
- **Griefing potential:** An attacker can list thousands of dust listings, consuming `nextListingId` slots. Each listing costs ~150K gas for the bond transfer + storage. At $0.01/listing on L2, creating 10K listings costs ~$100. These listings do not affect any iteration (listings are accessed by ID, not iterated).

### D-05c: `BondVault.redeemBond(epochId, 0)` / `redeemBond(epochId, 1)`

- `usdAmount = 0`: Reverts with `"Zero amount"`. **Safe.**
- `usdAmount = 1`: 1 bond token = $1. `luminaAmount = 1 * 1e36 / price`. At $0.036, this is ~27,777 LUMINA tokens (27,777e18 wei). This is a valid redemption.
- **No dust issue** -- 1 bond token represents $1, which is a meaningful amount.

### D-05d: `CEXLiquidityReserve.allocate(recipient, 1, ...)`

- `amount = 1` (1 wei LUMINA, ~$0.000000000000000036).
- Passes all checks. Costs ~200K gas ($0.01 on L2).
- Deducts 1 from sub-bucket. Adds to monthly allocations.
- **Griefing potential:** With `ALLOCATOR_ROLE` (admin only), could fragment allocations. But admin self-griefing is not a threat model.

### D-05e: `MaintenanceReserve.spend(recipient, 1, category, memo)`

- `amount = 1` (1 wei USDC = $0.000001).
- Passes all checks. Adds a SpendRecord.
- **Impact:** Negligible. Admin-controlled.

### D-05f: `CoverRouterV2.purchasePolicy(productId, coverageAmount, asset)`

- `coverageAmount` has a minimum of `100e6` ($100): `if (coverageAmount < 100e6) revert InvalidCoverage(...)`.
- **Safe** -- dust coverage is rejected.
- Premium calculation: `premium = coverage * payoutRatioBps * triggerProbBps * marginBps / 10000^3`. With minimum coverage $100 and typical parameters (8000, 20, 15000): `100e6 * 8000 * 20 * 15000 / 1e12 = 240,000` = $0.24. If premium rounds to 0, it is set to 1.

### Summary Table

| Function | Min Amount | Dust Viable? | Impact |
|---|---|---|---|
| `receivePremium()` | 1 wei USDC | Yes but harmless | Counter increment only |
| `marketplace.list()` | 1 wei price, 1 bond | Yes | Fee rounds to 0 -- no burn fee collected |
| `redeemBond()` | 1 USD ($1) | Not dust -- meaningful | Normal redemption |
| `CEXReserve.allocate()` | 1 wei LUMINA | Admin only | Not exploitable |
| `MaintenanceReserve.spend()` | 1 wei USDC | Admin only | Not exploitable |
| `purchasePolicy()` | $100 minimum | No | Enforced minimum |

### Severity

**LOW** -- The marketplace fee rounding to zero on dust-priced listings is a minor finding. It allows fee-free bond transfers via the marketplace (list at 1 wei, buy for 1 wei + 0 fee). This bypasses the intended 3% fee but provides no economic benefit over direct ERC-1155 transfer (which is free anyway). The marketplace fees are designed to capture value from legitimate secondary market trading, not to prevent transfers.

### Recommendation

Consider adding a minimum price floor to marketplace listings (e.g., `require(priceUSDC >= 1e4, "Price too low")` for $0.01 minimum) to ensure fees are always collected on marketplace trades.

---

## D-06: Front-Running Griefing on Marketplace Listings

### Description

**Scenario 1: Buy front-running**

Attacker sees a buyer's `executeBuy(listingId)` in the mempool and front-runs with their own `executeBuy(listingId)`. The original buyer's transaction reverts with `"Not active"` (listing already sold).

- **Impact:** The original buyer wastes ~50K gas on a revert. The attacker now holds the bonds (possibly at an unfavorable price). This is standard DEX front-running behavior on any marketplace.
- **Is this griefing?** The attacker pays the full price + fees. They only "win" if the bonds are valuable enough to buy. This is competitive buying, not griefing.

**Scenario 2: Cancel front-running**

A seller sees a buyer's `executeBuy(listingId)` and front-runs with `cancel(listingId)`. The buyer's transaction reverts.

- **Impact:** The buyer wastes ~50K gas. The seller recovers their bonds.
- **Is this griefing?** The seller has a legitimate right to cancel. This is standard marketplace behavior.

**Scenario 3: Listing manipulation**

An attacker creates many listings at attractive prices, waits for buyers to submit `executeBuy()` transactions, then cancels all listings before the buyer transactions execute.

- **Impact:** Buyers waste gas repeatedly. The attacker pays gas for listing + cancellation (~200K gas per cycle).
- **Cost to attacker:** ~200K gas per bait-and-cancel = ~$0.02 on L2.
- **Cost to victim:** ~50K gas per failed buy = ~$0.005 on L2.
- **Ratio:** Attacker spends 4x more gas than the victim. Not economically efficient griefing.

### Severity

**LOW** -- Standard marketplace dynamics. The attacker pays more gas than the victim in bait-and-cancel scenarios. On L2s with private mempools (Base, Arbitrum sequencer), front-running is significantly harder.

### Recommendation

No on-chain mitigation needed. Consider implementing commit-reveal for high-value listings if front-running becomes problematic in practice.

---

## D-07: Block Gas Limit Exhaustion

### Description

Systematic analysis of all functions for worst-case gas consumption:

### D-07a: `TWAPBurner.executeBurn()` -- Adaptive Mode

In adaptive mode, `executeBurn()` calls `_executeAdaptive()` which:
1. Calls `_getDistribution()` -- 2 external calls to `feeDistributor` (try/catch wrapped)
2. Up to 3 `safeTransfer` calls (buyback, ops, maintenance)
3. 1 `_swapAndBurn()` call -- Uniswap swap + LUMINA burn

**Worst-case gas:** ~500K--800K. Well within 30M block gas limit.

### D-07b: `BondVault.issueBond()`

1. External call to `priceOracle.getLuminaPrice()` -- ~50K
2. `lumina.balanceOf(address(this))` -- ~2.6K
3. `claimBond.mint()` -- ~80K--150K (ERC1155 mint, possible new epoch creation)

**Worst-case gas:** ~300K--400K. Safe.

### D-07c: `PolicyManagerV2.recordPolicy()`

1. External call to `bondVault.availableCapacityUSD()` -- ~100K (includes oracle call)
2. External call to `shield.createPolicy()` -- ~200K--400K (depends on shield)
3. Storage writes for `PolicyRecord` -- ~100K

**Worst-case gas:** ~500K--700K. Safe.

### D-07d: `SolvencyOracle.evaluate()`

1. `_calculateSolvencyRatio()` -- 3 external calls (~100K)
2. Array writes to `solvencyHistory[3]` and `momentumHistory[3]` -- ~40K
3. Classification and quadrant comparison -- ~10K

**Worst-case gas:** ~200K. Safe.

### D-07e: `CapacityOracle._getTwapPrice()` / `getTWAP()`

1. External call to `pool.observe()` -- ~10K--50K (depends on observation cardinality)
2. `_getSqrtPriceFromTick()` -- pure math, ~20 conditional multiplications -- ~10K

**Worst-case gas:** ~80K. Safe.

### D-07f: `CEXLiquidityReserve.allocate()`

1. Various checks + storage reads -- ~20K
2. Storage writes (counter + history append) -- ~100K--200K (depends on description length)
3. `safeTransfer` -- ~50K

**Worst-case gas:** ~300K. Safe.

### D-07g: View Functions with Potential Gas Issues

None of the view functions iterate over unbounded arrays. All view functions access individual storage slots or perform bounded computations.

**Critical check -- `getProductCount()`, `spendCount()`, `getAllocationHistoryLength()`:** All return `.length` of their respective arrays -- O(1) SLOAD. Safe.

### Summary

| Function | Worst-Case Gas | % of 30M Limit | Risk |
|---|---|---|---|
| `executeBurn()` (adaptive) | ~800K | 2.7% | NONE |
| `issueBond()` | ~400K | 1.3% | NONE |
| `recordPolicy()` | ~700K | 2.3% | NONE |
| `evaluate()` | ~200K | 0.7% | NONE |
| `_getTwapPrice()` | ~80K | 0.3% | NONE |
| `allocate()` | ~300K | 1.0% | NONE |
| `executeBuy()` marketplace | ~350K | 1.2% | NONE |

### Severity

**NONE** -- No function approaches the 30M block gas limit. The highest-cost function (`executeBurn` in adaptive mode) uses <3% of the limit. All arrays are either bounded, admin-controlled, or not iterated.

---

## Overall Summary Matrix

| ID | Vector | Severity | Exploitable? | Recommended Action |
|---|---|---|---|---|
| D-01 | `spendHistory` unbounded array | LOW | No (admin-only writes, no iteration) | Add paginated view |
| D-02 | `allocationHistory` unbounded array | NONE | No (admin-only, supply-capped) | None |
| D-03 | `productList`/`productIds` arrays | NONE | No (owner-only, realistically small) | None |
| D-04 | External state reverts | LOW | Partial (keeper gas grief) | Add try/catch in SolvencyOracle |
| D-05 | Zero/dust amounts | LOW | Fee rounding on marketplace | Add minimum listing price |
| D-06 | Marketplace front-running grief | LOW | Standard MEV, attacker pays more | None required |
| D-07 | Block gas limit exhaustion | NONE | No function exceeds 3% of limit | None |

## Key Finding

**The protocol has no significant DoS or griefing vulnerabilities.** The design avoids unbounded iteration patterns. All arrays are append-only with index access. State-changing functions are bounded in gas consumption. The most notable finding is the fee rounding to zero on dust-priced marketplace listings (D-05b), which is a cosmetic issue rather than a security vulnerability since direct ERC-1155 transfers are free regardless.

The one actionable recommendation is D-04c: adding try/catch around `capacityOracle.getLuminaPrice()` in `SolvencyOracle._calculateSolvencyRatio()` to prevent oracle failures from DoS-ing the evaluation system.

---

*End of Agent 4 DoS & Griefing Analysis*
