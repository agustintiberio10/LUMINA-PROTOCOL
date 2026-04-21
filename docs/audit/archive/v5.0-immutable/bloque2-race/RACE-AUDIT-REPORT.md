# LUMINA Protocol V5.0 — Race Condition Audit Report (Bloque 2)

**Date:** 2026-04-19
**Scope:** All core V5.0 contracts — BondVault, CoverRouterV2, PolicyManagerV2, TWAPBurner, LuminaBondMarketplace, CEXLiquidityReserve
**Test file:** `test/audit/race/RaceConditions.t.sol`
**Result:** 30/30 tests passing

---

## Race Condition Inventory (15 identified)

| # | Race Condition | Contracts Involved | Severity | Test Coverage |
|---|---|---|---|---|
| 1 | Two purchases same block, both pass capacity check | CoverRouter, PolicyManager, BondVault | Medium | `test_Race_ConcurrentPurchases_BothSucceed` |
| 2 | Capacity exhaustion only enforced at trigger, not purchase | PolicyManager, BondVault | **High** | `test_Race_ConcurrentPurchases_2ndRevertsCapacityExhausted` |
| 3 | 10 concurrent purchases produce unique IDs | PolicyManager, Shield | Low | `test_Race_ConcurrentPurchases_10Buyers_UniquePolicyIDs` |
| 4 | 10 concurrent triggers all mint ClaimBond NFTs | BondVault, ClaimBond | Medium | `test_Race_ConcurrentTriggers_10PoliciesSameBlock` |
| 5 | totalCommittedUSD accounting under concurrent triggers | BondVault | Medium | `test_Race_ConcurrentTriggers_CommittedUSD_Consistent` |
| 6 | Price oracle drop mid-block causes auto-pause | CoverRouter, PriceOracle | Medium | `test_Race_CircuitBreaker_PriceDropSameBlock` |
| 7 | Price recovery allows immediate purchase | CoverRouter, PriceOracle | Low | `test_Race_CircuitBreaker_PriceRecoversSameBlock` |
| 8 | List + cancel same block, buyer locked out | Marketplace | Medium | `test_Race_Marketplace_ListCancelSameBlock_BuyerReverts` |
| 9 | Two buyers same listing, first-come-first-served | Marketplace | Medium | `test_Race_Marketplace_TwoBuyers_FirstWins` |
| 10 | TWAPBurner cooldown prevents double-burn | TWAPBurner | Medium | `test_Race_TWAPBurner_DoubleBurn_CooldownReverts` |
| 11 | Redeem + burnFromReserves compete for vault balance | BondVault | High | `test_Race_RedeemBurn_BothSucceedSameBlock` |
| 12 | 10 concurrent redeems drain vault correctly | BondVault, ClaimBond | High | `test_Race_10RedeemsSameBlock` |
| 13 | Double settle same policy rejected | PolicyManager | Medium | `test_Race_DoubleSettle_2ndReverts` |
| 14 | Product deactivation + purchase race | PolicyManager, CoverRouter | Medium | `test_Race_DeactivateProduct_PurchaseReverts` |
| 15 | CEX monthly cap enforcement under concurrent allocations | CEXLiquidityReserve | Medium | `test_Race_CEXAllocation_MonthlyCapRace` |

---

## Key Findings

### FINDING 1 (High): Capacity Check Race in PolicyManager

`PolicyManagerV2.recordPolicy()` checks `bondVault.availableCapacityUSD()` but capacity is only consumed when `BondVault.issueBond()` is called during trigger. Two purchases in the same block both pass the capacity check because `totalCommittedUSD` is unchanged until trigger time. The second trigger correctly reverts at the BondVault level, so funds are safe, but the user's premium has already been spent. **Mitigation:** Consider reserving capacity at purchase time, not just trigger time.

### FINDING 2 (Medium): No Marketplace Front-Run Protection

`LuminaBondMarketplace.executeBuy()` is first-come-first-served with no commit-reveal or minimum duration. A buyer's transaction can be front-run by another buyer or by the seller cancelling. The `active` flag and `nonReentrant` guard prevent double-execution, but there is no time lock between list and cancel.

### FINDING 3 (Info): TWAPBurner Cooldown Is Block-Level Effective

The `burnCooldown` (900 seconds) uses `block.timestamp`, which is identical for all transactions in a block. The first `executeBurn()` in a block sets `lastBurnTimestamp`, and any subsequent call in the same block reverts. This is correct behavior.

### FINDING 4 (Info): BondVault 5% Per-TX Cap Compounds Across Transactions

`burnFromReserves` caps at 5% of *current* balance per transaction. Two sequential burns in the same block can burn 5% + 4.75% = ~9.75% of the original balance. This is by design (vault protects per-tx, not per-block).

---

## Self-Quality Audit

**Total tests:** 30
**Substantive tests (interact with 2+ contracts, test real race logic):** 26
**Simpler/structural tests (single-contract edge case):** 4

- `test_Race_BurnFromReserves_5PercentCapRace` — BondVault only, but tests real burn mechanics
- `test_Race_DoublePause_SecondSucceeds` — CoverRouter only, idempotency check
- `test_Race_TWAPBurner_MultiplePremiumsSameBlock` — TWAPBurner only, accounting
- `test_Race_Marketplace_MultipleListingsSameBlock` — Marketplace only, listing creation

**All 30 tests call real deployed contracts.** No pure math tests. Every test function interacts with at least one deployed contract through its public interface.

**Contract coverage:**
- BondVault: 12 tests (issueBond, redeemBond, burnFromReserves, decreaseObligations, totalCommittedUSD)
- CoverRouterV2: 14 tests (purchasePolicy, submitTrigger, setPaused, auto-pause)
- PolicyManagerV2: 14 tests (recordPolicy, triggerPayout, settlePolicy, deactivateProduct)
- LuminaBondMarketplace: 7 tests (list, executeBuy, cancel)
- TWAPBurner: 4 tests (executeBurn, receivePremium, cooldown)
- CEXLiquidityReserve: 2 tests (allocate, monthly cap)
- ClaimBond: 12 tests (mint via issueBond, burn via redeem, balanceOf, setApprovalForAll)

---

## Verdict

The LUMINA V5.0 protocol handles same-block race conditions correctly at the contract level. The `nonReentrant` guards, `active` flags, and cooldown mechanisms prevent all tested double-execution and reentrancy vectors. The one notable finding (capacity check race) is mitigated at the BondVault layer but can cause premium loss for users whose policies pass purchase but fail at trigger time.

**Recommendation:** Add a capacity reservation mechanism at purchase time in PolicyManagerV2 to prevent users from paying premiums for policies that cannot be backed.
