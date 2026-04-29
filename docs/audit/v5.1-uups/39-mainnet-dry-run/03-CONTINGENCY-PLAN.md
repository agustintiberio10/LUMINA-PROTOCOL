# 03 — Contingency plan

How to react when something goes wrong during or after the V5.1 mainnet deploy. Each scenario has a recovery procedure that has been verified against Sepolia or against the fork tests in audits #37–#38.

## Broadcast aborted mid-run

`forge script ... --broadcast` retries individual transactions automatically with `--slow`. If the whole script aborts (CTRL-C, network drop, RPC drops, gas spike past wallet balance):

### Diagnosis

Look at the broadcast log under `broadcast/DeployLuminaV5Mainnet.s.sol/8453/run-latest.json`. It records every tx, marked `pending` / `failed` / `succeeded`.

### Recovery — operator's actions in order

1. **Verify which contracts ARE on-chain.** Each `succeeded` tx in the broadcast log has a `contractAddress` field — check those exist with `cast code <addr> | head -c 32`.
2. **Resume.** Re-run the same `forge script` command **with `--resume`**. Foundry will skip already-succeeded txs and retry the rest.
   ```powershell
   forge script script/deploy/DeployLuminaV5Mainnet.s.sol:DeployLuminaV5Mainnet `
       --rpc-url $env:BASE_RPC_URL `
       --private-key $env:DEPLOYER_PRIVATE_KEY `
       --broadcast --verify --etherscan-api-key $env:BASESCAN_API_KEY `
       --resume -vvv
   ```
3. **If `--resume` does not pick up cleanly** (rare; happens when the cache JSON gets out of sync), the safe path is to start a NEW deploy from scratch. Costs another $1.54 USD; the addresses will differ. **Do NOT** try to "patch" a half-deployed system manually — proxy initialization order matters.

### Special case: out of gas in deploying just one contract

A single `new X()` revert during deploy is almost always a constructor revert (e.g., zero-address argument). Not a balance issue. Read the revert reason from the failed tx, fix the env var, re-run.

If genuinely out of ETH: top up the deployer wallet, re-run with `--resume`.

## Contract revert during deploy

Pre-broadcast, the audit-#37 + audit-#38 forge tests cover all known revert paths. If a NEW revert appears at deploy time:

1. **STOP**. Do not commit anything. Do not push.
2. Capture the failed tx hash and the revert reason from the broadcast log.
3. Compare against the fork test results — was this scenario ever exercised?
4. If a genuine bug, write a fix in a new branch, run the full Foundry suite, get the audit folder updated, **only then** re-deploy.
5. If a transient infrastructure issue (bad RPC, rate limit, etc.), wait 5 minutes, run with `--resume`.

## Verify step fails

`forge script ... --verify` calls Basescan's verification API. Common failures:

| Symptom | Cause | Fix |
|---|---|---|
| `Invalid API Key (#err2)` | Wrong / unset `BASESCAN_API_KEY` | Re-run verify standalone: `forge verify-contract <addr> <name> --etherscan-api-key <real-key> --chain-id 8453` |
| `Pending in queue` (8 retries × 15s) | Basescan backlog | Re-run `forge verify-contract` later. Some V5.1 deploys saw 5 of 54 contracts time-out on Sepolia and verify automatically a few minutes later — Basescan caches by bytecode hash. |
| `Already Verified` | Some other deploy beat us to it (unlikely on Mainnet) | Done. No action. |

The deploy itself succeeds even if verify fails. Verification is documentation, not protocol state.

## Bug detected after deploy

If a bug is found in production, the response order is **PAUSE → COMMUNICATE → DECIDE → ACT**.

### PAUSE (immediate)

Each contract that has a `setPaused` admin function should be paused first to stop the bleed. The owner is the deployer EOA, so a single tx per contract.

```powershell
# Stop new policy purchases
cast send $env:COVER_ROUTER "setPaused(bool)" true `
    --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY

# Stop USDC swaps to LUMINA
cast send $env:TWAP_BURNER "setPaused(bool)" true `
    --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY
```

The marketplace, BondVault, ClaimBond all expose similar pause guards (verified in audit-#28). Pause whatever the bug touches.

### COMMUNICATE

- Announce on Twitter / Discord that the protocol is paused.
- Do NOT disclose the technical bug yet — wait until a fix is ready, otherwise opportunists may attempt to exploit a related path.

### DECIDE — fix or rollback?

- **Fix-via-UUPS-upgrade** (most cases). Same flow as PR #92's `script/upgrade/UpgradeCoverRouterV2.s.sol`: write new impl, run `forge inspect storage-layout` diff (must be byte-identical), call `proxy.upgradeToAndCall(newImpl, "")` from the deployer EOA. Verified against Sepolia in PR #86.
- **Rollback to a prior impl** (rare). UUPS allows pointing the proxy back at a previous impl, but only if that prior impl is still at its old address (it is — bytecode is immutable). Use the same `upgradeToAndCall` call with the prior impl address.
- **Drain reserves** (worst case). The deployer EOA has admin rights and can recover stuck assets via the admin-rescue functions: `BondVault.recoverERC20`, `Marketplace.recoverToken`, etc. Audited in #26. Use as last resort if the protocol cannot be salvaged.

### ACT

After deploying the fix, re-run audit-#37 E2E tests against the upgraded mainnet contracts. Then unpause.

## Network-level scenarios

### Base sequencer downtime

Audit #14 covered this. The Chainlink L2 sequencer feed is wired into the shields' trigger checks, so when Base's sequencer is down, **policy triggers automatically pause** until the grace window expires. No operator action required.

### Chainlink oracle staleness

Audit #18 covered this. Each shield checks `latestRoundData()` and rejects triggers if `block.timestamp - updatedAt > MAX_AGE`. Stale data → no false trigger; instead, that shield's policies stay active until the feed updates.

### USDC depeg

A USDC depeg (price < $0.99 on the Chainlink USDC/USD feed) can cause the `MicroDepegShield` to start triggering for legitimate-but-unwanted reasons. Audit-#39's `PreMainnetVerification.t.sol::test_PreMainnet_Oracles_PositivePrices` asserts USDC stays within ±1% of $1 at the audit time. Operator should monitor this feed independently after broadcast and PAUSE the MicroDepegShield if USDC moves outside the band.

## Multisig + TimelockController — deferred

Per the founder note (2026-04-28), no multisig and no TimelockController are installed at deploy time. The deployer EOA owns everything. The roll-forward plan once the system stabilises:

1. Decide on a Gnosis Safe configuration (recommended: 2-of-3 with founder + audit lead + ops).
2. Deploy the Safe to mainnet.
3. Transfer ownership of every UUPS proxy from the deployer EOA to the Safe (one `transferOwnership(safe)` per contract — same pattern as the Sepolia deploy script lines 461-477).
4. Optionally deploy a TimelockController in front of the Safe and transfer ownership again (Safe → Timelock → Safe-as-proposer). The audit policy is to keep the timelock OUT of the deploy script and install it manually.

Until step 3 is complete, the deployer EOA is the **single point of failure** for all admin functions. Operator must keep the private key in cold storage and rotate it onto the Safe ASAP.
