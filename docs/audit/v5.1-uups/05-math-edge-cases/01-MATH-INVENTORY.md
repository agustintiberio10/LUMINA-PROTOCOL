# V5.1 Math Operations Inventory

**Audit:** V5.1 #5 — Math Edge Cases Re-audit on UUPS
**Branch:** `audit/v5.1-05-math-edge-cases-reaudit`
**Date:** 2026-04-22

---

## Key UUPS-driven change

Audit #1 (storage layout) confirmed: **all math constants remained `public constant`**
in the UUPS version — they were never converted to state or `immutable`. This means
their values live in bytecode, not proxy storage, and they cannot be altered by a
post-deploy admin action or upgrade (unless the implementation itself is replaced).

| Constant | Contract | Value | Kind |
|----------|----------|-------|------|
| `SAFETY_FACTOR_BPS` | BondVault | 5000 | `public constant` |
| `BOND_MATURITY_SECONDS` | BondVault | 730 days | `public constant` |
| `MIN_REDEEM_PRICE` | BondVault | 0.001e18 | `public constant` |
| `BOND_RESERVE` | CapacityOracle | 70_000_000e18 | `public constant` |
| `SAFETY_FACTOR_BPS` | CapacityOracle | 5000 | `public constant` |
| `AVG_PAYOUT_USD` | CapacityOracle | 500 | `public constant` |
| `MATURITY_DAYS` | CapacityOracle | 730 | `public constant` |
| `AVG_TRIGGER_RATE_BPS` | CapacityOracle | 100 | `public constant` |
| `SOLVENCY_ULTRA_BPS` | SolvencyOracle | 20000 | `public constant` |
| `SOLVENCY_HEALTHY_BPS` | SolvencyOracle | 10000 | `public constant` |
| `SOLVENCY_STRESSED_BPS` | SolvencyOracle | 7000 | `public constant` |
| `MOMENTUM_RALLY_BPS` | SolvencyOracle | 11000 | `public constant` |
| `MOMENTUM_STABLE_LOW_BPS` | SolvencyOracle | 9500 | `public constant` |
| `MOMENTUM_DECLINE_BPS` | SolvencyOracle | 8500 | `public constant` |
| `FALLBACK_BURN_BPS` | TWAPBurner | 8500 | `public constant` |
| `FALLBACK_BUYBACK_BPS` | TWAPBurner | 800 | `public constant` |
| `FALLBACK_OPS_BPS` | TWAPBurner | 200 | `public constant` |
| `FALLBACK_MAINTENANCE_BPS` | TWAPBurner | 500 | `public constant` |
| `SELLER_FEE_BPS` | LuminaBondMarketplace | 150 | `public constant` |
| `BUYER_FEE_BPS` | LuminaBondMarketplace | 150 | `public constant` |
| `BPS_DENOMINATOR` | LuminaBondMarketplace | 10000 | `public constant` |
| `MIN_PRICE_FOR_NEW_POLICIES` | CoverRouterV2 | 5e15 | `public constant` |
| `RESET_PRICE_FOR_NEW_POLICIES` | CoverRouterV2 | 8e15 | `public constant` |
| Product durations | Shields | 3600/14400/86400/172800/604800 | `public constant` |
| Product IDs | Shields | keccak256("...") | `public constant` |

**Conclusion of this row:** no constant was promoted to state; the "immutable → state"
regression that could in theory affect math did NOT occur in the migration. The
values are safe against post-deploy tampering.

---

## Math Operations Catalogue

### 1. Premium calculation (`CoverRouterV2.quotePremium`)
```
premium = (coverage × payoutRatioBps × triggerProbBps × marginBps) / (10000³)
if premium == 0 → premium = 1   // minimum 1 µUSD
```
- Min coverage: 100e6 ($100).
- Overflow guard: coverage up to 2^256 / (10000^3 × 10000) — in practice dust.
- Rounds DOWN (integer div) — favours the protocol (user pays at least `1`).

### 2. Redemption conversion (`BondVault.redeemBond`)
```
luminaAmount = (usdAmount × 1e36) / currentPrice
```
- `currentPrice` in 18-dec; `usdAmount` in integer dollars; result 18-dec LUMINA wei.
- Price floored to `MIN_REDEEM_PRICE = 0.001e18` by `_getSafePrice`, preventing
  div-by-zero.
