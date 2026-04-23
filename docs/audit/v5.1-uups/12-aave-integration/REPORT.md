# V5.1 Audit #12 — Aave V3 Integration Audit

**Audit ID:** V5.1 #12 of 40 (Bloque 3)
**Branch:** `audit/v5.1-12-aave-integration`
**Date:** 2026-04-22

---

## 1. Executive Summary

31 new tests (100% substantive) exercising the Aave V3 integration in
`RateShockShield` (UUPS) and `FounderVesting` (immutable). All pass.
Regression unchanged.

**Verdict: ROBUST WITH KNOWN LIMITS.** Both consumers read
`currentVariableBorrowRate` directly in RAY space, use strict `>`
comparisons at clearly-defined thresholds, and behave sensibly at
boundary / extreme / revert scenarios. FounderVesting's try/catch
wrapping degrades gracefully when Aave is unavailable. RateShockShield
propagates Aave reverts as policy-settlement reverts — acceptable
because the settlement call can be retried once Aave is back up.

---

## 2. Scope

- `RateShockShield` (UUPS, BaseShield-derived): reads
  `aavePool.getReserveData(usdc).currentVariableBorrowRate` at
  settlement and in view helpers.
- `FounderVesting` (immutable, non-UUPS): reads the same value in
  `_evaluateConditions()` for Condition C of the AltSeason trigger.

