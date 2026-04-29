# 02 — Mainnet deploy runbook

Step-by-step procedure for the day of broadcast. Time-budget: ~25 minutes from pre-flight to verified deploy. Every step assumes the operator has cleared the items in `01-PRE-MAINNET-CHECKLIST.md`.

> **Governance note:** per the founder instruction (2026-04-28), this deploy uses the **deployer EOA as owner**. No multisig, no TimelockController. `MULTISIG` env var below points at the deployer's own address.

## Pre-flight (5 min)

### 1. Set environment variables

```powershell
# Deployer wallet
$env:DEPLOYER_PRIVATE_KEY = "0x<deployer-private-key>"

# Endpoints
$env:BASE_RPC_URL          = "https://base-mainnet.g.alchemy.com/v2/<your-alchemy-key>"
$env:BASESCAN_API_KEY      = "<basescan-api-key>"

# Operator addresses — at this stage, MULTISIG = deployer EOA
$env:MULTISIG              = "0x<deployer-address>"
$env:LBP_DEPOSIT           = "0x<lbp-deposit-recipient>"
$env:OPS_WALLET            = "0x<ops-wallet>"
$env:FOUNDER_RECIPIENT     = "0x<founder-vesting-recipient>"
```

### 2. Repo state

```powershell
cd C:\Users\AGUSTIN\LUMINA-PROTOCOL
git status                                  # working tree clean
git checkout main
git pull origin main
forge clean                                 # discard previous build
forge build                                 # warnings only, 0 errors
forge test --no-match-contract "Fork"       # 2122/2122 pass
```

### 3. Pre-mainnet fork verification

```powershell
forge test --match-path "test/audit/v5.1-uups/integration/dry-run/*" -v
# 5/5 pass: USDC live, oracles healthy, Aave + Uniswap have bytecode, chain == 8453
```

### 4. Deployer balance

```powershell
$balanceWei = cast balance $env:MULTISIG --rpc-url $env:BASE_RPC_URL
$balanceEth = [decimal]$balanceWei / [decimal]1e18
Write-Host "Balance: $balanceEth ETH"

# Audit-#38 measured the deploy at 0.000657 ETH; require 0.005 minimum
# (~7.5x margin for gas spikes)
if ($balanceEth -lt 0.005) {
    Write-Host "INSUFFICIENT BALANCE - need >= 0.005 ETH" -ForegroundColor Red
    return
}
```

## Deploy (5 min)

### 5. Broadcast the production deploy

```powershell
forge script script/deploy/DeployLuminaV5Mainnet.s.sol:DeployLuminaV5Mainnet `
    --rpc-url $env:BASE_RPC_URL `
    --private-key $env:DEPLOYER_PRIVATE_KEY `
    --broadcast `
    --verify `
    --etherscan-api-key $env:BASESCAN_API_KEY `
    --slow `
    -vvv 2>&1 | Tee-Object -FilePath "deployments\mainnet\deploy-log-$(Get-Date -Format 'yyyy-MM-dd-HHmm').txt"
```

The script prints every deployed address as it goes. The wiring (BURNER_ROLE grant, marketplace authorisation, product registration + configuration, ownership transfer) happens inline in `_configureProducts(...)` and the wiring block at lines 408-454 of `DeployLuminaV5Complete.s.sol`. **No separate configure or wire step is needed for mainnet** — this matches the audit-#37 E2E rehearsal.

> If the broadcast errors out before completing, see `03-CONTINGENCY-PLAN.md` § "Broadcast aborted mid-run".

## Post-deploy verification (3 min)

### 6. On-chain verification script (read-only)

The verify script reads the env-vars `LUMINA_TOKEN`, `BOND_VAULT`, etc. for the deployed addresses. After the deploy, capture them from the broadcast log:

```powershell
# Extract addresses from the deploy log
$log = Get-Content "deployments\mainnet\deploy-log-*.txt" -Raw
# (operator: parse the printed addresses or open the log to copy them)

$env:LUMINA_TOKEN       = "0x..."
$env:BOND_VAULT         = "0x..."
$env:CLAIM_BOND         = "0x..."
$env:POLICY_MANAGER     = "0x..."
$env:COVER_ROUTER       = "0x..."
$env:CEX_LIQUIDITY_RESERVE  = "0x..."
$env:MAINTENANCE_RESERVE    = "0x..."
$env:CAPACITY_ORACLE    = "0x..."
$env:TWAP_BURNER        = "0x..."
$env:ADAPTIVE_FEE_DISTRIBUTOR = "0x..."
$env:FOUNDER_VESTING    = "0x..."
$env:TREASURY_VESTING   = "0x..."
$env:MARKETPLACE        = "0x..."
$env:BUYBACK_ENGINE     = "0x..."

forge script script/verify/VerifyLuminaV5Deployment.s.sol:VerifyLuminaV5Deployment `
    --rpc-url $env:BASE_RPC_URL `
    -vvv
```

Expected output: 28+ checks pass (balances, roles, wirings, ownership, oracle, shield registration). This is the same script that ran at the end of FASE 5 of the Sepolia deploy.

### 7. Spot-check via cast

```powershell
# LUMINA total supply must be exactly 100M
cast call $env:LUMINA_TOKEN "totalSupply()(uint256)" --rpc-url $env:BASE_RPC_URL
# → 100000000000000000000000000

# 9 products registered in PolicyManagerV2
cast call $env:POLICY_MANAGER "getProductCount()(uint256)" --rpc-url $env:BASE_RPC_URL
# → 9

