# V5.1 MEV / Front-Running Vectors Inventory

**Audit:** V5.1 #10 — Front-running / MEV
**Branch:** `audit/v5.1-10-front-running`
**Date:** 2026-04-22

---

## 1. Vectors catalogued

### 1.1 TWAPBurner sandwich attack
- **Hazard:** MEV bot sees `executeBurn()` in the mempool, manipulates
  LUMINA/USDC price before the swap.
- **Mitigation:** `maxSlippageBps` (50–1000 bps range) enforces a hard
  slippage floor; the swap reverts if the actual slippage exceeds it.
- **Residual risk:** Cost equal to maxSlippage × burn amount per
  successful attack. Tests: `test_FrontRun_TWAPBurner_SlippageCap_Enforced`,
  `test_FrontRun_TWAPBurner_SlippageRange_Bounded_To_1000Bps`.

### 1.2 CapacityOracle flash-loan manipulation
- **Hazard:** Flash-loan drives Uniswap V3 pool price within a block.
- **Mitigation:** CapacityOracle reads a TWAP over `twapWindow` (300–7200 s),
  not spot price. A 30-minute TWAP absorbs single-block pool manipulation.
- **Residual risk:** Sustained manipulation (> 5 minutes) would shift the
  TWAP proportionally; requires continuous capital commitment. Tests:
  `test_FrontRun_CapacityOracle_TwapWindow_RangeEnforced`.

### 1.3 Policy entry-price fixing
- **Hazard:** Bot observes a large policy purchase, manipulates price, and
  profits from subsequent trigger miscalculation.
- **Mitigation:** Entry price is captured at `createPolicy()` time and
  stored in `BSSData.strikePrice`. No one can re-assign it post-purchase.
  Tests: `test_FrontRun_Shield_StrikePrice_FixedAtCreation`.

### 1.4 BuybackEngine overpay
- **Hazard:** MEV bot lists a bond at price 99% of face value, expecting
  BuybackEngine to buy at any price up to 99%.
- **Mitigation:** `maxPricePercent` is capped at 95 by the setter guard.
  No listing above 95% can be bought by the engine.
- **Tests:** `test_FrontRun_BuybackEngine_MaxPct_95Cap_Enforced`.

### 1.5 BuybackEngine budget drain
- **Hazard:** Bot spams listings at 94% to drain the daily buyback budget.
- **Mitigation:** Daily budget is admin-configured and finite. Once
  `spentToday >= dailyBudget`, no more buybacks execute that day.
- **Tests:** `test_FrontRun_BuybackEngine_Budget_NonZero_Finite`.

### 1.6 Settlement back-run
- **Hazard:** Trigger condition met at block T. Bot sees trigger in
  mempool, back-runs to purchase bonds on secondary marketplace at
  discount before settlement reflects.
- **Mitigation:** `SafetyWindow` on PolicyManager — settlement is not
  immediate; users have a 24 h window during which the trigger is verified
  and finalized. ClaimBond only mints on finalized settlement.
- **Residual risk:** If a bot has edge info on trigger validity (e.g.
  controls oracle feed), it can buy bonds between trigger and finalization.
  Real oracle (Chainlink pull) mitigates this substantially. Tests:
  `test_FrontRun_PolicyManager_SettlementIsNotAtomic_WithPurchase`.

### 1.7 Capacity reservation MEV
- **Hazard:** Bot front-runs a large policy by reserving tiny amounts
  repeatedly to force the target tx to revert.
- **Mitigation:** PR #37 fix makes reservation atomic within
  `recordPolicy`. A hostile reservation requires being the PolicyManager
  (restricted) — normal users cannot call `reserveCapacity` directly.
- **Residual risk:** If PolicyManager upgrades to allow external callers,
  griefing becomes possible. Currently mitigated by `onlyPolicyManager`.
  Tests: `test_FrontRun_BondVault_ReserveCapacity_OnlyPolicyManager`.

### 1.8 Pause front-run
- **Hazard:** Bot sees admin `pause()` in mempool; submits large value
  extraction before pause mines.
- **Mitigation:** Standard EVM gas auction. Admin can increase gas / use
  private relay (Flashbots) to mine the pause tx first. This is an
  operational mitigation, not a code one.
- **Residual risk:** Acknowledged. Recommendation: admin uses Flashbots
  Protect when submitting pause ops on mainnet.

### 1.9 Upgrade front-run
- **Hazard:** Bot sees upgrade in mempool; front-runs to exploit V1
  before V2 installs.
- **Mitigation:** Same as above — gas auction + timelock (recommended
  48h pre-mainnet per audit #4).
- **Residual risk:** If no timelock, admin must use Flashbots Protect.

### 1.10 Chainlink oracle manipulation
- **Hazard:** N/A — Chainlink is pull-based with consensus across
  multiple oracle nodes. Cannot be front-run.
- **Mitigation:** Inherent to Chainlink design.
- **Residual risk:** Chainlink node operator collusion (out of scope).

---

## 2. Mitigations in code

1. **TWAP window** on CapacityOracle (30 min default, 5min–2h range).
2. **Max slippage** on TWAPBurner (50–1000 bps range, enforced on setter).
3. **Max price percent** on BuybackEngine (1–95, enforced on setter).
4. **Daily budget** on BuybackEngine (admin-set per-day ceiling).
5. **Entry price fixing** in shields at `createPolicy` time.
6. **Capacity reservation** atomic within `recordPolicy` (PR #37).
7. **Pause flag** on CoverRouterV2, ShieldKeeper.
8. **ReentrancyGuard** on all state-mutating externals (audit #9).

---

## 3. Recommended operational mitigations (not in code)

1. **Flashbots Protect** for admin operations (pause, upgrade, role grants).
2. **Private mempool relay** for large TWAPBurner executes.
3. **Commit-reveal** for proposals > $1M coverage (future feature).
4. **MEV monitoring** via a sentinel watching for sandwich patterns.
5. **48-h timelock** on admin ops (blocker pre-mainnet per audit #4).

See `REPORT.md` for the full verdict and raw test output.
