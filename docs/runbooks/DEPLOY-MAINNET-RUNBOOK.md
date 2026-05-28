# LUMINA Protocol V5.0 — Mainnet Deploy Runbook

## Overview

This runbook covers the full deployment lifecycle for LUMINA Protocol V5.0 to Ethereum mainnet, from T-7 preparation through T+7 post-deploy monitoring.

---

## T-7: Pre-Deploy Preparation

### Environment Verification

- [ ] Confirm all contracts compile cleanly: `forge build --sizes`
- [ ] Run full test suite: `forge test --fork-url $ETH_RPC_URL -vvv`
- [ ] Verify gas estimates are within acceptable limits
- [ ] Confirm deployer wallet has sufficient ETH (minimum 2.0 ETH recommended)
- [ ] Verify multisig wallet addresses are correct and accessible
- [ ] Confirm Chainlink price feed addresses for target network

### Configuration Review

- [ ] Review `DeployLuminaV5Complete.s.sol` parameters:
  - Treasury multisig address
  - Chainlink LUMINA/USD feed address
  - Chainlink ETH/USD feed address
  - TWAPBurner dexRouters configuration
  - Initial solvency parameters
- [ ] Verify all constructor arguments match intended values
- [ ] Cross-reference deployment parameters with governance-approved values

### External Dependencies

- [ ] Chainlink price feeds confirmed active and reporting
- [ ] Uniswap V3 pool exists or creation parameters defined
- [ ] DEX router addresses verified for TWAPBurner

---

## T-3: Final Checks

- [ ] Deploy to fork and run `VerifyLuminaV5Deployment.s.sol` against fork
- [ ] Simulate full user flows on fork (bond, trigger, claim, buyback)
- [ ] Confirm rollback procedure with all team members
- [ ] Notify multisig signers of deploy window
- [ ] Prepare communication drafts (success and delay announcements)

---

## T-1: Day Before Deploy

- [ ] Final code freeze — no merges after this point
- [ ] Re-run full test suite on frozen code
- [ ] Verify deployer wallet nonce and balance
- [ ] Confirm all signers available during deploy window
- [ ] Set up monitoring dashboards (blank, ready to receive data)
- [ ] **MANDATORY — run the fork dry-run orchestrator (ADR-027). All 6
  validations MUST pass before greenlight. If the orchestrator exits
  non-zero, STOP and triage before broadcasting anything.**

  ```bash
  BASE_MAINNET_RPC=<your-mainnet-rpc> bash script/dry-run/run.sh \
    || { echo "DRY-RUN FAILED — DO NOT BROADCAST"; exit 1; }
  ```

  Expected: `FAIL_COUNT_TOTAL=0`. See `script/dry-run/README.md` for what is
  validated and why this is non-optional.

---

## Deploy Day (T+0)

### Hour 0: Deploy Initiation

#### PRE-FLIGHT CHECKS — TWO CHECKPOINTS

> The pre-flight runs **twice** in the mainnet lifecycle. They are separate scripts because the LUMINA/USDC pool only exists after the LBP, so the full FN-C1 check (`pool != 0`) cannot pass at deploy time. See [`MAINNET-DEPLOY-STAGED-PLAN.md`](MAINNET-DEPLOY-STAGED-PLAN.md) for the full staged flow.

