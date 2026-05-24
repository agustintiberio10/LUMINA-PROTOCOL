# Lumina V5.3 Red Team Audit Report

**Auditor**: Senior Smart Contract Security Auditor (Claude) — CertiK-style adversarial engagement
**Style**: CertiK Adversarial / Trail-of-Bits-grade manual review + tooling + fuzzing
**Date**: 2026-05-24
**Sprint**: 7.2 — Red Team Adversarial Audit V5.3
**Scope**: 27 deployed V5.3 contracts (40 `.sol` files, ~6,250 LOC), Base Sepolia (84532), USDC = mUSDC. API + SDK as adjacent surface.
**Commit audited**: `b885d16` (`Merge pull request #152 from org-lumina/feat/fix-7-4-critical`), fresh clone of `main`.
**Methodology**: STRIDE threat modeling + adversarial manual review (line-by-line on critical contracts) + Slither static analysis + Foundry invariant/fuzz execution + live API probing. PoCs are conceptual (no on-chain execution; no contract modification).

> ⚠️ **IMMEDIATE ESCALATION (per engagement rules):** Finding **F-01 (CRITICAL)** is a *currently-exploitable* mispricing on the **live Base-Sepolia flash-shield product**. It was **NOT exploited** — only analyzed. Each flash-shield policy is economically a free knock-in barrier option (premium ≈ 0.24% of coverage; payout = 80% of coverage) because the advertised "3 oracle confirmations 60s apart" do **not exist on-chain** and both settlement entrypoints are permissionless. Treat as STOP-and-fix before any real value (Fase 5) flows through these shields.

---

## Executive Summary

Lumina V5.3 is a Base-native, agent-facing DeFi insurance protocol: parametric "flash shields" (1h/24h/48h BTC & ETH drop cover) sold via `CoverRouterV2`/`PolicyManagerV2`, settled into USD-denominated `ClaimBond` ERC-1155 bonds redeemable for LUMINA from `BondVault`, with a marketplace, buyback/burn engine, adaptive fee distribution, oracle stack, and founder/treasury vesting. The codebase is **mature and disciplined** on the classic vulnerability classes: `nonReentrant` + Checks-Effects-Interactions are applied consistently (no exploitable fund-theft reentrancy was found), all 13 UUPS proxies have correctly-gated `_authorizeUpgrade`, `_disableInitializers()`, and arithmetically-correct storage gaps across every executed upgrade, the adaptive fee matrix sums to exactly 100% in all 16 quadrants, EIP-712 oracle proofs are chain/contract-pinned, and core-fund rescue functions blacklist the protocol's own tokens.

The risk is **not** in the plumbing — it is **concentrated almost entirely on the price/oracle surface and the claim-settlement state machine**, which for an insurance protocol is the part that matters most. The single highest-leverage root cause recurs across the most severe findings:

> **A single instantaneous (or 1800s-TWAP-on-a-thin-pool) price read is used, with no second reference and no deviation circuit-breaker, for value-bearing decisions: trigger evaluation, redemption payout, capacity ratio, burn sizing, and auto-injection.**

This one design choice produces the CRITICAL (single-block trigger harvest), two of the HIGHs (TWAP-priced redemption extraction; auto-injection force-trigger), and several MEDIUMs. The secondary cluster is **settlement availability** — the shields hard-revert on oracle staleness/sequencer downtime with no fallback, so legitimately-triggered claims can be permanently denied (auto-expired as "not triggered") exactly during the volatility that produces claims. A third cluster is **BondVault capacity accounting** under the redemption throttle/queue (committed capacity freed before payout → solvency-ceiling breach).

**Findings:** **1 CRITICAL, 6 HIGH, 13 MEDIUM, 11 LOW, 8 INFORMATIONAL.** Two HIGH-adjacent items (auto-injection F-07, synchronous auto-burn F-13) are **dormant on-chain today** (`cexReserve = 0x0`, `maxPurchasesBeforeBurn = 0`) but are live code intended to be enabled for mainnet, so they are scored at their armed severity and flagged DORMANT.

**Verdict: ⚠️ NEEDS FIXES — NOT READY for mainnet (Fase 7).** Testnet (Fase 5) may proceed **only with F-01 fixed first**, because F-01 is exploitable against the live product now even on testnet (no real funds, but it invalidates any economic signal Fase 5 is meant to gather).

---

## Severity Distribution

| Severity | Count |
|---|---|
| CRITICAL | 1 |
| HIGH | 6 |
| MEDIUM | 13 |
| LOW | 11 |
| INFORMATIONAL | 8 |
| **Total** | **39** |

---

## CVSS Scoring

All findings are scored with CVSS 3.1 base vectors (`AV/AC/PR/UI/S/C/I/A`). Dormant findings are scored at armed severity with a DORMANT tag. Centralization findings on testnet are scored at their mainnet impact and tagged "design / pre-mainnet".

---

## Findings

### F-01 [CRITICAL] — Flash-shield trigger is a free knock-in barrier option (no real on-chain confirmation, no dwell, permissionless settle)

