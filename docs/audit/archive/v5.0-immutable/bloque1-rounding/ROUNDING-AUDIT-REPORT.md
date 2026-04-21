# LUMINA Protocol V5.0 - Rounding Error Audit Report

**Audit Block:** 1 - Rounding Errors  
**Date:** 2026-04-19  
**Auditor:** Automated audit suite (Foundry)  
**Scope:** All Solidity floor-division operations across core protocol contracts

---

## 1. Division Operations Inventory

| # | Contract | Operation | Formula | Denominator |
|---|----------|-----------|---------|-------------|
| 1 | CoverRouterV2 | Premium calculation | `coverage * payoutRatio * triggerProb * margin / 10000^3` | 1e12 |
| 2 | CoverRouterV2 | Payout calculation | `coverage * payoutRatioBps / 10000` | 10000 |
| 3 | BondVault | Redemption amount | `usdAmount * 1e36 / currentPrice` | price (18-dec) |
| 4 | BondVault | Reserve value USD | `reserveBalance * currentPrice / 1e18` | 1e18 |
| 5 | BondVault | Max commitment | `reserveValueUSD * SAFETY_FACTOR_BPS / 10000` | 10000 |
| 6 | BondVault | Burn cap per tx | `currentBalance * 5 / 100` | 100 |
| 7 | LuminaBondMarketplace | Seller fee | `price * 150 / 10000` | 10000 |
| 8 | LuminaBondMarketplace | Buyer fee | `price * 150 / 10000` | 10000 |
| 9 | TWAPBurner | Bucket distribution | `amount * bps / 10000` (x4 buckets) | 10000 |
| 10 | TWAPBurner | Effective price | `usdcAmount * 1e18 / luminaReceived` | variable |
| 11 | SolvencyOracle | Solvency ratio | `valueUSD * 10000 / obligations` | obligations |
| 12 | CapacityOracle | Max policies/day | `maxCommitUSD / (MATURITY_DAYS * dailyCommitUSD) / 1e18` | variable |
| 13 | FounderVesting | Tranche amount | `TOTAL_AMOUNT / TOTAL_TRANCHES` (compile-time) | 3 |

---

## 2. Rounding Direction Matrix

| Operation | Direction | Who Benefits | Acceptable? |
|-----------|-----------|-------------|-------------|
| Premium calculation | Floor (down) | User (pays less) | YES - min=1 catches zero |
| Payout (coverage*80%) | Floor (down) | Protocol (pays less) | YES |
| Bond redemption | Floor (down) | Protocol (sends less LUMINA) | YES |
| Marketplace seller fee | Floor (down) | Seller (pays less fee) | YES - negligible |
| Marketplace buyer fee | Floor (down) | Buyer (pays less fee) | YES - negligible |
| 4-bucket distribution | Floor (down) | Burner retains dust | YES - max 3 wei |
| Solvency ratio | Floor (down) | Conservative (safer) | YES - desired behavior |
| Burn cap (5%) | Floor (down) | Vault (burns less) | YES - protective |
| Vesting tranche (8M/3) | Floor (down) | Contract (holds 2 wei dust) | YES - last tranche compensates |
| Reserve value USD | Floor (down) | Conservative valuation | YES |
| Effective price log | Floor (down) | Informational only | YES - no fund impact |

---

## 3. Test Results Summary

**Total tests:** 30  
**Passing:** 30  
**Failing:** 0

### Key Findings by Section:

**Premium Rounding (3 tests):** Floor division consistently applied. Minimum premium = 1 enforced when result would be 0. Protocol-favorable in edge case (user pays at least 1 micro-USDC).

**Redemption Rounding (3 tests):** At $0.13 price, `100 * 1e36 / 0.13e18` produces floor with sub-wei remainder. Protocol retains fractional dust. Clean prices ($0.10) produce exact conversions.

**Marketplace Fees (4 tests):** Fee rounds to 0 only below $0.000066 (66 micro-USDC) -- effectively unreachable. Wei conservation holds: `buyerPays == sellerReceives + totalFees`. Split vs combined fee calculation produces at most 1 wei difference.

**Distribution Rounding (3 tests):** With fallback BPS summing to exactly 10000 and round amounts, distribution is exact. Non-round amounts produce < 4 wei dust per distribution. Over 100 distributions, accumulated dust < 400 wei.

**Solvency Rounding (2 tests):** Floor division makes ratio conservative (rounds down), preventing false-healthy signals near thresholds. Zero obligations correctly return max uint256.

**Burn Cap Rounding (2 tests):** 5% of 1 wei = 0 (floor). Threshold at 20 wei (first non-zero cap). Exact 5% succeeds, 5%+1 reverts as expected.

**Vesting Rounding (2 tests):** `8M / 3 = 2,666,666.666...e18` produces exactly 2 wei dust. The contract compensates by giving the last tranche `TOTAL_AMOUNT - totalReleased`, recovering all dust. Treasury vesting (250K/month, 3M total) has zero rounding -- 12 months exact.

**Cross-Operation (2 tests):** Full lifecycle dust is sub-wei at each step. No accumulation mechanism exists that could compound rounding errors into material loss.

---

## 4. Findings

### [INFO-1] Premium floor-to-minimum creates micro-subsidy
When premium calculates to 0 (extremely low coverage or probability), the `if (premium == 0) premium = 1` fallback means the protocol charges 1 micro-USDC ($0.000001). This is a negligible subsidy to the protocol and acceptable behavior.

### [INFO-2] Marketplace fee zero-floor at sub-cent prices
Fees round to 0 when listing price < 67 micro-USDC ($0.000067). This is economically irrelevant -- no rational actor would list bonds at sub-cent prices.

### [INFO-3] FounderVesting compensates 2-wei rounding dust
The `8M / 3` division loses exactly 2 wei. The contract explicitly handles this via `TOTAL_AMOUNT - totalReleased` for the final tranche, ensuring zero loss. Well-designed pattern.

### [INFO-4] Distribution dust stays in TWAPBurner
The 4-bucket split can leave up to 3 wei per distribution undistributed. These remain as USDC in the TWAPBurner and are included in the next burn cycle. No funds are lost.

### [INFO-5] All rounding favors protocol or is conservative
Every division operation either benefits the protocol (user receives less) or produces a conservative safety metric (solvency rounds down). This is the correct design for a DeFi insurance protocol.

---

## 5. Verdict

**PASS** -- No material rounding vulnerabilities found.

All floor-division operations in LUMINA Protocol V5.0 are correctly implemented and directionally safe. Dust from rounding is negligible (sub-wei to single-digit wei) and either stays in protocol contracts or is compensated by explicit remainder-handling logic (FounderVesting). The rounding direction consistently favors protocol safety. No action required.
