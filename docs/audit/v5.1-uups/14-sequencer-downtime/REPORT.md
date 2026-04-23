# Audit V5.1 #14 — Sequencer Downtime: Report

**Branch:** `audit/v5.1-14-sequencer-downtime`
**Date:** 2026-04-23
**Verdict:** ROBUST — with one informational finding about production oracle wiring.

---

## 1. Summary

Base L2 uses a single centralized sequencer. When it goes down, transactions
are not mined, Chainlink feeds can't update, and on-chain state that depends
on a "use-it-or-lose-it" deadline risks unfair loss. This audit maps every
place in V5.1 that could care about sequencer status and verifies the one
place that does (BaseShield's cleanup-window extension) actually works as
intended across every Shield product.

**Bottom line:** V5.1 handles downtime correctly. The only touch-point —
`_validateStatusForTrigger` in `BaseShield` — extends the trigger-cleanup
window by the reported downtime so users don't lose a valid claim because
the sequencer ate their cleanup grace period. Every concrete Shield
inherits this, no shield overrides it, and no other contract needs
additional gating (by the "if-mined-then-up" L2 invariant — see
§4 for the full coverage rationale).

## 2. What was verified

See `01-SEQUENCER-IMPACTS.md` for the inventory. In short:

- `IOracle.getSequencerDowntime(uint256 sinceTimestamp) view returns (uint256)` — interface in `src/interfaces/IOracle.sol`.
- `BaseShield._validateStatusForTrigger` — only call site in `src/`. Extends `cleanupAt` by the reported downtime.
- No other `src/` contract references the sequencer.

## 3. Tests

File: `test/audit/v5.1-uups/external-deps/sequencer/SequencerDowntime.t.sol`

**23 tests, 100% substantive (all call real shield contracts through proxies).**

Organised into six sections:

| Section | Count | Coverage |
|---|---|---|
| A. Cleanup window — baseline (no downtime) | 3 | Within cleanup / past cleanup / at exact cleanup |
| B. Cleanup window — extension | 5 | 60s / 1h / boundary / 24h / mutated mid-call |
| C. IOracle integration contract | 3 | Callable / default 0 / zero-downtime no-op |
| D. Coverage matrix (all 8 shields inherit) | 8 | BTC 1h/4h/24h/48h, ETH 1h/24h/48h, MicroDepeg |
| E. Non-gating (createPolicy / views) | 2 | Proves design intent |
| F. Edge cases | 2 | `type(uint256).max` overflow, finalized policy |

### Key assertion pattern

Rather than relying on side-effects or storage reads that aren't exposed,
the tests call `verifyAndCalculate` with an empty proof and assert that the
first 4 bytes of the revert data — the selector — is or is not the
`InvalidPolicyStatus` selector. That cleanly separates "the status check
fired" (the sequencer logic blocked us) from "we got past the status check"
(the sequencer extension let us through, and we then hit an oracle-proof
revert, which is a different code path).

## 4. Why no further gating is needed (design note)

We deliberately do NOT block `CoverRouterV2.purchasePolicy`, `BondVault.redeemBond`,
`TWAPBurner.executeBurn`, or `Marketplace.list/buy` on sequencer status:

- **"If my tx is mined, the sequencer is up"**: any function that *just got called*
  is proof the sequencer is processing transactions. An explicit `revert "sequencer down"`
  inside such a function is incoherent.
- **Only time-based state with a "use-it-or-lose-it" semantic needs awareness**:
  cleanup windows. Bond maturities and burn cooldowns don't expire — they
  just wait. Policy purchase doesn't have a deadline that can expire on you.
- **Stale Chainlink price handling**: covered by audit #11 chainlink-failures
  paths (price = 0 / negative / sanity bounds).

We confirmed this intent with two documentary tests:
`test_Sequencer_UUPS_CreatePolicy_NotGatedOnDowntime` and
`test_Sequencer_UUPS_GetPolicyInfo_NotGatedOnDowntime` — both succeed with
`sequencerDowntime = 48h`.

## 5. Findings

### 5.1 INFO — No concrete `IOracle.getSequencerDowntime` implementation in `src/`

The interface is declared in `src/interfaces/IOracle.sol` and consumed by
`BaseShield`, but `src/` contains no production implementation. The only
implementation lives in `archive/v1-deprecated/oracles/LuminaOracle.sol`
(with Chainlink Sequencer Uptime Feed + `MIN_DOWNTIME_EXTENSION = 2 hours`).

**Impact:** Tests pass because mocks return a configurable downtime (or 0).
**Mainnet impact:** If the production oracle contract returns 0 unconditionally,
the extension is a no-op. Users would lose trigger rights on any cleanup
window that falls during a sequencer outage.

**Recommendation:** Before mainnet, deploy an oracle contract that
implements `getSequencerDowntime` against Chainlink feed
`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` with at least a 1–2 hour
minimum extension. A port of the archived `LuminaOracle` logic is sufficient.

### 5.2 DESIGN NOTE — Single-point sequencer awareness

The cleanup-window extension is the only sequencer-aware code path in V5.1.
We documented and verified (§4) that this is both sufficient and correct
for this protocol's semantics. Other code paths silently process operations
when called, which is the right behavior — they couldn't execute if the
sequencer was genuinely down.

### 5.3 No issues of HIGH / MEDIUM / LOW severity found.

## 6. Coverage matrix verification

All eight shield implementations were exercised with a 1-hour downtime
against a 30-minute-past-cleanup timestamp; all eight passed the
`_validateStatusForTrigger` check. No overrides of that function exist
anywhere in `src/`, so inheritance is guaranteed.

## 7. Regression

Command:

```
forge test --no-match-contract "Fork" --no-match-path "test/audit/invariant*"
```

Result (final line from this run):

```
Ran 106 test suites in 22.55s (91.17s CPU time): 1672 tests passed, 0 failed, 0 skipped (1672 total tests)
```

Baseline before audit was 1649. The +23 delta is exactly the new test file.

## 8. Reverse audit

- **Total tests:** 23
- **% substantive:** 100% (every test deploys real shield proxies and calls real methods)
- **Quality:** 9.5/10 — covers baseline, extension, edge cases, cross-shield inheritance, and design-intent documentation. Trade-off: we don't test the real Chainlink-feed integration (no concrete oracle exists in `src/`), so we rely on the archived V1 implementation as the reference contract for the interface. That's consistent with the finding in §5.1.

## 9. Verdict

**ROBUST** — with one informational finding (§5.1) about production
oracle wiring, which is a deployment task, not a code defect.
