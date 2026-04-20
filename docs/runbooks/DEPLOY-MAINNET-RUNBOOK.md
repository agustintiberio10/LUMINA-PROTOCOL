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

---

## Deploy Day (T+0)

### Hour 0: Deploy Initiation

```bash
# Set environment
export DEPLOYER_PRIVATE_KEY=<secure-key>
export ETH_RPC_URL=<mainnet-rpc>
export ETHERSCAN_API_KEY=<key>

# Execute deployment
forge script script/DeployLuminaV5Complete.s.sol:DeployLuminaV5Complete \
  --rpc-url $ETH_RPC_URL \
  --broadcast \
  --verify \
  --slow \
  -vvv
```

- [ ] Record all deployed contract addresses immediately
- [ ] Verify each contract on Etherscan
- [ ] Confirm proxy admin ownership set correctly

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
