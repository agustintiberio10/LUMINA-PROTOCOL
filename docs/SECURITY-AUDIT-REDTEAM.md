# LUMINA PROTOCOL — RED TEAM SECURITY AUDIT
**Date:** 2026-04-04
**Agents:** SHADOW (Code Vulnerability Hunter) + SPECTER (Business Logic Exploit Hunter)
**Commit:** a557cef
**Risk Score: 3.5/10** (where 10 = totally insecure)

---

## EXECUTIVE SUMMARY

| Severity | SHADOW (Code) | SPECTER (Logic) | Combined (deduped) |
|----------|--------------|-----------------|---------------------|
| CRITICAL | 3 | 3 | 4 |
| HIGH | 7 | 5 | 9 |
| MEDIUM | 8 | 3 | 9 |
| LOW | 4 | 5 | 7 |
| **TOTAL** | **22** | **16** | **29** |

---

## TOP 5 MOST URGENT FINDINGS

### 1. [CRITICAL] ILIndexCover WAD vs BPS Unit Mismatch — Broken Payout Calculation
**Found by:** Both SHADOW and SPECTER independently
**Contract:** ILIndexCover.sol:_doVerifyAndCalculate():165-183

`ILMath.calculateIL()` returns IL in WAD (1e18 = 100%) but ILIndexCover treats it as BPS (1e4 = 100%). The deductible check `ilBps <= DEDUCTIBLE_BPS(200)` compares WAD ~5.72e16 against 200, making the deductible effectively zero. Any price movement triggers a payout. The subsequent multiplication produces astronomically large numbers (caught by maxPayout cap, but math is fundamentally broken).

**Impact:** Every IL policy with any price movement pays out maximum. Deductible non-functional.
**Fix:** `uint256 ilBps = ILMath.calculateIL(...) * BPS / WAD;`

### 2. [CRITICAL] BaseVault Storage Gap Collision Risk
**Found by:** SHADOW
**Contract:** BaseVault.sol:85-97

Variables (`payoutsPaused`, `performanceFeeBps`, `feeReceiver`, `userCostBasisPerShare`, `emergencyPause`) declared AFTER `__gap[50]` without reducing the gap. Future upgrades using gap slots will overwrite these variables.

**Impact:** Storage corruption on future upgrades — fees, pause state, cost basis destroyed.
**Fix:** Reduce `__gap` to `uint256[44]` or adopt ERC-7201 namespaced storage.

### 3. [CRITICAL] BSS Zero Waiting Period — Same-Block Front-Running
**Found by:** SPECTER
**Contract:** BlackSwanShield.sol

`WAITING_PERIOD = 0` allows buying BSS and triggering in the same block during a crash. Attacker sees crash developing, buys policy, collects 80% payout.

**Impact:** $800K+ profit on a single front-run ($1M coverage, ~$4K premium).
**Fix:** Add minimum waiting period (1-24 hours) to BSS.

### 4. [CRITICAL] Hardcoded 1:1 USDC Conversion — Depeg Breaks Protocol
**Found by:** Both agents
**Contract:** CoverRouter.sol:785-792

`_convertToUSDC()` returns `usdAmount` unmodified. During USDC depeg (historical: $0.87 in March 2023), entire protocol accounting breaks. `USDCConverter` library exists but is unused.

**Impact:** Systemic — all premiums, payouts, and vault accounting incorrect during depeg.
**Fix:** Integrate `USDCConverter.usdToUSDCStrict()` for premiums, `usdToUSDCSafe()` for payouts.

### 5. [HIGH] EmergencyPause Cooldown Direction Inverted
**Found by:** SHADOW
**Contract:** EmergencyPause.sol:75-89

Cooldown prevents RE-PAUSING after unpause, not re-unpausing. An attacker who forces an unpause creates a window where the protocol cannot be paused again.

**Impact:** Protocol vulnerable during cooldown window after premature unpause.
**Fix:** Move cooldown to unpause action, not pause.

---

## ALL FINDINGS — ORDERED BY SEVERITY

### CRITICAL (4)

| # | Finding | Agent | Contract |
|---|---------|-------|----------|
| C-1 | ILIndexCover WAD/BPS unit mismatch | Both | ILIndexCover.sol |
| C-2 | BaseVault storage gap collision | SHADOW | BaseVault.sol |
| C-3 | BSS zero waiting period front-running | SPECTER | BlackSwanShield.sol |
| C-4 | Hardcoded 1:1 USDC conversion | Both | CoverRouter.sol |

### HIGH (9)