# CoverRouterV2 wired correctly
cast call $env:COVER_ROUTER "policyManager()(address)" --rpc-url $env:BASE_RPC_URL
# → matches $env:POLICY_MANAGER
```

## Persist the address manifest (2 min)

### 8. Generate `deployments/mainnet/V5.1-<date>.json`

Mirror the format used for Sepolia (`deployments/sepolia/V5.1-2026-04-27.json`) — but include ALL deployed addresses, not just the 10-contract subset (audit-#38 finding INV-1 noted that the Sepolia manifest was incomplete).

```powershell
$manifest = @{
    version = "5.1"
    network = "base_mainnet"
    chainId = 8453
    deployedAt = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    deployer = $env:MULTISIG
    contracts = @{
        # protocol core
        luminaToken = $env:LUMINA_TOKEN
        claimBond = $env:CLAIM_BOND
        bondVault = $env:BOND_VAULT
        policyManager = $env:POLICY_MANAGER
        coverRouter = $env:COVER_ROUTER
        twapBurner = $env:TWAP_BURNER
        # marketplace
        marketplace = $env:MARKETPLACE
        buybackEngine = $env:BUYBACK_ENGINE
        # treasury / vesting
        cexLiquidityReserve = $env:CEX_LIQUIDITY_RESERVE
        maintenanceReserve = $env:MAINTENANCE_RESERVE
        founderVesting = $env:FOUNDER_VESTING
        treasuryVesting = $env:TREASURY_VESTING
        # oracles
        capacityOracle = $env:CAPACITY_ORACLE
        adaptiveFeeDistributor = $env:ADAPTIVE_FEE_DISTRIBUTOR
        # 9 shields (extract from log)
        # ...
    }
} | ConvertTo-Json -Depth 10
$manifest | Out-File "deployments\mainnet\V5.1-$(Get-Date -Format 'yyyy-MM-dd').json" -Encoding UTF8
```

Commit + push the manifest:

```powershell
git checkout -b deploy/v5.1-mainnet-$(Get-Date -Format 'yyyy-MM-dd')
git add deployments/mainnet/
git commit -m "deploy: V5.1 to Base Mainnet successful"
git push origin HEAD
gh pr create --title "deploy: V5.1 mainnet manifest"
```

## Update API and Web (5 min, async)

### 9. lumina-api → mainnet

In Railway dashboard for `lumina-api`:

| Variable | Old (Sepolia) | New (Mainnet) |
|---|---|---|
| `RPC_URL` | sepolia URL | `BASE_RPC_URL` paid endpoint |
| `CHAIN_ID` | 84532 | 8453 |
| `LUMINA_TOKEN` | sepolia addr | mainnet addr from manifest |
| `CLAIM_BOND` | sepolia addr | mainnet addr |
| `BOND_VAULT` | sepolia addr | mainnet addr |
| `POLICY_MANAGER` | sepolia addr | mainnet addr |
| `COVER_ROUTER` | sepolia addr | mainnet addr |
| `MARKETPLACE` | sepolia addr | mainnet addr |
| `USDC` | mock | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Generate a NEW relayer wallet for mainnet (do NOT reuse the Sepolia one). Fund it with ETH for gas. Authorise it on the new `CoverRouter`:

```powershell
cast send $env:COVER_ROUTER "setRelayer(address,bool)" `
    "0x<new-relayer-address>" true `
    --rpc-url $env:BASE_RPC_URL `
    --private-key $env:DEPLOYER_PRIVATE_KEY
```

Set `RELAYER_PRIVATE_KEY` in Railway to the new key. Restart the service. Hit `/health` to confirm `chainId: 8453` + relayer balance > 0.

### 10. lumina-org.com (frontend) → mainnet

Mirror the audit-#35 fix but for chainId 8453:

- Update `lib/lumina-config.ts` `CHAIN.id = 8453`, contract addresses to mainnet manifest
- Update `components/lumina/web3-provider.tsx` `chains: [base]` (instead of `baseSepolia`)
- Update `app/api/rpc/route.ts` RPC fallback list to mainnet endpoints

Push to main; Vercel auto-deploys. Run the `02-WEB-MANUAL-CHECKLIST.md` from audit-#37 (browser flow) against the new frontend.

## Smoke test on mainnet (5 min)

### 11. First on-chain policy

Mint USDC to a buyer wallet (operator's secondary EOA), approve `CoverRouter`, purchase via API:

```powershell
# This is a real $3 USDC spend on mainnet — operator should be ready to lose it.
$apiKey = "lk_<freshly-issued-mainnet-key>"
curl -X POST https://lumina-api-production-ac85.up.railway.app/api/v1/policies `
    -H "x-api-key: $apiKey" `
    -H "Content-Type: application/json" `
    -d '{"productId":"<flashbtc1h>","coverageAmount":"1000000000","asset":"<bytes32>","buyer":"0x<buyer>"}'
```

Expected response: `{ ok: true, policyId: 1, txHash: 0x..., ... }`. If the response is 503 `relayer_unauthorized`, step 9 was skipped — go back and run `setRelayer`.

### 12. Verify on Basescan

```
https://basescan.org/address/<COVER_ROUTER>#events
```

Should show `PolicyPurchased` event with the buyer's address and policyId 1.

## Total time

~25 minutes if everything goes right. Add 10-15 minutes of buffer for Basescan verification confirmations (5 minutes per contract × pipeline).

## Right-after-deploy operator action items

1. Tweet / Discord announcement.
2. Set up uptime monitoring on `https://lumina-api-production-ac85.up.railway.app/health`.
3. Document in audit log: deploy time, all tx hashes, gas spent (compare to audit-#38 estimate of 0.000657 ETH).
4. Open a PR with `deployments/mainnet/V5.1-<date>.json`.
5. After 24-48 hours of clean operation: schedule the multisig + TimelockController installation per the founder's roadmap.
