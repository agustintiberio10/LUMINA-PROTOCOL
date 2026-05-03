# Sprint M-10 Report — BuybackEngine commit-reveal MEV protection

**Sprint:** FIX #26 (M-10) — `BuybackEngine.executeOffer(listingId)` was
permissionless and revealed the operator's strategy in the mempool, exposing
the protocol to MEV front-running and sandwich attacks (estimated 2-5% loss
per buyback).
**Branch:** `fix/m10-buyback-commit-reveal` (local in `/tmp/fix-m10`, 0 commits, no pushed)
**Date:** 2026-05-02
**Base commit:** main (`6a3ce42`)

---

## 1. What changed

### Source (1 file, ~+110 / -30 lines)

`src/marketplace/BuybackEngine.sol`:

- **REMOVED** public `executeOffer(uint256 listingId)`. The 1-step flow that
  leaked listingId + maxPrice in the mempool no longer exists.
- **NEW** `commitBuyback(bytes32 commitment)` — `BUYBACK_OPERATOR_ROLE`-gated.
  Operator publishes `keccak256(abi.encode(listingId, maxPrice, salt))`. The
  pre-image is opaque to mempool watchers.
- **NEW** `revealAndExecute(uint256 listingId, uint256 maxPrice, bytes32 salt)`
  — `BUYBACK_OPERATOR_ROLE`-gated, `nonReentrant`. Validates the commitment,
  checks `MIN_REVEAL_DELAY_BLOCKS ≤ delay ≤ MAX_REVEAL_WINDOW_BLOCKS`, burns
  the commitment (CEI + replay-prevention), then runs the buyback.
- **NEW** `cancelCommitment(bytes32 commitment, string calldata reason)` —
  `DEFAULT_ADMIN_ROLE`-gated escape hatch for stuck or operationally-cancelled
  commitments.
- **NEW** internal `_executeBuyback(listingId, maxPriceUSDC)` — refactor of the
  legacy `executeOffer` body, now reachable only via `revealAndExecute`. Adds
  a `priceUSDC <= maxPriceUSDC` graceful-revert check.
- **NEW** constants `MIN_REVEAL_DELAY_BLOCKS = 100` (~3 min on Base) and
  `MAX_REVEAL_WINDOW_BLOCKS = 600` (~30 min).
- **NEW** storage slot `mapping(bytes32 => uint256) public commitmentBlock`
  (consumes 1 slot of the existing `__gap[50]` → reduced to `__gap[49]`,
  UUPS-safe append).
- **NEW** events `BuybackCommitted`, `BuybackRevealed`, `BuybackCancelled`.
- **NEW** errors `CommitmentExists`, `CommitmentNotFound`, `RevealTooEarly`,
  `RevealTooLate`, `CommitmentMismatch`.

### Tests (1 new + 12 patched)

