# 06 — UUPS upgrade procedure

When a fix or feature requires a code change in a deployed contract, V5.1's UUPS upgrade pattern allows the operator to point the proxy at a new implementation **without redeploying the proxy or re-wiring its dependents**. The upgrade is signed by the deployer EOA — there is no Timelock at this stage (per founder governance note 2026-04-28), so the upgrade is **immediate**.

This is fast and powerful, also irreversible at the proxy-storage level. Storage layout discipline is the only thing that prevents this from being an existential foot-gun.

## When NOT to upgrade

Before reaching for an upgrade, consider:

- **Bug is in off-chain code only?** → Fix lumina-api or the frontend instead. No upgrade needed.
- **Bug is a mis-configuration of an existing setter?** → Call the setter from owner. No upgrade needed (e.g., `setRelayer`, `setProductConfig`, `setPaused`).
- **Issue is upstream?** → If Chainlink / Aave / Uniswap is the root cause, fix the dependency or pause until it recovers.

Reach for an upgrade only when the fix requires a code change in a deployed contract.

## Pre-upgrade checklist

### 1. Develop the fix on a new branch

```powershell
git checkout main
git pull origin main
git checkout -b fix/upgrade-<contract>-<reason>
```

### 2. Storage layout invariant

The most important rule. UUPS upgrades preserve the proxy's storage; if the new implementation reorders or removes slots, the proxy's data is corrupted irrecoverably.

```powershell
# Capture current layout (BEFORE the fix)
forge inspect <ContractV2> storage-layout > storage-before.json

# After making your change
forge inspect <ContractV2New> storage-layout > storage-after.json

# Diff must be EMPTY (only `astId` differences are tolerable)
diff storage-before.json storage-after.json
```

Adding new state must only **append** at the end of the existing layout, ideally consuming a slot from the contract's `__gap` reserve (every UUPS-enabled contract in V5.1 declares a `uint256[50] __gap` for this purpose).

If the diff is non-empty for any reason other than `astId` / pure-comment shifts: STOP. Re-engineer the change.

### 3. Tests

```powershell
# Full Foundry suite must still pass
forge test --no-match-contract Fork

# Plus a new test that exercises the bug + fix (proves the fix works)
forge test --match-test test_FixUpgrade_<ContractName>_<Behaviour> -vv

# Plus the storage-layout test that's already in the audit suite
forge test --match-contract StorageLayoutTest -v
```

### 4. Adversarial review

For any HIGH or CRITICAL fix, run the adversarial-relayer-style audit pattern:

- Write at least 3 attack tests that the bug would have allowed.
- Confirm each one reverts on the new implementation.
- Confirm each one would have succeeded on the old implementation (regression proof).