| When | Script | What it allows / requires that's different |
|------|--------|---------------------------------------------|
| **Checkpoint A — BOOTSTRAP** (after deploy + pause + admin handoff, **before LBP**) | `script/PreFlightCheckBootstrap.s.sol` | Allows `pool == 0` (LBP hasn't happened). **Requires `coverRouter.paused() == true`** — the safety net that compensates for pool==0. |
| **Checkpoint B — FULL** (after LBP + `setPool`, **before unpause**) | `script/PreFlightCheck.s.sol` | Requires `pool != 0` (FN-C1 full). Run this gate BEFORE `coverRouter.setPaused(false)`. |

Both checks share the rest: FN-H1 (USDC=Circle), RM-C1 (admin=Safe, not EOA), chainId==8453, deployer != burned EOA.

##### Checkpoint A — BOOTSTRAP pre-flight (pre-LBP)

> **Hard gate before LBP.** With the protocol still paused and pool=0, this verifies everything else is correct so the LBP can run safely.

```bash
# Required env (deployed addresses from Hour 0 STEP 1 below):
export LUMINA_TOKEN=<token-proxy>
export BOND_VAULT=<bondvault-proxy>
export CAPACITY_ORACLE=<capacityoracle-proxy>     # pool() may be 0 here — OK at this stage
export COVER_ROUTER=<coverrouter-proxy>           # paused() MUST == true (safety net)
export GNOSIS_SAFE=<safe-multisig>                # MUST hold DEFAULT_ADMIN_ROLE on token + vault
export DEPLOYER=<NEW hardware wallet>             # MUST NOT be 0xe585…fDa8 (burned Sepolia EOA)

forge script script/PreFlightCheckBootstrap.s.sol:PreFlightCheckBootstrap \
  --rpc-url $BASE_MAINNET_RPC
```

Expected last line:
```
BOOTSTRAP PRE-FLIGHT PASSED - safe to proceed to LBP
REMEMBER: after setPool, run script/PreFlightCheck.s.sol (full) before unpausing.
```

On failure the script reverts with one of:
`BOOTSTRAP: coverRouter must be paused` · `FN-H1: USDC not mainnet` · `RM-C1: {EOA has|Safe missing} {token|vault} admin` · `BONUS: wrong chainId` · `BONUS: deployer is burned EOA`. **9 failure paths unit-tested** in `test/PreFlightCheckBootstrap.t.sol`.

##### Checkpoint B — FULL pre-flight (pre-unpause, post-LBP)

> **Hard gate before `setPaused(false)`.** Run AFTER the Safe has called `capacityOracle.setPool(realPool)` and the long TWAP window has filled (≥2h of swap activity).

```bash
# Same env vars as Checkpoint A — but now CAPACITY_ORACLE.pool() MUST != 0.
forge script script/PreFlightCheck.s.sol:PreFlightCheck \
  --rpc-url $BASE_MAINNET_RPC
```

Expected last line on success:
```
ALL PRE-FLIGHT CHECKS PASSED - safe to deploy
```

On failure the script reverts with one of:
`FN-C1: pool not set` · `FN-H1: USDC not mainnet` · `RM-C1: {EOA has|Safe missing} {token|vault} admin` · `BONUS: wrong chainId` · `BONUS: deployer is burned EOA`. **9 failure paths unit-tested** in `test/PreFlightCheck.t.sol`.

**Operator must see the success line** before calling `coverRouter.setPaused(false)` to activate the protocol.

#### STEP 1 — Deploy (chained: Complete + Phase C + handoff)

> **ADR-027 update**: the mainnet wrapper `DeployLuminaV5Mainnet` now chains
> Complete → Phase C (shields + product registration) → deferred PolicyManagerV2
> + CoverRouterV2 handoff to MULTISIG in a single `forge script` run. This
> is the ONLY supported deploy path for mainnet. The previous wrapper had a
> `msg.sender` bug (revert at STEP 8 "LUMINA proxy address mismatch - nonce
> drift") detected by the fork dry-run on 2026-05-28; the fix is the
> inheritance pattern with `super.run()`. See ADR-027 for full rationale.

```bash
# Set environment (DEPLOYER_PRIVATE_KEY is the canonical name — PR #186)
export DEPLOYER_PRIVATE_KEY=<secure-key>
export BASE_MAINNET_RPC=<mainnet-rpc>
export ETHERSCAN_API_KEY=<key>

# Operator-supplied addresses
export MULTISIG=<Gnosis Safe>
export RELAYER=<relayer EOA>
export ORACLE_KEY=<EIP-712 oracle signer EOA>
export SEQUENCER_UPTIME_FEED=0xBCF85224fc0756B9Fa45aA7892530B47e10b6433
export LBP_DEPOSIT=<LBP recipient>
export OPS_WALLET=<ops fee collector>
export FOUNDER_RECIPIENT=<founder vesting recipient>

# Execute chained deployment (Complete → PhaseC → handoff)
forge script script/deploy/DeployLuminaV5Mainnet.s.sol:DeployLuminaV5Mainnet \
  --rpc-url $BASE_MAINNET_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --broadcast \
  --verify \
  --slow \
  -vvv
```

Wrapper end-state when this exits cleanly:
- 19 core contracts deployed (Complete)
- 6 shields + 6 adapters deployed, registered on PolicyManagerV2,
  configured on CoverRouterV2 (Phase C)
- `coverRouter.setPaused(true)` already done
- PolicyManagerV2 + CoverRouterV2 ownership transferred to MULTISIG
- BondVault + LuminaTokenV2 DEFAULT_ADMIN_ROLE STILL held by deployer
  (handed off in STEP 2 below, per ADR-012)

- [ ] Record all deployed contract addresses immediately
- [ ] Verify each contract on Etherscan
- [ ] Confirm proxy admin ownership set correctly

#### STEP 2 — BondVault + LuminaTokenV2 admin handoff (ADR-012 + ADR-027 order)

> **ADR-027 — revoke order is NOT cosmetic.** AccessControl's `revokeRole`
> is itself gated by the role admin chain. On BondVault, both
> `DEFAULT_ADMIN_ROLE` and `AUTHORIZED_CALLER_ADMIN_ROLE` have
> `getRoleAdmin == DEFAULT_ADMIN_ROLE`. **If the deployer self-revokes
> `DEFAULT_ADMIN_ROLE` first, the subsequent revoke of
> `AUTHORIZED_CALLER_ADMIN_ROLE` reverts** with
> `AccessControlUnauthorizedAccount` and the deployer remains a permanent
> phantom admin. Always revoke `DEFAULT_ADMIN_ROLE` LAST. Regression test:
> `test/deploy/RevokeOrder.t.sol`.

Canonical order (deployer signs all 6 calls):

```bash
# Grants (any order)
cast send $BOND_VAULT  "grantRole(bytes32,address)" 0x00 $MULTISIG \
  --rpc-url $BASE_MAINNET_RPC --private-key $DEPLOYER_PRIVATE_KEY
cast send $BOND_VAULT  "grantRole(bytes32,address)" $AUTH_ROLE $MULTISIG \
  --rpc-url $BASE_MAINNET_RPC --private-key $DEPLOYER_PRIVATE_KEY
cast send $LUMINA_TOKEN "grantRole(bytes32,address)" 0x00 $MULTISIG \
  --rpc-url $BASE_MAINNET_RPC --private-key $DEPLOYER_PRIVATE_KEY

# Verify multisig holds all 3 BEFORE any revoke (off-chain via cast call)

# Revokes — AUTHORIZED_CALLER_ADMIN_ROLE FIRST, DEFAULT_ADMIN_ROLE LAST on BondVault
cast send $BOND_VAULT  "revokeRole(bytes32,address)" $AUTH_ROLE $DEPLOYER \
  --rpc-url $BASE_MAINNET_RPC --private-key $DEPLOYER_PRIVATE_KEY
cast send $BOND_VAULT  "revokeRole(bytes32,address)" 0x00 $DEPLOYER \
  --rpc-url $BASE_MAINNET_RPC --private-key $DEPLOYER_PRIVATE_KEY
cast send $LUMINA_TOKEN "revokeRole(bytes32,address)" 0x00 $DEPLOYER \
  --rpc-url $BASE_MAINNET_RPC --private-key $DEPLOYER_PRIVATE_KEY
```

where `$AUTH_ROLE = cast call $BOND_VAULT "AUTHORIZED_CALLER_ADMIN_ROLE()(bytes32)"`.

**Safer alternative**: have the MULTISIG itself revoke the deployer (via a
Safe transaction). The multisig already holds `DEFAULT_ADMIN_ROLE` after the
grants, so it can revoke in any order without the ordering trap. Use this
path if any signer is uncomfortable with the manual deployer-self-revoke
sequence above.

- [ ] Verify post-handoff: deployer holds NO admin role on BondVault or LuminaTokenV2
- [ ] Verify post-handoff: multisig holds DEFAULT_ADMIN_ROLE + AUTHORIZED_CALLER_ADMIN_ROLE on BondVault, DEFAULT_ADMIN_ROLE on LuminaTokenV2

### Hour 1: Verification

```bash
# Run verification script
forge script script/VerifyLuminaV5Deployment.s.sol:VerifyLuminaV5Deployment \
  --rpc-url $ETH_RPC_URL \
  -vvv
```

- [ ] SolvencyOracle reporting correct reserves
- [ ] CoverRouter accepting test bond (minimum amount)
- [ ] TreasuryManager multisig set correctly
- [ ] BondVault receiving deposits
- [ ] LUMINA token metadata correct (name, symbol, decimals)

### Hour 2: Chainlink Automation Setup

- [ ] Register Chainlink Automation upkeep for SolvencyOracle updates
- [ ] Set check interval (recommended: 1 hour)
- [ ] Fund upkeep with sufficient LINK (minimum 10 LINK)
- [ ] Verify first automated execution triggers correctly
- [ ] Register Chainlink Automation for TWAPBurner execution
- [ ] Confirm keeper-compatible interface responds to checkUpkeep()

### Hour 3: TWAPBurner and DEX Configuration

- [ ] Configure dexRouters in TWAPBurner:
  - Uniswap V3 Router address
  - SushiSwap Router address (if applicable)
  - Slippage parameters (recommended: 50 bps max)
  - TWAP window (recommended: 30 minutes)
- [ ] Execute test buyback with minimum amount
- [ ] Verify burned tokens are sent to dead address
- [ ] Confirm event emissions are correct

### Hour 4: Adaptive Mode Activation

- [ ] Activate adaptive solvency mode on SolvencyOracle
- [ ] Set initial adaptive parameters:
  - Sensitivity: medium
  - Update frequency: hourly
  - Deviation threshold: 5%
- [ ] Verify adaptive mode responds to simulated price movements
- [ ] Confirm auto-pause thresholds are set (LUMINA < $0.005)

---

## Post-Deploy Verification (T+0 to T+1)

- [ ] All monitoring alerts are firing correctly (test alerts)
- [ ] Subgraph indexing new contracts (if applicable)
- [ ] Frontend connected and displaying correct data
- [ ] First real user bond executes successfully
- [ ] Treasury balance reflects correct initial state
- [ ] Multisig can execute transactions against new contracts

---

## T+1 to T+7: Stabilization Period

### Daily Checks

- [ ] SolvencyOracle updating on schedule
- [ ] No unexpected pauses triggered
- [ ] Chainlink Automation executing reliably
- [ ] Gas costs within expected range
- [ ] No anomalous transactions detected

### T+3 Review

- [ ] Compile first 72-hour metrics report
- [ ] Review gas optimization opportunities
- [ ] Assess Chainlink Automation LINK consumption rate
- [ ] Confirm no smart contract warnings from monitoring tools

### T+7 Sign-Off

- [ ] All systems nominal for 7 consecutive days
- [ ] No emergency actions required
- [ ] Performance metrics within acceptable ranges
- [ ] Formal sign-off from technical lead
- [ ] Move to standard daily operations cadence

---

## Rollback Plan

### Triggers for Rollback

- Critical vulnerability discovered in deployed contracts
- SolvencyOracle reporting incorrect data persistently
- Funds at risk due to logic error
- Chainlink feed integration failure with no recovery path

### Rollback Procedure

1. **Immediate**: Call `setPaused(true)` on CoverRouter via multisig
2. **Immediate**: Call `setEmergencyPause(true)` on SolvencyOracle via multisig
3. **Within 1 hour**: Communicate pause to community with reason
4. **Assessment**: Determine if fix-forward is possible or full rollback needed
5. **If full rollback**:
   - Deploy patched contracts or revert to V4 contracts
   - Migrate any user funds if necessary
   - Update all references (frontend, subgraph, documentation)
6. **Resolution**: Post-mortem within 48 hours

### Rollback Decision Authority

- Any single multisig signer can initiate emergency pause
- Full rollback requires 2-of-3 multisig approval
- Founder has unilateral pause authority in first 7 days

---

## Contacts

| Role | Responsibility During Deploy |
|------|------------------------------|
| Deployer (Founder) | Execute scripts, verify contracts |
| Technical Advisor | Review transactions, validate parameters |
| Multisig Signer 2 | Available for emergency actions |
| Multisig Signer 3 | Available for emergency actions |

---

## Appendix: Contract Addresses (Fill Post-Deploy)

| Contract | Address | Verified |
|----------|---------|----------|
| LUMINA Token | | [ ] |
| CoverRouter | | [ ] |
| BondVault | | [ ] |
| SolvencyOracle | | [ ] |
| TreasuryManager | | [ ] |
| TWAPBurner | | [ ] |
| ProxyAdmin | | [ ] |
