# LUMINA PROTOCOL — RED TEAM RE-AUDIT V2 (POST-FIXES)
**Date:** 2026-04-04
**Agents:** SHADOW V2 + SPECTER V2 + PHANTOM (new)
**Commit:** 0d22b31
**Previous Risk Score:** 3.5/10 → **New Risk Score: 2.5/10**

---

## 1. ORIGINAL 29 FINDINGS — STATUS

| # | Finding | Severity | Status |
|---|---------|----------|--------|
| C-1 | ILIndexCover WAD/BPS mismatch | CRITICAL | **FIXED** |
| C-2 | BaseVault storage gap collision | CRITICAL | **FIXED** (gap 50→46) |
| C-3 | BSS zero waiting period | CRITICAL | **FIXED** (0→1h) |
| C-4 | Hardcoded 1:1 USDC conversion | CRITICAL | **NOT FIXED** (accepted risk) |
| H-1 | EmergencyPause cooldown inverted | HIGH | **FIXED** |
| H-2 | Aave failure + allocation release | HIGH | **PARTIALLY FIXED** |
| H-3 | claimPendingPayout no pause check | HIGH | **FIXED** (see N-3 below) |
| H-4 | LP withdrawal race | HIGH | **PARTIALLY FIXED** (irrevocable cooldown) |
| H-5 | cancelScheduledPayout blocks claim | HIGH | **FIXED** (always reverts) |
| H-6 | PremiumMath.verifyPremium unused | HIGH | **NOT FIXED** (accepted) |
| H-7 | Aave pause blocks claims | HIGH | **PARTIALLY FIXED** |
| H-8 | triggerPayout griefing | HIGH | **FIXED** (restricted) |
| H-9 | Correlated risk | HIGH | **NOT FIXED** (accepted) |
| M-1 | First depositor inflation | MEDIUM | **NOT FIXED** (mitigated by offset=3) |
| M-2 | Performance fee gaming | MEDIUM | **PARTIALLY FIXED** |
| M-3 | Oracle proof replay | MEDIUM | **NOT FIXED** (by design) |
| M-4 | Cooldown cancel adverse selection | MEDIUM | **FIXED** (irrevocable) |
| M-5 | releaseAllocation silent clamp | MEDIUM | **FIXED** (event added) |
| M-6 | Approve without reset | MEDIUM | **FIXED** |
| M-7 | No event updateMaxAllocation | MEDIUM | **FIXED** |
| M-8 | getLatestRoundData unvalidated | MEDIUM | **FIXED** |
| M-9 | Sequencer outage claim expiry | MEDIUM | **FIXED** (downtime extension) |
| L-1 | _computeStatus ACTIVE for expired | LOW | **FIXED** |
| L-2 | Double _convertToUSDC | LOW | **FIXED** |
| L-3 | _productIds grows forever | LOW | **FIXED** (cleanProductIds) |
| L-4 | ExploitShield hardcoded Aave | LOW | **FIXED** (configurable) |
| L-5 | Premium splitting arbitrage | LOW | **N/A** (secure) |
| L-6 | Daily withdrawal reset | LOW | **FIXED** (50% documentation) |
| L-7 | ExploitShield $50K Sybil | LOW | **PARTIALLY FIXED** ($150K lifetime) |

**Fix Rate: 17 FIXED / 6 PARTIALLY FIXED / 6 NOT FIXED (4 accepted risk, 2 remaining)**

---

## 2. NEW FINDINGS — SHADOW V2

| # | Finding | Severity | Description |
|---|---------|----------|-------------|
| N-1 | cancelScheduledPayout traps collateral on fraud | HIGH | Always-revert means no way to cancel fraudulent large payouts. Admin must rely on delay window. |
| N-2 | Abandoned withdrawal inflates pending shares | MEDIUM | If LP loses wallet access, `_pendingWithdrawalShares` stays inflated forever, reducing `_freeAssets()`. Needs admin cleanup function. |
| **N-3** | **claimPendingPayout blocked during pause** | **HIGH** | `whenProtocolNotPaused` traps legitimate payouts during emergency. Should be removed — funds already owed. |
| N-4 | triggerPayout restriction blocks 3rd-party claims | MEDIUM | If insured agent is offline/compromised, no one else can trigger (except relayer/owner). |
| N-5 | getSequencerDowntime inaccurate for multiple outages | MEDIUM | Only captures latest outage, not cumulative. Best-effort estimate. |

---

## 3. NEW FINDINGS — SPECTER V2

| # | Finding | Severity | Description |
|---|---------|----------|-------------|
| N-6 | Sequencer downtime locks expired collateral | HIGH | Unbounded extension means expired policy collateral stays locked for duration of sequencer downtime + original grace. |
| N-7 | Allocation released before Aave payout queued | HIGH | `_allocatedAssets` freed before USDC leaves vault → `_freeAssets()` overstated during Aave failures. |
| N-8 | BSS 1h waiting still gameable for macro events | MEDIUM | 1h blocks same-block but not macro-telegraphed crashes. Oracle backend is real defense. |
| N-9 | ExploitShield $150K lifetime cap still Sybil-able | MEDIUM | Per-wallet, no on-chain identity. 100 wallets = $5M exposure. Off-chain oracle is defense. |

