# Reverse Audit: PR #32 Rounding Tests

**Purpose:** Verify if the 30 claimed rounding tests are real or inflated.

## Test-by-Test Classification

| # | Test Name | Classification | Quality | Notes |
|---|---|---|---|---|
| 1 | test_premium_rounding_odd_coverage | REAL | 8/10 | Tests non-clean division with actual CoverRouter call |
| 2 | test_premium_rounding_minimum_coverage | REAL | 7/10 | Actual quotePremium call, checks >= 1 |
| 3 | test_premium_favors_protocol | REAL | 7/10 | 10 coverages iterated, verifies floor |
| 4 | test_redemption_rounding_nonclean_price | REAL | 9/10 | Best test: $0.13, verifies floor, checks user <= owed |
| 5 | test_redemption_rounding_clean_price | REAL | 8/10 | Exact conversion at $0.10 verified |
| 6 | test_redemption_protocol_keeps_dust | REAL | 7/10 | Vault dust retention checked |
| 7 | test_marketplace_fee_nonclean_price | REAL | 7/10 | Fee floor at $333 |
| 8 | test_marketplace_fee_small_price | REAL | 8/10 | $1 fee -- catches rounding to 0 |
| 9 | test_marketplace_fee_conservation | REAL | 8/10 | Wei conservation verified |
| 10 | test_marketplace_fees_sum_to_burner | REAL | 7/10 | Full flow, fees to burner |
| 11 | test_distribution_rounding_dust_stays | REAL | 7/10 | 4-bucket split dust check |
| 12 | test_distribution_dust_bound | REAL | 7/10 | Non-clean amounts |
| 13 | test_distribution_accumulated_dust | REAL | 6/10 | 100 iters but mock-based |
| 14 | test_solvency_ratio_rounds_down | REAL | 7/10 | Conservative floor check |
| 15 | test_solvency_near_threshold_boundary | REAL | 6/10 | Mock oracle based |
| 16 | test_burn_cap_rounds_down | REAL | 7/10 | Non-round balance cap |
| 17 | test_burn_cap_exact_boundary | REAL | 8/10 | 5% exact + 5%+1 reverts |
| 18 | test_vesting_tranche_rounding | REAL | 7/10 | 8M/3 remainder = 2 wei |
| 19 | test_treasury_vesting_no_rounding | REAL | 6/10 | 250K exact (trivially true but valid) |
| 20 | test_cross_operation_full_lifecycle_dust | REAL | 7/10 | Multi-step lifecycle dust |
| 21 | test_cross_operation_dust_under_100_wei | REAL | 6/10 | Similar to #20 |
| 22 | test_premium_near_zero_enforces_minimum | REAL | 7/10 | Low-prob product |
| 23 | test_redemption_multiple_accumulate_dust | REAL | 8/10 | 10 non-round redemptions |
| 24 | test_solvency_zero_obligations_max | **INFLATED** | 3/10 | Pure if/else, no contract call |
| 25 | test_burn_cap_tiny_balance | **TRIVIAL** | 3/10 | Pure math (1*5)/100, no contract |
| 26 | test_burn_cap_boundary_19_wei | **TRIVIAL** | 4/10 | Pure math, no contract |
| 27 | test_distribution_partial_bps | REAL | 5/10 | Math test, no TWAPBurner |
| 28 | test_payout_rounding | REAL | 6/10 | Payout floor verified |
| 29 | test_capacity_safety_factor_rounding | REAL | 5/10 | CapacityOracle view |
| 30 | test_effective_price_rounding | REAL | 6/10 | Price consistency |

## Summary

| Metric | Count |
|---|---|
| Total claimed | 30 |
| Real substantive tests | **24** |
| Inflated (no contract call) | **1** (#24) |
| Trivial (pure math) | **2** (#25, #26) |
| Moderate (math-only, limited value) | **3** |
| **Honest quality** | **6.5/10** |

## Report Accuracy

- "30 tests" -- 27 are real, 3 are trivial/inflated (**PARTIALLY ACCURATE**)
- "0 bugs found" -- **HONEST** (verified)
- "All rounding favors protocol" -- **ACCURATE** (verified in real tests)
- Rounding direction matrix -- **ACCURATE**
- Dust accumulation claims use mocks, **less rigorous than implied**

## Verdict

**PR adds real value but has ~10% padding.** 24 of 30 tests call actual contracts with meaningful assertions. 3 tests (#24, #25, #26) are pure Solidity math with no contract interaction -- they should be replaced with actual contract-level tests.

The core findings are honest: no rounding bugs, protocol-favored direction, dust bounded. The padding doesn't change the conclusions but overstates the rigor.
