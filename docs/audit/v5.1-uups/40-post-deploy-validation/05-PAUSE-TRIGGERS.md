# 05 — Pause triggers and procedure

This document defines **when** to pause the protocol and **how**. The deployer EOA owns every `setPaused(bool)` admin function (per founder governance note), so any pause is a single transaction signed by the operator.

## When to pause — auto vs. manual

### Auto-pause (already wired in V5.1, no operator action needed)

These are protective mechanisms that fire without operator intervention:

| Mechanism | Audit | Effect |
|---|---|---|
| **LUMINA price < $0.005** | audit #11, #18 | `CapacityOracle.getLuminaPrice()` returns the floor price; new policy purchases revert because the cover/premium math relies on a positive LUMINA price. New policies STOP automatically. Existing policies remain active. |
| **Base sequencer downtime** | audit #14 | Each shield wires the Chainlink L2 sequencer feed; when the sequencer is down or freshly recovered (within the grace window), shield triggers reject. **Auto-pause for trigger evaluation only**, not for new policies — those still settle once the sequencer is healthy. |
| **Chainlink staleness > MAX_AGE** | audit #18 | `latestRoundData()` updatedAt is checked per shield. If stale, the shield rejects all triggers. Result: false triggers cannot fire from a dead feed. New policies still purchasable as long as LUMINA price oracle is fresh. |

These auto-mechanisms are passive defences. The operator should still be aware of them via monitoring (24h validation thresholds in `02-24H-VALIDATION.md`) — repeated auto-pauses are a sign the upstream dependency is unhealthy.

### Manual pause (admin decision required)

The operator should pause manually for any of these conditions:

| Condition | What pauses | Severity |
|---|---|---|
| **CRITICAL bug discovered post-deploy** | All user-facing entry points: `CoverRouter.setPaused(true)`, `Marketplace.setPaused(true)`, `BondVault.setPaused(true)` | STOP-THE-WORLD |
| **Oracle manipulation suspected** (price prints inconsistent with off-chain market) | The shield that consumes the manipulated feed (e.g., MicroDepegShield if USDC oracle moves) | LOCALIZED |
| **Aave issues affecting RateShockShield** (Aave proxy reverts, borrow-rate math glitches) | RateShockShield only | LOCALIZED |
| **Massive trigger event with anomaly signals** (e.g., 1000 bonds issued in 5 min from one shield) | The triggering shield + CoverRouter (no new buys until investigated) | INVESTIGATIVE |
| **Funds rescue prep** (operator detects an exploit attempt and needs to drain reserves before tx confirms) | All admin contracts | STOP-THE-WORLD |
| **Founder calls for pause** (governance) | Whatever the founder specifies | PER-DECISION |

The PAUSE step in audit-#39's contingency plan (`03-CONTINGENCY-PLAN.md` § "Bug detected after deploy") is implemented through this document.

## Procedure — single contract pause

```powershell
# Pause the CoverRouter (stops new policy purchases)
cast send $env:COVER_ROUTER "setPaused(bool)" true `
    --rpc-url $env:BASE_RPC_URL `
    --private-key $env:DEPLOYER_PRIVATE_KEY

# Confirm
cast call $env:COVER_ROUTER "paused()(bool)" --rpc-url $env:BASE_RPC_URL
# Expected: true
```

Time-to-effect: a single Base mainnet block (~2 seconds). The CoverRouter rejects new `purchasePolicyFor` calls immediately after the tx confirms.

## Procedure — STOP-THE-WORLD (multiple contracts)

When the operator suspects an exploit, pause every user-facing entry point in parallel. The deployer EOA can sign multiple txs in the same block; PowerShell can fire-and-forget:

