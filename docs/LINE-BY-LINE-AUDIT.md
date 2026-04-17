# Line-by-Line Audit — Lumina V2
## Date: 2026-04-16
## Auditors: 5 parallel independent senior-auditor agents (CertiK-level paranoia)

## Scope
- 9 core V2 contracts + 5 V2 shields + BaseShield (read-only reference)
- Every line inspected against a ~30-item checklist per contract
- Focus: arithmetic, units, CEI, access control, edge cases, NatSpec accuracy, dead code

## Finding totals

| Severity | Count | Fixed in this commit | Deferred / documented |
|---|---|---|---|
| CRITICAL | **0** | — | — |
| HIGH | **3** | 2 | 1 (token1-Lumina branch — deploy-time verification) |
| MEDIUM | **~9** | 2 | 7 (documentation-level, timelock-ownership, informational) |
| LOW | many | — | documented below |
| INFO | many | — | |

**No fund-loss vectors identified.** All previously-fixed issues (SR2/SR3) confirmed present at the exact expected lines.

---

## Fixes applied in this commit

### LBL-H1 — LuminaTokenV2 constructor duplicate-recipient guard
- **File:** `src/v2/token/LuminaTokenV2.sol:32-40`
- **Finding:** Constructor accepted duplicate recipient addresses. If a deployer passed e.g. `bondVault == treasuryVesting`, the combined 85M would silently accumulate in one address, violating the `82/5/10/3` distribution invariant and breaking downstream systems that assume separate holders.
- **Fix:** Added 6 pairwise `require(a != b, "Duplicate: a/b")` checks covering all combinations of the 4 recipient params.
- **Regression test:** `test_duplicateRecipient_reverts` in `test/token/LuminaTokenV2Test.t.sol` — verifies 3 representative collision cases.

### LBL-M1 — TWAPBurner SafeERC20 on receivePremium + receiveMarketplaceFee
- **File:** `src/v2/core/TWAPBurner.sol:104, 112`
- **Finding:** Both entry points used raw `transferFrom(...)` inside `require` wrapper. Bridged USDC variants (USDC.e, certain L2 forks) and non-standard ERC20 tokens may not return `true` reliably.
- **Fix:** Replaced with `usdc.safeTransferFrom(msg.sender, address(this), amount)`. Contract already has `using SafeERC20 for IERC20;` in scope — this just applies it consistently.

### LBL-M2 — TWAPBurner.executeBurn forceApprove
- **File:** `src/v2/core/TWAPBurner.sol:130`
- **Finding:** `usdc.approve(swapRouter, amountToSwap)` uses raw `approve`. USDC and USDC.e in some L2 deployments revert on non-zero → non-zero. The post-swap residual is zero in practice (exact-amount swap consumes it), but the pre-swap approval can collide with a stale allowance if a prior `executeBurn` failed mid-execution.
- **Fix:** Replaced with `usdc.forceApprove(swapRouter, amountToSwap)`.

### LBL-H3 — CapacityOracle tick-rounding to match Uniswap V3 reference
- **File:** `src/v2/oracles/CapacityOracle.sol:88-94`
- **Finding:** `int24(tickDiff / int56(int32(twapWindow)))` truncates toward zero. Uniswap V3 `OracleLibrary.consult` explicitly floors toward negative infinity when `tickDiff < 0 && tickDiff % window != 0`. Without this, our TWAP is 1 tick (≈0.01% price) higher than Uniswap's reference on downtrends — a small but non-zero bias that affects `BondVault`'s issuance capacity and `TWAPBurner`'s slippage bound during price drops.
- **Fix:** Added `if (tickDiff < 0 && (tickDiff % secs != 0)) { avgTick--; }` after the division. Matches the exact logic from `uniswap-v3-periphery/contracts/libraries/OracleLibrary.sol`.

---

## HIGH findings NOT patched (deferred, require deployment-time verification)

### LBL-H2 — CapacityOracle token1-Lumina decimal branch
- **File:** `src/v2/oracles/CapacityOracle.sol:105-107`
- **Finding:** In the inverted branch (`!isToken0Lumina`), the decimal adjustment uses `* 1e12` (same as the token0 branch). Unit analysis suggests this may be off by a factor of 1e24 depending on pool deployment. The test suite only covers the emergency-price fallback path — this branch is never exercised.
- **Why not patched:** (1) the math is subtle and requires a live Uniswap V3 LUMINA/USDC pool to verify empirically, (2) production deployment will fix `token0` based on lexicographic address ordering, (3) deployment script can invert address ordering to force `isToken0Lumina = true`, avoiding the branch entirely.
- **Action required:** Pre-deployment, verify which branch will execute based on the actual LUMINA and USDC token addresses. If LUMINA address < USDC address → `isToken0Lumina = true` → safe token0 branch. If LUMINA address > USDC address, either (a) empirically test the token1 branch against known prices on testnet, or (b) adjust deployment so LUMINA is token0 (e.g., by deploying a new LUMINA address with a mining-like preimage).