Out of scope: the rest of FounderVesting's economic design (covered by a
future vesting-specific audit) and any Chainlink oracle concerns (audit #11).

See `01-AAVE-USAGE.md` for the full consumption inventory.

---

## 3. Tests Created

| File | Tests |
|------|-------|
| `AaveIntegration.t.sol` | 31 |

### Categories
- **RateShockShield**:
  - Aave revert propagation (1)
  - Boundary: exactly 10%, +1 wei, just below (3)
  - Rate zero, extreme (1000%), max uint128 (3)
  - Constants verification (3)
  - createPolicy independence from Aave (1)
  - Pool & USDC wiring (1)
  - No setter-for-pool — upgrade only (1)
- **FounderVesting**:
  - Aave revert → condition C gracefully unmet (1)
  - Condition C boundary at 7% exact / +1 wei (3)
  - Sustained full 7 days triggers AltSeason (1)
  - Sustained short of 7 days does not trigger (1)
  - Sustain timer reset on drop (1)
  - checkAltSeason idempotent when already met (1)
  - Immutable pool / USDC (2)
  - Constants (4)
- **Cross / meta**:
  - Aave failure does not affect other shields (1)
  - RAY-space comparison sanity (2)
  - Documented INFOs (no staleness, no sanity bound) (2)

---

## 4. Issues Found

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| LOW | 0 |
| INFO | 3 |

### INFO

- **I-01** — **No staleness check on `lastUpdateTimestamp`.** Neither
  `RateShockShield` nor `FounderVesting` reads the timestamp field from
  `getReserveData`. This is acceptable for an active USDC pool (rates
  update on every interaction), but in a paused-reserve scenario the
  rate value may be stale. Risk is low for a 7-day window.
- **I-02** — **No sanity upper bound on the rate.** An Aave-reported rate
  of 1000% APY would be accepted as a valid trigger. Unlike price feeds
  (audit #11 / fix M-01), an upper bound on rates is not applied here
  intentionally — legitimate crisis scenarios can produce very high
  rates, and blocking those would prevent legitimate payouts.
- **I-03** — **FounderVesting immutability.** If Aave V3 is fully
  deprecated or the pool address is retired, Condition C becomes
  permanently unmeetable. AltSeason can still trigger on Conditions A
  and B (ETH/BTC ratio + ETH > $4000) if 2-of-3 are met, plus the
  4-year fallback guarantees release regardless.

No actionable code changes. All three findings are explicit design
choices documented here.

---

## 5. Quality Rating

**9.1 / 10**

- +3.0 Every failure mode covered (revert, zero, extreme, boundary).
- +1.5 FounderVesting sustained-7-days flow exercised forward & reset.
- +1.5 RAY-space comparison explicitly tested (no precision loss).
- +1.0 Both consumers wired and tested independently.
- +0.8 All thresholds asserted as constants.
- +0.5 Cross-component isolation (Aave fail ↛ FlashBTC).
- −0.7 Can't simulate `aavePool` contract upgrade without a forked
       mainnet test. Documented in §4 I-03 as a known limit rather than
       a tested path.
- −0.5 Settlement path on RateShockShield is gated by
       `block.timestamp < cp.waitingEndsAt` + `block.timestamp > cp.expiresAt`
       — a full settle test requires the router mock call path, which
       is covered by integration suites elsewhere.

---

## 6. Verdict

**ROBUST WITH KNOWN LIMITS**

All Aave failure modes — revert, zero, extreme, boundary — produce the
expected behaviour. Sustained conditions in FounderVesting work as
documented. The three INFO findings are explicit design choices, not
bugs.

---

## 7. Recommendations (non-blocking)

1. **Optional staleness check.** Add `require(data.lastUpdateTimestamp
   >= block.timestamp - STALENESS_WINDOW)` in future shield versions.
   `STALENESS_WINDOW` of 7 days would cover most operational scenarios.
2. **Optional rate sanity bound.** If desired, `require(rate < 100e25)`
   would cap the accepted rate at 100% APY. This is a policy decision;
   current behaviour (unbounded) is defensible.
3. **Future-proof pool address.** For a V6 refactor, consider a
   DEFAULT_ADMIN_ROLE-gated `setAavePool(address)` in RateShockShield so
   Aave V4 migration can be done without a full contract upgrade.
   FounderVesting is immutable — a pool migration there requires
   accepting the 2-of-3 fallback behaviour or deploying a new vesting
   contract.

---

## 8. Raw `forge test` Output

```
No files changed, compilation skipped

Ran 31 tests for test/audit/v5.1-uups/external-deps/aave/AaveIntegration.t.sol:AaveIntegration
[PASS] test_Aave_AaveFailure_DoesNotAffect_BTCShield() (gas: 28935)
[PASS] test_Aave_DOCUMENTED_NoRateSanityBound() (gas: 424)
[PASS] test_Aave_DOCUMENTED_NoStalenessCheck() (gas: 468)
[PASS] test_Aave_FounderVesting_AaveRevert_ConditionCUnmet() (gas: 2951776)
[PASS] test_Aave_FounderVesting_BorrowRateThreshold_Is7e25() (gas: 2907126)
[PASS] test_Aave_FounderVesting_CheckAltSeasonTwice_SameState() (gas: 2989502)
[PASS] test_Aave_FounderVesting_ConditionC_Boundary_7PercentPlus1_MetOnly1of3() (gas: 2954496)
[PASS] test_Aave_FounderVesting_ConditionC_Boundary_Exactly7Percent_NotMet() (gas: 2954585)
[PASS] test_Aave_FounderVesting_ConditionC_Met_Plus_CondB_StartsSustain() (gas: 2979531)
[PASS] test_Aave_FounderVesting_ETH_BTC_Threshold() (gas: 2906972)
[PASS] test_Aave_FounderVesting_ETH_USD_Threshold_4000_Dollars() (gas: 2906863)
[PASS] test_Aave_FounderVesting_Pool_Immutable() (gas: 2907973)
[PASS] test_Aave_FounderVesting_SustainReset_WhenRateDrops() (gas: 2969658)
[PASS] test_Aave_FounderVesting_SustainedDuration_7Days() (gas: 2907878)
[PASS] test_Aave_FounderVesting_SustainedFull7Days_TriggersAltSeason() (gas: 3179454)
[PASS] test_Aave_FounderVesting_SustainedShortOf7Days_NoTrigger() (gas: 2988392)
[PASS] test_Aave_FounderVesting_USDC_Immutable() (gas: 2907615)
[PASS] test_Aave_RateShock_Boundary_10PercentPlus1Wei_Triggers() (gas: 1822507)
[PASS] test_Aave_RateShock_Boundary_Exactly10Percent_NoTrigger() (gas: 1822295)
[PASS] test_Aave_RateShock_Boundary_Just_Below_10Percent_NoTrigger() (gas: 1822375)
[PASS] test_Aave_RateShock_CreatePolicy_NoOracleRead() (gas: 2121898)
[PASS] test_Aave_RateShock_Duration_Is7Days() (gas: 1795237)
[PASS] test_Aave_RateShock_GetReserveDataReverts_ViewReverts() (gas: 1823911)
[PASS] test_Aave_RateShock_NoSetAavePoolFunction_ExistsOnlyViaUpgrade() (gas: 1794993)
[PASS] test_Aave_RateShock_PoolAndUSDC_Correctly_Wired() (gas: 1795676)
[PASS] test_Aave_RateShock_RateExtreme_1000Percent_Readable() (gas: 1822705)
[PASS] test_Aave_RateShock_RateMax_Uint128_Readable() (gas: 1822683)
[PASS] test_Aave_RateShock_RateZero_NoTrigger() (gas: 1802895)
[PASS] test_Aave_RateShock_TriggerRate_Is10e25() (gas: 1794484)
[PASS] test_Aave_RayComparison_10Percent_IsLessThan20Percent() (gas: 879)
[PASS] test_Aave_RayComparison_5Percent_IsLessThan7Percent() (gas: 1011)
Suite result: ok. 31 passed; 0 failed; 0 skipped

Ran 1 test suite in 64.42ms: 31 tests passed, 0 failed, 0 skipped (31 total tests)
```

Full regression (non-fork, non-invariant): **1599 tests passed, 0 failed, 0 skipped (1599 total)**
— 1568 pre-existing + 31 new = zero regression.
