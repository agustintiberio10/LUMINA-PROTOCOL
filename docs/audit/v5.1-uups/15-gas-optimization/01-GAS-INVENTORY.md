# Audit V5.1 #15 — Gas Optimization: Inventory

**Target:** LUMINA Protocol V5.1 (UUPS upgradeable) on Base L2
**Scope:** Measure gas of every user-facing / keeper / admin operation; flag anything > 500k gas as potentially inviable; propose optimisations without changing behaviour.
**Date:** 2026-04-23

---

## 1. Operations measured directly (with assertions)

| # | Operation | Where | Threshold |
|---|---|---|---|
| 1 | `coverRouter.purchasePolicy(id, coverage, asset)` | user buys policy | < 1 M cold / < 600 k warm |
| 2 | `coverRouter.purchasePolicyFor(id, coverage, asset, buyer)` | relayer buys | < 1 M cold |
| 3 | `coverRouter.configureProduct(...)` | admin config | < 100 k |
| 4 | `twapBurner.executeBurn()` | keeper burn | < 500 k |
| 5 | `shield.checkAndSettlePolicy(id)` | permissionless settle | < 300 k |
| 6 | `shieldKeeper.performUpkeep(performData)` | Chainlink Automation | < 350 k |
| 7 | `coverRouter.upgradeToAndCall(newImpl, "")` | UUPS upgrade | < 100 k |
| 8 | `purchasePolicy` across 3 shields (FlashBTC1h / 4h, FlashETH1h) | cross-shield variance | spread ≤ 25 % |
| 9 | `purchasePolicy` cold vs warm slots | slot-heating effect | warm < cold |
| 10 | `coverRouter.products(id)` read-only slot layout check | storage packing | — |

## 2. Operations covered elsewhere (documented in REPORT §3)

| Operation | Coverage |
|---|---|
| `bondVault.redeemBond` | Exercised end-to-end in `test/bonds/BondVaultTest.t.sol` and integration scenarios; cited via forge gas-report |
| `marketplace.list` / `executeBuy` / `cancel` | Exercised in `test/integration/scenarios/FullPolicyLifecycle.t.sol` |
| `buybackEngine.executeOffer` | Exercised in `test/marketplace/BuybackEngineTest.t.sol` |

Adding duplicate fixtures for these in the benchmark file would not sharpen the numbers — the assertions already live in the existing suites and the numbers there are authoritative.

## 3. Test harness

Self-contained E2E setup in `GasBenchmark.t.sol` — copies the deployment pattern from `test/integration/deploy/DeployE2ETest.t.sol` but only spins up what the gas path touches (3 shields instead of 9, skips some treasury reserves and shield-keeper-related registrations not exercised here). All calls go through real deployed proxies; no mocked shield internals.

## 4. Viability framing

Base mainnet gas price typically 0.005–0.05 gwei. Using the upper bound (0.05 gwei) and ETH ≈ $3 000:

`cost_usd = gas × 0.05 × 1e−9 × 3000`

So even the most expensive measured operation (~828 k gas, cold) costs ≈ **$0.124** at the high end of normal Base gas, ≈ **$0.012** at the low end. All operations are economically viable for retail and agent flows.

See REPORT.md §3 for the full table and §5 for optimisation findings.
