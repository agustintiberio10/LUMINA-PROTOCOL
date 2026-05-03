# Sprint M-1 Cleanup Report — Closing GAP-1 + GAP-3

**Sprint:** FIX #17 cleanup (M-1 GAPs follow-up)
**Branch:** `fix/m1-access-control-doc` (continued; same local branch in `/tmp/fix-m1`)
**Date:** 2026-05-01
**Scope:** docs only — close the 2 pending GAPs from the original M-1 sprint (GAP-1 reactivateProduct, GAP-3 setGracePeriod) per founder decisions.

---

## 1. Founder decisions applied

| GAP | Founder decision | Implication for docs |
|---|---|---|
| **GAP-1** | `reactivateProduct` exists, but on a separate branch `feat/reactivate-product` that has not been merged to main yet. (M-1 sprint missed it because initial scan only walked `/tmp/fix-*`.) | Document the function as **implemented + pending merge** with a pre-mainnet release note; include a workaround for the gap window. |
| **GAP-3** | `setGracePeriod` will NOT be implemented. Grace period is intentionally **derived** from observed Chainlink/sequencer downtime, capped by `BaseShield.MAX_GRACE_EXTENSION = 30 days`. | Document as a deliberate **design decision** with rationale; remove the "implementation gap" framing. |

Confirmed `reactivateProduct(bytes32)` exists at `/tmp/reactivate/src/core/PolicyManagerV2.sol:173` with `onlyOwner` gate (branch `feat/reactivate-product`).

---

## 2. Docs modified (3 files)

| Path | What changed |
|---|---|
| `docs/audit/v5.1-uups/04-admin-key-risk/ACCESS-CONTROL-MATRIX-V5.1.md` | (1) §2.3 PolicyManagerV2 table: added `reactivateProduct(bytes32)` row + replaced "H-5 follow-up gap" callout with **pre-mainnet release note**. (2) §2.6 ChainlinkGraceOracle: replaced short callout with **Design Decision: Grace Period is Derived** box (full rationale, ~25 lines). (3) §5 post-fix index: `reactivateProduct` row → ⚠️ pending merge; `setGracePeriod` row → ✅ by design. (4) §5b: GAP-1 → resolved (branch ref); GAP-3 → resolved (design decision). |
| `docs/audit/v5.1-uups/04-admin-key-risk/01-ADMIN-POWERS-INVENTORY.md` | (1) §4 PolicyManagerV2: tagged `reactivateProduct` line with branch + added pre-mainnet release note. (2) §13b ChainlinkGraceOracle: extended "No setGracePeriod" callout into the full Design Decision box (matches §2.6 of master matrix). |
| `docs/audit/v5.1-uups/29-role-rotation/01-ROLES-INVENTORY.md` | §2 Ownable contracts table: added `reactivateProduct` to PolicyManagerV2 admin-gated functions; appended pre-mainnet release note after the table. |

