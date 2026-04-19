# Agent 3: Economic Attack Specialist -- Red Team Analysis

**Protocol:** LUMINA Protocol V5.0
**Date:** 2026-04-19
**Auditor Class:** Economic Attack Specialist (Agent 3)
**Scope:** All contracts in `src/` -- oracle manipulation, sandwich attacks, buyback drain, front-running, time manipulation, price impact, and wash trading vectors.

---

## Table of Contents

1. [E-01: Oracle Manipulation via Flash Loans](#e-01-oracle-manipulation-via-flash-loans)
2. [E-02: Sandwich Attacks on TWAPBurner.executeBurn()](#e-02-sandwich-attacks-on-twapburnerexecuteburn)
3. [E-03: Buyback Drain via Cheap Bond Creation](#e-03-buyback-drain-via-cheap-bond-creation)
4. [E-04: Front-Running of Administrative Functions](#e-04-front-running-of-administrative-functions)
5. [E-05: Time Manipulation via block.timestamp](#e-05-time-manipulation-via-blocktimestamp)
6. [E-06: Price Impact and Slippage Exploitation](#e-06-price-impact-and-slippage-exploitation)
7. [E-07: Wash Trading on Bond Marketplace](#e-07-wash-trading-on-bond-marketplace)

---

## E-01: Oracle Manipulation via Flash Loans

### Attack Description

The `CapacityOracle` reads Uniswap V3 TWAP with a configurable window (default 30 minutes, range 5 min -- 2 hr). The attacker's goal is to manipulate the TWAP to influence:

1. **BondVault.issueBond()** -- inflated price increases `maxCommitUSD`, allowing over-issuance of bonds relative to true reserve value.
2. **BondVault.redeemBond()** -- deflated price increases the LUMINA paid per dollar of bond, draining vault reserves faster.
3. **TWAPBurner._swapAndBurn()** -- manipulated `amountOutMin` causes either (a) reverts (DoS) or (b) acceptance of worse-than-market swap rates.

**Flash Loan Viability Analysis:**

Flash loans execute atomically within a single transaction. A Uniswap V3 TWAP over 30 minutes requires the price to be distorted across at least 1,800 seconds of accumulated tick data. Flash loans cannot persist state across blocks, making direct TWAP manipulation via flash loan **infeasible** against the 30-minute window.

**Multi-Block Manipulation (More Realistic):**

An attacker with significant capital could attempt sustained spot manipulation across multiple blocks:

- The LUMINA/USDC pool is a 1% fee tier (`poolFee = 10000`), implying low liquidity and high volatility.
- Cost to move the TWAP by X% for 30 minutes: attacker must maintain an off-market position for ~120 blocks (at 15s/block on L1, or ~900 blocks on L2 at 2s/block).
- Capital required: For a pool with $500K TVL, moving price 20% for 30 min would require continuous capital deployment of approximately $100K--$200K, subject to arbitrage losses on every block.
- Arbitrageurs would continuously trade against the displaced price, imposing cumulative losses of ~$50K--$150K on the attacker per 30-minute window.

**Profit Opportunity:**

- Inflating price for `issueBond()`: Attacker needs a policy to trigger, which is oracle-dependent and not controllable.
- Deflating price for `redeemBond()`: Attacker needs matured bonds (24-month maturity). Not viable for an opportunistic attack.
- The profit from over-issuance or under-priced redemption is unlikely to exceed the sustained manipulation cost.

### Capital Required

$100K--$200K sustained over 30 minutes, plus cumulative arbitrage losses of $50K--$150K.

### Estimated Profit/Loss

**Net loss** for the attacker in most scenarios. The 30-min TWAP window and arbitrageur activity make the attack economically irrational against any pool with >$200K liquidity.

### Current Mitigations

| Mitigation | Location | Effectiveness |
|---|---|---|
| 30-min TWAP window (configurable 5 min -- 2 hr) | `CapacityOracle.twapWindow` | HIGH -- resists single-block manipulation |
| Emergency price fallback | `CapacityOracle.emergencyPrice` | MEDIUM -- backstop if TWAP fails |
| `MIN_PRICE` circuit breaker ($0.005) | `BondVault.MIN_PRICE` | HIGH -- blocks issuance at extreme lows |
| `MIN_REDEEM_PRICE` floor ($0.001) | `BondVault.MIN_REDEEM_PRICE` | MEDIUM -- limits drain rate |
| Hysteresis on circuit breaker reset ($0.008) | `BondVault.RESET_PRICE` | HIGH -- prevents flap attacks |
| 1-hour breaker cooldown | `BondVault.BREAKER_COOLDOWN` | MEDIUM -- prevents rapid toggle |
| `_getSafePrice()` try/catch fallback | `BondVault._getSafePrice()` | MEDIUM -- graceful degradation |

### Residual Risk Rating

**LOW**

The 30-minute TWAP makes flash loan manipulation infeasible. Multi-block manipulation is economically irrational for pools with reasonable liquidity. The circuit breaker and hysteresis add further defense-in-depth. Residual risk exists if `twapWindow` is reduced to the 5-minute minimum via admin action -- this should be documented as a governance risk.

**Recommendation:** Consider enforcing a minimum TWAP window of 15 minutes (currently 5 min allowed). Add a Chainlink price feed as a secondary oracle for cross-validation.

---

## E-02: Sandwich Attacks on TWAPBurner.executeBurn()

### Attack Description

`executeBurn()` is permissionless and predictable. The attacker:

1. Observes a pending `executeBurn()` transaction in the mempool (or predicts it via `canBurn()` returning true).
2. **Front-runs** with a large swap: buy LUMINA with USDC on the same Uniswap V3 pool, moving the price up.
3. The `executeBurn()` transaction executes, buying LUMINA at an inflated price (receiving fewer tokens).
4. **Back-runs** by selling the LUMINA purchased in step 2, profiting from the price impact.

**Profitability Analysis:**

- `maxBurnAmount = 10,000 USDC` per execution. This caps the victim trade size.
- Pool fee tier: 1% (`poolFee = 10000`). The attacker pays 1% on both the front-run and back-run swaps.
- Attacker's cost: 2x pool fees on their capital = 2% minimum loss.
- The attacker's profit is the price impact of the 10K USDC burn on their position, minus 2% fees.
- For a pool with $500K TVL, a $10K swap creates ~2% price impact. The attacker would need to deploy ~$50K to capture meaningful slippage, paying ~$1K in fees.
- Sandwich profit on a $10K trade with 2% impact: ~$200. Minus $1K fees = **net loss of $800**.
- For a pool with $50K TVL, the math improves but the 5% slippage protection (`maxSlippageBps = 500`) would cause the burn TX to revert if the front-run moves the price too far.

**Adaptive Mode Complication:**

In V5.0 adaptive mode, only a fraction of the USDC goes to the swap (the `burnBps` portion). In crisis mode (solvencyLevel=3, momentum=3), `burnBps=0` -- no swap occurs at all, eliminating the sandwich vector.

### Capital Required

$50K--$100K per sandwich attempt on a $500K TVL pool.

### Estimated Profit/Loss

**Net loss** for the attacker on pools with >$100K TVL due to the 1% fee tier and 5% max slippage. **Marginal profit** ($50--$200) possible on very thin pools (<$50K TVL) with reduced slippage settings.

### Current Mitigations

| Mitigation | Location | Effectiveness |
|---|---|---|
| `maxSlippageBps = 500` (5%) oracle-derived `amountOutMin` | `TWAPBurner._swapAndBurn()` | HIGH -- reverts if price moves >5% |
| `maxBurnAmount = 10,000 USDC` per execution | `TWAPBurner.maxBurnAmount` | HIGH -- caps victim trade size |
| 15-minute cooldown between burns | `TWAPBurner.burnCooldown` | MEDIUM -- limits attack frequency |
| 1% pool fee tier | `TWAPBurner.poolFee` | HIGH -- makes sandwiching expensive |
| Oracle-based `amountOutMin` from CapacityOracle | `TWAPBurner._swapAndBurn()` | HIGH -- anchors to TWAP not spot |

### Residual Risk Rating

**LOW**

The combination of 1% pool fees, 5% oracle-derived slippage protection, and $10K max burn amount makes sandwich attacks unprofitable on any pool with reasonable liquidity. The protocol is specifically designed for TWAP-distributed micro-swaps, which is the standard defense against this vector.

**Recommendation:** Consider deploying on an L2 with a private mempool (e.g., Flashbots Protect on L1, or native sequencer ordering on Base/Arbitrum) to eliminate mempool visibility. Alternatively, integrate with a MEV-aware DEX aggregator.

---

## E-03: Buyback Drain via Cheap Bond Creation

### Attack Description

The attacker attempts to:

1. Acquire ClaimBonds cheaply (either by purchasing discounted bonds on the marketplace or by triggering policies to receive bonds).
2. List bonds on the `LuminaBondMarketplace` at a price that is attractive to the `BuybackEngine`.
3. The `BuybackEngine` buys the bonds, spending USDC from its budget, and executes Double Burn (reducing obligations + burning LUMINA from BondVault reserves).

**Viability Analysis:**

- **Bond acquisition cost:** Bonds are only issued by `BondVault.issueBond()` when a policy triggers. The user must (a) buy a policy, (b) have a legitimate oracle-verified trigger event occur. The attacker cannot manufacture triggers -- they require real price movements and valid oracle signatures.
- **Marketplace listing:** The attacker can list bonds at any price. The `BuybackEngine.executeOffer()` enforces `priceUSDC <= maxAllowedPriceUSDC`, where max allowed = `faceValue * maxPricePercent / 100`. With `maxPricePercent` capped at 95%, the engine never pays more than 95% of face value.
- **Budget constraint:** `dailyConfig.dailyBudget` limits total spend per session. `dailyConfig.validUntil` expires within 72 hours maximum.
- **Activation delay:** The `BuybackEngine` has a 365-day `ACTIVATION_DELAY` from deployment. No buybacks can occur in the first year.
- **Solvency check:** Double Burn only occurs when `solvencyRatio >= 15000` (150%). In stressed conditions, only the obligation reduction happens (no LUMINA burn from reserves).

**Attack economics:** The attacker's cost is the premium for a policy + 3% marketplace fees. Their "revenue" is the USDC received from the buyback engine. Since the engine pays at most 95% of face value, and the attacker's bonds cost at least the premium (which is a fraction of face value), the net profit depends on the premium-to-payout ratio.

For FLASHBTC1H: premium ~ coverage * 0.8 * 0.002 * 1.5 = 0.24% of coverage. Payout = 80% of coverage. If the attacker obtains bonds (requires a real BTC crash), lists at 50% of face value, and the engine buys:
- Attacker spent: 0.24% of coverage in premium + already experienced a real market event.
- Attacker receives: 50% of face value from engine.
- Net: Attacker profits, but **only if a genuine trigger event occurs**, which is not controllable.

### Capital Required

Premium cost for policies (~0.24% of coverage) + 3% marketplace fees. Minimum ~$100 policy.

### Estimated Profit/Loss

**Not exploitable as an attack.** The attacker cannot manufacture trigger events. If bonds are legitimately obtained and sold at a discount, this is normal market behavior, not an exploit. The BuybackEngine is designed to buy discounted bonds -- this is its purpose.

### Current Mitigations

| Mitigation | Location | Effectiveness |
|---|---|---|
| 365-day activation delay | `BuybackEngine.ACTIVATION_DELAY` | HIGH -- no buybacks in year 1 |
| `maxPricePercent` cap (1--95%) | `BuybackEngine.setDailyBuyback()` | HIGH -- never overpays |
| Daily budget limit | `BuybackEngine.dailyConfig.dailyBudget` | HIGH -- caps exposure |
| Session expiry (max 72 hours) | `BuybackEngine.dailyConfig.validUntil` | MEDIUM -- time-boxed |
| Solvency gate for Double Burn (150%) | `BuybackEngine.MIN_SOLVENCY_FOR_DOUBLE_BURN` | HIGH -- protects reserves |
| Oracle-verified trigger requirement | `BaseShield`, `PolicyManagerV2` | HIGH -- cannot fabricate bonds |
| 3% marketplace fees (1.5% each side) | `LuminaBondMarketplace` | LOW -- minor friction |

### Residual Risk Rating

**NONE**

The attack requires manufacturing oracle-verified trigger events, which is not feasible. The BuybackEngine's design (activation delay, budget caps, price limits, solvency gates) provides comprehensive protection. Buying discounted bonds at market price is intended behavior, not an exploit.

---

## E-04: Front-Running of Administrative Functions

### Attack Description

Critical administrative functions that could be front-run:

1. **`ClaimBond.setBondVault()`**: One-shot setter, `onlyOwner`. An attacker would need to front-run the owner's transaction. Since `onlyOwner` is enforced, the front-run transaction would revert (attacker is not owner). **Not exploitable.**

2. **`BondVault.setPolicyManager()`**: One-shot setter, `onlyDeployer`. Same protection as above -- the deployer address is immutable, and only the deployer can call. **Not exploitable.**

3. **`CoverRouterV2.setPolicyManager()` / `setTwapBurner()`**: `onlyOwner`, but **not** one-shot. These can be called repeatedly. Front-running is not applicable since the attacker cannot impersonate the owner. However, the owner *could* be socially engineered into setting a malicious address. This is a governance risk, not a front-running risk.

4. **`CoverRouterV2.configureProduct()`**: `onlyOwner`. An attacker could observe a `configureProduct()` transaction and front-run with a `purchasePolicy()` call using the old (potentially more favorable) pricing. This is a minor MEV opportunity but not a security vulnerability -- the old pricing was previously valid.

5. **`BondVault.setAuthorizedCaller()`**: `onlyRole(AUTHORIZED_CALLER_ADMIN_ROLE)`. Protected by AccessControl. If a malicious caller is authorized, they can call `decreaseObligations()` and `burnFromReserves()`. This is a governance risk (admin key compromise), not front-running.

### Capital Required

N/A -- front-running of admin functions is not viable due to access control.

### Estimated Profit/Loss

**Zero.** All critical setters are access-controlled. The one-shot pattern on `setBondVault` and `setPolicyManager` eliminates the deployment-frontrun vector.

### Current Mitigations

| Mitigation | Location | Effectiveness |
|---|---|---|
| `onlyOwner` on all admin functions | All contracts | HIGH |
| One-shot pattern (`_bondVaultSet`, `_policyManagerSet`) | `ClaimBond`, `BondVault` | HIGH |
| `onlyDeployer` for `setPolicyManager` | `BondVault` | HIGH |
| AccessControl roles | `BondVault`, `BuybackEngine`, `SolvencyOracle` | HIGH |

### Residual Risk Rating

**NONE**

Access control comprehensively prevents front-running of administrative functions. The one-shot pattern on deployment-critical setters is correctly implemented.

---

## E-05: Time Manipulation via block.timestamp

### Attack Description

Several contracts depend on `block.timestamp` for critical logic:

1. **Epoch calculation** (`BondVault._timestampToEpoch()`): Maps maturity timestamps to YYYYMM epochs. A miner/validator can manipulate `block.timestamp` by up to ~15 seconds (Ethereum consensus allows blocks within 15s of parent). This could theoretically shift a bond's epoch at a month boundary.

2. **Vesting schedules** (`FounderVesting`, `TreasuryVesting`, `CEXLiquidityReserve`): All use `block.timestamp` for lock durations, tranche releases, and monthly caps. Manipulation window: ~15 seconds.

3. **Burn cooldown** (`TWAPBurner.burnCooldown = 900`): 15-minute cooldown. A 15-second manipulation is <2% of the cooldown period.

4. **Policy expiry** (`BaseShield`): Duration-based expiry with 24-hour grace period. 15-second manipulation is negligible relative to the grace period.

5. **SolvencyOracle.evaluate()**: `EVALUATION_INTERVAL = 1 days`, `COOLDOWN_BETWEEN_QUADRANT_CHANGES = 7 days`. 15-second manipulation is <0.002% of the interval.

**Impact Analysis:**

The most sensitive case is epoch boundary manipulation. If a bond maturity falls exactly on a month boundary (e.g., timestamp 1767225600 + N * 2629746), a 15-second shift could change the epoch from 202801 to 202712 or vice versa. However:
- Bond maturity is 730 days from issuance. The exact epoch only matters for grouping in the ClaimBond ERC-1155.
- The `maturityDate` is set correctly based on the epoch, so the actual maturity timing is consistent regardless of which epoch the bond lands in.
- The user can still redeem when `block.timestamp >= maturityDate[epochId]`, and the date is derived from the epoch, so the round-trip is consistent.

### Capital Required

N/A -- requires validator/miner collusion (extremely expensive on PoS Ethereum).

### Estimated Profit/Loss

**Zero practical profit.** The 15-second manipulation window is negligible relative to all time-dependent parameters in the protocol. Epoch boundary edge cases affect grouping, not value.

### Current Mitigations

| Mitigation | Location | Effectiveness |
|---|---|---|
| Large time constants (15 min, 24 hr, 7 days, 730 days) | All contracts | HIGH -- dwarfs manipulation window |
| 24-hour claim grace period | `BaseShield.CLAIM_GRACE_PERIOD` | HIGH -- absorbs timing variance |
| Hysteresis on circuit breaker (1 hr cooldown) | `BondVault.BREAKER_COOLDOWN` | HIGH |
| 7-day quadrant change cooldown | `SolvencyOracle.COOLDOWN_BETWEEN_QUADRANT_CHANGES` | HIGH |

### Residual Risk Rating

**NONE**

All time-dependent logic uses sufficiently large intervals that the ~15-second `block.timestamp` manipulation window has no meaningful impact.

---

## E-06: Price Impact and Slippage Exploitation

### Attack Description

The `TWAPBurner._swapAndBurn()` function uses Uniswap V3 `exactInputSingle` with slippage protection:

```solidity
uint256 amountOutMin = 0; // default: no protection
if (capacityOracle != address(0)) {
    // oracle-derived minimum
    amountOutMin = (expectedOut * (10_000 - maxSlippageBps)) / 10_000;
}
```

**Attack Vectors:**

1. **No oracle set (`capacityOracle == address(0)`):** `amountOutMin = 0`. The swap has zero slippage protection. An attacker can sandwich the burn with arbitrary price manipulation and extract maximum value.

2. **Oracle set but stale:** If the CapacityOracle returns a stale/incorrect price (e.g., emergency price fallback during extended pool issues), the `amountOutMin` is anchored to a wrong price. If the oracle price is higher than reality, `amountOutMin` is too high and burns revert (DoS). If lower, slippage protection is too loose.

3. **`maxSlippageBps = 500` (5%):** The owner can set this between 0.5% and 10%. At 5%, the attacker can extract up to 5% of the burn amount per execution. On a $10K burn, that is $500 per execution.

4. **Pool fee tier manipulation:** The owner can change `poolFee` to 500 (0.05%), 3000 (0.3%), or 10000 (1%). Lower fee tiers have more concentrated liquidity, reducing price impact but also reducing the cost of sandwich attacks for the attacker.

**Worst-case scenario (no oracle):**

- $10K burn with `amountOutMin = 0`.
- Attacker front-runs, moves price 20%, burn executes at inflated price.
- Attacker back-runs, captures ~$2K profit minus pool fees.
- Repeatable every 15 minutes (cooldown).
- Daily extraction: $2K * 96 = ~$192K/day (theoretical maximum, limited by pool liquidity).

### Capital Required

$50K--$200K for sandwich capital on a thin pool, or $0 if `capacityOracle` is not set (pure sandwich).

### Estimated Profit/Loss

- **Without oracle:** Up to $500--$2,000 per burn execution. **HIGH risk**.
- **With oracle, 5% slippage:** Up to $500 per burn execution. **MEDIUM risk** but capped.
- **With oracle, 0.5% slippage:** Up to $50 per burn execution. **LOW risk**.

### Current Mitigations

| Mitigation | Location | Effectiveness |
|---|---|---|
| Oracle-derived `amountOutMin` | `TWAPBurner._swapAndBurn()` | HIGH (when set) |
| `maxSlippageBps` configurable (0.5%--10%) | `TWAPBurner.setMaxSlippageBps()` | MEDIUM -- depends on setting |
| `maxBurnAmount = 10,000 USDC` | `TWAPBurner.maxBurnAmount` | HIGH -- caps per-tx exposure |
| 15-min cooldown | `TWAPBurner.burnCooldown` | MEDIUM -- limits frequency |
| Try/catch on oracle call | `TWAPBurner._swapAndBurn()` | CAUTION -- falls back to 0 on failure |

### Residual Risk Rating

**MEDIUM**

The critical finding is that if `capacityOracle` is `address(0)` or the oracle call fails (caught by try/catch), `amountOutMin` defaults to 0, removing all slippage protection. This is a design choice for graceful degradation, but it creates a window of vulnerability.

**Recommendations:**
1. **CRITICAL:** If the oracle call fails in `_swapAndBurn()`, consider reverting instead of falling back to `amountOutMin = 0`. A failed oracle should pause burns, not remove protection.
2. Reduce `maxSlippageBps` to 200 (2%) as the default.
3. Add a minimum `amountOutMin` floor as a constant (e.g., prevent burns when slippage would exceed 3% regardless of oracle).

---

## E-07: Wash Trading on Bond Marketplace

### Attack Description

An attacker creates two accounts (A and B):

1. Account A lists bonds on `LuminaBondMarketplace`.
2. Account B buys the bonds from Account A.
3. Repeat to inflate volume metrics.

**Fee Analysis:**

- Seller fee: 1.5% of `priceUSDC` deducted from seller proceeds.
- Buyer fee: 1.5% of `priceUSDC` added to buyer cost.
- Total fee per wash trade: 3% of the listed price, sent to `twapBurner`.

**Profit Opportunity:**

The attacker loses 3% per round-trip. There is no mechanism to recover these fees. Wash trading:
- Does not affect oracle prices (marketplace trades are off-chain for price discovery).
- Does not affect solvency calculations (bonds change hands, not obligations).
- Does not generate any revenue or governance benefit for the attacker.
- Does inflate `nextListingId` counter, but this is a monotonic uint256 -- no practical limit.

The only "benefit" is artificial volume for marketing purposes, at a 3% cost per trade.

**Self-Trade via BuybackEngine:**

An attacker with `BUYBACK_OPERATOR_ROLE` could configure the engine to buy their own listings. However:
- This requires compromising the multisig (governance risk).
- The engine enforces `priceUSDC <= faceValue * maxPricePercent / 100`, so the attacker cannot list above face value.
- The engine's USDC comes from protocol reserves, so this would be a rug pull via the buyback mechanism (see Agent 5 centralization report).

### Capital Required

Bonds (face value $100+) + 3% fee per trade. Minimum ~$103 per wash trade.

### Estimated Profit/Loss

**Net loss of 3% per trade.** No profit mechanism exists. Wash trading is economically irrational.

### Current Mitigations

| Mitigation | Location | Effectiveness |
|---|---|---|
| 3% total fees (1.5% + 1.5%) | `LuminaBondMarketplace` | HIGH -- makes wash trading costly |
| Fees sent to TWAPBurner (burned) | `LuminaBondMarketplace.executeBuy()` | HIGH -- fees are not recoverable |
| No volume-based incentives | Protocol design | HIGH -- no reason to wash trade |

### Residual Risk Rating

**NONE**

Wash trading is unprofitable by design. The 3% fee acts as a Sybil resistance mechanism. There are no volume-based rewards, governance rights, or other incentives that would motivate artificial trading.

---

## Summary Matrix

| ID | Attack Vector | Capital Required | Profit/Loss | Residual Risk |
|---|---|---|---|---|
| E-01 | Oracle Manipulation (Flash Loans) | $100K--$200K | Net loss | **LOW** |
| E-02 | Sandwich Attack on executeBurn() | $50K--$100K | Net loss (normal conditions) | **LOW** |
| E-03 | Buyback Drain via Cheap Bonds | Premium cost | Not exploitable | **NONE** |
| E-04 | Front-Running Admin Functions | N/A | Zero | **NONE** |
| E-05 | block.timestamp Manipulation | Validator collusion | Zero practical | **NONE** |
| E-06 | Slippage Exploitation (no oracle) | $0--$200K | Up to $500/burn | **MEDIUM** |
| E-07 | Wash Trading on Marketplace | $103+ per trade | -3% per trade | **NONE** |

## Critical Recommendation

The single most impactful improvement is addressing E-06: the try/catch fallback to `amountOutMin = 0` in `TWAPBurner._swapAndBurn()`. When the oracle is unavailable, burns should pause rather than execute without slippage protection. This converts a MEDIUM risk to NONE.

---

*End of Agent 3 Economic Attack Analysis*
