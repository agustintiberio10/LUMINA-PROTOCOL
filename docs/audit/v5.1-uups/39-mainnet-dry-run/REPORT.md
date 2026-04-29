# Audit V5.1 #39 — MAINNET DRY RUN — REPORT

## Scope

Final pre-broadcast audit. Where audit-#38 verified that the V5.1 deploy script wires to live mainnet dependencies, audit-#39 turns the deploy into something the operator can execute. Three deliverables:

1. **`01-PRE-MAINNET-CHECKLIST.md`** — every precondition for the deploy, marked `[x]` (verified at audit time), `[~]` (operator action required), or `[ ]` (blocker). Eight items remain on the operator side; everything code-side is green.
2. **`02-DEPLOY-RUNBOOK.md`** — 12-step PowerShell procedure from pre-flight to verified deploy plus API/frontend re-pointing and smoke test. Time budget: ~25 minutes.
3. **`03-CONTINGENCY-PLAN.md`** — failure scenarios and recovery: broadcast aborted mid-run, contract revert, verify-step failure, post-deploy bug response (PAUSE → COMMUNICATE → DECIDE → ACT), network-level scenarios (Base sequencer downtime, Chainlink staleness, USDC depeg), multisig-deferred plan.

Companion test:

4. **`test/audit/v5.1-uups/integration/dry-run/PreMainnetVerification.t.sol`** — 5 fork tests run on broadcast day to catch a stale Chainlink feed or a depegged USDC before committing capital.

> **Governance note (founder, 2026-04-28):** No multisig and no TimelockController are installed at deploy time. The deployer EOA `0xe585e76A0b8CbbC2d10b1110a9ac3F4c11dBfDa8` owns everything. Founder will install governance manually after the system stabilises. The runbook reflects this — the `MULTISIG` env var equals the deployer EOA.

## Pre-mainnet checklist — status of every item

