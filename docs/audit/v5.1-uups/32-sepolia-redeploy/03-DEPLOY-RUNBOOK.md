# Sepolia V5.1 Deploy Runbook

Step-by-step procedure for executing the clean V5.1 redeploy on Base Sepolia.

**Prerequisite:** every item in `02-PRE-DEPLOY-CHECKLIST.md` is checked.

---

## Step 0 — Final preflight

```bash
cd C:\Users\AGUSTIN\LUMINA-PROTOCOL
git checkout main
git pull origin main
git status   # must be clean
git rev-parse HEAD > /tmp/deploy-commit.txt   # record for audit trail

forge build
forge test --no-match-contract "Fork" 2>&1 | tail -3   # must show 2091+ pass
```

---

## Step 1 — Run the deploy script

```bash
forge script script/deploy/DeployLuminaV5Sepolia.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

The script:
1. Deploys mocks (USDC, oracles, DEX router).
2. Deploys ClaimBond, MaintenanceReserve.
3. Predicts LUMINA proxy address.
4. Deploys CapacityOracle, BondVault (with PM=0), CEXLiquidityReserve, TreasuryVesting.
5. Deploys LUMINA proxy — verifies prediction matches actual.
6. Wires `claimBond.setBondVault(bondVault)`.
7. Deploys SolvencyOracle, AdaptiveFeeDistributor, TWAPBurner.
8. Deploys PolicyManagerV2, CoverRouterV2 — wires both.
9. Calls `bondVault.setPolicyManager(pm)` (one-shot).
10. Deploys Marketplace, BuybackEngine.
11. **[Fix #31]** Calls `claimBond.setAuthorizedOperator(marketplace, true)` and `claimBond.setAuthorizedOperator(buybackEngine, true)`.
12. Deploys ShieldKeeper + 9 Shields.
13. Registers 9 products in PolicyManager.
14. Configures 9 products in CoverRouter.
15. Authorizes BuybackEngine in BondVault.
16. Wires TWAPBurner: feeDistributor, reserves, capacityOracle, authorizedSender, adaptiveMode.
17. Grants BURNER_ROLE to TWAPBurner.

### Expected output

Console logs every contract address. Final summary:
```
=== DEPLOYMENT COMPLETE ===
Network: Sepolia (testnet)
--- Mocks ---
  MockUSDC:           0x...
--- Core Protocol ---
  LuminaTokenV2:      0x...
  ...
```

### What can go wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `LUMINA proxy address prediction failed!` | Nonce drift between predict and deploy | Restart, ensure no other tx queued |
| Specific contract verify fails on BaseScan | Constructor args encoding | Re-run `--verify` only on that contract |
| Out-of-gas mid-deploy | Insufficient ETH balance | Top up deployer, restart |
| `setAuthorizedOperator` revert | ClaimBond's `bondVault` not yet set when called | Verify order — must be after setBondVault |

If something fails partway through, **DO NOT re-run the script** (it's not idempotent — would create orphaned proxies). Manually complete the missing steps using `WireLuminaV5PostDeploy` helpers.

---

## Step 2 — Run the verify script

```bash
forge script script/verify/VerifyLuminaV5Deployment.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --sig "run()" \
  -vvv
```

Set the env vars first (paste from Step 1's output):
```bash
export LUMINA_TOKEN=0x...
export BOND_VAULT=0x...
export CLAIM_BOND=0x...
export MARKETPLACE=0x...
export BUYBACK_ENGINE=0x...
# ... etc (15 addresses total)
```

The verify script reads every contract and prints `[PASS]` / `[FAIL]` per check. **Every line must be PASS.** Any FAIL = stop, investigate.

Specifically watch for:
- `[PASS] ClaimBond.authorizedOperators[marketplace] == true`
- `[PASS] ClaimBond.authorizedOperators[buybackEngine] == true`

These are the post-fix-#31 checks. If they FAIL, the deploy script didn't apply the CRITICAL fix.

---

## Step 3 — Smoke-test the deployment

Manual smoke test using `cast`. Replace `$LUMINA`, `$USDC`, etc. with addresses from Step 1.

### 3.1 Mint test USDC to a fresh wallet

```bash
TEST_BUYER=0x...  # any test EOA
cast send $USDC "mint(address,uint256)" $TEST_BUYER 10000000000 \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY
```

(`10000000000` = 10000 USDC at 6 decimals.)

### 3.2 Approve CoverRouter

```bash
cast send $USDC "approve(address,uint256)" $COVER_ROUTER 10000000000 \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $TEST_BUYER_KEY
```

### 3.3 Buy a policy (FlashBTC1h)

```bash
PRODUCT_ID=$(cast keccak "FLASHBTC1H-001")
cast send $COVER_ROUTER "purchasePolicy(bytes32,uint256,bytes32)" \
  $PRODUCT_ID 1000000000 0x4254430000000000000000000000000000000000000000000000000000000000 \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $TEST_BUYER_KEY
