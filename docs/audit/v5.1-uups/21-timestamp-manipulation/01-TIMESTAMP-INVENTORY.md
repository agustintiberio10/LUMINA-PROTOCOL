# Audit V5.1 #21 — Timestamp Manipulation: Inventory

**Target:** `src/` — every `block.timestamp` dependency.
**Date:** 2026-04-23

---

## 1. Raw inventory

`grep block.timestamp src/ → 78 occurrences across 22 files`.

Highest-concentration files (relevant to this audit's attack surface):

| File | Hits | Purpose |
|---|---|---|
| `src/products/BaseShield.sol` | 8 | policy lifecycle (`waitingEndsAt`, `expiresAt`, `cleanupAt`, `_computeStatus`, safety-window gate, etc.) |
| `src/oracles/SolvencyOracle.sol` | 7 | evaluation interval |
| `src/token/FounderVesting.sol` | 12 | tranches, altSeason-sustain |
| `src/token/TreasuryVesting.sol` | 7 | monthly cap reset |
| `src/core/TWAPBurner.sol` | 5 | `lastBurnTimestamp` + `burnCooldown` |
| `src/products/*Shield*.sol` | 2 each | product-specific policy data (strike price, etc.) |
| `src/core/PolicyManagerV2.sol` | 3 | policy record timestamps |
| `src/bonds/ClaimBond.sol` | 2 | per-epoch maturity computation |
| `src/bonds/BondVault.sol` | 1 | `maturityTimestamp = block.timestamp + BOND_MATURITY_SECONDS` |
| `src/marketplace/BuybackEngine.sol` | 2 | `dailyConfig.validUntil` |
| `src/marketplace/LuminaBondMarketplace.sol` | 2 | listing expiration checks |
| others (CEX reserve, adapters, maintenance) | ≤ 5 each | less security-critical |

## 2. Critical constants

| Constant | Value | Source |
|---|---|---|
| `CLAIM_GRACE_PERIOD` | 24 hours | `BaseShield` — `cleanupAt = expiresAt + 24h` |
| `SAFETY_WINDOW` | 24 hours | `BaseShield` — gate on `checkAndSettlePolicy` |
| `BOND_MATURITY_SECONDS` | 730 days | `BondVault` — bond maturity offset |
| `burnCooldown` (default) | 900 s | `TWAPBurner` — mutable (60 s – 86 400 s) |
| `BOND_VAULT_BASE_TS` / `ClaimBond BASE_TIMESTAMP` | `1_767_225_600` (Jan 1 2026 UTC) | both contracts — epoch math origin |
| `ClaimBond` seconds/month | `2_629_746` | avg per-month divisor |

## 3. Test-covered boundaries

| Boundary | Test |
|---|---|
| Policy ACTIVE → EXPIRED at `expiresAt` | `Policy_ActiveExactlyUntilExpiresAt` |
| `checkAndSettlePolicy` gate at `expiresAt + SAFETY_WINDOW` | `CheckAndSettle_RejectedBeforeSafetyWindow`, `_ExactBoundary_Succeeds` |
| `verifyAndCalculate` gate at `expiresAt + CLAIM_GRACE_PERIOD` | `VerifyAndCalculate_ExactlyAtCleanup_Reverts`, `_JustInsideCleanup_PassesStatusCheck` |
| Bond maturity at exactly 730 days | `Bond_NotMatured_Before730Days`, `Bond_MaturedAtExactMaturityDate` |
| Epoch transitions (ClaimBond monthly boundary) | `Epoch_ConsecutiveMonthsDiffer`, `Epoch_SameCalendarMonth_SameEpoch` |
| TWAPBurner cooldown at 900 s | `TWAPBurn_JustBeforeCooldown_Reverts`, `_ExactlyAtCooldown_Succeeds` |
| Small sequencer nudge (12 s) cannot flip state | `SmallNudge_CannotFlipPolicyStatus`, `_CannotCrossSafetyWindow` |
| Far-future timestamp (year 2096+) works | `FarFuture_Year2096_StillWorks` |
| Constant coherence (CLAIM_GRACE = SAFETY_WINDOW = 24h) | `ClaimGrace_And_SafetyWindow_Are24h` |
| Same-block policy creation → identical expiry | `CreatePolicy_SameBlock_SameTimestamp` |
| Later-block policy creation → later expiry | `CreatePolicy_LaterBlock_LaterExpiry` |
| Policy status is monotonic with time | `PolicyStatus_MonotonicWithTime` |

## 4. Out of this audit's scope

- **`FounderVesting` / altSeason-sustained logic**: complex state machine handled in Blocks 2/7. This audit validates the simpler policy / bond / cooldown boundaries.
- **`TreasuryVesting` monthly cap**: same — separate vesting audit.
- **`PolicyManagerV2`**: its timestamps mirror BaseShield's (tested transitively via shield tests).

## 5. Findings (preview — see REPORT)

- 0 HIGH / MEDIUM / LOW severity.
- Boundaries behave exactly as documented: `>=` for gate-open, strict `<` for gate-closed — no off-by-one.
- Small (≤ 12 s) sequencer-level manipulation cannot cross any critical boundary in isolation (verified by two tests).
- Epoch math handles same-month and cross-month cases correctly.
- Far-future timestamps (year 2096+) do not overflow any arithmetic in src/.