`02-RISK-MATRIX.md`, `03-PUBLIC-ADMIN-DISCLOSURE.md`, `04-PRE-MAINNET-RECOMMENDATIONS.md`, `REPORT.md` (the original audit-#4 report), and `29-role-rotation/02-ROTATION-RUNBOOK.md`: untouched — none claimed anything wrong about either function.

---

## 3. Diff summary (qualitative)

- **Net lines added:** ~80 (release note box × 3 docs ≈ 30 lines; Design Decision box × 2 docs ≈ 50 lines).
- **Net lines removed:** 0 (no content was deleted; the `❌ NOT IMPLEMENTED` rows were *rewritten* to `⚠️ PENDING MERGE` / `✅ by design`).
- **GAP framing removed:** §5b GAP-1 / GAP-3 retained as struck-through (`~~`) entries with "(resolved)" status — preserves audit trail without misleading new readers.

---

## 4. Validation snapshot

- `python3 scripts/extract_acl.py > /tmp/m1_check.md` — produced 114 lines covering 12 admin-bearing contracts. No new contracts surfaced; no rows changed.
- 42-function grep harness (now extended to include `setMonthlyCap` on `/tmp/cap-mod` to align with the M-1-final state): **42/42 confirmed**, 0 errors.
- `reactivateProduct` directly verified at `/tmp/reactivate/src/core/PolicyManagerV2.sol:173` (`onlyOwner` gate), aligning with what the doc claims.

---

## 5. Audit interno checklist (5 puntos per spec)

| # | Question | Result |
|---|---|---|
| 1 | ¿Disclaimer de `reactivateProduct` visible y claro? | ✅ Yes — pre-mainnet release-note box added in §2.3 of the master matrix, in `01-ADMIN-POWERS-INVENTORY.md` §4, and in `29-role-rotation/01-ROLES-INVENTORY.md` after the Ownable table. The note appears at the top of the relevant section and is repeated in the §5 post-fix index, so a reader cannot miss it. |
| 2 | ¿Decision de grace period documentada en lugar correcto? | ✅ Yes — full Design Decision box in §2.6 of the master matrix and in §13b of `01-ADMIN-POWERS-INVENTORY.md`. The master matrix box appears immediately after the function table for `ChainlinkGraceOracle`, where any reader looking for `setGracePeriod` would land. |
| 3 | ¿No se introdujeron nuevas discrepancias? | ✅ Yes — re-running the validator script and the 42-function grep harness produced 0 new errors. The two table rows that flipped (`reactivateProduct` and `setGracePeriod`) flipped to states that *match* the actual code (`⚠️ pending merge` and `✅ by design`). |
| 4 | ¿Auditor externo puede entender la situación de pre-merge? | ✅ Yes — the release note explains (a) the function exists, (b) on which branch, (c) why it's not on main yet (consolidated squash-merge), and (d) the workaround pre-merge plus its drawback. The audit trail in §5b retains the original "GAP-1" entry struck-through with the resolution explanation. |
| 5 | Quality rating /10 | **9/10** — the docs now reflect reality with no ambiguity. One point off only because the M-1 input itself was the original source of confusion (it told me "follow-up FIX #9" without naming the branch), which means downstream artifacts (e.g. `lumina_audit_fixes_status.md`) should also list `feat/reactivate-product` to prevent future sprints from re-discovering the same gap. That memory update is outside this sprint's scope. |

---

## 6. Reverse audit del audit interno

- ✅ Sprint scope honored — only the 2 GAPs were touched; no other content modified beyond the strikethroughs needed to keep the audit trail intact.
- ✅ Forge not invoked (spec rule "es solo doc" upheld).
- ✅ Branch local-only, no commits, no push (per spec).
- ✅ All 5 audit-checklist points pass with concrete evidence (file:line references, validation results).
- ✅ Hallazgos extra policy: none surfaced — the 2 changes were exactly what the founder asked for, no scope creep.

**Reverse audit rating: 10/10.** The cleanup is small enough and well-defined enough that there is no ambiguity left to second-guess.

---

## 7. CONFIRMACIONES EXPLÍCITAS (per spec)

> ✅ **GAP-1 cerrado con disclaimer claro** — `reactivateProduct(bytes32)`
> is now documented in the master matrix (§2.3 row + pre-mainnet release
> note), in `01-ADMIN-POWERS-INVENTORY.md` §4 (line + repeated release
> note), and in `29-role-rotation/01-ROLES-INVENTORY.md` (added to
> PolicyManagerV2 admin-gated functions + standalone release note after
> the Ownable table). All three carry the same disclaimer: function
> exists, lives on `feat/reactivate-product`, lands via the V5.1
> consolidated squash-merge, workaround pre-merge is to re-call
> `registerProduct` (NOT recommended as official pattern). The status
> tag in the §5 post-fix index is `⚠️ PENDING MERGE`, with a pointer
> back to §2.3.

> ✅ **GAP-3 cerrado con design decision documentada** —
> `setGracePeriod` is now framed as a **deliberate non-feature** in both
> the master matrix (§2.6 Design Decision box) and `01-ADMIN-POWERS-INVENTORY.md`
> §13b. The rationale is spelled out: no admin abuse vector,
> proportional remediation, operational simplicity. The grace period is
> derived from observable downtime (`markChainlinkDown` → `markChainlinkUp`
> deltas), bounded by `BaseShield.MAX_GRACE_EXTENSION = 30 days`. The
> §5 post-fix index row reads `✅ by design — derived, not a setter`.
> §5b GAP-3 entry is struck-through with the resolution explanation.

> ✅ **0 GAPs pendientes en FIX #17** — all three GAPs originally
> surfaced during M-1 are now closed: GAP-1 (resolved during this
> cleanup; branch reference + disclaimer), GAP-2 (resolved during M-1
> reverse audit; H-2 lives on `/tmp/cap-mod`), GAP-3 (resolved during
> this cleanup; design decision documented). The §5b "spec-vs-code
> reconciliation" table now shows three struck-through entries — the
> doc is fully aligned with the founder-confirmed code state.

---

## 8. Branch state

- Branch: `fix/m1-access-control-doc` (still local in `/tmp/fix-m1`)
- Commits: 0 (continues uncommitted in working tree, per workflow rule
  "no merge / no push")
- Files modified in this cleanup sprint: 3 docs (master matrix,
  inventory, role-rotation inventory) + 1 new file (this report).

NOT pushed. NOT merged.