- Rounds DOWN — holder receives floor LUMINA, protocol keeps dust.

### 3. Capacity (`BondVault.availableCapacityUSD`)
```
reserveValueUSD18 = (reserveBalance × currentPrice) / 1e18
maxCommitUSD18    = (reserveValueUSD18 × SAFETY_FACTOR_BPS) / 10000
totalUsed         = totalCommittedUSD + totalReservedUSD
if maxCommitUSD18 <= totalUsed: return 0
else: return (maxCommitUSD18 - totalUsed) / 1e18
```
- Underflow guard via `<=` check.
- Safety factor is 50% (5000 BPS).
- Rounds DOWN.

### 4. Epoch ID (`BondVault._timestampToEpoch`)
```
BASE_TS = 1767225600  // Jan 1 2026 UTC
monthsFromBase = (ts - BASE_TS) / 2629746  // 2629746s ≈ 30.44 days avg month
year  = 2026 + monthsFromBase / 12
month = 1 + monthsFromBase % 12
epochId = year × 100 + month   // YYYYMM
```
- Epoch ID domain: 202600 ≤ epochId ≤ 210012 (enforced by ClaimBond mint).
- Month boundary drift: average-month approximation; real epoch IDs may shift ~1
  month around year boundaries but fall within the [202600, 210012] range.

### 5. Solvency (`SolvencyOracle._calculateSolvencyRatio`)
```
solvencyBps = (vaultValueUSD × 10000) / totalCommittedUSD
```
- If `totalCommittedUSD == 0` → returns `SOLVENCY_ULTRA_BPS` (20000) as fallback
  (no div-by-zero; no commitments means solvency is maximal).

### 6. Burn cap (`BondVault.burnFromReserves`)
```
maxBurnPerTx = (currentBalance × 5) / 100   // 5%
require(amount <= maxBurnPerTx)
```
- Expressed as `× 5 / 100`, not `× 500 / 10000`, but mathematically identical.

### 7. Distribution lookup (`AdaptiveFeeDistributor._lookupDistribution`)
16 quadrants, each (burn, buyback, ops, maintenance). Every row sums to 10000.
Maintenance ≥ 200 in every row.

### 8. Marketplace fees (`LuminaBondMarketplace`)
```
buyerFee  = (priceUSDC × 150) / 10000   // 1.5%
sellerFee = (priceUSDC × 150) / 10000   // 1.5%
```
- Both in 10000-BPS denomination.

### 9. Chainlink 8-dec price → 18-dec internal
```
internal18 = chainlink8 × 1e10
```
- Standard scaling; 10^10 multiplier.

### 10. Aave RAY (27-dec) → APY checks
RateShockShield compares Aave `currentVariableBorrowRate` (RAY = 1e27) against
an APY threshold. Comparisons stay in RAY space to avoid precision loss.

---

## Potential-breakage list (tested in `MathEdgeCasesUUPS.t.sol`)

| # | Hazard | Mitigation verified |
|---|--------|---------------------|
| 1 | Constants not tampered post-deploy | Read bytecode values and assert. |
| 2 | Premium overflow on large coverage | Explicit revert or graceful min. |
| 3 | Capacity underflow | `<=` check returns 0, never underflows. |
| 4 | Solvency div-by-zero | Returns ULTRA_BPS fallback. |
| 5 | Redeem div-by-zero | Price floored to `MIN_REDEEM_PRICE`. |
| 6 | USDC-6 → LUMINA-18 precision | Always multiply before divide. |
| 7 | Epoch at year boundary | IDs stay within [202600, 210012]. |
| 8 | Distribution sum invariant | All 16 rows sum exactly 10000. |
| 9 | Burn cap boundary | Exactly 5% succeeds, 5%+1 reverts. |
| 10 | Rounding favours protocol | Premium rounds down; redeem rounds down. |
| 11 | Chainlink 8-dec scaling | `×1e10` verified. |
| 12 | Aave RAY threshold | Verified in RAY space. |
| 13 | Reserved capacity no double-count | `totalUsed` sums once. |
| 14 | V5.0 product-duration fix holds | MicroDepeg/RateShock = 604800s (7d). |
| 15 | V5.0 product-ID fix holds | Shield `PRODUCT_ID` matches router config. |

See `REPORT.md` for audit verdict.
