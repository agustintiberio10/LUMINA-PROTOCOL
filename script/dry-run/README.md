# Mainnet deploy dry-run

`script/dry-run/run.sh` — orchestrator that forks Base mainnet (anvil), runs
the full `DeployLuminaV5Mainnet` wrapper end-to-end, performs the BondVault +
LuminaToken admin handoff in the order pinned by ADR-027, and validates
every post-deploy invariant. **Required runbook step (T-1 day pre-deploy).**

## Why

The fork dry-run of 2026-05-28 surfaced three structural deploy bugs that
**`forge test` cannot catch** because they only manifest under `--broadcast`:

| Finding | What it caused |
|---|---|
| Wrapper `new Complete() + completeRunner.run()` broke `msg.sender` | Revert at STEP 8 with `"LUMINA proxy address mismatch - nonce drift"` |
| Phase C ran after PM+CR ownership transfer to multisig | `OwnableUnauthorizedAccount` on every `registerProduct` |
| BondVault revokeRole order revoked `DEFAULT_ADMIN_ROLE` first | `AccessControlUnauthorizedAccount`; phantom-admin left wedged |

All three are fixed in ADR-027 / branch `fix/post-dryrun-deploy-fixes`. This
orchestrator is the regression net.

## Usage

```bash
# Default (Base public RPC, anvil dummy keys, multisig impersonated)
bash script/dry-run/run.sh

# Custom RPC (Alchemy / Infura / private)
BASE_MAINNET_RPC=https://base-mainnet.g.alchemy.com/v2/$KEY \
  bash script/dry-run/run.sh

# CI signal — exit 0 iff every validation passes
bash script/dry-run/run.sh || echo "DRY-RUN FAILED — do NOT broadcast"
```

Outputs land in `./dry-run-out/`:
- `REPORT.md` — summary table + addresses
- `log/` — per-stage forge + cast logs

## What it validates (6 invariants)

1. 19/19 core contracts have non-zero `code()`
2. 11/11 Ownable contracts owned by MULTISIG (or deferred PM+CR
   transferred at the end of the wrapper)
3. 6/6 Phase-C products registered on PolicyManagerV2 +
   configured on CoverRouterV2
4. `coverRouter.paused() == true` (bootstrap state)
5. `capacityOracle.pool() == 0x0` (legitimate bootstrap)
6. Purchase attempt reverts with `ContractPaused`

If any of these fail, the orchestrator exits non-zero and the operator
**MUST NOT** proceed to mainnet broadcast.

## Caveats

- Uses anvil's pre-funded key #0 as the deployer signing key (`forge script
  --broadcast --unlocked --sender X` doesn't work on top of
  `anvil_impersonateAccount` — forge errors `"No Signer available"`). The
  production deploy uses the real EOA via `--private-key
  $DEPLOYER_PRIVATE_KEY`. The structural validation is unaffected; only the
  signing address differs.
- The multisig (`MULTISIG` env var, default the production Safe) is
  impersonated via `anvil_impersonateAccount` + `anvil_setBalance`. `cast send
  --unlocked --from <impersonated>` requires explicit `--gas-limit` because
  anvil's gas estimator returns 0 for impersonated callers.
- Per ADR-027 the wrapper now does Complete + Phase C + the deferred PM+CR
  handoff in a single `forge script` invocation, so ETAPA 1 in this dry-run
  is the full chain (not just Complete).

## See also

- ADR-027 — `tracking/architectural-decisions.md` (full rationale)
- Runbook — `docs/runbooks/DEPLOY-MAINNET-RUNBOOK.md` ("T-1 day" section)
- Wrapper — `script/deploy/DeployLuminaV5Mainnet.s.sol`
