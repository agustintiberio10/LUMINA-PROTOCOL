# Sprint Migrate Legacy Tests — 2026-05-25

**Trigger:** After the Red-Team (Sprint Fix 7.2) and Manual-Review (Sprint Fix 7.3) fixes landed on `main`, the broad legacy test suite (`test/audit/`, `functional/`, `integration/`, `fuzz/`, `products/`, `shields/`, `simulation/`, `stress/`, …) was still **red** — those suites encoded PRE-fix behavior and were never migrated (documented as red-team V2 pending item #3). CI `build`/`CI` had been failing on `main` since the #155 merge (~284 fails), and PR #158 added ~70 more from its own intentional behavior changes (~354 total).

**Scope:** TESTS ONLY — no `src/` changes, no PR merge. Mechanical migration of test expectations/mocks/setups to the new behaviors. Branch `feat/migrate-legacy-tests` (off `main` 78c112e).

**Result:** ✅ **Full non-Fork suite GREEN** (~1,900 tests, 0 failures), verified per-folder at `FOUNDRY_OPTIMIZER_RUNS=1` (the full-suite `forge test` hangs on the Windows host — chunked by folder). 2 obsolete tests removed. **No real contract bugs found.**

---

## Patterns migrated

| # | Cause (fix) | Migration |
|---|-------------|-----------|
| 1 | **F-01** multi-block confirmation | Shield triggers now need 3 sub-barrier observations in distinct blocks, ≥60s apart, after `start + MIN_DWELL_PERIOD` (5min). Added a `_drive3Confirmations` helper (captures base block once + ABSOLUTE rolls — avoids a via_ir `block.number` caching gotcha; fresh oracle round per obs). |
| 2 | **F-03** window-expiry | `verifyAndCalculate`/`checkAndSettlePolicy` on an expired window now SETTLES false (returns `WINDOW_EXPIRED`) instead of reverting → tests assert the return. |
| 3 | **F-03** markExpired | `markExpired` re-evaluates the shield and reverts `PolicyTriggerable` if still triggerable → mock shields given a `shouldTrigger`/`setTriggerResult` toggle, set false for genuine-expiry tests. |
| 4 | **F-02** fail-closed redeem | Redeem at/below `MIN_REDEEM_PRICE` (raised 0.001→0.005e18) reverts `ORACLE_UNAVAILABLE` (no longer "uses the floor") → floor-use tests flipped to assert the revert; fuzz price bounds raised above the floor. |
| 5 | **F-08 / F-01** gating | `createPolicy`/`verifyAndCalculate` `onlyPolicyManager`; `checkAndSettlePolicy` `onlyKeeperOrRelayer` → tests prank the wired authority; the obsolete "IsPermissionless" test reworked to assert the gate. (Adapter remaps `SEQUENCER_DOWN`/`ORACLE_STALE`→`ORACLE_UNAVAILABLE`.) |
| 6 | **F-14** pull-payment | Marketplace seller proceeds go to `pendingWithdrawals` → tests call `withdraw()` (pranked as seller) before asserting balances; wash-trade test nets to fees after withdraw. |
| 7 | **F-18** obligation sync | `ClaimBond.burnByHolder` decrements vault obligations (BuybackEngine no longer does it directly) → `setAuthorizedCaller(ClaimBond, true)` wired; sim mock claimbond forwards `decreaseObligations`. |
| 8 | **F-19** TWAPBurner oracle | Burn-path `minOut` derives from the capacity oracle and reverts `"TWAPBurner: oracle unset"` without one → `setCapacityOracle(mock)` wired in burn-exercising setUps. |
| 9 | **F-23 / F-10** caps | Coverage > $10k reverts `InvalidCoverage`; per-user redeem capped at 10% of epoch cap → amounts bounded / asserted reverts; fuzz `bound()` to valid ranges. |
| 10 | **MR-H01** freshness gate | `getLuminaPrice` reverts on stale/thin pool → mock Uniswap pools report `observationCardinality >= 10` and add `observations()` with a fresh timestamp. |
| 11 | **MR-M01** payout ratio | `configureProduct` requires `payoutRatioBps == 8000`. |
| 12 | **MR-M04** buyback gate | `executeOffer` `onlyRole(BUYBACK_OPERATOR_ROLE)` → tests prank the operator. |

## Tests removed (obsolete, not migrated)

- `test/auto-burn/AutoBurn.t.sol`: the two tests asserting the **synchronous in-purchase auto-burn + `tx.origin` gas refund** — that path was removed by F-13/F-22 (burn is now async via `executeBurn()`/`autoBurnReady()`). Documented in-file with `// [legacy-migration] removed:`.

## Execution

Migration done with the main thread + parallel sub-agents per folder cluster (edits only; a shared `migration-playbook.md` defined each pattern's fix). Verification serial per-folder (parallel `forge` builds OOM the host). Per-folder green counts: products 48, audit 1016, functional 61, integration 36 (+19 Fork skipped), shields 32, simulation 20, stress 14, fuzz 20, unit 184, core 88, marketplace 33, oracles 37, treasury 42, token 33, deploy 17, auto-burn 6, automation 8, redteam-fixes+manual-review-fixes 81.

**No real contract bugs surfaced** — every failure traced to a test expectation/mock/setup encoding pre-fix behavior.

## Verdict

CI build should now be GREEN on this branch. Closes the legacy-migration debt (red-team V2 pending item #3). PR `feat/migrate-legacy-tests` (draft). No PR merged.