| # | Finding | Agent | Contract |
|---|---------|-------|----------|
| H-1 | EmergencyPause cooldown direction inverted | SHADOW | EmergencyPause.sol |
| H-2 | Aave failure + allocation release = under-collateralization | SHADOW | BaseVault.sol/CoverRouter.sol |
| H-3 | `claimPendingPayout` no emergency pause check | SHADOW | BaseVault.sol |
| H-4 | LP withdrawal race before large payout | SPECTER | BaseVault.sol |
| H-5 | `cancelScheduledPayout` permanently blocks claim | Both | CoverRouter.sol |
| H-6 | `PremiumMath.verifyPremium()` exists but never called on-chain | SPECTER | CoverRouter.sol |
| H-7 | Aave V3 pause blocks claim functions (no try/catch) | SPECTER | BaseVault.sol |
| H-8 | `triggerPayout` permissionless — griefing via rate limit consumption | SHADOW | CoverRouter.sol |
| H-9 | Correlated risk — simultaneous all-product trigger drains vaults | SPECTER | Systemic |

### MEDIUM (9)

| # | Finding | Agent | Contract |
|---|---------|-------|----------|
| M-1 | First depositor inflation (partially mitigated by offset=3) | SHADOW | BaseVault.sol |
| M-2 | Performance fee cost basis gaming via timed deposits | Both | BaseVault.sol |
| M-3 | Oracle proof replay across policies (by design, but amplifies oracle compromise) | SHADOW | All Shields |
| M-4 | Cooldown cancel/re-request adverse selection | SPECTER | BaseVault.sol |
| M-5 | `releaseAllocation` silently clamps underflows | SHADOW | PolicyManager.sol |
| M-6 | `deposit()` approve without reset to 0 | SHADOW | BaseVault.sol |
| M-7 | No event for `updateMaxAllocation` | SHADOW | PolicyManager.sol |
| M-8 | `getLatestRoundData` view returns unvalidated data | SHADOW | LuminaOracle.sol |
| M-9 | Gas spike / sequencer outage > 24h = claim expiry | SPECTER | Systemic |

### LOW (7)

| # | Finding | Agent |
|---|---------|-------|
| L-1 | `_computeStatus` returns ACTIVE for expired policies | SHADOW |
| L-2 | Double `_convertToUSDC` computation in `purchasePolicyFor` | SHADOW |
| L-3 | `_productIds` array grows monotonically (no removal) | SHADOW |
| L-4 | ExploitShield Aave V3 pool address hardcoded | SHADOW |
| L-5 | No premium splitting arbitrage (confirmed secure) | SPECTER |
| L-6 | Daily withdrawal limit reset timing | SPECTER |
| L-7 | ExploitShield $50K cap bypassable via Sybil | SPECTER |

---

## WHAT IS SECURE (Why Attacks Fail)

1. **Reentrancy:** `nonReentrant` on all entry points + soulbound shares
2. **Oracle L2 Protection:** Sequencer uptime feed + 1h grace + per-feed staleness
3. **UUPS Safety:** `_disableInitializers()` in all constructors, `_authorizeUpgrade` = `onlyOwner`
4. **EIP-712:** Correct domain separator with fork detection, nonce tracking, deadline
5. **Flash Loan:** Deposits require real USDC transfer, cooldowns prevent instant withdrawal
6. **Sandwich:** Soulbound shares prevent secondary market manipulation
7. **Vault Isolation:** 4 independent vaults with separate TVL, allocation, and share prices
8. **Dual Trigger:** ExploitShield requires both oracle + Phala TEE attestation
9. **TOCTOU Defense:** `recordAllocation` re-verifies all caps independently of `canAllocate`

---

## RECOMMENDATIONS FOR PRE-TIER-1 AUDIT HARDENING

1. **Fix C-1 immediately** — ILIndexCover unit mismatch makes IL product non-functional
2. **Fix C-3** — Add BSS waiting period (minimum 1 hour)
3. **Fix H-1** — Invert EmergencyPause cooldown direction
4. **Fix H-5** — Reset `_policyResolved` on `cancelScheduledPayout`
5. **Add `__gap` to PolicyManager and CoverRouter** (currently missing entirely)
6. **Integrate `USDCConverter`** — Even if 1:1 now, oracle-aware conversion is defense-in-depth
7. **Call `PremiumMath.verifyPremium()` on-chain** — Don't rely solely on oracle signature
8. **Add try/catch to `claimPendingPayout`/`claimPendingWithdrawal`**
9. **Increase `_decimalsOffset` to 6** for stronger first-depositor protection
10. **Document accepted risks** — oracle proof replay, 2/3 multisig centralization, USDC depeg

---

*Report generated by automated red-team agents. Manual verification recommended for all CRITICAL and HIGH findings before remediation.*
