# 01 — Immediate post-deploy smoke tests (1 hour)

Run this checklist within the first 60 minutes after broadcasting the V5.1 deploy. Total time-budget: ~30 minutes; total USDC cost: ~$10.50.

> **Owner note**: per the founder instruction (2026-04-28), no multisig and no Timelock at deploy time. The deployer EOA is the only admin. All `cast send` calls below sign with `$env:DEPLOYER_PRIVATE_KEY`.

## Preconditions

- The runbook in audit-#39 (`02-DEPLOY-RUNBOOK.md`) ran cleanly and printed all addresses.
- `deployments/mainnet/V5.1-<date>.json` is committed and reviewable.
- Env vars from §6 of the runbook are still set in the operator's PowerShell session (`$env:LUMINA_TOKEN`, `$env:BOND_VAULT`, etc.).
- Deployer EOA still has > 0.001 ETH for gas of admin calls.

## Test 1 — VerifyLuminaV5Deployment script (read-only, free)

```powershell
forge script script/verify/VerifyLuminaV5Deployment.s.sol:VerifyLuminaV5Deployment `
    --rpc-url $env:BASE_RPC_URL `
    -vvv
```

**Expected:** every check prints `[PASS]`; the script exits with no revert. The script verifies 28+ invariants:

- Token balances: BondVault = 70M, CEX = 14M, Founder = 8M, LBP = 5M, Treasury = 3M (sum = 100M).
- Wirings: `CoverRouter.policyManager == PolicyManager`, `PolicyManager.bondVault == BondVault`, `TWAPBurner.feeDistributor == AdaptiveFeeDistributor`, etc.
- Roles: `LuminaToken.MINTER_ROLE` holders are the 5 distribution targets; `BondVault.authorizedCallers[PolicyManager] == true`; `ClaimBond.authorizedOperators[Marketplace] == true`; `ClaimBond.authorizedOperators[BuybackEngine] == true` (Fix audit #31).
- Ownership: every UUPS proxy `owner() == $env:MULTISIG` (= deployer EOA at this stage).
- Capacity oracle: `getLuminaPrice()` returns a positive uint256.

If any line says `[FAIL]`, do NOT proceed to test 2. Triage via the audit-#39 contingency plan § "Contract revert during deploy".

## Test 2 — End-to-end policy purchase ($10.50 USDC spend)

A single live policy purchase against the production API confirms the full path: API → relayer → CoverRouter → PolicyManager → shield → BondVault.

### 2.1. Prepare buyer wallet

The buyer is the operator's secondary EOA (not the deployer; we want to prove third-party purchase works).

```powershell
$buyer = "0x<buyer-eoa>"

# Send the buyer enough USDC + ETH for gas
# (operator manually transfers ~$10.50 USDC via Coinbase / OnRamp / their own wallet to $buyer)

# Confirm balance on Base mainnet
cast call 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "balanceOf(address)(uint256)" `
    $buyer --rpc-url $env:BASE_RPC_URL
# → at least 10500000 (= 10.50 USDC, 6 decimals)
```

### 2.2. Approve CoverRouter for buyer's USDC

```powershell
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 `
    "approve(address,uint256)" $env:COVER_ROUTER 10500000 `
    --rpc-url $env:BASE_RPC_URL --private-key $env:BUYER_PRIVATE_KEY
```

### 2.3. Buy 10 USDC of FlashBTC1h coverage via the API

```powershell
$apiKey = "lk_<freshly-issued-mainnet-key-from-admin-endpoint>"

curl -X POST https://lumina-api-production-ac85.up.railway.app/api/v1/policies `
    -H "x-api-key: $apiKey" `
    -H "Content-Type: application/json" `
    -d "{`"productId`":`"<flashbtc1h-product-id>`",`"coverageAmount`":`"10000000`",`"asset`":`"<asset-bytes32>`",`"buyer`":`"$buyer`"}"
```

**Expected response:** `{ "ok": true, "policyId": 1, "txHash": "0x...", "premium": "<value>" }`

### 2.4. Verify the policy on chain

```powershell
cast call $env:POLICY_MANAGER "getPolicy(uint256)(...)" 1 --rpc-url $env:BASE_RPC_URL
# Should return: productId, shield, buyer == $buyer, coverage == 10000000, payout, premium > 0, ...
```

The buyer's USDC went to TWAPBurner; the next BTC oracle round will trigger a swap to LUMINA and burn it.

### 2.5. Verify the burn flow (eventual)

Within ~5 minutes of the policy buy (depending on TWAPBurner's swap conditions):

```powershell
# Pre-burn LUMINA total supply (should be 100M = 100000000000000000000000000)
cast call $env:LUMINA_TOKEN "totalSupply()(uint256)" --rpc-url $env:BASE_RPC_URL
```

If the swap has happened, total supply drops slightly. (Burn is asynchronous — fine if not visible immediately.)

## Test 3 — Marketplace authorization (Fix audit #31)

CRITICAL — if these return `false`, the marketplace cannot operate on bonds and the bug fixed in audit #31 has regressed.

```powershell
cast call $env:CLAIM_BOND "authorizedOperators(address)(bool)" $env:MARKETPLACE `
    --rpc-url $env:BASE_RPC_URL
# Expected: true

cast call $env:CLAIM_BOND "authorizedOperators(address)(bool)" $env:BUYBACK_ENGINE `
    --rpc-url $env:BASE_RPC_URL
