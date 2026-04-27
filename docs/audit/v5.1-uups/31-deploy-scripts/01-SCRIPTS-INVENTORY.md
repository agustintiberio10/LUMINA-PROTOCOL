# Audit V5.1 #31 — Deploy Scripts Inventory

Every script in `script/` evaluated for purpose, dependencies, inputs, outputs, and idempotency.

---

## 1. `script/deploy/DeployLuminaV5Complete.s.sol` (mainnet)

**Purpose:** Production deployment of all 24 UUPS contracts + FounderVesting.

**Entry point:** `run()` — single function.

**Environment variables (required):**
- `USDC_ADDRESS` — mainnet USDC (e.g. Base: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`).
- `SWAP_ROUTER` — DEX router address.
- `MULTISIG` — Gnosis Safe that will own the protocol.
- `LBP_DEPOSIT` — wallet receiving 5M LBP LUMINA at mint.
- `OPS_WALLET` — wallet receiving the ops bucket from TWAPBurner distribution.
- `FOUNDER_RECIPIENT` — FounderVesting recipient EOA.
- `CHAINLINK_ORACLE` — price feed for shields.
- `AAVE_POOL` — Aave V3 Pool (for RateShockShield).

**Outputs:** 24 addresses logged (Core + Treasury + Marketplace + 9 Shields + FounderVesting).

**Re-runnable:** ❌ NOT idempotent. Each run deploys fresh contracts. No detection of existing deployments. Running twice creates orphaned proxies.

**Ownership transfer:** ✅ Transfers ownership of all Ownable contracts + admin roles of all AccessControl contracts to `cfg.multisig` at the end. Revokes deployer's roles.

**Deploy order (19 steps):** MaintenanceReserve → ClaimBond → precompute LUMINA → CapacityOracle → BondVault(pm=0) → CEX → FounderVesting → TreasuryVesting → LUMINA → ClaimBond.setBondVault → SolvencyOracle → AdaptiveFeeDistributor → TWAPBurner → PolicyManagerV2 → BondVault.setPolicyManager → CoverRouterV2 → PolicyManagerV2.setRouter → Marketplace → BuybackEngine → 9 Shields → wiring + role transfer.

### Critical gap identified

**The script DOES NOT call `claimBond.setAuthorizedOperator(marketplace, true)`.** Fix #18 requires this to allow Marketplace to move bonds. Without it, the marketplace is non-functional post-deploy.

Secondary gap: no `setAuthorizedOperator(buybackEngine, true)` either — BuybackEngine can execute `executeBuy` because the tokens transfer from Marketplace (which IS the sender) rather than from BuybackEngine directly. But a second audit of BuybackEngine's bond flow is warranted.

---

## 2. `script/deploy/DeployLuminaV5Sepolia.s.sol` (testnet)

**Purpose:** Sepolia testnet deployment with inline mocks (USDC, Chainlink oracle, shield oracle, Aave pool, DEX router).

**Entry point:** `run()`.

**Environment variables:**
- `PRIVATE_KEY` — deployer's private key.

**Outputs:** Same contract set as Complete, plus mock addresses.

**Re-runnable:** ❌ NOT idempotent.

**Key difference from mainnet:** FounderVesting is **NOT deployed** — uses `_labelToAddress("founderVesting")` to generate a deterministic placeholder. 8M LUMINA is minted to this address, effectively burned (no private key controls it on testnet). Same for `lbpDeposit` (5M).

**Ownership transfer:** ❌ Does NOT transfer to multisig — deployer retains control (testnet convention).

### Critical gap identified (same as Complete)

**No `claimBond.setAuthorizedOperator(marketplace, true)` call.** Sepolia deploys a non-functional marketplace.

---

## 3. `script/deploy/DeployLuminaWithSaltMining.s.sol` (CREATE2 variant)

**Purpose:** Presumably for CREATE2-mined vanity addresses.

Not audited in detail (scope — the Sepolia/Complete scripts are the primary deployment paths).

---

## 4. `script/wire/WireLuminaV5PostDeploy.s.sol`

**Purpose:** Post-deploy administrative utilities for ops team.

**Functions provided:**
- `addShield(...)` — register a new shield in PM + configure in Router.
- `removeShield(...)` / `deactivateProduct(...)` — product lifecycle.
- `transferOwnership(...)` helpers for Ownable contracts.
- Role management helpers (grant/revoke).

**Not exposed:**
- No `setAuthorizedOperator` helper — missing! If admin needs to authorize Marketplace or BuybackEngine on ClaimBond, they must call it directly via cast/Etherscan.

**Re-runnable:** ✅ Each function is idempotent on its own call.

---

## 5. `script/verify/VerifyLuminaV5Deployment.s.sol`

**Purpose:** Post-deploy verification utility.

**Coverage:** reads state from deployed contracts and logs for manual review.

**Gap:** does NOT verify `claimBond.authorizedOperators(marketplace) == true`. Would have caught the deploy bug.

---

## 6. `script/run-tests.sh`

Shell script to run Foundry tests. Not a deploy script per se.

---

## 7. Testnet testing scripts (`script/testnet-tests/`)

Scripts for post-deploy sanity tests on Sepolia. Not reviewed in detail.

---

## 8. Summary matrix

| Script | Purpose | Env vars | Re-runnable | Ownership transfer | Critical gap |
|---|---|---|---|---|---|
| DeployLuminaV5Complete | Mainnet deploy | 8 vars | ❌ | ✅ to multisig | **missing setAuthorizedOperator** |
| DeployLuminaV5Sepolia | Testnet deploy | PRIVATE_KEY | ❌ | ❌ (deployer retains) | **missing setAuthorizedOperator** + **FounderVesting not deployed** |
| DeployLuminaWithSaltMining | CREATE2 vanity | TBD | TBD | TBD | not audited in detail |
| WireLuminaV5PostDeploy | Post-deploy ops | per-fn | ✅ | helper only | no setAuthorizedOperator helper |
| VerifyLuminaV5Deployment | Post-deploy verify | — | ✅ | — | doesn't check marketplace wiring |

## 9. Action items for deploy scripts (blocking mainnet)

1. **CRITICAL** — Add `claimBond.setAuthorizedOperator(address(marketplace), true)` to both deploy scripts (right after marketplace deploy, before any user can interact).
2. **CRITICAL** — Consider also `claimBond.setAuthorizedOperator(address(buybackEngine), true)` for buyback's double-burn path if it needs to transfer bonds.
3. **HIGH** — Add `authorizedOperators(mp) == true` assertion to VerifyLuminaV5Deployment so a misdeployed protocol is caught.
4. **MEDIUM** — Add `setAuthorizedOperator(address,bool)` helper to WireLuminaV5PostDeploy for manual fix path.
5. **LOW** — Document in a `DEPLOY-RUNBOOK.md` that these scripts are not idempotent — re-running creates orphaned proxies.
