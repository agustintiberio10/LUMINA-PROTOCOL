# Audit V5.1 #23 — Long-Running State: Inventory

**Target:** LUMINA Protocol V5.1 behaviour under 10–100 year operation.
**Date:** 2026-04-23

---

## 1. Counters and their types

| Counter | Type | File | Overflow at |
|---|---|---|---|
| `BaseShield._policyCounter` | `uint256` | BaseShield.sol:68 | 10^77 — never |
| `PolicyManagerV2.totalPolicies` | `uint256` | PolicyManagerV2.sol:72 | 10^77 — never |
| `LuminaBondMarketplace.nextListingId` | `uint256` | LuminaBondMarketplace.sol:51 | 10^77 — never |
| `BondVault.totalCommittedUSD` | `uint256` (18-dec USD wei) | BondVault.sol | 10^77 — never |
| `BondVault.totalReservedUSD` | `uint256` | BondVault.sol:55 | 10^77 — never |
| `TWAPBurner.totalUSDCReceived` | `uint256` | TWAPBurner.sol | 10^77 — never |
| `TWAPBurner.totalUSDCBurned` | `uint256` | TWAPBurner.sol | 10^77 — never |
| `TWAPBurner.totalLUMINABurned` | `uint256` | TWAPBurner.sol | 10^77 — never |

**All counters use `uint256`.** No counter overflow possible in any realistic horizon.

## 2. Non-counter smaller integers (reviewed)

| Field | Type | Use | Issue? |
|---|---|---|---|
| `IShield.CreatePolicyParams.durationSeconds` | `uint32` | policy duration (max ≈ 136 years) | no — 136-year duration cap is way beyond any product |
| `CoverRouterV2.ProductConfig.durationSeconds` | `uint32` | product duration | no |
| `CapacityOracle.twapWindow` | `uint32` | TWAP window (max ≈ 136 years) | no — TWAP window is always minutes |
| Uniswap V3 / Aerodrome interface params | `uint160`, `uint16`, etc. | required by external spec | no |

No field that increments over time uses a smaller-than-uint256 type.

## 3. Storage-growth vectors

| Pattern | File | Status |
|---|---|---|
| `mapping(uint256 => CorePolicy)` in BaseShield | per-shield policy storage | O(1) access, no iteration |
| `mapping(uint256 => Listing)` in Marketplace | listings | O(1) access |
| `mapping(uint256 => uint256) maturityDate` in ClaimBond | per-epoch | O(1) access; bounded by max 85 epochs (2026–2100) |
| `ERC1155 balances` in ClaimBond | per-holder, per-epoch | O(1) access |
| `BondVault` accounting | scalar counters | no growth |
| Keeper batch | `uint256[] policyIds` param | bounded by `MAX_POLICIES_PER_UPKEEP` |

**No unbounded arrays in `src/`.** All scaling is via mappings.

## 4. Epoch-space bounds

ClaimBond enforces `epochId >= 202600 && epochId <= 210012` (line 70):

- Lower bound: Jan 2026
- Upper bound: Dec 2100 (epoch 210012)
- Total epochs: 75 years × 12 months = 900 possible epochs.

Post-2100 issuance reverts with `"Invalid epoch"`. Verified by `test_LongRun_UUPS_PastEpochCap_RevertsCleanly`.

## 5. State that persists indefinitely (by design)

- Expired policies: no cleanup function; `getPolicyInfo` still returns their data.
- Redeemed bonds: ERC-1155 balance drops to zero, but the epoch's `maturityDate` and `epochExists` flags remain (other holders may still hold balance in the same epoch).
- Burned tokens: `totalSupply` decreases (via `ERC1155Supply`) but the epoch entry persists.

This is correct behaviour — the protocol doesn't try to reclaim storage it doesn't own.

## 6. Dynamic tests exercised

| Test | Property |
|---|---|
| `10Years_CondensedLifecycle` | 60 iterations × 2 months of purchases + burns |
| `PolicyCreation_GasStableAfter_200Ops_OverTime` | gas flat across 200 ops over 200 simulated days |
| `12Epochs_IndependentState` | 12 monthly bond issuances → distinct epochs |
| `Committed_Exact_After_60Issuances` | accounting exact after 60 issuances spanning 5 years |
| `Bond_Redeem_10YearsLater` | issue, warp 10 years, redeem — state intact |
| `Commit_Decommit_HealsToZero` | full lifecycle → totalCommittedUSD = 0 |
| `ExpiredPolicy_StatePersists_AcrossDecade` | policy data retrievable after 10 years |
| `RedeemedEpoch_ResidualStorage` | maturityDate preserved after holder redeems |
| `NearEpochCap_IssueWorks` | year 2095 issuance works |
| `PastEpochCap_RevertsCleanly` | year 2103 issuance reverts with `Invalid epoch` |
| `AllCounters_Are_Uint256_Static` | pins the type inventory |

## 7. Findings (preview — see REPORT)

- 0 HIGH / MEDIUM / LOW severity.
- INFO: Epoch cap at year 2100 (month 12) is explicit; post-cap issuance reverts cleanly.
- INFO: `uint32 durationSeconds` is fine (max ≈ 136-year policy duration — well past any realistic product).