**CVSS 3.1**: 9.3 (`AV:N/AC:L/PR:N/UI:N/S:C/C:N/I:H/A:H`)
**Status**: Open — **exploitable on live testnet product**
**Contract**: `src/shields/BaseFlashShield.sol` (`verifyAndCalculate` 131–172, confirmation loop 142–152; `createPolicy` 111–129), settlement entrypoints `src/core/CoverRouterV2.sol` (`submitTrigger`) and `src/shields/FlashShieldAdapter.sol:149` (`checkAndSettlePolicy`, permissionless).

**Description.** The documented security control — *"3 oracle confirmations 60 seconds apart"* — **does not exist on-chain**. `verifyAndCalculate` reads `_currentPrice()` three times **in the same transaction** and takes the `min`; three reads of `latestRoundData()` in one block return the identical value, so `min` of three equal numbers is a no-op. The 60s spacing is "enforced off-chain by the relayer," but **both** settlement entrypoints are **permissionless**, so an attacker bypasses the relayer entirely. The trigger therefore reduces to a single-block test: *at any block in the policy window, is spot ≤ strike·(1 − triggerDropBps)?* There is also no minimum dwell — a policy can be bought and triggered in adjacent blocks (was tracked separately as B-4/HIGH; folded here as the same attack).

**Attack Scenario (FlashBTCShield1h, `triggerDropBps = 250` = 2.5%).**
1. Premium ≈ `coverage × payoutRatio(0.80) × triggerProb × margin`. With the router's example `triggerProbBps`≈20 (0.20%) and `marginBps`≈1.5×, premium ≈ `coverage × 0.0024` (~0.24% of coverage). Payout on trigger = `coverage × 0.80`.
2. Attacker buys max coverage just before a known-volatile window (CPI/FOMC print, liquidation cascade) — or simply holds the cheap policy for the full hour.
3. On **any single block** where the BTC/USD feed prints ≥2.5% below strike (routine intraday for a 1h horizon; Chainlink's 0.5% deviation + 1200s heartbeat makes a 2.5% gap reachable within a couple of updates), attacker calls `checkAndSettlePolicy(policyId)` directly — no relayer, no 60s wait.
4. `dropBps ≥ 250` → `triggered = true` → bond face = 80% of coverage. **ROI ≈ 0.80 / 0.0024 ≈ 333× on premium.**

**Impact.** Every flash-shield policy is a grossly-mispriced barrier option harvestable by any actor. At scale this mints `ClaimBond` face value up to BondVault's 50% capacity ceiling against premiums that priced in a ~0.20% trigger probability — a direct, repeatable drain of the bond reserve and a total break of the product's economics. **Live on Base Sepolia now** (the `/sandbox/try` and purchase flows mint real policies on these shields).

**Proof of Concept** (conceptual; not executed):
```solidity
uint256 cov = 1_000_000e6;                       // $1M coverage
router.purchasePolicy(FLASHBTC1H, cov, "BTC");   // premium ~ $2,400
// ... wait for ANY single block where spot dips >=2.5% under strike ...
adapter.checkAndSettlePolicy(policyId);          // permissionless: no relayer, no 60s spacing
// PolicyManagerV2.settlePolicy issues ClaimBond face = $800,000
```

**Recommendation.**
1. Enforce confirmations **across blocks/time on-chain**: store the first sub-barrier observation `(roundId, updatedAt, ts)`; require a later confirmation with strictly-increased `updatedAt` and `≥ CONFIRMATION_INTERVAL` elapsed before the trigger is eligible. Remove the in-tx 3× loop (it provides zero assurance).
2. Use a **multi-round minimum / short TWAP** for the barrier test (read historical `getRoundData(roundId-k)`), not a single instantaneous spot.
3. Add a **minimum dwell**: `require(block.timestamp >= p.startTimestamp + MIN_DWELL)` and `require(block.number > purchaseBlock)`.
4. Re-derive premiums from the *real* (post-fix) trigger probability.

**References**: SWC-114 (oracle/transaction-order dependence); bZx / Harvest flash-oracle incidents; CWE-367 (TOCTOU).

---

### F-02 [HIGH] — Fixed-USD bond redemption settled at a manipulable/floored price → up to 10× LUMINA extraction

**CVSS 3.1**: 7.5 (`AV:N/AC:H/PR:L/UI:N/S:U/C:N/I:H/A:H`)
**Status**: Open
**Contract**: `src/bonds/BondVault.sol:365` (`redeemBond`, `luminaAmount = usdAmount*1e36/currentPrice`), `:503-509` (`_getSafePrice`); price source `src/oracles/CapacityOracle.sol:82-123` (`getLuminaPrice`, 1800s Uniswap-V3 TWAP, `emergencyPrice` fallback). *(Consolidates E-1, K-1, H-ORACLE.)*

**Description.** Bonds are denominated `$1 = 1 bond` but **paid in LUMINA at the price observed at redemption**. `_getSafePrice` reads the `CapacityOracle` 1800s TWAP and, on any oracle revert/zero, **silently floors to `MIN_REDEEM_PRICE = $0.001`** — and `redeemBond` only requires `price >= MIN_REDEEM_PRICE`, which the floor itself satisfies. Two independent ways to push the redemption price down therefore both pay out *more LUMINA per dollar*:
- **Manipulation:** on a thin LUMINA/USDC pool a 30-minute TWAP is cheaply skewable by sustained one-sided selling across the window (no single-block flash loan needed).
- **Outage chain (K-1):** a young pool with low `observationCardinality` makes `observe()` revert → `getLuminaPrice` returns `emergencyPrice`; if that too is low/broken, `_getSafePrice` floors to $0.001.

The per-epoch throttle caps **USD** out (1.08%/epoch), not **LUMINA tokens** — and the USD cap scales *down* with price, so token drainage per dollar scales *inversely* with price.

**Attack Scenario.** Holder of a $1,000 matured bond: at $0.01 receives 100,000 LUMINA; at the $0.001 floor receives **1,000,000 LUMINA (10×)** for the same claim — pure dilution of every other holder, repeatable each 7-day epoch until reserves drain.

**Impact.** Reserve drain / uncontrolled dilution; the "~13% in 12 weeks" drain guarantee (`BondVault.sol:67`) holds only at the assumed price.

**Recommendation.** Settle redemptions on a **longer, dual-sourced** price (`max(longTWAP, chainlinkRef)`) with a **deviation circuit-breaker** that reverts on TWAP/secondary divergence > N bps; **fail closed** (revert/pause) on oracle unavailability instead of flooring; throttle on **LUMINA tokens** out per epoch (not only USD); require `currentPrice > MIN_REDEEM_PRICE` strictly; ensure the pool has adequate `observationCardinality` before relying on its TWAP.

**References**: SWC-114; OZ price-feed guidance; CWE-1339.

---

### F-03 [HIGH] — Shield oracle staleness/sequencer revert has no fallback → legitimate payouts permanently denied

**CVSS 3.1**: 6.8 (`AV:N/AC:H/PR:N/UI:N/S:C/C:N/I:N/A:H`) — rated HIGH on insurance-criticality
**Status**: Open
**Contract**: `src/shields/BaseFlashShield.sol:102-107` (`_currentPrice` hard-reverts `ORACLE_STALE`/`ORACLE_INVALID`), `:93-99,67-70` (`whenSequencerActive` on both create & verify); `src/shields/FlashShieldAdapter.sol:149-166` (`checkAndSettlePolicy` catches ONLY `WINDOW_EXPIRED`); `src/core/PolicyManagerV2.sol:400` (`markExpired` permissionless, no oracle check). *(Consolidates C-DOS-1, C-DOS-2, B-7.)*

**Description.** The shields read Chainlink directly with a **hard revert** on staleness (>1h) or sequencer downtime, with **no secondary feed, no cached last-good price, and no admin/governance escape hatch**. `verifyAndCalculate` is the single chokepoint for both the trigger and keeper-settlement paths. During a feed outage or sequencer-grace window:
- A policy that **legitimately triggered** cannot be settled-as-triggered (the revert is not `WINDOW_EXPIRED`, so the adapter re-reverts; the keeper emits `SettlementFailed` and moves on).
- Once the window passes, the only callable paths (`markExpired`, or `checkAndSettlePolicy` catching `WINDOW_EXPIRED`) settle the policy as **NOT triggered**, release the reservation, and **permanently deny the owed payout**. `markExpired` is permissionless and has no oracle-availability check, so anyone (including an adversary wanting to deny a payout) can lock in the denial.

Aggravating: the shield's flat `MAX_PRICE_STALENESS = 3600s` is *shorter than some Base feed heartbeats* (stable feeds up to 86400s per `LuminaOracleV2` NatSpec), so a feed operating normally can still trip the gate.

**Impact.** 100% of in-window claims during any staleness/sequencer overlap are at risk of permanent denial — the worst-case failure for an insurance product, occurring precisely when coverage is needed (flash-crash → both many triggers AND feed/sequencer stress).

**Recommendation.** Add a fallback / cached-last-valid price with a longer SETTLEMENT tolerance; distinguish "oracle unavailable" from "did not trigger" and never auto-expire-as-untriggered when the oracle was down during the window — route to a manual/governance-signed settlement queue (the EIP-712 `LuminaOracleV2` signer set already exists); set per-feed `MAX_PRICE_STALENESS ≥ actual heartbeat`; gate `markExpired` against oracle-unavailable windows.

**References**: SWC-128; CWE-703; CWE-841.

---

### F-04 [HIGH] — BondVault over-cap queued redemption frees committed capacity before LUMINA is paid → solvency-ceiling breach / over-issuance

**CVSS 3.1**: 7.1 (`AV:N/AC:H/PR:L/UI:N/S:U/C:N/I:H/A:H`)
**Status**: Open
**Contract**: `src/bonds/BondVault.sol:339-344` (commitment decremented up-front), `:346-359` (over-cap queue push), `:418-456` (`processQueue`), `:461-470` (`availableCapacityUSD`). *(Consolidates H-Q1, C-DOS-3a.)*

**Description.** In `redeemBond`, `totalCommittedUSD` is decremented up-front in **both** the immediate and the over-cap **queued** path. On the queued branch the bonds are burned but the LUMINA has not left the vault — yet committed capacity is already reduced, and the queued obligation is tracked in **neither** `totalCommittedUSD` **nor** `totalReservedUSD`. `availableCapacityUSD()` therefore overstates free backing by the full queued amount, and that same LUMINA is counted as free backing for **new** bond issuance (`recordPolicy → reserveCapacity → issueBond`).

**Attack Scenario.** Vault near its 50% commitment ceiling → a large holder redeems over-cap → bonds burned, entry queued, `totalCommittedUSD` drops by the full face value → `availableCapacityUSD()` immediately reports the queued amount as free → new policies are written/triggered against LUMINA already owed to the queue → when `processQueue()` runs, effective backing exceeds the 50% cap and queued holders can hit "Insufficient reserve" and be stranded. In a mass-queue black-swan (the exact scenario the throttle exists for), the **entire 7-day backlog is double-counted as free capacity**, defeating the solvency invariant.

**Recommendation.** Introduce `totalQueuedUSD`; on the over-cap branch add to it and **do not** reduce `totalCommittedUSD` until `processQueue` actually pays; subtract `totalQueuedUSD` in `availableCapacityUSD()`.

```solidity
uint256 public totalQueuedUSD; // 18-dec
// over-cap branch: totalQueuedUSD += requestedUSD18;  (do NOT reduce totalCommittedUSD yet)
// processQueue on pay:  totalQueuedUSD -= needUSD18; totalCommittedUSD -= needUSD18;
// availableCapacityUSD: used = totalCommittedUSD + totalReservedUSD + totalQueuedUSD;
```

**References**: SWC-101; accounting-invariant violation.

---

### F-05 [HIGH] — Uninitialized FlashShieldAdapter proxy: deploy-script regression enables init front-run / takeover

**CVSS 3.1**: 7.9 (`AV:N/AC:H/PR:N/UI:N/S:C/C:H/I:H/A:H`)
**Status**: Open (latent on live adapters; live for any future re-deploy) — **verify on-chain**
**Contract**: `script/deploy/DeployFlashShieldsT30c.s.sol:67-90` (`new ERC1967Proxy(impl, "")` then a **separate** `initialize()` tx); `src/shields/FlashShieldAdapter.sol:79-86` (`initialize` runs `__Ownable_init(msg.sender)` → first caller becomes owner). *(= D-H1.)*

**Description.** The 6 T-30c adapters were deployed with **empty proxy init data** and a separate `initialize()` call, leaving the proxy uninitialized for a tx window. An adversary front-running the `initialize()` tx becomes `owner()`, controls `_authorizeUpgrade` (onlyOwner), and can `upgradeToAndCall` to a malicious implementation that forges `verifyAndCalculate` outcomes into `PolicyManagerV2.settlePolicy` (PM trusts `msg.sender == pr.shield`, and the adapter *is* the registered shield) → mint unbacked `ClaimBond`s up to the 50% capacity ceiling, or brick settlement. The main deploy (`DeployLuminaV5Sepolia.s.sol`) correctly uses atomic `abi.encodeCall(...)` init in the proxy constructor — the T-30c script regressed from that safe pattern.

**Mitigating reality.** The founder's broadcast almost certainly initialized first, so the live adapters likely have the founder as owner. The defect is **latent**: any future re-deploy via this script, or any adapter whose `initialize` tx was dropped/replaced, is exploitable.

**Recommendation.** Deploy adapter proxies **atomically** (`new ERC1967Proxy(impl, abi.encodeCall(FlashShieldAdapter.initialize, (shield, productId)))`); resolve the shield↔adapter address chicken-and-egg with CREATE2 pre-computation. **Verify on-chain that each of the 6 live adapters' `owner()` is the founder Safe before mainnet.**

**References**: SWC-118; CWE-665 (Improper Initialization).

---

### F-06 [HIGH] — Flash shields skip `answeredInRound`/round-completeness validation

**CVSS 3.1**: 6.8 (`AV:N/AC:H/PR:N/UI:N/S:C/C:N/I:H/A:L`)
**Status**: Open
**Contract**: `src/shields/BaseFlashShield.sol:102-107` (`_currentPrice`). *(= B-1.)*

**Description.** `_currentPrice` validates only `answer > 0` and `block.timestamp - updatedAt <= MAX_PRICE_STALENESS`. It omits the `answeredInRound >= roundId` (incomplete/carried-over round) and `updatedAt != 0 / updatedAt <= block.timestamp` checks that `LuminaOracleV2.getLatestPrice` (192–208) *does* perform. A stale answer carried into a fresh round with a refreshed timestamp passes silently; an attacker observing divergence between a frozen feed and the true market can buy/trigger against the stale value. (A future-`updatedAt` would instead underflow-revert → DoS, not bypass.) The validated `LuminaOracleV2` reader is effectively **dead code** on the live trigger path (INFO-3), so the validation effort sits in the wrong contract; the testnet `MockAggregatorV3` always returns `answeredInRound == roundId`, hiding this gap in tests (INFO-2).

**Recommendation.** Add `require(answeredInRound >= roundId)`, `require(updatedAt != 0)`, `require(updatedAt <= block.timestamp)` to `_currentPrice` (or route all reads through one shared validated reader library).

**References**: SWC-114 (Chainlink data-feed misuse); Trail-of-Bits stale-price pattern.

---

### F-07 [HIGH — DORMANT] — Auto-injection (R1) force-trigger drains CEX reserve via manipulable capacity ratio

**CVSS 3.1**: 6.8 (`AV:N/AC:H/PR:N/UI:N/S:C/C:N/I:H/A:L`)
**Status**: Open — **DORMANT on-chain** (`cexReserve = 0x0`; live code, intended-on for mainnet)
**Contract**: `src/bonds/BondVault.sol:594-625` (`_checkAndInject`), `:631-633` (`pokeCheckAndInject`, permissionless), `:574-582` (`_availableCapacityRatioBps`); `src/treasury/CEXLiquidityReserve.sol:203-211` (`injectToVault`). *(= E-2.)*

**Description.** `pokeCheckAndInject()` is permissionless and `injectToVault` fires whenever available-capacity ratio ≤ 50%, pulling 10% of the CEX reserve's LUMINA balance into the vault. But the capacity ratio is a function of `reserveValueUSD = balance × currentPrice` — the **same manipulable TWAP as F-02**. An attacker depresses the price → capacity *looks* low → pokes injection → then redeems matured bonds (F-02) against the freshly-injected LUMINA at the depressed price. There is no cooldown, no per-caller limit, and no price-deviation gate; the floor-pause blocks new policies but not redemptions/injections. Damping is only that `injectAmount` shrinks as the reserve shrinks.

**Recommendation.** Gate the injection trigger behind a price-deviation check (reject price-only capacity dips); add an injection cooldown + cumulative cap per rolling window; require the dip to persist (sustained, not instantaneous); and fix F-02 so injected liquidity cannot be immediately drained at a manipulated price. **Re-audit when `cexReserve` is wired for mainnet.**

**References**: SWC-114; economic-design.

---

## MEDIUM Findings (condensed — full detail in the per-phase appendices)

| ID | Title | Contract:line | CVSS | Fix (one-line) |
|----|-------|---------------|------|----------------|
| **F-08** | `FlashShieldAdapter.createPolicy`/`verifyAndCalculate` unauthenticated → ghost policies, id desync, premature-finalize capacity DoS | `FlashShieldAdapter.sol:93,102` | 5.4 (`AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:L/A:L`) | gate both to `msg.sender == policyManager` (leave `checkAndSettlePolicy` permissionless) |
| **F-09** | `CapacityOracle.emergencyPrice` owner-override silently masks TWAP; short-window TWAP breaker grindable | `CapacityOracle.sol:82-90,175-186` | 5.8 (`AV:N/AC:H/PR:H/UI:N/S:C/C:N/I:L/A:L`) | bound `emergencyPrice` deviation vs last good TWAP; raise min window; never ship the no-pool/`emergencyPrice`-only path to mainnet |
| **F-10** | Redemption queue: unbounded FIFO push + head-of-line `break` + global (not per-user) throttle → liveness/fairness DoS | `BondVault.sol:346-359,418-456` | 6.5 (`AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:L/A:H`) | `continue`/partial-fill instead of `break`; bound queue len + min entry size; per-account sub-cap or pro-rata |
| **F-11** | `BuybackEngine` double-burn sizes vault burn from spot price → over-burn / forced deflation | `BuybackEngine.sol:186-194` | 5.3 (`AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:L`) | size burn from dual-sourced/long TWAP + deviation guard; cap `luminaToBurn` |
| **F-12** | FounderVesting "sustained 1 day" = only two oracle snapshots 24h apart (not continuous); `condB` wrongly gated on BTC-feed liveness → premature 8M LUMINA unlock | `FounderVesting.sol:104-149,236-240` | 5.9 (`AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:H/A:N`) | require continuous/N-spaced all-true observations on a TWAP/EMA; compute `condB` independent of `btcPrice` |
| **F-13** | Synchronous auto-burn DEX swap inside buyer's purchase tx + `tx.origin` gas refund → gas-grief / mis-targeted refund (**DORMANT**, `maxPurchasesBeforeBurn=0`) | `CoverRouterV2.sol:243`, `TWAPBurner.sol:120-138,493-527` | 3.7 (`AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:L`) | decouple burns from purchase hot path (use permissionless `executeBurn`/keeper); drop `tx.origin`; pull-based refund |
| **F-14** | Marketplace fill force-revert: USDC blacklist (or revert-on-receive) on seller/`twapBurner` bricks every `executeBuy` on that listing | `LuminaBondMarketplace.sol:170-171` | 3.7 (`AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:L`) | pull-payment for seller proceeds; try/catch the fee transfer |
| **F-15** | `MaintenanceReserve.monthlyCap` defaults to **0 = unlimited**; SPENDER_ROLE can drain entire USDC balance | `MaintenanceReserve.sol:107-116` | 4.9 (`AV:N/AC:L/PR:H/UI:N/S:U/C:N/I:N/A:H`) | require non-zero cap in `initialize`, or invert so `0` = disabled |
| **F-16** | `BondVault.setPolicyManager` one-shot bound to deployer **EOA**, not admin role → key-loss brick / privilege split | `BondVault.sol:234-241` | 5.3 (`AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:L/A:H`) | gate on `DEFAULT_ADMIN_ROLE` |
| **F-17** | Single-EOA owner/admin across all proxies, no timelock/multisig → upgrade power = unbounded fund control; no exit warning window | protocol-wide (see admin table) | 7.2 base, MEDIUM on testnet (`AV:N/AC:L/PR:H/UI:N/S:C/C:H/I:H/A:H`) | migrate owner/admin to Gnosis Safe + TimelockController; `Ownable2Step`; renounce `_deployer` powers — **must-fix pre-mainnet** |
| **F-18** | `ClaimBond.burnByHolder` never calls `decreaseObligations` → direct burns permanently inflate `totalCommittedUSD` (capacity choke) | `ClaimBond.sol:126-131`; `BondVault.sol:524` | 5.3 (`AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:L/A:L`) | have it call `bondVault.decreaseObligations`, or restrict to authorized engine |
| **F-19** | `TWAPBurner.executeBurn` (permissionless) derives `minOut` from the **DEX's own live quote** → sandwichable when oracle floor stale/absent | `TWAPBurner.sol:149-164,219-248` | 3.1–HIGHer-if-oracle-stale (`AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:L/A:N`) | derive `minOut` solely from an independent manipulation-resistant oracle; revert (not skip) if unavailable; private mempool |
| **F-20** | Sandbox API gas-drain DoS: `/sandbox/try` mints a real on-chain policy from the founder wallet; only per-IP rate-limited (10/h) → multi-IP sybil drains testnet ETH | API `POST /sandbox/try` | 5.3 (`AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:L/A:L`) | global hourly mint budget; sandbox-wallet balance auto-refill+alert; never reuse founder wallet as sandbox signer on mainnet |

---

## LOW Findings (condensed)

| ID | Title | Contract:line | CVSS |
|----|-------|---------------|------|
| **F-21** | `LuminaTokenV2.burnFrom` drops allowance check (intended H-1 fix; BURNER_ROLE = confiscation-capable) — document + hold role only via Safe/timelock, never an EOA | `LuminaTokenV2.sol:98-101` | 6.5 base, LOW given current sole holder = TWAPBurner |
| **F-22** | `TWAPBurner._autoBurn` uses `tx.origin` refund recipient + drains `address(this).balance` (bounded by `gasRefundCap`) | `TWAPBurner.sol:136,517-525` | 3.1 |
| **F-23** | No max-coverage ceiling in `_purchase` (only min $100 + capacity); one huge policy can lock out all others | `CoverRouterV2.sol:207-250` | 3.7 |
| **F-24** | Auto-burn path bypasses `burnCooldown` that `executeBurn` enforces → back-to-back burns, extra MEV surface | `TWAPBurner.sol:120-138 vs 149-151` | 3.1 |
| **F-25** | Marketplace `executeBuy` lacks the maturity check `list` has → matured-bond trade at stale listed price; listings never auto-expire | `LuminaBondMarketplace.sol:158-175` | 2.6 |
| **F-26** | `ClaimBond.reinitializeURI` is `reinitializer`-gated but **not** `onlyOwner` → griefer can burn version numbers / reset baseURI to default | `ClaimBond.sol:66` | 3.1 |
| **F-27** | `block.timestamp` boundary gaming on 7-day throttle epoch + bond maturity (±~15s proposer drift) | `BondVault.sol:383-385`, `ClaimBond.sol:144-147` | 3.1 |
| **F-28** | ERC-1155 `onERC1155Received` callback to buyer in `executeBuy` — cross-function reentrancy surface (currently blocked by `nonReentrant` + CEI) | `LuminaBondMarketplace.sol:158-175` | 3.1 |
| **F-29** | `checkAndSettlePolicy` only catches `WINDOW_EXPIRED`; stale/sequencer reverts strand settlement until `markExpired` (liveness; subsumed by F-03) | `FlashShieldAdapter.sol:149-166` | 3.1 |
| **F-30** | API: malformed JSON returns `500 internal_error` instead of `400` (error-class confusion; no info leak) | API body-parser | 2.3 |
| **F-31** | `BaseFlashShield` imports `IChainlinkAggregator.decimals()` but never reads it (latent decimal-mismatch; safe today — feed immutable, ratio cancels) | `BaseFlashShield.sol:102-107` | 2.4 |

---

## INFORMATIONAL

- **INFO-1** — Two parallel Chainlink interfaces (`IChainlinkAggregator` for shields vs `IAggregatorV3` for oracle) cause the F-06 validation drift; consolidate to one validated reader.
- **INFO-2** — Testnet `MockAggregatorV3` is owner-omnipotent (`setPrice/setStale/setRevert`) → fully deterministic trigger/strike on Sepolia; and `answeredInRound == roundId` always, hiding F-06 in tests. Must be the real Chainlink aggregator on mainnet (deploy script does not enforce it).
- **INFO-3** — The well-validated `LuminaOracleV2.getLatestPrice`/`getLatestRoundData` is dead code on the live flash-shield trigger path.
- **INFO-4** — `CoverRouterV2.syncCircuitBreaker` is permissionless and price-driven (lets anyone toggle the `autoPausedOnce` hysteresis flag; low impact).
- **INFO-5** — `PolicyManagerV2.getActivePolicyIds` is an unbounded `1..totalPolicies` view loop; can exceed `eth_call` gas as policies grow → degrades keeper *discovery* (not on-chain settlement, which is bounded to 10 per `performUpkeep`).
- **INFO-6** — Marketplace ↔ BuybackEngine self-deal wash-trade can front-run/drain the buyback `dailyBudget` (bounded by operator config + 3% fee); time-value arbitrage funded by the protocol.
- **INFO-7** — **Doc/spec mismatch:** the marketplace fee is hardcoded **3% (1.5% buyer + 1.5% seller)**, not the "2%" stated in the sprint brief / earlier docs. Fee arithmetic itself is correct.
- **INFO-8** — `CapacityOracle.setEmergencyPrice` and `LuminaOracleV2.setOracleKey`/`addSigner` are the highest-leverage centralization powers (owner can forge the price/trigger surface). Pure centralization; mitigated only by F-17 (Safe + timelock).

---

## Recommendations Summary

| # | Finding | Severity | Fix Effort | Priority |
|---|---------|----------|-----------|----------|
| 1 | F-01 flash-shield barrier-option harvest | CRITICAL | High (on-chain multi-block confirmation + dwell + re-price) | **Before any Fase 5 value** |
| 2 | F-02 TWAP-priced redemption extraction | HIGH | Medium (dual-source + deviation breaker, fail-closed) | Pre-mainnet (root-cause) |
| 3 | F-03 oracle-outage payout denial | HIGH | Medium (fallback + oracle-unavailable terminal state) | Pre-mainnet |
| 4 | F-04 queued-redemption capacity leak | HIGH | Low (`totalQueuedUSD` accumulator) | Pre-mainnet |
| 5 | F-05 uninitialized adapter proxy | HIGH | Low (atomic init) + on-chain `owner()` verification | Verify now |
| 6 | F-06 missing round validation | HIGH | Low (3 require lines / shared reader) | Pre-mainnet |
| 7 | F-07 auto-injection force-trigger | HIGH (dormant) | Medium | Before wiring `cexReserve` |
| 8 | F-08…F-20 | MEDIUM | Low–Medium | Pre-mainnet |
| 9 | F-17 governance → Safe+Timelock | MEDIUM | Medium (ops) | **Must-fix pre-mainnet** |
| 10 | F-21…F-31 / INFO | LOW/INFO | Low | Best-effort |

**Cross-cutting:** fixing the single price-surface root cause (F-02's dual-source + deviation-breaker + fail-closed pattern, plus F-01's on-chain confirmation) collapses F-01, F-02, F-07, F-11, F-19 and parts of F-03/F-10 simultaneously.

---

## Methodology Used

- STRIDE threat modeling per contract (spoofing/tampering/repudiation/info-disclosure/DoS/elevation).
- Adversarial manual code review — line-by-line on the critical contracts (BondVault, CoverRouterV2, PolicyManagerV2, TWAPBurner, BaseFlashShield, FlashShieldAdapter, the oracle stack, marketplace, FounderVesting), executed across **5 parallel specialist review streams** (oracle; reentrancy+DoS; access-control+upgrade+governance; economic+MEV; logic+cross-contract chains).
- Static analysis: **Slither 0.11.5** (full run, 377 results; triaged below).
- Fuzzing / invariants: **Foundry** invariant suite (`test/invariant/`, config `runs=1000, depth=500, fuzz runs=10000`) executed; existing **Echidna** property suite (`test/echidna/`, 14 invariants) reviewed.
- Live API probing (non-destructive recon): headers, CORS, rate-limits, input validation, sandbox cap.
- Cross-reference of tool output against manual findings; composability / multi-step attack-chain construction (Phase K).

---

## Tools Used

| Tool | Version | Findings contributed |
|------|---------|----------------------|
| Slither | 0.11.5 | 4 High / 64 Medium (static); corroborated F-04 reentrancy-balance class in `processQueue` (confirmed CEI-safe), F-13/F-22 `arbitrary-send-eth` in `TWAPBurner._autoBurn`, 31 `divide-before-multiply` (TWAP/BPS precision — reviewed, the value-bearing ones map to F-02), `weak-prng` on `_timestampToEpoch %12` (false positive — month math, not randomness) |
| Foundry (forge) | 1.5.1 | Build (clean) + invariant/fuzz execution — see Invariant Results below |
| Echidna suite (reviewed) | repo `test/echidna/` | 14 properties (FounderVestingV2 + 6 shields) reviewed; consistent with manual findings |
| Manual review (Claude, 5 streams) | — | 1 CRITICAL, 6 HIGH, and the majority of MEDIUM/LOW |
| API recon (curl) | — | F-20, F-30, INFO-7; confirmed strong helmet/CORS/rate-limit/input-validation baseline |
| Aderyn | n/a | **Unavailable** — npm install broken (`MODULE_NOT_FOUND`); deferred to a Linux CI run (consistent with prior sprints) |
| Mythril | n/a | **Unavailable** in this environment (DNS-blocked in prior sprints); deferred |

**Slither High triage:** `reentrancy-balance`/`reentrancy-no-eth` in `BondVault.processQueue` — manually confirmed **CEI-safe** (LUMINA is a trusted non-callback ERC-20; effects before transfer); flagged the *accounting* issue separately as F-04. `arbitrary-send-eth` in `TWAPBurner._autoBurn` → F-13/F-22. `weak-prng` → false positive.

**Invariant Results.** The repo's Foundry invariant suite (`test/invariant/`) was executed — **17 tests across 5 suites, 0 failed** (BondVault invariants + TWAPBurner `invariant_noOverBurn`, `invariant_receivedMatchesGhost`; 0 reverts/discards in handlers). The full-config run (`runs=1000, depth=500`) hangs in this Windows environment (known issue), so a bounded run (`runs=20, depth=30`) was used for the pass signal. **Coverage caveat:** the existing invariants do **not** exercise the adversarial paths behind F-04 (over-cap queue → new issuance against freed capacity) or F-11/F-02 (price-manipulated burn/redeem sizing) — the handlers neither manipulate the price oracle nor drive the over-cap queue then issue new bonds. The green invariants are therefore consistent with, and do not contradict, the manual findings; a recommended follow-up is to add red-team invariants (`totalCommittedUSD + totalReservedUSD + totalQueuedUSD` consistency; `LUMINA-out-per-epoch` bound; capacity-never-overstated-during-queue) and run Echidna 200k on a Linux host.

---

## Verdict

**Score**: **6.0 / 10**
**Verdict**: ⚠️ **NEEDS FIXES**

- **Recommendation for Fase 5 (testnet):** **CONDITIONAL YES** — proceed *only after F-01 is fixed*. F-01 is exploitable against the live flash-shield product now; left unfixed it invalidates the economic data Fase 5 is meant to collect (no real funds are at risk on Sepolia/mUSDC, so it is not a fund-loss emergency, but it is a product-correctness blocker). F-02/F-03/F-04 should also be addressed during Fase 5 since they govern redemption and claim settlement.
- **Recommendation for Fase 7 (mainnet):** **NO** — not until the full CRITICAL + HIGH set (F-01…F-07) and the governance hardening (F-17 → Safe + Timelock) are fixed and re-audited, plus the dormant features (F-07 auto-injection, F-13 auto-burn) re-reviewed at the moment they are armed.

**Why 6.0 and not lower:** the engineering discipline is genuinely strong (no reentrancy fund-theft, correct UUPS/storage-gap hygiene across many real upgrades, correct fee math, EIP-712 replay protection, rescue-blacklists, hardened API). **Why not higher:** the protocol's *core promise* — correctly pricing triggers and honoring/limiting payouts — rests on a single un-cross-checked price read and a settlement state machine that can deny valid claims; the one CRITICAL is live and trivially profitable.

---

## Pending Items (not fully audited / require more time or environment)

1. **On-chain verification** of the 6 live FlashShieldAdapter proxies' `owner()` (F-05) and of `BURNER_ROLE`/`DEFAULT_ADMIN_ROLE` custody on `LuminaTokenV2`/`BondVault` (F-17/F-21) — requires RPC state reads against Base Sepolia.
2. **Mythril** symbolic execution on the 5 critical contracts and **Aderyn** — both unavailable in this Windows environment; defer to Linux CI.
3. **Echidna 200k-run** custom red-team invariants (the brief's Phase N.1 target) — Echidna is not installed on Windows; the existing 14-property suite was reviewed statically and the Foundry invariant suite was executed instead.
4. **Live TWAP-manipulation cost modeling** for F-02/F-07 on the actual mainnet LUMINA/USDC pool depth (testnet pool is empty/owner-priced).
5. **SDK supply-chain** (`@lumina-org/sdk` npm 2FA / provenance) — off-chain, founder action.

---

*Engagement conducted under explicit authorization from the protocol founder (`agustin.tiberio@gmail.com`, owner `0xe585…BfDa8`). No contracts were modified; no exploit was executed on-chain (testnet or mainnet); PoCs are conceptual. Per engagement rules, the live-exploitable CRITICAL (F-01) is escalated at the top of this report.*