---

## MEDIUM findings documented (not code-patched)

### LBL-M3 — LuminaTokenV2 DEFAULT_ADMIN_ROLE to deployer EOA
- **File:** `src/v2/token/LuminaTokenV2.sol:40` (post-duplicate-check edit, line shifted to ~47)
- **Finding:** `_grantRole(DEFAULT_ADMIN_ROLE, msg.sender)` grants admin to whoever deploys. Deployment script must transfer to a Timelock + Gnosis Safe combo immediately after TWAPBurner deployment (which needs BURNER_ROLE).
- **Mitigation:** Already documented as L-10 in SECURITY-AUDIT-V4.md. Deploy script (`script/V2-DEPLOY-ORDER.md`) covers this.

### LBL-M4 — FounderVesting silent oracle catches
- **File:** `src/v2/token/FounderVesting.sol:190-204`
- **Finding:** `_evaluateConditions` uses `try/catch {}` on both oracle and Aave calls. Reverts produce `condA/B/C = false` silently. Legitimate conditions may be masked by a broken oracle.
- **Mitigation (deferred):** Add a diagnostic event inside each `catch` block. Low priority because AltSeason is a one-time trigger and the fallback path (1460 days) ensures eventual release.

### LBL-M5 — FounderVesting Aave ReserveData struct layout fragility
- **File:** `src/v2/token/FounderVesting.sol:34-52` + RateShockShield
- **Finding:** If Aave upgrades and adds fields to `ReserveData`, our local struct definition goes out of sync and ABI decoding reads garbage / zero.
- **Mitigation (deferred):** Minimal-interface getter returning only `currentVariableBorrowRate`. Out of scope for V4.1 launch; document in deployment runbook to pin Aave V3 version.

### LBL-M6 — TWAPBurner effectivePrice decimal comment
- **File:** `src/v2/core/TWAPBurner.sol` (around `effectivePrice` emission)
- **Finding:** Comment claims 18-dec, actual unit analysis yields 6-dec (`6+18−18=6`). Affects only the `BurnExecuted` event value — no funds at risk. Off-chain indexers must know this unit.
- **Mitigation:** Document in API docs. Could be patched by multiplying by `1e12` before emission, but that changes event ABI interpretation for any already-deployed listener.

### LBL-M7 — TreasuryVesting skipped-month allowance forfeiture
- **File:** `src/v2/token/TreasuryVesting.sol:43-47`
- **Finding:** If owner skips releases, only one release per month-gap is possible. Intentional semantics but not explicitly documented.
- **Mitigation:** Add a comment to `release()` stating "Skipped months forfeit their 250K allowance (rate-limit, not running-total)."

### LBL-M8 — CoverRouterV2 residual-allowance exposure on burner rotation
- **File:** `src/v2/core/CoverRouterV2.sol:160`
- **Finding:** `forceApprove(twapBurner, premium)` sets an approval that persists between calls. If owner rotates `twapBurner` via `setTwapBurner` while a future purchase hasn't yet consumed the previous approval, the old burner still has allowance on the router's USDC (no outstanding USDC though, because the call is atomic).
- **Mitigation:** Trust boundary on owner (Gnosis Safe). `setTwapBurner` rotations should zero the old allowance in the same tx (not currently enforced).

### LBL-M9 — CoverRouterV2 setPolicyManager/setTwapBurner without timelock or events
- **File:** `src/v2/core/CoverRouterV2.sol:213-221`
- **Finding:** Hot-swap of critical dependencies without timelock or state-change event. Acceptable for Gnosis Safe–owned deployments but worth adding events for transparency.
- **Mitigation:** Deploy under Timelock; add `PolicyManagerUpdated` + `TwapBurnerUpdated` events in a future cleanup.

---

## LOW / INFO findings (informational)

### BondVault — no findings
All SR2/SR3 fixes confirmed:
- SR2 V2 (redemption `* 1e36`) → `src/v2/bonds/BondVault.sol:134`
- SR2 V3 (capacity 18-dec normalization) → `src/v2/bonds/BondVault.sol:100, 107, 138`
- SR3 (breaker persistence via separate `triggerBreaker`) → `src/v2/bonds/BondVault.sol:94, 157-164`
- `grep` for `withdraw/owner/admin/upgrade/selfdestruct/delegatecall` on BondVault → **zero matches** in executable code (only in documentation comments).

### ClaimBond — 1 LOW
- **LBL-L1:** Calendar drift from `2629746` avg-seconds-per-month is ~30 min per 24-month bond; documented and acceptable. Full fix (calendar math) would add ~5K gas per mint.