```powershell
$rpc = $env:BASE_RPC_URL
$pk  = $env:DEPLOYER_PRIVATE_KEY

# Fire all pauses in parallel via background jobs
Start-Job { cast send $env:COVER_ROUTER     "setPaused(bool)" true --rpc-url $using:rpc --private-key $using:pk }
Start-Job { cast send $env:TWAP_BURNER      "setPaused(bool)" true --rpc-url $using:rpc --private-key $using:pk }
Start-Job { cast send $env:MARKETPLACE      "setPaused(bool)" true --rpc-url $using:rpc --private-key $using:pk }
Start-Job { cast send $env:BUYBACK_ENGINE   "setPaused(bool)" true --rpc-url $using:rpc --private-key $using:pk }
Start-Job { cast send $env:BOND_VAULT       "setPaused(bool)" true --rpc-url $using:rpc --private-key $using:pk }
Start-Job { cast send $env:CLAIM_BOND       "setPaused(bool)" true --rpc-url $using:rpc --private-key $using:pk }

# Wait for all jobs to complete
Get-Job | Wait-Job | Receive-Job
```

> **Beware nonces.** A single EOA submitting 6 parallel txs at the same nonce will result in 5 of them failing. PowerShell parallel jobs each open a new RPC session, but Base's mempool serializes by sender. In practice, send the txs sequentially with `--legacy` if your RPC provider is strict about nonces, or pre-compute nonces and pass them via `--nonce`.
>
> A safer fallback: send them sequentially. Total time ~12 seconds for 6 contracts (~2s per Base block) — still well under the time it takes for an exploit to drain a meaningful position.

## Verifying paused state

```powershell
# Run the post-deploy health check; the pause-status test will log the state
forge test --match-test test_HealthCheck_CoverRouter_PauseStatus -vv
```

Or directly:

```powershell
cast call $env:COVER_ROUTER     "paused()(bool)" --rpc-url $env:BASE_RPC_URL
cast call $env:TWAP_BURNER      "paused()(bool)" --rpc-url $env:BASE_RPC_URL
cast call $env:MARKETPLACE      "paused()(bool)" --rpc-url $env:BASE_RPC_URL
# … etc
```

## Communication during pause

Per the audit-#39 contingency plan:

1. **Within 5 min of pause**: Twitter / Discord post stating "Protocol paused for investigation. No funds at risk. Updates to follow." Do NOT disclose the technical details yet.
2. **Within 1 hour**: post a brief, non-actionable update if known. Avoid speculation.
3. **Once a fix is ready (and tested)**: announce the upgrade plan and ETA before broadcasting.

## Unpause procedure

After the issue is resolved (fix deployed via UUPS upgrade, or external dependency recovered):

```powershell
# Re-validate using the smoke tests in 01-IMMEDIATE-SMOKE-TESTS.md
forge script script/verify/VerifyLuminaV5Deployment.s.sol -vvv

# Run the full health check
forge test --match-contract MainnetHealthCheckTest -vv
# All 8 should pass

# Then unpause in the reverse order — settlement first, purchase entry last
cast send $env:CLAIM_BOND       "setPaused(bool)" false --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY
cast send $env:BOND_VAULT       "setPaused(bool)" false --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY
cast send $env:BUYBACK_ENGINE   "setPaused(bool)" false --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY
cast send $env:MARKETPLACE      "setPaused(bool)" false --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY
cast send $env:TWAP_BURNER      "setPaused(bool)" false --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY
cast send $env:COVER_ROUTER     "setPaused(bool)" false --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY
```

The order matters: re-enabling settlement (BondVault, ClaimBond) before re-enabling purchases ensures any policies bought after unpause can be settled normally.

## Pause cost

Each `setPaused(bool)` is a single SSTORE + event emit, ~30 000 gas. At Base's typical gas price (0.01 gwei) and ETH/USD ~$2 348, each pause costs **~$0.0007 USD**. Six pauses (STOP-THE-WORLD) is ~$0.0042 USD. The operator's deployer wallet must have > 0.001 ETH set aside specifically for emergency admin actions.

## Audit trail

Every pause and unpause emits a `Paused`/`Unpaused` event (OpenZeppelin's standard `PausableUpgradeable`). The operator should:

1. Capture the tx hash of every pause/unpause action.
2. Log it in an internal incident timeline.
3. Reference those tx hashes in the post-incident report (per audit-#39 contingency plan § "ACT").