# Expected: true
```

If either returns `false`, run the standalone wire script:

```powershell
forge script script/wire/WireLuminaV5PostDeploy.s.sol:WireLuminaV5PostDeploy `
    --rpc-url $env:BASE_RPC_URL --private-key $env:DEPLOYER_PRIVATE_KEY --broadcast
```

## Test 4 — Token supply distribution health

```powershell
cast call $env:LUMINA_TOKEN "balanceOf(address)(uint256)" $env:BOND_VAULT `
    --rpc-url $env:BASE_RPC_URL
# Expected: 70_000_000 * 1e18 = 70000000000000000000000000

cast call $env:LUMINA_TOKEN "balanceOf(address)(uint256)" $env:CEX_LIQUIDITY_RESERVE `
    --rpc-url $env:BASE_RPC_URL
# Expected: 14_000_000 * 1e18

cast call $env:LUMINA_TOKEN "balanceOf(address)(uint256)" $env:FOUNDER_VESTING `
    --rpc-url $env:BASE_RPC_URL
# Expected: 8_000_000 * 1e18

cast call $env:LUMINA_TOKEN "balanceOf(address)(uint256)" $env:TREASURY_VESTING `
    --rpc-url $env:BASE_RPC_URL
# Expected: 3_000_000 * 1e18

cast call $env:LUMINA_TOKEN "balanceOf(address)(uint256)" $env:LBP_DEPOSIT `
    --rpc-url $env:BASE_RPC_URL
# Expected: 5_000_000 * 1e18

cast call $env:LUMINA_TOKEN "totalSupply()(uint256)" --rpc-url $env:BASE_RPC_URL
# Expected: 100_000_000 * 1e18 (or slightly less if test 2.5 already burned)
```

If any balance is wrong, the deploy distributed tokens incorrectly — STOP and triage. Should never happen because `VerifyLuminaV5Deployment` already covered this (test 1), but verify independently as defence in depth.

## Test 5 — Oracle health (live data)

Re-run the audit-#39 dry-run test against the LIVE chain (no block pin):

```powershell
forge test --match-path "test/audit/v5.1-uups/integration/dry-run/*" -vv
```

Expected: 5 passes — USDC, BTC/ETH/USDC oracles, Aave + Uniswap bytecode, chainId 8453.

Additionally spot-check oracle freshness from the admin perspective:

```powershell
# Chainlink BTC/USD updatedAt should be within last 6 hours
cast call 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F `
    "latestRoundData()(uint80,int256,uint256,uint256,uint80)" `
    --rpc-url $env:BASE_RPC_URL
# updatedAt (4th return value) should be > now() - 21600
```

If `updatedAt` is more than 24 hours old, the oracle is dead and shields will reject all triggers. Pause the affected shields manually (see `05-PAUSE-TRIGGERS.md`) until it recovers.

## Test 6 — API health

```powershell
curl https://lumina-api-production-ac85.up.railway.app/health
```

**Expected JSON:**

```json
{
  "ok": true,
  "chainId": 8453,
  "rpc": "<masked-but-not-empty>",
  "relayer": {
    "address": "0x<new-mainnet-relayer>",
    "balance": "0.x ETH"
  },
  "db": "ok",
  "uptime": "<seconds>"
}
```

If `chainId != 8453`: API was not re-pointed at mainnet → step 9 of the runbook was skipped or failed.
If `relayer.balance < 0.001 ETH`: top up before any user can buy a policy.
If `db != "ok"`: the SQLite volume on Railway has issues — check the docker-entrypoint chown.

## Test 7 — Frontend (lumina-org.com) live check

Open `https://lumina-org.com` in a browser:

- Network indicator should show **Base** (chainId 8453), NOT Base Sepolia.
- Connect wallet (RainbowKit). Wallet address should match operator's secondary EOA.
- "My Bonds" tab loads (post audit-#37 LP-GAP triage, this is the renamed "My Vaults").
- Browser console: zero errors related to RPC / contract reads.

## Acceptance gate

If ALL 7 tests pass within 1 hour of broadcast, mark **DEPLOY-VERIFIED-T+1H** and proceed to the 24h validation in `02-24H-VALIDATION.md`.

If ANY test fails:

1. STOP user-facing comms.
2. Capture failure details (logs, tx hashes, response bodies).
3. Triage via audit-#39 `03-CONTINGENCY-PLAN.md`.
4. If a PAUSE is required, follow `05-PAUSE-TRIGGERS.md` → § "Procedure".
