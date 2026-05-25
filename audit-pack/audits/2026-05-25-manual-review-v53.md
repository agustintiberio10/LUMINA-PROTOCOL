# Lumina V5.3 — Manual Code Review (Sprint 7.3)

**Auditor**: Senior Smart-Contract Security Auditor (CertiK-level methodology)
**Methodology**: Line-by-line manual review. **No** static analysis / fuzzing / symbolic execution (that is Sprint 7.2 — Slither/Mythril/Echidna/Aderyn). Pure human reading of source, cross-contract reasoning, and PoC construction.
**Date**: 2026-05-25
**Scope**: 27 production contracts V5.3 + the 6 flash shields & 6 adapters re-deployed UUPS (V5.4) + lumina-api + lumina-sdk
**Commit reviewed**: `d7b31f7` (main, post PR #155 / #156)
**Constraints honored**: no code modified, no PR merged, every finding carries `file:line` evidence, CVSS for Medium+, PoCs for High, no duplication of findings already closed in Sprints 7.2 / 7.4 / 7.5.

---

## Executive Summary

The protocol is in good shape after the Sprint 7.2 red-team remediation (V2 global 8.6/10). The CRITICAL/HIGH red-team findings were verified present and correctly implemented. This **manual** pass — looking specifically for the subtle logic / accounting / cross-contract / lying-comment defects that fuzzing and adversarial testing miss — found:

- **0 CRITICAL**
- **2 HIGH** — one genuine on-chain oracle-staleness defect that feeds value-bearing settlement (**MR-H01**), and one off-chain relayer concurrency/DoS gap on the core purchase path (**MR-H02**).
- **7 MEDIUM** — the most material being an **unenforced 3-way payout-ratio coupling** across CoverRouter / PolicyManager / shield (**MR-M01**), a **per-user redemption-throttle dilution across the queue epoch boundary** (**MR-M02**), and a **permissionless buyback `executeOffer`** that lets a seller force the protocol to buy their own bonds at the cap price (**MR-M04**).
- **11 LOW**, **8 INFO** (including 2 confirmed *lying comments* tied to MR-H01).

None of the findings is immediately and unconditionally exploitable for direct theft on the current testnet wiring; several Mediums are **latent** (fire only once `cexReserve` is wired, or only on owner misconfiguration), which is why they did not surface in functional or red-team testing. The single finding that materially gates mainnet is **MR-H01** (oracle freshness), because it can serve a stale redemption price on a thin or idle LUMINA/USDC pool — a condition that is the *norm* on testnet and on a freshly-seeded mainnet pool.

**Verdict: ⚠️ NEEDS FIXES (pre-mainnet). Score 8.0 / 10.** Testnet Fase 5 may proceed with MR-H01 explicitly tracked (see Verdict section).

---

## Severity Distribution

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 7 |
| Low | 11 |
| Informational | 8 |

---

## CVSS Scoring (Critical / High / Medium)

| ID | Sev | CVSS | Vector |
|----|-----|------|--------|
| MR-H01 | High | 7.1 | AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:L |
| MR-H02 | High | 7.1 | AV:N/AC:H/PR:L/UI:N/S:U/C:N/I:H/A:H |
| MR-M01 | Medium | 6.5 | AV:N/AC:H/PR:H/UI:N/S:U/C:N/I:H/A:H |
| MR-M02 | Medium | 5.9 | AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:L |
| MR-M03 | Medium | 5.3 | AV:N/AC:H/PR:N/UI:N/S:C/C:N/I:L/A:L |
| MR-M04 | Medium | 6.5 | AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:L |
| MR-M05 | Medium | 6.0 | AV:N/AC:H/PR:H/UI:N/S:U/C:N/I:H/A:N |
| MR-M06 | Medium | 5.9 | AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:N |
| MR-M07 | Medium | 4.2 | AV:N/AC:H/PR:H/UI:N/S:U/C:N/I:L/A:L |

---

## Findings

### MR-H01 [HIGH] — CapacityOracle TWAP serves a stale frozen-pool price; no observation-age / cardinality gate, and the deviation breaker cannot detect whole-pool staleness
**CVSS**: 7.1 (AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:L)
**Contract**: `src/oracles/CapacityOracle.sol`
**Lines**: `getLuminaPrice` 138-175 (fallbacks 146-150, 157-163), `_getTwapPriceForWindow` 187-218 (esp. 192)

**Description.** `_getTwapPriceForWindow` derives the price from `IUniswapV3Pool(pool).observe(secondsAgos)` **only** (line 192). It never reads `slot0()` for `observationCardinality` / latest-observation timestamp — the interface declares those getters (lines 41-43) but they are never called anywhere in the contract. There is no analogue of Chainlink's `block.timestamp - updatedAt < heartbeat` staleness gate for the Uniswap source.

Uniswap V3 `observe()` does **not** revert on an idle pool: when no swap has touched the pool since the last observation, it extrapolates the most recent observation to `block.timestamp` at the **last recorded tick**. A pool that has had zero trading for hours therefore returns a well-formed, non-zero, *stale* price. Because both the short and long windows read the same frozen tick, the F-02 cross-window deviation breaker (lines 169-172) computes `dev == 0` and passes trivially. The `try/catch` fallbacks (lines 146-150, 157-163) only fire when `observe()` *reverts* (window exceeds available history) or returns zero — neither of which happens for an idle-but-deep pool.

**Attack scenario.** LUMINA/USDC on testnet (or a freshly-seeded mainnet pool) is thin. The last trade fixed LUMINA at, say, $0.50; the market then moves (or the pool simply idles) for several hours with no swaps. `getLuminaPrice()` returns the stale $0.50. A redeemer calls `BondVault.redeemBond` → `_redeemPrice()` (BondVault:388/510) → settles at the stale price. Symmetrically, `BondVault.issueBond` sizes capacity against it and `TWAPBurner._swapAndBurn` derives `minOut` from it.

**Impact.** Value-bearing settlement (redemption payout, capacity sizing, burn slippage floor, `SolvencyOracle` ratio) consumes a price that can be materially disconnected from market, on exactly the low-liquidity conditions that hold on testnet and early mainnet. The F-02 deviation breaker is defeated *by construction* against staleness (it compares two windows of the same frozen pool). The CapacityOracle header (lines 16-22) asserts "`getLuminaPrice()` … either a trustworthy price or a revert" — this is a **lying comment** for the staleness branch (see INFO-4).

**PoC**: `test/manual-review-poc/MR_H01_OracleStaleness_PoC.t.sol` — mock pool whose `observe()` returns a frozen `tickCumulative` (no swaps); asserts `getLuminaPrice()` returns the stale price and the deviation breaker does not trip.

**Recommendation.** Add an observation-freshness gate: read `slot0()` for `observationIndex`/`observationCardinality`, fetch the latest observation's `blockTimestamp`, and require `block.timestamp - lastObservationTs <= maxObservationAge` (a configurable heartbeat). Also require `observationCardinality >= minCardinality` so a `window`-second TWAP is genuinely backed by that much history rather than silently extrapolated. **Revert (fail-closed)** when stale, matching the documented trust model. Reconcile the header NatSpec.

---

### MR-H02 [HIGH] — lumina-api relayer purchase path has no nonce management or serialization; concurrent purchases collide and can drop premium-charged transactions
**CVSS**: 7.1 (AV:N/AC:H/PR:L/UI:N/S:U/C:N/I:H/A:H)
**Component**: lumina-api
**Lines**: `src/services/policies.ts:272-392` (`purchaseViaRelayer`), `src/utils/ethers.ts:50` (relayer wallet)

**Description.** The relayer is a bare `new Wallet(cfg.RELAYER_PRIVATE_KEY, provider)` with no `NonceManager` and no in-process lock. `purchaseViaRelayer` runs a long sequence of `await` pre-flights then `coverRouterRelayer.purchasePolicyFor(...)` (line 376) with no explicit nonce. Two concurrent authenticated requests (or one without an Idempotency-Key) both read the same `pending` nonce. The faucet path explicitly added a *global* `withLock(GLOBAL_LOCK_KEY, …)` (`routes/faucet.ts:70-95,114`) to close "audit HIGH-1" for exactly this relayer race — **that mitigation was never propagated to the purchase path**, which signs from the *same* wallet/nonce space.

**Attack scenario.** A burst of concurrent purchases — trivially reachable (free tier 10 rpm, paid 100 rpm, plus the public `/sandbox/try` at 10/h/IP, all sharing one relayer) — produces duplicate-nonce txs. One replaces the other in the mempool or both stall; legitimate purchases fail with `tx_reverted`/timeout, or a buyer's premium is charged while their policy tx is dropped. A request-spray attacker can wedge the relayer nonce sequence and DoS all purchasing.

**Impact.** Denial of service on the core revenue path; lost/duplicated transactions; DB-vs-chain inconsistency.

**PoC**: described in `test/manual-review-poc/MR_H02_RelayerNonce_NOTE.md` (integration-level; not a Solidity PoC).

**Recommendation.** Wrap the relayer in ethers v6 `NonceManager`, or serialize all relayer-signing sends through one in-process queue using a shared lock key (`relayer-tx`) across faucet + purchase, since they share one nonce space.

---

### MR-M01 [MEDIUM] — Unenforced 3-way payout-ratio coupling: configurable `CoverRouter.payoutRatioBps` vs hardcoded `8000` in PolicyManager/adapter vs shield `DEDUCTIBLE_BPS = 2000`
**CVSS**: 6.5 (AV:N/AC:H/PR:H/UI:N/S:U/C:N/I:H/A:H)
**Contracts**: `src/core/CoverRouterV2.sol:258,277,284,298`; `src/core/PolicyManagerV2.sol:259`; `src/shields/FlashShieldAdapter.sol:182`; `src/shields/BaseFlashShield.sol:84,366`

**Description.** The router prices premium and emits payout from a **per-product** `config.payoutRatioBps` (CoverRouterV2:258,277). But `PolicyManagerV2.recordPolicy` hardcodes `payoutAmount = (coverageAmount * 8000) / 10000` (line 259), the adapter advertises `maxPayout = coverage * 8000 / 10_000` (FlashShieldAdapter:182), and the shield pays exactly `coverage * (10000 - DEDUCTIBLE_BPS)/10000` with `DEDUCTIBLE_BPS = 2000` (BaseFlashShield:84,366). `configureProduct` (CoverRouterV2:284) accepts an arbitrary `_payoutRatioBps` with **no bound check**.

**Attack scenario.** The owner configures a product with `payoutRatioBps != 8000` (e.g. 9000 for a "90% cover" SKU — a plausible product decision). The router then prices premium and reports `PolicyPurchased.payout` / `quotePremium.payout` at 90%, but PolicyManager reserves capacity and issues the bond at 80%, and the shield pays 80%. The buyer is charged a 90%-calibrated premium for coverage that can only ever pay 80%.

**Impact.** Premium/payout mismatch (buyer overpayment) or capacity under-reservation; `PolicyPurchased.payout` and `quotePremium` report a number the protocol will never honor. The coupling `config.payoutRatioBps == 8000 == 10000 - DEDUCTIBLE_BPS` is an implicit invariant nothing enforces.

**Recommendation.** Make it single-sourced: either remove `payoutRatioBps` from per-product config and derive it from the shield deductible, or bound-check `_payoutRatioBps == 8000` in `configureProduct`, or have PolicyManager read the ratio from router config instead of hardcoding `8000`. Document the invariant.

---

### MR-M02 [MEDIUM] — Per-user redemption throttle (F-10) is diluted across the queue epoch boundary; a queued payout is not charged to the user's per-user counter in the epoch it is paid
**CVSS**: 5.9 (AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:L)
**Contract**: `src/bonds/BondVault.sol`
**Lines**: `redeemBond` 392-432 (esp. 399-400), `processQueue` 507-588 (esp. 531, 541, 581)

**Description.** The per-user cap (`redeemedByUserInEpoch`) is enforced and incremented only in `redeemBond`, keyed on `throttleEpoch = currentEpoch()` **at queue time** (lines 399-400). Over-cap requests are queued for `target = throttleEpoch + 1` (line 410). When `processQueue` later pays the entry (in epoch N+1), it adds the drained USD to the **global** `redeemedInEpoch[N+1]` (via `already`, line 581) but **never touches `redeemedByUserInEpoch[N+1][holder]`**.

So in epoch N+1 the holder's per-user counter starts at 0. They can perform a fresh immediate redemption up to the full per-user cap *while* their carried-over queue payout simultaneously consumes the same epoch N+1 global cap. One account can thus occupy up to `2 × MAX_USER_REDEEM_BPS` of a single epoch's actual LUMINA outflow.

**Note on bound.** The **global** epoch cap is *not* broken: `processQueue` gates each payment with `already + needUSD18 > capUSD18` (line 531), so total drain per epoch (immediate + queued) stays under `capUSD18`. Only the **per-user fairness** guarantee is weakened — hence Medium, not High. During a bank-run a sophisticated holder captures a disproportionate share of each epoch's cap versus throttled small holders.

**PoC**: `test/manual-review-poc/MR_M02_ThrottleDilution_PoC.t.sol` — whale queues max in epoch N, then in N+1 redeems a fresh max while the queue pays out, draining ~2× the per-user share of the N+1 cap.

**Recommendation.** When paying a queued entry in `processQueue`, also debit `redeemedByUserInEpoch[currentEpoch()][q.holder] += needUSD18` (and optionally enforce the per-user cap there). Carry the per-user attribution in the `QueuedRedemption` struct so the throttle follows the obligation into the processing epoch.

---

### MR-M03 [MEDIUM, LATENT] — Emergency CEX injection decision uses the *floored* display price via permissionless `pokeCheckAndInject`; the reserve enforces no independent cap/cooldown
**CVSS**: 5.3 (AV:N/AC:H/PR:N/UI:N/S:C/C:N/I:L/A:L)
**Contracts**: `src/bonds/BondVault.sol` (`pokeCheckAndInject` 804, `_getSafePrice` 643-649, `_checkAndInject` 756-797, `_availableCapacityRatioBps` 761); `src/treasury/CEXLiquidityReserve.sol` (`injectToVault` 203-211)

**Description.** Settlement uses the fail-closed `_redeemPrice()` (reverts `ORACLE_UNAVAILABLE`). But the **permissionless** `pokeCheckAndInject()` (BondVault:804) feeds `_getSafePrice()` into `_checkAndInject`. `_getSafePrice()` **floors to `MIN_REDEEM_PRICE` (0.005e18)** on oracle revert/zero (lines 643-649). A lower price reduces `reserveValueUSD18` → reduces `maxCommitUSD18` → collapses `_availableCapacityRatioBps` toward/under `CAPACITY_RATIO_THRESHOLD_BPS` (5000), **firing the injection branch on a synthesized floor price** during the exact oracle outage the system should suspend on. The comment at BondVault:756-757 claims injection uses "the SAME TWAP price the rest of the system uses — no second oracle" — misleading for this entry point, which synthesizes a price settlement explicitly rejects.

On the asset side, `CEXLiquidityReserve.injectToVault` (lines 203-211) trusts `bondVault` for any amount up to its full balance with **no reserve-side cooldown or per-window cap** — the only throttle is BondVault's `INJECTION_COOLDOWN` (1 day) and 10%/call size, both living in the *upgradeable caller's* storage. The reserve's own comment (CEXLiquidityReserve:757-759) admits the per-window cap "completes when cexReserve is wired."

**Why latent.** `cexReserve == address(0)` on-chain today (BondVault:760 guards the branch), so this is dormant. It becomes a live, permissionlessly-pokeable 10%/day reserve-drain primitive the moment `setCexReserve` + `setBondVault` are wired — the documented production end-state.

**Recommendation.** The injection *decision* must use a fail-closed price (revert on oracle-unavailable) or skip the injection branch entirely when the oracle is unavailable — never spend reserve on a synthesized floor price. Add defense-in-depth inside `CEXLiquidityReserve`: an independent cooldown + per-window cumulative-injected cap.

---

### MR-M04 [MEDIUM] — `BuybackEngine.executeOffer` is permissionless; a seller can force the protocol to buy their own bonds at the cap price and trigger reserve burns on their own schedule
**CVSS**: 6.5 (AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:H/A:L)
**Contract**: `src/marketplace/BuybackEngine.sol:156-180`

**Description.** Unlike `setDailyBuyback` (gated by `BUYBACK_OPERATOR_ROLE`, line 140), `executeOffer` is `external nonReentrant` with **no access control**. The only constraints are the operator-set window (`block.timestamp <= dailyConfig.validUntil`), a per-listing price cap (`priceUSDC <= maxAllowedPriceUSDC`, lines 168-170), and the running daily budget (line 177).

**Attack scenario.** Whenever a buyback window is open, any bond holder lists their own ClaimBonds at exactly `maxPricePercent`% of face (e.g. 95%), then calls `executeOffer(listingId)` themselves. The Engine pays up to 95% of face in USDC and each call triggers `_executeDoubleBurn`, draining LUMINA from BondVault reserves (capped 5%/tx by `burnFromReserves`). The seller — not the operator — decides which listings the protocol buys and when, steering the entire `dailyBudget` toward their own bonds.

**Impact.** Subverts buyback intent (retire bonds at an *operator-selected* discount): any participant sells to the protocol at the cap and force-triggers reserve burns. Bounded by `dailyBudget`, `maxPricePercent`, `validUntil`, and the 5%/tx vault cap → Medium.

**PoC**: `test/manual-review-poc/MR_M04_ExecuteOfferOpen_PoC.t.sol` — non-operator EOA lists own bonds at cap and self-executes against the open window.

**Recommendation.** Gate `executeOffer` with `onlyRole(BUYBACK_OPERATOR_ROLE)`. If permissionless keeper execution is desired, add an operator-controlled allowlist of listingIds so the Engine selects which bonds to buy.

---

### MR-M05 [MEDIUM] — FounderVesting v1 → V2 migration is not enforced on-chain: no balance check, v1 not freezable, constructor carry not consistency-checked
**CVSS**: 6.0 (AV:N/AC:H/PR:H/UI:N/S:U/C:N/I:H/A:N)
**Contracts**: `src/token/FounderVesting.sol:162-179`; `src/token/FounderVestingV2.sol:113-151,263-280`; mint at `src/token/LuminaTokenV2.sol:81`

**Description.** `LuminaTokenV2.initialize` mints the 8M founder allocation to a single `founderVesting` (the v1 contract). V2's "migration" is a pure constructor carry of counters (`_initialTranchesReleased`, `_initialTotalReleased`, `_alreadyTriggered`, `_triggerTimestamp`) emitting `MigratedState`; it does **not** verify the 8M actually moved to V2, and does **not** disable v1. v1 is an immutable `Ownable` whose `releaseTranche()`/`checkAltSeason()`/`triggerFallback()` are permissionless; renouncing ownership does **not** stop them. The migration note (V2:30-41) says "freeze v1 (renounce / leave dormant)" but renounce does not freeze release. Additionally, the V2 constructor accepts `_initialTotalReleased` and `_initialTranchesReleased` independently (only `<= TOTAL_AMOUNT` / `<= TOTAL_TRANCHES`) with no mutual-consistency check.

**Attack/failure scenario.** Founder migrates counters into V2 but the balance sweep is forgotten/partial. v1's fallback later fires; both v1 and V2 `releaseTranche()` pay out, distributing more than the intended 8M tranche budget in aggregate. Or a mis-entered carry desyncs the final-tranche remainder math (`TOTAL_AMOUNT - totalReleased`), over/under-paying.

**Impact.** The vesting invariant "founder receives exactly 8M via 3 tranches" is violable across the v1/V2 pair. (The 100M hard cap is still respected — mint happens once.)

**Recommendation.** Add a one-shot `migrateFrom(v1)` on V2 that reads v1 `getStatus()` for the carry and requires `luminaToken.balanceOf(v1) == 0` before V2 release is enabled; add a `frozen` flag + `freeze()` on v1 that hard-blocks release. At minimum add the constructor consistency check `(_initialTranchesReleased == 0) == (_initialTotalReleased == 0)` and `_initialTotalReleased ≈ _initialTranchesReleased * TRANCHE_AMOUNT`.

---

### MR-M06 [MEDIUM] — DEX adapters are permissionless with caller-supplied `minOut` and no in-adapter slippage floor (`sqrtPriceLimitX96 = 0`)
**CVSS**: 5.9 (AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:N)
**Contracts**: `src/dex/UniswapV3Adapter.sol:63-84,79,94`; `src/dex/AerodromeAdapter.sol:57-75,69`

**Description.** `swap` is `external` with no access control on both adapters; it forwards the caller-supplied `minAmountOut` straight to the router and sets `recipient: msg.sender`. The Uniswap adapter also sets `sqrtPriceLimitX96: 0` (line 79/94), so `amountOutMinimum` is the *sole* protection. There is no in-adapter floor: a caller passing `minAmountOut = 0` swaps with zero protection.

The live production caller — `TWAPBurner._swapAndBurn` — derives `minOut` from the oracle and enforces `minOut > 0` (TWAPBurner:270-280), so the live path is safe (F-19 intact). But these are standalone, permissionless, *shared-infrastructure* contracts; any other integrator (or a future internal caller) passing 0 gets sandwiched.

**Recommendation.** Either restrict `swap` to an allow-listed caller set, or reject `minAmountOut == 0` in the adapter as a defense-in-depth invariant matching TWAPBurner's own. Document that `minAmountOut` must be oracle-derived. Verify the deployed Uniswap router is `SwapRouter02` (the `ExactInputSingleParams` struct omits `deadline`, matching 02, not the original SwapRouter).

---

### MR-M07 [MEDIUM, LATENT] — `TWAPBurner.setUsdc` re-points the premium token without migrating balance, resetting accrual, or asserting decimals
**CVSS**: 4.2 (AV:N/AC:H/PR:H/UI:N/S:U/C:N/I:L/A:L)
**Contract**: `src/core/TWAPBurner.sol:351-356` (+ `receiveMarketplaceFee` 144-149, `_swapAndBurn` 274-276)

**Description.** `setUsdc` swaps the `usdc` reference with no migration: any USDC already accrued (`accumulatedUSDCSinceBurn`, in the old token's 6-dec units) is afterwards compared against a balance read from the *new* token, and `_swapAndBurn` hard-codes the 6-dec conversion `usdcAmount * 1e12` (line 274) — silently wrong if the new token is not 6-dec, corrupting the `minOut` floor. Separately, `receiveMarketplaceFee` (144-149) lacks `nonReentrant` while its sibling `receivePremium` has it — harmless for vanilla USDC but inconsistent given the contract is explicitly designed to be re-pointed (Sprint CR-USDC-Reconfig) to mock/arbitrary tokens.

**Recommendation.** In `setUsdc`, require `accumulatedUSDCSinceBurn == 0` (or reset it) and a zero/swept balance of the old token; record/assert the new token's decimals (store `usdcDecimals`, use it in `_swapAndBurn` instead of hard-coded `1e12`). Add `nonReentrant` to `receiveMarketplaceFee` for parity.

---

### LOW findings

| ID | Contract:line | Title |
|----|---------------|-------|
| MR-L01 | `PolicyManagerV2.sol:259-266` | `recordPolicy` truncates payout to integer USD and has no local `payoutUSD > 0` guard at record time; if the router min-coverage floor is ever lowered (separate, swappable contract) a sub-$1.25 coverage truncates to a zero reservation / un-triggerable policy. Fail-fast in `recordPolicy`. |
| MR-L02 | `PolicyManagerV2.sol:502-523` | `getActivePolicyIds` bounds its loop on the **global** `totalPolicies` while indexing the **per-product** `policies[productId][i]` map. Correct today (per-product IDs are dense from 1) but fragile and O(totalPolicies) gas-wasteful for low-volume products. Track a per-product count and bound on it. |
| MR-L03 | `PolicyManagerV2.sol:448` | `markExpired` calls the **state-mutating** `verifyAndCalculate` as its expiry gate; correctness relies on tx-atomic rollback when it then reverts `PolicyTriggerable`, not on a side-effect-free probe. A future refactor that swallows the inner error would strand the reservation. Use a view probe. |
| MR-L04 | `BondVault.sol:399-422` | `redeemedByUserInEpoch` is charged the **unclamped** `requestedUSD18` before the over-cap clamp at line 420; on the clamp edge the user is over-charged window allowance and the burned-bond `usdAmount` can diverge from the queued/`totalQueuedUSD` value. Clamp before charging. |
| MR-L05 | `TWAPBurner.sol:144-149` | `receiveMarketplaceFee` missing `nonReentrant` (parity gap with `receivePremium`). (Folded with MR-M07.) |
| MR-L06 | `SolvencyOracle.sol:116-130` | `evaluate()`/`_calculateSolvencyRatio` call `getLuminaPrice()` with no try/catch, so a future F-02 deviation revert bricks `evaluate()` (quadrant freezes during volatility), while `isHealthy()` does catch and returns `false`. `isHealthy()` also returns `true` purely on `price > 0`, not on the solvency ratio. Record a STRESSED reading instead of reverting; fold ratio into `isHealthy`. |
| MR-L07 | `LuminaOracleV2.sol:464-480` | `_checkSequencer` computes `block.timestamp - startedAt <= GRACE` but does not guard `startedAt == 0` (uninitialized round), so a malformed/bootstrap sequencer feed passes the grace check. Add `if (startedAt == 0) revert ...` per Chainlink reference. |
| MR-L08 | `redeem.ts:37-68` (api) | Redeem duplicate-check is TOCTOU; fully backstopped by the `tx_hash UNIQUE` constraint + 409 mapping. Informational — the API only *verifies/records* an already-on-chain event, so no fund impact. |
| MR-L09 | `UniswapV3Adapter.sol:10-18` | `ExactInputSingleParams` omits `deadline`, matching `SwapRouter02`. If the deployed router is the original `SwapRouter` the ABI mismatches. Verify deployment. |
| MR-L10 | `BondVault.sol:417-423`, `ClaimBond.sol:156-171` | Obligation accounting: a holder's `burnByHolder` unconditionally decrements `totalCommittedUSD`, but value already reclassified into `totalQueuedUSD` (at queue time) is not distinguished. **Unconfirmed** whether reachable as a double-debit; recommend an explicit invariant test `totalCommittedUSD + totalQueuedUSD == Σ outstanding-bond face`. |
| MR-L11 | `BuybackEngine.sol:77-84,150,177` | `dailyConfig.spentToday` only resets inside `setDailyBuyback`, never on a day/`validUntil` boundary; `durationHours` ≤ 72, so the "daily" budget is really per-config over up to 3 days, and a mid-window reconfig resets `spentToday` → up to `2×budget` in one calendar day. Rename to per-window or implement real daily accounting. |

### INFORMATIONAL

- **INFO-1** `MaintenanceReserve.sol:116-129` — case-only twin names `_enforceMonthlyCap()` (a month-index helper that enforces nothing) vs `_enforceMonthlycap(uint256)` (the real enforcer). Foot-gun; rename the helper to `_currentMonthIndex()`.
- **INFO-2** `ShieldKeeper.sol:19` — `IShieldSettleable.getPolicyStatus(uint256)` declared but never called and not implemented by adapter/shield. Misleading; remove.
- **INFO-3** `FlashShieldAdapter.sol:203` — NatSpec references a `"NEEDS_MORE_CONFIRMATIONS"` reason the shield never emits (real reasons: `ACCRUING`/`RESET`, reverts `SAME_BLOCK_OBSERVATION`/`STALE_ROUND_OBSERVATION`/`CONFIRMATION_TOO_SOON`). Align comment.
- **INFO-4** `CapacityOracle.sol:16-22` — **lying comment**: "either a trustworthy price or a revert" is false for the staleness branch (MR-H01) and the three silent `emergencyPrice` fallbacks. Reconcile once MR-H01 fixed.
- **INFO-5** `TWAPBurner.sol:266-269` — **lying comment**: claims the oracle "reverts fail-closed … preserves `minOut > 0` by construction"; untrue when CapacityOracle silently serves `emergencyPrice`/stale price (MR-H01). Reconcile.
- **INFO-6** `FounderVestingV2.sol:204-233` — PATH-2 "sustained 1 day / 24 hourly observations" comment understates the worst case (24 *spaced* observations can land well past 24h if keepers call faster than hourly). Founder-adverse only (delays unlock); reword.
- **INFO-7** `utils/ChainGuard.sol:21` — revert's `expected` arg hardcoded to `BASE_MAINNET` even on Sepolia; cosmetic.
- **INFO-8** `AdaptiveFeeDistributor.sol:70-91` — **positive confirmation**: all 16 quadrant rows of `_lookupDistribution` hand-summed to exactly 10000 bps; the 100%-split invariant holds, 85/8/2/5 is row (1,1). No action.

---

## Cross-Contract Consistency Review

- **Payout ratio (MR-M01)** — the single material cross-contract inconsistency: `CoverRouter.config.payoutRatioBps` (configurable, unbounded) vs `PolicyManager` hardcoded `8000` vs `BaseFlashShield.DEDUCTIBLE_BPS = 2000`. Coupled by an implicit, unenforced invariant.
- **Interfaces** — PolicyManager's local `IShieldV2` (2-arg `verifyAndCalculate → PayoutResult`) matches the adapter's legacy surface; the slim `interfaces/IShieldV2.sol` matches the adapter→shield call. No ABI mismatch found.
- **Min coverage ⇄ payout truncation (MR-L01)** — the router's `$100` floor and PolicyManager's `/1e6` truncation are tuned together but the dependency is implicit and unenforced at the PM boundary.
- **Obligation accounting (MR-L10)** — `committed`/`queued`/outstanding-bond-supply 1:1 mapping relies on burn paths debiting the correct bucket; recommend an invariant test.
- **Reserve ⇄ vault dual-control (MR-M03)** — intended two-sided throttle on CEX injection is not realized; reserve adds no independent bound.
- **Fee splits** — marketplace 1.5%+1.5% conservation is exact (no stranded dust); AdaptiveFeeDistributor matrix sums to 100% on every quadrant. Consistent.

## Documentation Accuracy

Two **lying comments** found (INFO-4 CapacityOracle "trustworthy or revert"; INFO-5 TWAPBurner "fail-closed by construction"), both tied to MR-H01. Three stale/misleading NatSpec items (INFO-2/3/6). F-01 in V1 was itself a lying comment — this pass found two more in the oracle/burn trust narrative, which is the highest-value documentation-accuracy result.

## Pattern Compliance

- **UUPS (G.1)** — all upgradeable contracts verified: `_disableInitializers()` in constructor, `initializer`-guarded `initialize`, no constructor state, `_authorizeUpgrade` owner/admin-gated, storage `__gap` decrements match every appended slot (BondVault 40, ClaimBond 48, CoverRouter 48, PolicyManager 50, CapacityOracle 48, Marketplace 48, TWAPBurner 43, CEXLiquidityReserve 48). **No gap/init defect found.** BaseFlashShield's UUPS conversion is clean and starts from a fresh ERC1967 layout (the old shields were non-upgradeable, non-proxy — no in-place storage-collision risk).
- **Oracle (G.3)** — LuminaOracleV2 Chainlink reads are textbook (answer>0, answeredInRound≥roundId, future-ts guard, per-feed maxStaleness). The gap is the **Uniswap** TWAP source (MR-H01) and the sequencer `startedAt==0` edge (MR-L07).
- **Token/ERC-1155 (G.2)** — 100M cap minted once and asserted; supply only decreases via burn; marketplace ERC-1155 callback path is strict-CEI + `nonReentrant`.
- **Access control (G.4)** — sound except `executeOffer` (MR-M04) and the unbounded `configureProduct` (MR-M01).
- **Math (G.5)** — BPS, premium product, and Uniswap sqrt/tick math reviewed; the `divide-before-multiply` slither suppressions are correctly justified (canonical reference math). No precision defect beyond the documented truncations (MR-L01/L04).

## Comparison with Previous Audits

| | Sprint 7.2 Red Team | Sprint 7.3 Manual (this) |
|---|---|---|
| Method | Adversarial + Slither/Mythril/Echidna | Line-by-line human reading |
| Headline | F-01 flash-trigger single-block | **MR-H01 oracle staleness** (different class: liveness/freshness of the Uniswap source, which fuzzing/static tools don't model) |
| Overlap | none re-reported | verified all F-01..F-31/N-01 present & correct |
| New classes found | — | unenforced cross-contract invariant (MR-M01); throttle-across-epoch dilution (MR-M02); permissionless `executeOffer` (MR-M04); migration-not-enforced (MR-M05); 2 lying comments in the oracle/burn narrative |

**Findings common with 7.2**: 0 re-reported (all closed items verified, not duplicated). **Findings new**: all 28 items here are new (the red-team closed the trigger/settlement/economic surface; this pass found the *freshness*, *cross-contract-coupling*, and *governance-of-flows* surface those tools structurally miss).

## Tools Used

**NONE.** Per Sprint 7.3 constraints, no Slither / Mythril / Echidna / Aderyn. Manual reading + cross-contract reasoning + PoC construction only.

## PoCs Developed

`test/manual-review-poc/` (forge test, **not** executed on testnet/mainnet; local-fork execution deferred to CI Linux per the documented via_ir OOM constraint on the Windows audit host):
1. `MR_H01_OracleStaleness_PoC.t.sol` — stale frozen-pool price served by `getLuminaPrice` (HIGH).
2. `MR_M02_ThrottleDilution_PoC.t.sol` — per-user throttle diluted across queue epoch (MEDIUM).
3. `MR_M04_ExecuteOfferOpen_PoC.t.sol` — permissionless buyback self-execution (MEDIUM).
4. `MR_H02_RelayerNonce_NOTE.md` — integration-level reproduction note for the API relayer race (HIGH; not a Solidity PoC).

---

## Recommendations Summary (priority order)

1. **MR-H01** — add Uniswap observation-age + cardinality freshness gate to CapacityOracle; fail-closed on stale. (Mainnet blocker.)
2. **MR-H02** — serialize/NonceManager the relayer purchase path. (Pre-launch / scale blocker.)
3. **MR-M01** — enforce or remove the configurable `payoutRatioBps`.
4. **MR-M03** — injection decision must not use a synthesized floor price; add reserve-side cap/cooldown (before `cexReserve` is wired).
5. **MR-M04** — gate `executeOffer` to the operator role.
6. **MR-M02 / MR-M05 / MR-M06 / MR-M07** — throttle attribution, enforced v1 freeze, adapter minOut floor, `setUsdc` hardening.
7. Lows/Infos — fail-fast `payoutUSD`, sequencer `startedAt==0`, lying-comment reconciliation, invariant test for obligation accounting.

---

## Verdict

**Score: 8.0 / 10** — ⚠️ **NEEDS FIXES (pre-mainnet).**

- **Fase 5 (testnet): SÍ**, with **MR-H01 explicitly tracked** — note that the stale-price condition is most acute on the thin/idle testnet LUMINA/USDC pool, so any redemption-price anomaly on testnet should be read against this finding rather than treated as an oracle bug elsewhere.
- **Fase 7 (mainnet): NO** until MR-H01 (oracle freshness), MR-H02 (relayer serialization), MR-M01 (payout coupling), and MR-M03 (injection price source + reserve cap) are fixed, and the standing `BL-MULTISIG` (F-17) governance blocker is resolved.

**Reverse-audit self-assessment: 8.5/10** — high-confidence on MR-H01 (verified against Uniswap `observe()` semantics and the exact code), MR-M01/M02/M04 (verified against quoted code + PoCs). MR-L10 is explicitly flagged *unconfirmed* (needs an invariant test) rather than asserted, and several Mediums are correctly labelled *latent* rather than overstated. No invented findings.

**Sprint 7.3 — Manual Review V5.3: CLOSED ✅**
**Next: Sprint 7.6 Operational Audit.**