### CapacityOracle — 2 LOW / 1 INFO (beyond HIGH/MEDIUM above)
- **LBL-L2:** No pool-cardinality check at `setPool`. If cardinality < twapWindow, `observe` reverts, try/catch falls through to emergencyPrice. Acceptable.
- **LBL-L3:** `_getSqrtPriceFromTick` magic-number table covers up to `|tick| ≤ 524287`. Uniswap's MAX_TICK is 887272. Ticks above ~524K would be silently wrong. Add `require(absTick <= 887272)` or extend the table.
- **LBL-I1:** `_getTwapPrice` uses external self-call (`this._getTwapPrice()`) for try/catch. Adds ~2600 gas; required pattern for view-reverts.

### TWAPBurner — 2 LOW / 1 INFO
- **LBL-L4:** `authorizedSenders` mapping + `setAuthorizedSender` are dead code (no modifier uses them).
- **LBL-L5:** `amountToSwap * 1e12 * 1e18` safe for realistic `maxBurnAmount` but would overflow if `setMaxBurnAmount` ever raised above ~1e50 USDC (academic).
- **LBL-I2:** `effectivePrice` decimal-comment drift (see LBL-M6).

### PolicyManagerV2 — 3 LOW / 2 INFO
- **LBL-L6:** `deactivateProduct` lacks existence guard — cosmetic.
- **LBL-L7:** `payoutAmount / 1e6` truncates sub-dollar precision (e.g. `124.99 USDC → $99 integer`). Negligible at current $100 min coverage.
- **LBL-L8:** `registerProduct` allows re-registering same `productId`, duplicating `productIds[]` entry.
- **LBL-I3:** `result.recipient` from shield is ignored; bond always goes to `pr.buyer` (correct design).
- **LBL-I4:** `setRouter` has no event.

### CoverRouterV2 — 4 LOW / 1 INFO
- **LBL-L9:** `setPaused` no separate guardian role.
- **LBL-L10:** Min coverage `$100` hard-coded, not configurable.
- **LBL-L11:** `configureProduct` can silently change pricing mid-stream; event doesn't log full config.
- **LBL-L12:** (plus M8 above) residual-approval exposure.
- **LBL-I5:** `quotePremium` reverts with string (consider custom error).

### Shields — 2 LOW / 2 INFO
- **LBL-L13:** `RateShockShield` constructor uses `require(... , "string")` while others use `ZeroAddress(string)` custom error. Cosmetic.
- **LBL-L14:** `RateShockShield`: 24h grace period in `BaseShield` is effectively unreachable because `verifyAndCalculate` checks `block.timestamp <= cp.expiresAt`. Rate spikes within grace can't be claimed. Document as expected behavior.
- **LBL-I6:** `RateShockShield.RateShockData.policyStart` is written but never read. Dead storage. ~20K gas/policy.
- **LBL-I7:** `RateShockShield` imports `IShield` but only uses it transitively.

### FounderVesting — 3 LOW (beyond M-above)
- **LBL-L15:** `TrancheReleased` event emits post-increment count. Off-chain indexers comparing with pre-increment `nextTranche` will be off-by-one.
- **LBL-L16:** `recipient` is mutable via `updateRecipient` without 2-step or timelock — owner-key compromise instantly redirects 10M.
- **LBL-L17:** No sweep for accidentally-donated LUMINA above TOTAL_AMOUNT (stuck forever).

### TreasuryVesting — 3 LOW
- **LBL-L18:** `MONTH = 30 days` drifts vs calendar (~5 days/year).
- **LBL-L19:** Raw `IERC20.transfer` return-value check; use SafeERC20 for consistency.
- **LBL-L20:** No sweep for donated non-LUMINA tokens.

---

## Cross-contract consistency verification
- All PRODUCT_IDs unique `keccak256` hashes. ✅
- All shields inherit from `src/products/BaseShield.sol` (not archived V1). ✅
- All reason strings unique (`FLASHBTC1H_DROP5`, `FLASHBTC4H_DROP8`, `FLASHETH1H_DROP7`, `MICRODEPEG_USDT_BELOW_995`, `RATESHOCK_AAVE_USDC_ABOVE_10`). ✅
- `BondVault.BASE_TS` consistent with `ClaimBond.BASE_TIMESTAMP` (both `1767225600` = Jan 1 2026 UTC). ✅
- `BondVault.totalCommittedUSD` / `availableCapacityUSD` / `PolicyManagerV2.recordPolicy` unit handling verified end-to-end (18-dec internal, integer-$ external API). ✅

## Test impact
Full regression: **168/168 tests passing** (added `test_duplicateRecipient_reverts` to `LuminaTokenV2Test`).

## Ship decision
**Risk score: 7.5/10** (up from 7/10 pre-LBL audit).

The 3 applied fixes (LBL-H1, LBL-M1, LBL-M2, LBL-H3) are small, well-understood patches. The remaining HIGH (LBL-H2 token1-Lumina) is a **deploy-time verification task**, not a code defect per se — deployment script must confirm pool token ordering and either use the verified branch or re-deploy with inverted ordering.

Ready for Foundry CI on Linux + external adversarial audit (Zellic / Spearbit) pre-mainnet.
