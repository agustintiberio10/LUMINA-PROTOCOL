# 01 — Pre-mainnet checklist

This is the actionable status of every precondition the operator should clear before broadcasting the V5.1 deploy on Base Mainnet. Each entry is `[x]` (verified at audit time), `[~]` (operator action required), or `[ ]` (blocker).

> **Owner / governance instruction (founder, 2026-04-28):** NO Multisig and NO TimelockController are to be installed at deploy time. Owner = deployer EOA. The founder will install governance manually after the system stabilises.

## Code readiness

- [x] **Audits #33-#38 + their fixes merged in main.** PRs #86 (relayer-payment fix), #87 (adversarial relayer), #88 (audit #33 API), #90 (audit #36 auth-rate deep), #91 (audit #37 E2E), #92 (audit #38 mainnet fork rehearsal), #93 (audit-38 gas estimate fix) all show `MERGED` per `gh pr view`.
- [~] **Older audit PRs still open.** PRs #72 (#24 disaster recovery), #74 (#26 funds rescue), #76 (#27 owner ops), #78 (#28 pause/unpause), and a few non-audit PRs (#5, #22, #23) remain `OPEN`. None are CRITICAL/HIGH-flagged in their bodies, but the founder should triage merge-or-close before broadcasting.
- [x] **`forge fmt` clean.** Last formatter run on 2026-04-28 reformatted only audit-#38 files; main is now clean.
- [x] **`forge build` succeeds with warnings only.** Warnings are forge-lint style (snake/camel-case suggestions, unaliased imports). Zero compile errors.
- [x] **`forge test --no-match-contract Fork`** → 2 122 / 2 122 pass / 0 fail / 0 skip (per audit-#37 verification on 2026-04-28).
- [x] **Storage layouts byte-identical** for the only contract that received a logic-only fix in V5.1 (`CoverRouterV2`). Audit-#86 tracked this via `forge inspect CoverRouterV2 storage-layout` before/after diff = empty.

## Infrastructure

- [~] **Base Mainnet RPC URL.** `foundry.toml` has `base = "${BASE_RPC_URL}"`; the operator must set `BASE_RPC_URL` to a paid Alchemy/Infura URL before broadcasting. The public `https://mainnet.base.org` works for fork tests but is rate-limited under broadcast load.
- [~] **BaseScan API key.** `foundry.toml` has `[etherscan].base = { key = "${BASESCAN_API_KEY}" }`. Operator must set `BASESCAN_API_KEY` for `--verify` to succeed at deploy time.
- [~] **Wallet deployer balance ≥ 0.005 ETH.** Audit-#38 measured the full deploy at **0.000657 ETH ≈ $1.54 USD**. A 7× margin (0.005 ETH ≈ $11.74) is the recommended cushion to absorb gas-price spikes. Operator must verify with `cast balance` before broadcasting.
- [x] **Foundry version.** Tested with the foundry pinned in this repo's CI; `forge --version` reports a recent build.
- [x] **`foundry.toml` has `base_mainnet` endpoint.** Added in audit-#38 (`https://mainnet.base.org` as default; overridable via `BASE_RPC_URL`).

## Real-dependency addresses validated (per audit-#38 fork tests)

- [x] **USDC** `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` — `decimals() == 6` confirmed at fork block 30 000 000.
- [x] **Chainlink BTC/USD** `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` — returned $103 196 at audit time, 8-decimals.
- [x] **Chainlink ETH/USD** `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` — returned $2 348.
- [x] **Chainlink USDC/USD** `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` — returned $1.00002.
- [x] **Aave V3 Pool** `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` — `cast call` returned variable borrow rate 1.183e27 ray ≈ 11.83% APY (within sanity band 0.1%–30%). Foundry-fork limitation documented in audit-#38; does NOT block deploy because the deploy script does not call Aave at deploy time.
- [x] **Uniswap V3 SwapRouter02** `0x2626664c2603336E57B271c5C0b26F421741e481` — bytecode present at fork block.
- [x] **Aerodrome Router** `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` — alternative; not used by default. Documented in `01-MAINNET-DEPS.md` (audit #38).

## Configuration scripts

- [x] **`script/deploy/DeployLuminaV5Mainnet.s.sol`** — production entry point with hardcoded mainnet dependency addresses, delegating to the audited `DeployLuminaV5Complete` flow via `vm.setEnv`. Created in audit #38, merged in #92.
- [x] **`script/deploy/DeployLuminaV5Complete.s.sol`** — the underlying deploy logic. Reads operator-supplied env vars (`MULTISIG`, `LBP_DEPOSIT`, `OPS_WALLET`, `FOUNDER_RECIPIENT`). Already audited as part of audits #1-#36.
- [x] **Configure-products is in `DeployLuminaV5Complete`.** No separate `ConfigureLuminaV5Products.s.sol` exists; the configuration step is in-line in the main deploy script (calls `_configureProducts(...)` near the end, registering and configuring all 9 products in one shot). Verified by reading `script/deploy/DeployLuminaV5Complete.s.sol:436-445` and `:524-534`.
- [x] **`script/wire/WireLuminaV5PostDeploy.s.sol`** — exists. Includes the `authorizeMarketplaceOperators(claimBond, marketplace, buybackEngine)` call from fix #31 (audit #86 confirmed wiring correctness post-deploy on Sepolia). For mainnet the wiring already happens inline in `DeployLuminaV5Complete.run()` at lines 430-432; the standalone Wire script is a safety net for re-running idempotently.
- [x] **`script/verify/VerifyLuminaV5Deployment.s.sol`** — exists. Read-only; reads back the deployed addresses via env vars and validates wiring (balances, roles, ownership). Confirmed working on Sepolia post-#86 (28/28 checks passed).

## Operational

- [~] **Communication plan.** Operator action: prepare a Twitter / Discord / mailing-list post for the moment of broadcast. Out of audit scope.
- [x] **Rollback documented.** See `03-CONTINGENCY-PLAN.md` in this audit folder.
- [~] **Monitoring.** The lumina-api `/health` endpoint exposes RPC connectivity + relayer balance. Operator must point a generic uptime monitor (UptimeRobot, BetterUptime, etc.) at `https://lumina-api-production-ac85.up.railway.app/health` after the API gets re-pointed at mainnet.
- [~] **Bug bounty.** Out of audit scope; founder should publish a bounty doc before public-launch announcement.

## Mainnet-specific operator action items pending

The audit cannot tick these on the operator's behalf:

1. Set `BASE_RPC_URL` env var (paid endpoint).
2. Set `BASESCAN_API_KEY` env var.
3. Set `DEPLOYER_PRIVATE_KEY` env var.
4. Set the four operator addresses for `MULTISIG`, `LBP_DEPOSIT`, `OPS_WALLET`, `FOUNDER_RECIPIENT`. **Per the founder note above, `MULTISIG` should equal the deployer EOA at this stage.**
5. Fund the deployer wallet with ≥ 0.005 ETH on Base mainnet.
6. Decide what to do with the older open PRs (#5, #22, #23, #72, #74, #76, #78).
7. After broadcast, point the lumina-api Railway env vars at the new mainnet contract addresses + chainId 8453.
8. After broadcast, re-deploy the v0-lumina-landing-page frontend with the mainnet config (mirror of audit-#35 fix but for chainId 8453).

## Verdict on this checklist

**CONDITIONAL GO** — every code-side item is green; eight operator-side items remain. Once those are done, the deploy can be broadcast within ~10 minutes per the runbook in `02-DEPLOY-RUNBOOK.md`.