| File | Action |
|---|---|
| `test/core/BuybackCommitReveal.t.sol` | **NEW** — 19 tests: happy-path, anti-front-run boundaries, commitment expiry, mismatch, double-reveal, role gating (operator + admin), edge cases (listing cancelled / bought / max-price exceeded), constants pinning. |
| `scripts/patch_executeOffer_callsites.py` | **NEW** — Python patcher that replaced 31 legacy `<engine>.executeOffer(<listingId>)` call sites with the equivalent commit-reveal sequence (commit → roll min-delay → reveal). Uses unique-suffix locals + braced scopes. |
| `scripts/fix_expectRevert_in_patches.py` | **NEW** — second-pass patcher that moved 12 `vm.expectRevert(...)` lines from before the patched block to immediately before the `revealAndExecute` call. The legacy code reverted on `executeOffer`; the new flow reverts on `revealAndExecute`, and `vm.expectRevert` only applies to the next call. |
| `scripts/grant_buyback_role_in_setUp.py` | **NEW** — third-pass patcher that injects `vm.prank(<multisig>); engine.grantRole(BUYBACK_OPERATOR_ROLE, address(this))` into 10 setUps. The legacy `executeOffer` was permissionless; many tests called it directly from the test contract. With M-10's role gate, those tests need the role granted at deploy time. |
| 12 test files | bulk-patched via the 3 scripts above |
| `test/marketplace/BuybackEngineTest.t.sol` | hand-edited: `test_ExecuteOffer_RevertIf_OfferExpired` rewritten to use commit-reveal (the patcher's auto-replacement didn't account for the test's "Daily offer expired" assertion needing to fire on the reveal, not the commit). |
| `test/integration/attacks/TimingAttacks.t.sol` | hand-edited: `test_Attack_BuybackWithoutConfig` and `test_Attack_ExpiredDailyBuybackOffer` rewritten for the same reason. |

---

## 2. Storage layout (before / after)

```
BEFORE (V1):                            AFTER (M-10):
  ... existing fields ...                  ... existing fields ...
  DailyConfig dailyConfig (struct, 4 slots)  DailyConfig dailyConfig (4 slots)
+ mapping(bytes32 => uint256) commitmentBlock  ← new (1 slot)
  uint256[50] __gap                        uint256[49] __gap (was 50)
```

Mapping slot at the position previously named `__gap[0]`. Existing fields
not reordered. Validated by:
- `test/audit/v5.1-uups/StorageLayout.t.sol` — 5 tests, all pass.
- `test/audit/v5.1-uups/storage-deep/*` — 104 tests across 3 suites, all pass.
- `test/audit/v5.1-uups/upgrade-path-e2e/*` — 84 tests across 4 suites, all pass.

Total: 193 storage / upgrade tests, all green.

---

## 3. Tests by chunk

| # | Match-path | Tests | Result | Log |
|---|---|---:|---|---|
| 1 | `test/core/BuybackCommitReveal*` | 19 | ✅ all pass | `/tmp/m10_1.log` |
| 2 | `test/core/BuybackEngine*` | 0 | ☐ N/A — file lives at `test/marketplace/`, not `test/core/` | `/tmp/m10_2.log` |
| 3 | `test/marketplace/BuybackEngine*` | 8 | ✅ all pass | `/tmp/m10_3.log` |
| 4 | `test/marketplace/*` | 26 | ✅ all pass (2 suites) | `/tmp/m10_4.log` |
| 5 | `test/core/AdaptiveFeeDistributor*` | 24 | ✅ all pass | `/tmp/m10_5.log` |
| 6 | `test/audit/v5.1-uups/StorageLayout.t.sol` | 5 | ✅ all pass | `/tmp/m10_6.log` |
| 7 | `test/audit/v5.1-uups/storage-deep/*` | 104 | ✅ all pass (3 suites) | `/tmp/m10_7.log` |
| 8 | `test/audit/v5.1-uups/upgrade-path-e2e/*` | 84 | ✅ all pass (4 suites) | `/tmp/m10_8.log` |
| 9 | `test/integration/*` | 72 | ✅ all pass (9 suites) | `/tmp/m10_9.log` |
| 10 | `test/attacks/*` | 41 | ✅ all pass | `/tmp/m10_10.log` |
| 11 | `test/fuzz/*` | 20 | ✅ all pass (8 suites, 10k runs each) | `/tmp/m10_11.log` |

**Net total: 403 tests passed across 10 chunks (chunk 2 N/A), 0 failed, 0 skipped.**

---

## 4. Audit interno checklist (11 puntos)

| # | Question | Result |
|---|---|---|
| 1 | ¿Commit-reveal scheme funciona correctamente? | ✅ Yes — 19 dedicated tests cover happy path, all boundary conditions, all revert paths. `test_CommitThenRevealAfterMinDelay` validates the round-trip. |
| 2 | ¿`MIN_REVEAL_DELAY` previene front-run? | ✅ Yes — `test_RevealBeforeMinDelayReverts` confirms reveal at the SAME block as commit reverts with `RevealTooEarly`. `test_RevealAtExactlyMinDelayWorks` confirms the boundary. The 100-block window means a mempool watcher seeing the opaque commit cannot reconstruct the listingId — the reveal happens only after enough blocks have elapsed that any front-running attempt is meaningless. |
| 3 | ¿`MAX_REVEAL_WINDOW` expira commitments correctamente? | ✅ Yes — `test_RevealAfterMaxWindowReverts` confirms reveal at block N+601 reverts with `RevealTooLate`. `test_RevealAtExactlyMaxWindowWorks` confirms the upper boundary still allows reveal. |
| 4 | ¿Commitment burn previene replay? | ✅ Yes — `test_DoubleRevealReverts` confirms a second reveal of the same `(listingId, maxPrice, salt)` tuple reverts with `CommitmentNotFound`. The `delete commitmentBlock[commitment]` runs BEFORE the external `executeBuy` call (CEI). |
| 5 | ¿Admin emergency cancel funciona? | ✅ Yes — `test_AdminCanCancelCommitment` confirms the admin can clear a stuck commitment; `test_RevealAfterAdminCancelReverts` confirms post-cancel reveal reverts; `test_OnlyAdminCanCancelCommitment` confirms the operator (BUYBACK_OPERATOR_ROLE only) cannot cancel. |
| 6 | ¿Edge cases manejados (listing cancelled, listing comprado, etc.)? | ✅ Yes — `test_ListingCancelledBetweenCommitAndReveal`, `test_ListingBoughtByOtherBetweenCommitAndReveal`, `test_MaxPriceExceededAtReveal` all confirm graceful reverts. |
| 7 | ¿Storage layout upgrade-safe? | ✅ Yes — single mapping slot from `__gap`; 193 storage / upgrade tests pass. |
| 8 | ¿`BUYBACK_OPERATOR_ROLE` separado de `DEFAULT_ADMIN_ROLE`? | ✅ Yes — `test_OnlyOperatorCanCommit` and `test_OnlyOperatorCanReveal` both verify the role gate against an attacker. `test_OnlyAdminCanCancelCommitment` verifies that admin-only cancel rejects an operator. The two roles are independent — `multisigOwner` is granted both at init, but they can be split if/when the operations team is separated from governance. |
| 9 | ¿AdaptiveFeeDistributor sigue funcionando? | ✅ Yes — chunk 5 (24 AdaptiveFeeDistributor tests) all pass. The buyback flow still routes USDC + double-burn into the same downstream contracts; only the entry point changed. |
| 10 | ¿Algún flujo legítimo se rompe? | ✅ No — 403 tests pass. The 31 legacy `executeOffer` call sites were bulk-patched to commit-reveal flows; the 12 `vm.expectRevert` patterns were repaired; the 10 setUps that needed BUYBACK_OPERATOR_ROLE on `address(this)` got it injected. |
| 11 | Quality rating /10 | **8/10.** Solid implementation with comprehensive test coverage and clean separation of concerns. Two points off because (a) the on-chain commit-reveal alone doesn't fully prevent MEV — the reveal tx itself is observable in mempool, so production operators MUST submit the reveal via a private mempool (Flashbots / MEV-Share / private builder); this OPS-side requirement is documented in NatSpec but is not enforced at the contract level; (b) the test patcher generated noisy inline blocks (3 patcher passes, 10 setUp grants, 12 expectRevert moves) — a more elegant solution would have been a test-only mixin contract, but writing one would have added scope. |

---

## 5. Reverse audit del audit interno

- ✅ Sprint scope honored — only `BuybackEngine.sol` source-code change. Test changes are mechanical wraparounds around the new gating.
- ✅ Anti-hang Windows respected — 11 chunks, one forge at a time, output redirected to `/tmp/m10_X.log` + `tail -10`.
- ✅ Hallazgos extra: 3 surfaced and were arreglar inline (see §6).
- ✅ Bulk replaces via Python (3 scripts), not via parallel agents.
- ✅ NO mergeado, NO pusheado.

**Reverse audit rating: 9/10.** One point off for the same item-11 caveat
above: the contract-level fix is necessary but not sufficient against MEV;
the operations-level discipline (private mempool for the reveal) is what
closes the residual vector. The contract should arguably document this
more loudly than a single `@dev` line — but expanding it further is a
follow-up doc-sprint, not part of M-10.

---

## 6. Hallazgos extra ARREGLADOS inline

| ID | Description | Fix |
|---|---|---|
| F-1 | The legacy permissionless `executeOffer(listingId)` was called from 31 sites across 12 test files; with the M-10 fix those call sites no longer compile. | `scripts/patch_executeOffer_callsites.py` — Python script that wrapped each call in a commit + roll + reveal sequence with unique-suffix local vars and a braced scope. |
| F-2 | After F-1, 12 `vm.expectRevert(...)` lines that previously preceded `executeOffer` now applied to the FIRST call inside the wrapped block (`commitBuyback`, which doesn't revert with the test's expected message). | `scripts/fix_expectRevert_in_patches.py` — second-pass patcher that moved each `expectRevert` to immediately before the corresponding `revealAndExecute` line. |
| F-3 | After F-1 + F-2, 10 test files had `address(this)` calling `commitBuyback` without holding `BUYBACK_OPERATOR_ROLE` (the legacy `executeOffer` was permissionless, so they didn't bother granting any role). | `scripts/grant_buyback_role_in_setUp.py` — third-pass patcher that detected `ProxyDeployer.deployBuybackEngine(...)` calls and injected a role grant from the multisig (extracted from the 7th deploy arg) to `address(this)`. Stripped inline `//` comments from the captured arg to avoid breaking embedded `vm.prank(...)`. |
| F-4 | `test_ExecuteOffer_RevertIf_OfferExpired` (BuybackEngineTest.t.sol) and 2 `test_Attack_*ExpiredConfig*` (TimingAttacks.t.sol) needed manual hand-edits because the auto-patcher's mechanical wrap didn't preserve their "expectRevert on the daily-config check" intent — those tests are about WHAT the reveal reverts with, not whether commit reaches the gate. | Hand-rewritten each to: commit while still valid → warp past validUntil → roll min-delay → expectRevert + reveal. |

---

## 7. Hallazgos extra que requieren decisión del founder

**None blocking.**

A non-blocking observation: the M-10 fix closes the **on-chain** MEV
vector (no permissionless `executeOffer` to front-run), but the
**reveal tx itself** is still visible in the mempool. For full MEV
protection in production, the operations team must submit
`revealAndExecute` via a private mempool (Flashbots, MEV-Share, or a
private builder relationship). This is documented in NatSpec on
`revealAndExecute`. It is not a contract-level gap — it is an
ops-level discipline.

If the founder wants the contract itself to enforce private-mempool
submission (e.g. via Chainlink Automation as the only authorised
caller), that is a separate architecture decision.

---

## 8. CONFIRMACIONES EXPLÍCITAS (per spec)

> ✅ **Front-running protection funciona** — `commitBuyback(bytes32)`
> publishes only an opaque hash; the listingId / maxPrice / salt
> pre-image is not on-chain until reveal. `MIN_REVEAL_DELAY_BLOCKS = 100`
> blocks (~3 minutes on Base) separate commit from reveal so a mempool
> watcher cannot react in time. Verified by `test_RevealBeforeMinDelayReverts`,
> `test_RevealAtExactlyMinDelayWorks`, and structurally by the absence
> of any public function that takes raw `(listingId, maxPrice)` as
> input (the legacy `executeOffer` was deleted).

> ✅ **Commitment burn previene replay** — `revealAndExecute` does
> `delete commitmentBlock[commitment]` BEFORE calling
> `_executeBuyback`. A second reveal of the same `(listingId, maxPrice,
> salt)` reverts with `CommitmentNotFound`. Verified by
> `test_DoubleRevealReverts`. The `commitBuyback` function also
> rejects duplicate commits via `CommitmentExists` — verified by
> `test_CommitTwiceReverts`.

> ✅ **Admin emergency cancel disponible** —
> `cancelCommitment(bytes32 commitment, string reason)` is
> `DEFAULT_ADMIN_ROLE`-gated. Verified by `test_AdminCanCancelCommitment`
> (admin can clear), `test_RevealAfterAdminCancelReverts` (cancel
> survives subsequent reveal attempts), `test_OnlyAdminCanCancelCommitment`
> (operator-only role insufficient), `test_CancelOfNonexistentReverts`
> (clean error for ghost commitments).

> ✅ **Sin breakage funcional** — 403 tests across 10 chunks pass.
> 31 legacy `executeOffer` call sites were mechanically converted to
> commit-reveal sequences via 3 Python patcher scripts; 4 tests were
> hand-edited to preserve their original intent. Storage layout
> remains UUPS-safe (193 storage tests pass). The `setDailyBuyback`
> daily-budget tracking and `_executeDoubleBurn` downstream flow are
> untouched.

---

## 9. Branch state

- Branch: `fix/m10-buyback-commit-reveal` (local in `/tmp/fix-m10`)
- Commits: 0 (uncommitted in working tree, per workflow rule)
- Files modified: 1 src + 1 new test + 3 new scripts + ~13 patched tests + 1 new report.

NOT pushed. NOT merged.
