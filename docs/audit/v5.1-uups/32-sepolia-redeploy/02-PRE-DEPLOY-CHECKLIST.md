# Pre-Deploy Checklist — Sepolia V5.1 Redeploy

Complete every item below BEFORE running the deploy command. If any item fails, halt and resolve before proceeding.

---

## 1. Code state

- [ ] On branch `main`, fully synced with `origin/main` (no local commits ahead).
- [ ] Working tree clean (`git status` shows no uncommitted changes).
- [ ] All pending audits/fixes merged to main:
  - [ ] Audit #1-31 merged
  - [ ] Fix M-01 merged
  - [ ] Fix M-02 merged
  - [ ] Fix M-03 merged
  - [ ] Fix #18 (NFT metadata + restricted transfers) merged
  - [ ] Fix #26 (recoverToken batch + LOW-1 event) merged
  - [ ] Fix #27 (admin-setter events) merged
  - [ ] Fix #28 (pause hysteresis + KeeperPaused event) merged
  - [ ] Fix #31 (deploy CRITICAL + 2 HIGH) merged ← **most important for this deploy**

## 2. Build + test

- [ ] `forge fmt --check` exits 0 (no formatting drift)
- [ ] `forge build` exits 0 (no errors, no warnings)
- [ ] Full regression: `forge test --no-match-contract "Fork"` exits 0
- [ ] **2091 tests pass** (or higher, never lower)

## 3. Wallet + RPC

- [ ] Deployer EOA holds ≥ **0.5 ETH** on Base Sepolia for gas.
  - Estimated total deploy gas: ~50-80M units. At 0.5 gwei base fee, ~0.04 ETH actual cost; 0.5 ETH covers safety margin.
- [ ] Base Sepolia RPC endpoint operational. Test with:
  ```
  cast rpc eth_blockNumber --rpc-url $BASE_SEPOLIA_RPC_URL
  ```
  Should return current block number, not error.
- [ ] BaseScan (Etherscan-compatible) API key available for source verification.
- [ ] If transferring ownership: Multisig Safe address ready (`MULTISIG_ADDRESS` env var).

## 4. Environment variables

Required:
```bash
export PRIVATE_KEY=0x...                        # deployer EOA
export BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/...
export ETHERSCAN_API_KEY=...                    # Base Sepolia uses BaseScan, same API
```

Optional (for later steps):
```bash
export MULTISIG_ADDRESS=0x...   # for ownership transfer step
```

Never:
- Commit any of these to git.
- Share via Slack/Discord (use a password manager).
- Reuse the deployer key on mainnet (deploy mainnet from a fresh, ceremony-tested key).

## 5. Verification scripts ready

- [ ] `script/verify/VerifyLuminaV5Deployment.s.sol` includes the new marketplace authorization checks (post fix #31).
- [ ] `script/wire/WireLuminaV5PostDeploy.s.sol` includes the `authorizeMarketplaceOperators` helper.

Spot-check by grepping for "Fix audit #31" markers in those files.

## 6. Backup

- [ ] Snapshot of git HEAD SHA recorded for post-deploy reference.
- [ ] Branch `main` tag at HEAD (e.g. `v5.1-sepolia-redeploy-{date}`) for easy rollback.

## 7. Communication

- [ ] If beta testers exist on V5.0 Sepolia, notify them of the impending redeploy + new addresses.
- [ ] Post-deploy plan: who updates the front-end? When?

---

When ALL items checked, proceed to `03-DEPLOY-RUNBOOK.md`.