```

(coverage = 1000 USDC = 1e9; asset = "BTC" padded.)

Verify policy was created:
```bash
cast call $POLICY_MANAGER "totalPolicies()" --rpc-url $BASE_SEPOLIA_RPC_URL
# Should return 1 (or higher if other test buyers ran)
```

### 3.4 List a bond on marketplace (after settlement)

This requires settlement first. For automated smoke test, use a Foundry script:

```bash
forge script script/testnet-tests/SmokeTestE2E.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $TEST_BUYER_KEY
```

(The script triggers settlement via mock oracle, lists bond on marketplace, executes buy from a second test wallet.)

If the marketplace `list()` call succeeds, **the CRITICAL fix #31 is confirmed working in production**.

---

## Step 4 — Record addresses

Create `deployments/sepolia/V5.1-{YYYY-MM-DD}.json` with the template structure shown in `REPORT.md §6` or copy from `V5.1-TEMPLATE.json`. Fill in every address from Step 1 output.

Commit + push:
```bash
git add deployments/sepolia/V5.1-*.json
git commit -m "chore(deploy): record Sepolia V5.1 addresses ({date})"
git push
```

---

## Step 5 — (Optional) Transfer ownership to multisig

If `MULTISIG_ADDRESS` is set, transfer all ownership/admin roles using the wire helper. **Only do this if the multisig is fully tested and you have access to its signing keys.**

```bash
# For each Ownable contract:
forge script script/wire/WireLuminaV5PostDeploy.s.sol \
  --sig "transferOwnership(address,address)" $TWAP_BURNER $MULTISIG_ADDRESS \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Repeat for: COVER_ROUTER, POLICY_MANAGER, CAPACITY_ORACLE, CLAIM_BOND, TREASURY_VESTING, FOUNDER_VESTING (if deployed), ADAPTIVE_FEE_DISTRIBUTOR, SHIELD_KEEPER + each shield
```

For AccessControl contracts (BondVault, BuybackEngine, Marketplace, CEXReserve, MaintenanceReserve, SolvencyOracle, LuminaTokenV2):
```bash
DEFAULT_ADMIN=$(cast keccak "0x")  # = bytes32(0)
# Grant to multisig
forge script script/wire/WireLuminaV5PostDeploy.s.sol \
  --sig "grantRole(address,bytes32,address)" $BOND_VAULT $DEFAULT_ADMIN $MULTISIG_ADDRESS \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
# Then revoke from deployer:
forge script script/wire/WireLuminaV5PostDeploy.s.sol \
  --sig "revokeRole(address,bytes32,address)" $BOND_VAULT $DEFAULT_ADMIN $DEPLOYER \
  --rpc-url $BASE_SEPOLIA_RPC_URL --private-key $MULTISIG_KEY --broadcast
```

(Note: revoke is from the multisig's authority since deployer just lost it.)

For Sepolia testnet ownership transfer is OPTIONAL — many teams keep the deployer key for ease of testing.

---

## Step 6 — Announce + monitor

- Update front-end / API integrations with new addresses.
- Post the new V5.1-Sepolia addresses to the community channel.
- Set up event monitoring for the next ~72 hours: track `Upgraded`, `RoleGranted`, `OwnershipTransferred`, `TokenRecovered`, `PolicyPurchased`. Anomalies → investigate immediately.

---

## Rollback plan

If a critical bug is detected post-deploy in V5.1 Sepolia:

- **Sepolia is testnet** — abandoning a deploy is acceptable.
- Mark the new V5.1 Sepolia addresses as deprecated.
- Fix the bug in main.
- Re-run this runbook with a fresh deploy.

For mainnet (audit #38+), the rollback procedure differs — see future audits.