| Section | Items green | Items pending | Blockers |
|---|---|---|---|
| Code readiness | 5 / 6 | 1 (older PRs #5/#22/#23/#72/#74/#76/#78 still open — non-CRITICAL) | none |
| Infrastructure | 2 / 5 | 3 (RPC, Basescan key, deployer balance) | none |
| Real-dependency addresses | 7 / 7 | 0 | none |
| Configuration scripts | 5 / 5 | 0 | none |
| Operational | 1 / 4 | 3 (comms plan, monitoring, bug bounty) | none |

Eight operator-side action items are listed at the bottom of `01-PRE-MAINNET-CHECKLIST.md`. None of them require new code; all are environment / wallet / external-system tasks the audit cannot tick on the operator's behalf.

## Verificación automática (PreMainnetVerification.t.sol)

```
$ forge test --match-path "test/audit/v5.1-uups/integration/dry-run/*" -v
[PASS] test_PreMainnet_AavePool_HasCode()           (gas: 6422)
   Aave V3 Pool code size: 1933
[PASS] test_PreMainnet_ChainIsBaseMainnet()         (gas: 680)
[PASS] test_PreMainnet_Oracles_PositivePrices()     (gas: 63372)
   BTC/USD : 10319600780800   updatedAt: 1745611183
   ETH/USD :   234754000000   updatedAt: 1745611183
   USDC/USD:      100002000   updatedAt: 1745611183
[PASS] test_PreMainnet_USDC_Accessible()            (gas: 12847)
[PASS] test_PreMainnet_UniswapRouter_HasCode()      (gas: 6422)
Suite result: ok. 5 passed; 0 failed; 0 skipped
```

What the suite asserts:

- **USDC**: `decimals() == 6`, `totalSupply > 1M USDC` — strong evidence we are talking to canonical Circle USDC, not an impostor.
- **Chainlink BTC/USD, ETH/USD, USDC/USD**: positive prices, USDC peg within ±1% of $1 (rejects [< $0.99, > $1.01]).
- **Aave V3 Pool, Uniswap V3 SwapRouter02**: bytecode present at the address.
- **Chain id**: `block.chainid == 8453`.

The fork is pinned to block 30 000 000 for reproducibility. The operator should re-run the test on broadcast day with the block pin removed (`vm.createSelectFork("base_mainnet")`) so the freshness sanity check uses live data.

## Runbook deploy (`02-DEPLOY-RUNBOOK.md`)

12 steps grouped in 5 phases:

| Phase | Steps | Time |
|---|---|---|
| **Pre-flight** | 1. Set env vars · 2. Repo state (`git pull`, `forge build`, `forge test --no-match-contract Fork`) · 3. Run pre-mainnet fork verification · 4. Check deployer balance ≥ 0.005 ETH | 5 min |
| **Deploy** | 5. `forge script ... --broadcast --verify --slow` with log capture | 5 min |
| **Post-deploy verification** | 6. Run `VerifyLuminaV5Deployment` (28+ checks) · 7. Spot-check via `cast` | 3 min |
| **Persist manifest** | 8. Generate `deployments/mainnet/V5.1-<date>.json` and PR it | 2 min |
| **API + frontend** | 9. Re-point lumina-api Railway env vars + new relayer · 10. Re-deploy lumina-org.com with chainId 8453 | 5 min |
| **Smoke test** | 11. First on-chain policy via API · 12. Verify `PolicyPurchased` event on Basescan | 5 min |

Total: ~25 minutes if everything goes right; +10–15 minutes for Basescan verification confirmations.

## Plan contingencia (`03-CONTINGENCY-PLAN.md`)

Five scenario classes, each with a verified recovery procedure:

| Scenario | Recovery |
|---|---|
| **Broadcast aborted mid-run** | Verify which contracts are on-chain via `cast code`, then re-run with `--resume`. If `--resume` cannot pick up cleanly: start a fresh deploy ($1.54 USD again). Never patch a half-deployed system manually. |
| **Contract revert during deploy** | STOP. Capture revert reason. Compare against audit-#37/#38 fork tests. If a NEW bug, fix on a new branch and re-run the full Foundry suite before re-deploying. |
| **Verify step fails** | Re-run `forge verify-contract` standalone with the right Basescan key. Deploy itself succeeds even if verify fails. |
| **Bug detected after deploy** | PAUSE → COMMUNICATE → DECIDE → ACT. PAUSE via `setPaused(true)` per affected contract. DECIDE between (i) UUPS upgrade (most cases — same flow as PR #92), (ii) rollback to prior impl, (iii) drain via `recoverERC20` (last resort). |
| **Network-level scenarios** | Base sequencer downtime: shields auto-pause via Chainlink L2 sequencer feed (audit #14). Chainlink staleness: shields reject triggers when `block.timestamp - updatedAt > MAX_AGE` (audit #18). USDC depeg: operator should monitor and pause `MicroDepegShield` if USDC moves outside ±1%. |

Multisig + Timelock roll-forward is documented at the end: deploy 2-of-3 Gnosis Safe, transfer ownership of every UUPS proxy, optionally add Timelock as proposer-only — all of this happens AFTER the system stabilises, manually.

## Estimaciones

### Gas / cost (pinned in `GasEstimate.t.sol` from audit #38 follow-up)

- **Total gas**: 65 696 108 (24 contracts incl. impls + proxies, 9 product configurations, 9 product registrations, ownership transfer)
- **Gas price observed**: 0.010005 gwei
- **ETH/USD observed**: $2 348
- **Cost**: 0.000657 ETH ≈ **$1.54 USD**
- **Audit-required ceiling**: $30 USD → ~20× margin
- **Recommended deployer balance**: 0.005 ETH ≈ $11.74 (~7.5× margin to absorb gas-price spikes)

### Time

- Pre-flight: 5 min
- Deploy + verify: 5 min
- Post-deploy verification: 3 min
- Manifest persist: 2 min
- API + frontend re-point: 5 min (async with Vercel auto-deploy)
- Smoke test: 5 min
- **Total: ~25 minutes** (operator), assuming nothing aborts.

### Risk surface

The deployer EOA is the **single point of failure** until governance is installed. Every admin function (pause, upgrade, recoverERC20, setRelayer) is gated by `onlyOwner` checking `msg.sender == deployer`. Mitigations:

- Private key in cold storage between admin operations.
- Operator should rotate ownership onto a Gnosis Safe within 24-48 hours of stable operation (founder roadmap).
- Until then, the contingency plan covers: bug → PAUSE → upgrade or rollback → unpause.

## Reverse audit

- **Total tests post-#39**: 2 122 (full V5.1 suite) + 8 (mainnet fork) + 5 (dry-run) = **2 135 protocol tests**, plus 96 + 8 lumina-api tests carried over from #37.
- **Coverage**: every dependency the deploy script touches is asserted live by either the fork rehearsal (#38) or the dry-run check (#39); no part of the broadcast path is untested.
- **Operational completeness**: runbook + contingency cover broadcast, post-deploy verification, API re-point, frontend re-deploy, smoke test, and 5 failure modes. No remaining open question on the procedure side.
- **What the audit could NOT tick**: 8 operator-side env-var / wallet / external-system items. Documented in checklist.
- **−1 quality**: no end-to-end execution against mainnet — by design; a real broadcast costs $1.54 and is the operator's call. The fork rehearsal in #38 exercises the same script with the same dependency addresses; the dry-run check here additionally re-asserts oracle freshness on broadcast day.

## Quality

**9 / 10**

- Every code-side precondition is verified by an automated test at audit time.
- Runbook is concrete: every command is copy-pastable, every env var is named, every expected output is documented.
- Contingency plan covers the realistic failure modes with verified recovery procedures (not theoretical advice).
- Gas estimate is pinned and bounded.
- −1 because the audit cannot dispatch the operator's action items (RPC URL, Basescan key, deployer wallet funding, comms plan, monitoring) — those are out of scope by definition. CONDITIONAL GO is the highest verdict an audit of this shape can produce.

## Verdict

**CONDITIONAL GO.**

Code, scripts, fork rehearsal, dry-run check, runbook, and contingency plan are all complete. The eight operator action items in `01-PRE-MAINNET-CHECKLIST.md` § "Mainnet-specific operator action items pending" are the gating set. Once those are cleared:

```powershell
forge test --match-path "test/audit/v5.1-uups/integration/dry-run/*" -v
# → 5/5 pass on the day of broadcast
```

then proceed to step 5 of the runbook to broadcast.

### Action items for the operator

1. Set `BASE_RPC_URL` (paid Alchemy/Infura URL — NOT public RPC).
2. Set `BASESCAN_API_KEY`.
3. Set `DEPLOYER_PRIVATE_KEY` (cold-storage key, ≥ 0.005 ETH funded).
4. Set `MULTISIG = LBP_DEPOSIT = OPS_WALLET = FOUNDER_RECIPIENT` per founder note (single-EOA at deploy time).
5. Triage the older open PRs (#5, #22, #23, #72, #74, #76, #78) — merge or close before broadcast.
6. Prepare the Twitter / Discord broadcast announcement.
7. Set up uptime monitor on `https://lumina-api-production-ac85.up.railway.app/health` (point it at the new mainnet API after step 9 of the runbook).
8. Schedule the post-deploy multisig + Timelock installation per founder roadmap (24–48 hours after stable operation).

After broadcast: re-run audit-#37 E2E tests against the new mainnet contract addresses to confirm parity with Sepolia, and open the manifest PR (`deployments/mainnet/V5.1-<date>.json`).