This step caught the relayer-payment bug originally (audit #87 / PR #87).

## Upgrade execution

### 1. Deploy the new implementation

```powershell
# Set env for the new implementation deploy
$env:CONTRACT_TO_UPGRADE = "CoverRouterV2"  # for example

# Use the existing UUPS upgrade script as a template (PR #92 / audit-#86)
forge script script/upgrade/UpgradeCoverRouterV2.s.sol:UpgradeCoverRouterV2 `
    --rpc-url $env:BASE_RPC_URL `
    --private-key $env:DEPLOYER_PRIVATE_KEY `
    --broadcast --verify --etherscan-api-key $env:BASESCAN_API_KEY -vvv
```

The upgrade script does three things:

1. Deploys the new implementation contract (no constructor args; UUPS impls have empty constructors with `_disableInitializers()`).
2. Calls `proxy.upgradeToAndCall(newImpl, "")` from the deployer EOA (passes `""` because the existing storage doesn't need re-initialization — call data only matters when the upgrade introduces new state that needs default values).
3. Emits the `Upgraded(address newImpl)` event from the proxy. Pin this in the upgrade log.

### 2. Capture the new implementation address

The script's broadcast log records the new impl deployment. Append it to the manifest:

```powershell
# deployments/mainnet/V5.1-<date>.json
# Add to "implementations" section:
#   "coverRouterImpl": {
#     "v1": "0x<original-impl>",
#     "v2": "0x<new-impl-from-upgrade>"
#   }
```

This trail lets the operator roll back to a prior implementation in seconds (see § "Rollback").

### 3. Verify the upgrade landed

```powershell
# Read the proxy's implementation slot directly (EIP-1967)
cast storage $env:COVER_ROUTER 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc `
    --rpc-url $env:BASE_RPC_URL
# Should equal the new implementation address (left-padded to 32 bytes)

# Run the audit-#37 E2E suite against the upgraded mainnet contract addresses
# (set the relevant env vars to point at mainnet then:)
forge test --match-contract E2EIntegrationTest -vv

# Run the post-deploy health check
forge test --match-contract MainnetHealthCheckTest -vv
# All 8 must pass
```

If any check fails after upgrade, **rollback immediately** (see next section) — don't try to patch forward.

### 4. Smoke test post-upgrade

Mirror the audit-#37 smoke tests but against the upgraded contracts on mainnet:

- Issue a fresh API key
- Buy a $10 USDC policy via the API
- Confirm the `PolicyPurchased` event fires from the upgraded `CoverRouter`
- Verify the buyer's wallet shows the new policyId in the API's `/policies?owner=…` response

If smoke test passes, the upgrade is **VERIFIED**. If smoke test fails, rollback.

## Rollback

UUPS lets you point the proxy back at any prior implementation, as long as the prior bytecode is still on chain. Bytecode is immutable, so as long as you haven't lost the prior impl address (it's in the manifest), rollback is one tx:

```powershell
cast send $env:COVER_ROUTER `
    "upgradeToAndCall(address,bytes)" `
    "0x<prior-impl-address>" `
    "0x" `
    --rpc-url $env:BASE_RPC_URL `
    --private-key $env:DEPLOYER_PRIVATE_KEY
```

If the new implementation introduced storage that the old one doesn't read, rollback is safe (orphan slots are forgotten). If the new implementation **removed or repurposed** a slot the old one reads, rollback can corrupt state — this is why the storage-layout invariant in § "Pre-upgrade checklist" is non-negotiable.

## After-the-fact governance

Post the upgrade:

1. Open a PR with the new implementation source code (already on main when the fix branch was merged), the upgrade script (if new), and the manifest update.
2. Tag the commit with `mainnet-upgrade-<date>` for the timeline.
3. Write a brief postmortem if the upgrade was reactive to a bug. Audit-#39 contingency plan § "ACT" already requires this — copy that template.

## Without Timelock — what's missing

The founder note (2026-04-28) defers Timelock installation. Until it's installed:

- **No public delay** between an upgrade decision and its execution. Anyone watching the chain sees the new implementation contract appear, and ~the same block the proxy points at it.
- **No revocability window**. Once you sign `upgradeToAndCall`, the upgrade is live. There is no "queued" period during which the community could react.
- **Single key risk**. If the deployer key is compromised, the attacker can upgrade to a malicious implementation that drains funds.

These are all known trade-offs the founder accepted. To restore each:

| Risk | Mitigation when Timelock is installed (T+30d per audit-#40) |
|---|---|
| No public delay | Timelock proposes upgrade with 24-48h delay; community can scrutinize in-between |
| No revocability | Timelock's `cancel()` method allows the multisig to abort a queued upgrade |
| Single-key risk | Multisig (2-of-3) is the upgrade owner; compromising one key isn't enough |

## Cost

Per UUPS upgrade on Base mainnet, by audit-#38 measurements:

- Implementation deploy: ~3M gas (~$0.07)
- `upgradeToAndCall` proxy call: ~50 000 gas (~$0.001)
- Verify on Basescan: free (just an API call)

**Total per upgrade: ~$0.08 USD.** Negligible. The cost is operational discipline (storage layout, testing, communication), not gas.
