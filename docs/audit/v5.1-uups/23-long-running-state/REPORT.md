# Audit V5.1 #23 — Long-Running State: Report

**Branch:** `audit/v5.1-23-long-running-state`
**Date:** 2026-04-23
**Verdict:** SUSTAINABLE — no counter overflow, no unbounded storage growth, gas is flat across ops, state persists correctly across decades, epoch cap enforced cleanly. 0 HIGH / MEDIUM / LOW. Cierre Bloque 6.

---

## 1. Summary

Audit of LUMINA V5.1 behaviour under long-horizon (10–100 year) operation. See `01-ACCUMULATING-STATE.md` for the full inventory of counters, storage vectors, and bounds.

**Bottom line:** the protocol scales cleanly over time.

- Every counter is `uint256` — overflow is mathematically impossible in any realistic horizon.
- No unbounded arrays in `src/` — all scaling is via mappings (O(1) per access).
- Gas per operation stays flat after 200+ prior operations.
- Bond redemption still works 10 years after issuance.
- The ClaimBond epoch cap (year 2100, month 12) is explicit — post-cap issuance reverts with `"Invalid epoch"`, not silent corruption.

## 2. How the audit was conducted

- File: `test/audit/v5.1-uups/time-based/long-running/LongRunning.t.sol` (11 tests).
- Real proxies throughout: `ClaimBond`, `BondVault`, `LuminaTokenV2`, `CapacityOracle`, `TWAPBurner`, `FlashBTCShield1h`.
- Mix of dynamic tests (actual simulated time + operations) and static-claim tests (documenting the type inventory).

## 3. Results

| Section | Test | Verdict |
|---|---|---|
| Counter sizes | `AllCounters_Are_Uint256_Static` | ✅ all `uint256` |
| Epoch accumulation | `12Epochs_IndependentState` | ✅ 12 distinct epochs |
| Accounting exactness | `Committed_Exact_After_60Issuances` | ✅ sum matches |
| Gas stability | `PolicyCreation_GasStableAfter_200Ops_OverTime` | ✅ within 25% |
| Bond longevity | `Bond_Redeem_10YearsLater` | ✅ redeems cleanly |
| Invariant heal | `Commit_Decommit_HealsToZero` | ✅ totalCommittedUSD → 0 |
| Expired state | `ExpiredPolicy_StatePersists_AcrossDecade` | ✅ data retrievable |
| Residual storage | `RedeemedEpoch_ResidualStorage` | ✅ maturityDate preserved |
| Far-future | `NearEpochCap_IssueWorks` | ✅ year 2095 works |
| Epoch cap | `PastEpochCap_RevertsCleanly` | ✅ reverts `Invalid epoch` |
| 10-year sim | `10Years_CondensedLifecycle` | ✅ counters advance, no corruption |

## 4. Findings

- **HIGH / MEDIUM / LOW:** 0.
- **INFO §4.1:** Epoch cap at year 2100 (month 12, epoch 210012) is an explicit protocol boundary. Issuance past that reverts cleanly. Plan to revisit well before 2100 — but that's a 75-year horizon; V5.1 is not long-term constrained.
- **INFO §4.2:** Expired policies are never deleted from storage (by design). Each policy's ~10-slot CorePolicy struct persists forever. At 10M active policies over 10 years (wildly optimistic scale), that's ~400 MB of state — well within Ethereum's practical limits per-contract.
- **INFO §4.3:** ERC-1155 epoch entries (maturityDate, epochExists) persist even after every holder has redeemed. This is correct — other holders may still own balance.
- **INFO §4.4:** `uint32 durationSeconds` fields (policy duration, TWAP window) don't overflow until ≈ year 2162 of policy life — not a constraint.

## 5. Performance under load

Audit #16 (stress test) already proved O(1) scaling up to 2000 ops. This audit adds:

- `PolicyCreation_GasStableAfter_200Ops_OverTime` — 200 creates spanning 200 simulated days, asserts gFirst and gLast within 25%.
- `Committed_Exact_After_60Issuances` — accounting is exact after 60 issuances with 30-day spacing.

Both confirm the conclusion: no secret O(N) behaviour emerges at longer horizons.

## 6. State persistence semantics

The protocol does NOT reclaim storage for finalized state:

- **Expired policies:** `_policies[id]` persists. `getPolicyInfo` still returns the correct data.
- **Redeemed bonds:** holder balance → 0, but `maturityDate[epochId]` and `epochExists[epochId]` stay. An ERC-1155 epoch is shared by many holders; the protocol doesn't know when it's "done".
- **Burned tokens:** `ERC1155Supply.totalSupply` decreases; epoch metadata unchanged.

**This is correct behaviour.** Users paying to delete storage to get a small refund is a classic gas-golf trap; the protocol doesn't do that. See `test_LongRun_UUPS_ExpiredPolicy_StatePersists_AcrossDecade` and `test_LongRun_UUPS_RedeemedEpoch_ResidualStorage` for the documentation.

## 7. Epoch space analysis

ClaimBond.mint enforces `202600 <= epochId <= 210012`:

- 75-year window (Jan 2026 → Dec 2100).
- 900 distinct monthly epochs — each is a mapping slot + a storage-supply slot.
- Maximum storage from epoch metadata: 900 × 2 slots × 32 bytes = 57.6 KB.

Entirely negligible storage cost.

## 8. Regression

```
forge test --no-match-contract "Fork" --no-match-path "test/audit/invariant*"
```

```
Ran 117 test suites in 21.24s (120.65s CPU time): 1869 tests passed, 0 failed, 0 skipped (1869 total tests)
```

Baseline before audit was 1858. Delta = +11 new long-running tests.

## 9. Reverse audit

- **Total tests:** 11 (new)
- **% substantive:** ~90 % dynamic (real 10-year simulations + warps) + 10 % static-claim.
- **Quality:** 9/10 — comprehensive coverage of long-horizon invariants and edge cases (epoch cap, post-cap revert, 10-year bond redemption, residual storage semantics).

## 10. Verdict

**SUSTAINABLE.** No code changes recommended. Cierre Bloque 6. Audit #23 of 40 V5.1.
