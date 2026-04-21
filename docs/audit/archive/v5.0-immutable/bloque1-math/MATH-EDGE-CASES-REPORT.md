# LUMINA Protocol V5.0 - Math Edge Cases Audit Report

**Bloque 1** | Branch: `audit/v5-bloque1-math-edge-cases`
**Date:** 2026-04-19 | **Auditor:** Automated + Manual Review
**Test file:** `test/audit/math/MathEdgeCases.t.sol`

---

## 1. Math Operations Inventory

| # | Contract | Operation | Formula / Description |
|---|----------|-----------|----------------------|
| 1 | CoverRouterV2 | Premium calculation | `coverage * payoutRatioBps * triggerProbBps * marginBps / (10000^3)` |
| 2 | CoverRouterV2 | Payout calculation | `coverage * payoutRatioBps / 10000` |
| 3 | BondVault | LUMINA redemption amount | `usdAmount * 1e36 / currentPrice` |
| 4 | BondVault | Capacity check (reserve value) | `reserveBalance * currentPrice / 1e18` |
| 5 | BondVault | Max commitment | `reserveValueUSD * SAFETY_FACTOR_BPS / 10000` |
| 6 | BondVault | totalCommittedUSD tracking | `+= usdPayout * 1e18` (18-dec USD-wei) |
| 7 | BondVault | Burn cap enforcement | `currentBalance * 5 / 100` |
| 8 | BondVault | Epoch calculation | `_timestampToEpoch: (ts - BASE_TS) / 2629746` |
| 9 | ClaimBond | Maturity timestamp | `BASE_TIMESTAMP + monthsFromBase * 2629746` |
| 10 | TWAPBurner | 4-bucket distribution | `amount * bps / 10000` per bucket |
| 11 | TWAPBurner | Effective burn price | `usdcAmount * 1e18 / luminaReceived` |
| 12 | LuminaBondMarketplace | Seller/buyer fees | `priceUSDC * 150 / 10000` (1.5% each) |
| 13 | SolvencyOracle | Solvency ratio (bps) | `(valueUSD * 10000) / obligations` |
| 14 | CapacityOracle | Max policies/day | `maxCommitUSD / (MATURITY_DAYS * dailyCommitUSD) / 1e18` |
| 15 | CEXLiquidityReserve | Linear vesting | `VESTING_AMOUNT * elapsed / VESTING_DURATION` |
| 16 | CEXLiquidityReserve | Monthly cap | `monthlyAllocations[month] + amount <= MONTHLY_CAP` |
| 17 | TreasuryVesting | Month calculation | `(timestamp - deployedAt - LOCK_DURATION) / 30 days` |
| 18 | FounderVesting | Tranche amount | `TOTAL_AMOUNT / TOTAL_TRANCHES` (last gets remainder) |
| 19 | CapacityOracle | TWAP price from tick | `sqrtPriceX96^2 * 1e18 >> 192 * 1e12` |

---

## 2. Test Coverage by Category

| Category | Tests | Status | Key Findings |
|----------|-------|--------|--------------|
| 1. Overflow | 5 | ALL PASS | Max $10M coverage fits uint256. `type(uint256).max` inputs revert cleanly via Solidity overflow. |
| 2. Underflow | 4 | ALL PASS | All underflow paths guarded: bonds check balance, `decreaseObligations` checks committed, `totalCommittedUSD` uses safe floor-to-zero pattern. |
| 3. Division by Zero | 5 | ALL PASS | Solvency returns `type(uint256).max` when obligations=0. Oracle price=0 falls back to `MIN_REDEEM_PRICE`. Zero BPS params yield minimum premium of 1. |
| 4. Precision Loss | 5 | ALL PASS | Premium > 0 for minimum $100 coverage ($0.24). Distribution dust <= 3 wei for odd amounts. Integer division always rounds down (protocol-favored). |
| 5. Decimal Mismatch | 4 | ALL PASS | USDC 6-dec to LUMINA 18-dec conversion correct via `1e36` scaling. `totalCommittedUSD` stored as 18-dec USD-wei. Oracle prices consistently 18-dec. |
| 6. Boundary Conditions | 6 | ALL PASS | Min coverage $100 works; $99.999999 reverts. 5% burn cap enforced exactly. Sequential burns recalculate against new balance. |
| 7. Epoch Arithmetic | 4 | ALL PASS | Epoch calculation correct from BASE_TS through 2050+. Month boundaries cross cleanly. Maturity timestamps match stored values. |
| 8. Oracle Edge Cases | 3 | ALL PASS | Price=0 triggers fallback. Very small ($0.001) and very large ($1000) prices compute exact LUMINA amounts. |

**Total: 36 tests, 36 passing, 0 failing.**

---

## 3. Bugs Found

### No Critical or High-Severity Bugs

All math operations in the audited contracts are correctly implemented:

- **V3/SR2 fix confirmed**: `totalCommittedUSD` uses 18-dec USD-wei consistently across issuance, redemption, and capacity checks.
- **V2/SR2 fix confirmed**: LUMINA redemption formula `usdAmount * 1e36 / price` correctly scales integer-dollar bonds to 18-dec LUMINA wei.
- **Premium floor**: `if (premium == 0) premium = 1` prevents zero-premium policies.
- **Safe price fallback**: `_getSafePrice()` returns `MIN_REDEEM_PRICE` on oracle failure or zero price.
- **Underflow guard**: `totalCommittedUSD` uses `>= commitmentToRemove ? subtract : set to 0` pattern.

### Informational Notes

| ID | Severity | Description |
|----|----------|-------------|
| I-1 | Info | TWAPBurner 4-bucket distribution can lose up to 3 wei of dust per execution (rounding truncation). Dust remains in the contract and is included in the next burn cycle. |
| I-2 | Info | `FounderVesting.TRANCHE_AMOUNT = 8M / 3 = 2,666,666.666...e18` truncates. Last tranche uses `TOTAL_AMOUNT - totalReleased` to capture the 2-wei remainder. Correctly handled. |
| I-3 | Info | `CapacityOracle.maxPoliciesPerDay()` divides by `1e18` at the end, which truncates sub-integer policy counts to 0 for very low LUMINA prices. This is conservative behavior. |

---

## 4. Verdict

**PASS** - All 19 math operations across 8 contracts have been verified for overflow, underflow, division-by-zero, precision loss, decimal mismatch, boundary conditions, epoch arithmetic, and oracle edge cases. No exploitable math bugs found. The V3/SR2 and V2/SR2 fixes for unit scaling are correctly applied. Integer division consistently favors the protocol (rounding down on payouts). The system is arithmetically sound for deployment.