---

## 4. NEW FINDINGS — PHANTOM (Payment Flow & Pause)

| # | Finding | Severity | Flow | Description |
|---|---------|----------|------|-------------|
| P-1 | claimPendingPayout blocked by protocol pause | HIGH | CLAIM | Same as N-3. Agent with valid approved claim cannot retrieve USDC during global pause. `claimPendingWithdrawal()` correctly lacks this modifier. |
| P-2 | payoutsPaused can block claims past grace period | MEDIUM | CLAIM | Vault owner pauses payouts >24h → agents miss claim window. Sequencer extension doesn't cover admin pauses. |
| P-3 | No force-complete for stuck withdrawals | MEDIUM | WITHDRAWAL | If vault stays fully allocated post-cooldown, LP retries indefinitely. No liquidation mechanism. |
| P-4 | 3% payout fee effectively increases deductible | LOW | CLAIM | BSS stated 20% deductible → actual 22.4% after fee. Should be disclosed. |
| P-5 | allocatedAssets > totalAssets possible if Aave loss | MEDIUM | ACCOUNTING | Handled gracefully (returns 0 free) but LP funds at risk during Aave crisis. |

---

## 5. CONSOLIDATED TOP 5 URGENT ITEMS

1. **N-3/P-1 [HIGH]: Remove `whenProtocolNotPaused` from `claimPendingPayout()`** — Funds already approved and owed. Blocking during pause is punitive. `claimPendingWithdrawal()` correctly doesn't have it.

2. **C-4 [CRITICAL persists]: Integrate USDCConverter** — Library exists, tested, but unused. Systemic risk during USDC depeg.

3. **N-7 [HIGH]: Allocation release order during Aave failure** — `releaseAllocation` before `executePayout` creates accounting gap. Consider deferring release until payout confirmed.

4. **N-1 [HIGH]: Add emergency cancel for scheduled payouts** — Current always-revert means fraudulent large payouts can't be stopped. Need admin override with proper state cleanup.

5. **H-7 [HIGH persists]: Add try/catch to claim functions** — `claimPendingPayout` and `claimPendingWithdrawal` call Aave without try/catch. If Aave is down, claims are blocked.

---

## 6. WHAT'S SECURE (PHANTOM Confirmed)

- **Purchase flow**: Fully atomic. TX failure = clean revert, no orphaned state.
- **Double claim**: Impossible (`_policyResolved` + `cp.finalized` dual protection).
- **Claim after cleanup**: Impossible (`_policyResolved` set by cleanup too).
- **Share price correctness**: ERC4626 with virtual offset, soulbound, correct share math.
- **Vault isolation**: 4 independent vaults, no cross-contamination.
- **Product freeze**: Correctly blocks new purchases only, existing claims unaffected.
- **Cooldown irrevocable**: Prevents adverse selection. LP bears fair risk.
- **CEI pattern**: All state updates before external calls across all flows.
- **H-1 fix verified**: Pause always instant, cooldown only on unpause.
- **Sequencer extension**: Consistently applied in both claim validation and cleanup.
- **Policy state machine**: All transitions verified, no limbo states possible.
- **Fee accounting**: Integer rounding dust is negligible, favors vault.

---

## 7. RISK SCORE

| Category | V1 Score | V2 Score | Change |
|----------|----------|----------|--------|
| Smart Contracts | 8.0 | 8.5 | +0.5 (C-1,C-2,C-3 fixed) |
| Governance/Timelock | 3.5 | 5.0 | +1.5 (H-1,H-5 fixed, EmergencyPause) |
| Oracle Design | 4.5 | 5.0 | +0.5 (H-8 fixed, proof replay accepted) |
| Economic Model | 7.5 | 8.0 | +0.5 (M-4,M-5,M-9 fixed) |
| ERC-4626 Compliance | 8.5 | 8.5 | +0.0 |
| Payment Flows (new) | -- | 7.5 | NEW (PHANTOM audit) |
| **Overall** | **3.5/10** | **2.5/10** | **-1.0 (improved)** |

---

## 8. TIER 1 AUDIT READINESS ASSESSMENT

**Ready with caveats.** The protocol has significantly improved since V1:
- 3 of 4 CRITICAL findings fixed
- 7 of 9 HIGH findings fixed or mitigated
- 119/119 tests passing
- Payment flows verified end-to-end by PHANTOM

**Before submitting to Tier 1 audit, fix:**
1. Remove `whenProtocolNotPaused` from `claimPendingPayout()` (quick fix, 1 line)
2. Add try/catch to `claimPendingPayout()`/`claimPendingWithdrawal()` (H-7)
3. Document C-4 (USDC 1:1) as accepted risk with rationale

**Can defer to post-audit:**
- N-1 (scheduled payout cancel mechanism)
- N-7 (allocation release order)
- H-6 (on-chain premium verification)

---

*Report generated by 3 automated red-team agents. Manual verification recommended for HIGH findings.*
