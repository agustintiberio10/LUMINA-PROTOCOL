# V5.1 Aave V3 Usage Inventory

**Audit:** V5.1 #12 — Aave V3 Integration
**Branch:** `audit/v5.1-12-aave-integration`
**Date:** 2026-04-22

---

## 1. Where Aave V3 is consumed

### 1.1 RateShockShield (UUPS)
- `_doVerifyAndCalculate` — reads `aavePool.getReserveData(usdc).currentVariableBorrowRate` on-chain at settlement.
- `_checkTriggerCondition` — same read, in a view helper for keepers.
- `currentBorrowRate()` — public view returning current rate.
- **No try/catch.** Aave revert propagates to caller.
- Trigger: `currentRate > TRIGGER_RATE` where `TRIGGER_RATE = 10e25` (10% APY in RAY).

### 1.2 FounderVesting (IMMUTABLE, not UUPS)
- `_evaluateConditions` — reads Aave pool for Condition C:
  `data.currentVariableBorrowRate > BORROW_RATE_THRESHOLD` where
  `BORROW_RATE_THRESHOLD = 7e25` (7% APY in RAY).
- **Wrapped in try/catch.** Aave revert → `condC = false` (graceful).
- The oracle reads (Conditions A & B) are also try/catch-wrapped.

---

## 2. Aave interface used

```solidity
interface IAaveV3Pool {
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;   // ← we read this
        uint128 currentStableBorrowRate;
        uint40  lastUpdateTimestamp;         // ← NOT checked for staleness
        uint16  id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 accruedToTreasury;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }
    function getReserveData(address asset) external view returns (ReserveData memory);
}
```

Both RateShockShield and FounderVesting declare this interface
identically and use only `currentVariableBorrowRate`.

---

## 3. Units: RAY (1e27) comparisons

Aave expresses per-second rate × time-to-APY as RAY:
- `10e25` RAY = 10% APY
- `7e25` RAY  = 7%  APY
- `TRIGGER_RATE` (RateShock) = 10e25 RAY
- `BORROW_RATE_THRESHOLD` (FounderVesting) = 7e25 RAY

Comparisons stay entirely in RAY space — no conversion is required. This
avoids any precision loss that a `ray → 18-dec` conversion would
introduce.

---

## 4. Failure modes mapped to contract behaviour

| Failure | RateShockShield | FounderVesting |
|---------|-----------------|-----------------|
| `getReserveData` reverts (Aave pause / deprecated) | Settlement revert (no try/catch) | `condC = false` (try/catch) |
| Rate returns 0 | `>`-strict: no trigger | No condition C |
| Rate extremely high (e.g. 200% APY) | Trigger fires correctly | Condition C met |
| Pool address changes | Shield needs upgrade (address is state after UUPS migration) | FV is immutable → permanent loss of Condition C |
| Reserve paused | Aave reverts with `RESERVE_FROZEN` etc. | `condC = false` |
| `lastUpdateTimestamp` is old | **NOT CHECKED** — stale rate accepted | Same |
| Rate = `type(uint128).max` | Trigger fires (outlier accepted) | Condition C met (outlier accepted) |

---

## 5. Thresholds & boundaries

| Threshold | Value | Strict | What happens at exact value |
|-----------|-------|--------|------------------------------|
| `RateShockShield.TRIGGER_RATE` | `10e25` | `>` (strict) | Exactly 10e25 does NOT trigger; 10e25+1 does. |
| `FounderVesting.BORROW_RATE_THRESHOLD` | `7e25` | `>` (strict) | Exactly 7e25 does NOT meet condC; 7e25+1 does. |

Both use strict `>`, consistent with each other.

---

## 6. Known limitations (to document in REPORT.md)

- **No staleness check.** Neither contract verifies
  `lastUpdateTimestamp`. Aave's `currentVariableBorrowRate` is updated
  on every deposit/borrow/repay interaction, so on an active reserve
  this is normally fresh. If the reserve is paused or otherwise has no
  activity, the rate can be stale. Impact: low (if Aave is paused, the
  rate is whatever it was last; this is acceptable for a 7-day insurance
  window).
- **No sanity bounds on the rate.** A rate of 1000% APY would be
  accepted. Unlike price oracles (audit #11 / fix M-01), there is no
  reasonable upper bound on borrow rates in a distressed market.
  Recommendation: optional `MAX_RATE_APY = 100_000_000_000_000_000 RAY`
  (100%) as a sanity bound — or explicitly not, since a legitimate
  crisis could exceed 100%.
- **FounderVesting immutability** means a permanent Aave failure (e.g.
  Aave V3 fully deprecated, pool address retired) would force AltSeason
  to trigger only on 2-of-3 evaluations of conditions A & B. Fallback
  at T+1460 days still releases the 8M LUMINA.

See `REPORT.md` for the verdict and test-level verification.
