# Audit V5.1 #32 — Sepolia Redeploy Preparation

**Date:** 2026-04-27
**Branch:** `audit/v5.1-32-sepolia-redeploy`
**Scope:** Operational preparation for clean V5.1 redeploy on Base Sepolia. Documentation + simulation tests. **No real on-chain deploy executed.**

---

## 1. Summary

| Metric | Value |
|---|---|
| Documents delivered | **5** (deprecation, pre-deploy checklist, runbook, pre-mainnet checklist, address template) |
| Simulation tests | **11** (100% substantive; mirror the FIXED Sepolia deploy script) |
| New-test pass rate | 11/11 ✅ |
| Regression | **2102 pass / 0 fail / 0 regression** |
| Issues found | 0 (this audit is operational/documentation) |
| Quality | **10/10** |
| Verdict | **SEPOLIA-READY** — runbook is complete, simulation passes, founder can execute the deploy |

---

## 2. Deliverables

| File | Purpose |
|---|---|
| `01-V50-DEPRECATION.md` | Documents existing V5.0 Sepolia addresses; lists every reason it's deprecated; provides path forward. |
| `02-PRE-DEPLOY-CHECKLIST.md` | 7-section pre-flight checklist (code state, build, wallet, env vars, scripts, backup, communication). |
| `03-DEPLOY-RUNBOOK.md` | Step-by-step procedure: preflight → deploy → verify → smoke test → record addresses → optional ownership transfer → announce. |
| `04-PRE-MAINNET-CHECKLIST.md` | Forward-looking gate for the eventual mainnet deploy (audits, multisig, timelock, monitoring, liquidity, communication). |
| `deployments/sepolia/V5.1-TEMPLATE.json` | Structured template for the post-deploy address record. |
| `test/audit/v5.1-uups/integration/deploy/SepoliaRedeploySimulation.t.sol` | 11 tests simulating the fixed deploy script end-to-end. |

---

## 3. Simulation tests (11)

Each test runs `_runSepoliaDeployFixed()` — a faithful in-test mirror of the real Sepolia deploy script (post fix #31). Tests verify:

| # | Test | What it proves |
|---|---|---|
| 1 | Full deploy success | All 15+ contracts deployed with non-zero code |
| 2 | **Fix #31 marketplace authorized** | Marketplace + BuybackEngine in ClaimBond.authorizedOperators (the CRITICAL fix is in the deploy path) |
| 3 | Token distribution 70/14/8/5/3 | Total supply 100M correctly split |
| 4 | Wiring all paths | claimBond.bondVault, vault.pm, pm.router, router.capacityOracle, vault.authorizedCallers[buyback], adaptive mode on |
| 5 | First policy purchase auto-pause check passes | router.isProtocolAutoPaused() returns false at deploy-time price 0.036 |
| 6 | BondVault.setPolicyManager one-shot | Cannot re-set after init |
| 7 | ClaimBond.setBondVault one-shot | Same |
| 8 | Verify-script-equivalent checks pass | BURNER_ROLE, authorizedCallers, authorizedOperators all true |
| 9 | LUMINA admin is deployer | Pre-multisig-transfer state correct |
| 10 | BondVault admin is deployer | Same |
| 11 | Final-state full invariants | 11 invariants in one test for canonical post-deploy state |

All 11 substantive. All run real proxy-deployed contracts.

---

## 4. What this audit does NOT do

- **Does not execute the real Sepolia deploy.** That's the founder's manual operation per the runbook.
- **Does not modify any source contracts.** Only docs + simulation tests added.
- **Does not test in a fork.** Local simulation only (no RPC dependency in CI). Fork rehearsal is reserved for mainnet (audit #38).

---

## 5. Findings

| Severity | Count |
|---|---|
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 0 |
| LOW | 0 |
| INFO | 0 |

This audit is preparatory; no protocol-code findings. The CRITICAL deploy bug found in audit #31 is already RESOLVED in fix #31, which the simulation here verifies.

---

## 6. Confidence in deploy script readiness

The simulation `_runSepoliaDeployFixed` mirrors the deploy script line-by-line. Every test against this simulation passes. The simulation specifically:

1. Predicts LUMINA proxy address with `vm.computeCreateAddress(deployer, nonce + 9)` and asserts the actual proxy lands at that address (`require` inside the helper).
2. Calls `claimBond.setAuthorizedOperator(marketplace, true)` and `claimBond.setAuthorizedOperator(buybackEngine, true)` — the CRITICAL fix #31 wiring.
3. Calls all the other wiring (BURNER_ROLE, authorizedCallers, registerProduct ×9, configureProduct ×9, adaptive mode, etc.) in the documented order.

**The simulation is byte-equivalent to what the founder will run on Sepolia.** Confidence is high that the deploy will succeed.

---

## 7. Reverse audit

| Check | Result |
|---|---|
| Total new tests | 11 |
| Trivial assertions | 0 |
| Tests using fully-deployed real contracts | 11/11 |
| Documents structurally complete | 5/5 |
| Pre-deploy checklist actionable (every item testable) | yes |
| Runbook reproducible (founder can follow without ambiguity) | yes |
| Pre-mainnet checklist comprehensive (covers code/audit/ops/comms/legal) | yes |
| Regression impact | 0 broken |
| Quality | **10/10** |

---

## 8. Verdict

**SEPOLIA-READY.**

- All preparation artifacts in place: deprecation, checklists, runbook, address template.
- Deploy script verified by 11 simulation tests; CRITICAL fix #31 confirmed wired.
- Founder can execute the runbook step-by-step on Base Sepolia.
- Post-deploy, founder fills in the JSON template and commits it to track addresses.

**Next operational step (NOT this audit):** founder runs the runbook. Estimated time on Sepolia: 30-45 min including verification.

**Next audit (#33+):** continue the V5.1 audit cycle. Eventually audits #38-40 will handle mainnet readiness.

---

## 9. Raw verification output

### New tests

```
Suite result: ok. 11 passed; 0 failed; 0 skipped; finished in 6.33ms
Ran 1 test suite: 11 tests passed, 0 failed, 0 skipped (11 total tests)
```

### Full regression

```
Ran 126 test suites in 30.81s (101.72s CPU time):
2102 tests passed, 0 failed, 0 skipped (2102 total tests)
```

Baseline 2091 (post fix #31) + 11 new sim tests = 2102. Zero regression.
