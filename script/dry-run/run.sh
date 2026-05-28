#!/usr/bin/env bash
# Mainnet deploy dry-run — full Base mainnet deploy against an anvil fork.
# Reproducible, NO real broadcast, anvil dummy keys, dry-run-only artifacts.
#
# ADR-027 (post-2026-05-28 dry-run): this orchestrator is a MANDATORY runbook
# pre-flight ("T-1 day: run dry-run, exigir 6/6 verde"). Catches whole classes
# of `--broadcast`-only bugs that `forge test` cannot surface:
#  - wrapper inheritance / msg.sender drift
#  - admin role revoke ordering
#  - flag-based ownership deferral
#  - paused-gate behavior at the network boundary
#
# Usage:
#   BASE_MAINNET_RPC=https://mainnet.base.org bash script/dry-run/run.sh
#   (or rely on the default Base public RPC if BASE_MAINNET_RPC is unset)
#
# Outputs:
#   ./dry-run-out/REPORT.md   — markdown report (gas, addresses, validations)
#   ./dry-run-out/log/        — per-stage forge / cast logs
#
# Exit:
#   0 on full pass (FAIL_COUNT_TOTAL == 0)
#   non-zero if any validation fails (CI signal)
#
# IMPORTANT: never commit anything from dry-run-out/ — the addresses are
# anvil-ephemeral and have no production meaning.

set -u
export PATH="${HOME}/.foundry/bin:$PATH"

REPO=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${DRYRUN_WORK:-"$REPO/dry-run-out"}
LOG=$WORK/log
mkdir -p "$LOG"
cd "$REPO"

# ─── inputs ───────────────────────────────────────────────────────────────────
RPC_UPSTREAM=${BASE_MAINNET_RPC:-https://mainnet.base.org}
RPC=http://127.0.0.1:8545
ANVIL_PORT=8545

# Production deployer (impersonated, info only — actual broadcast is anvil[0])
PROD_DEPLOYER=${PROD_DEPLOYER:-0x130377f9dE9f0134Fa82e24273C0225fB23B9040}

# Operator-supplied values for the deploy
MULTISIG=${MULTISIG:-0xa9aE612fD97f5e33B5829d16B6408ebD8422C783}
RELAYER=${RELAYER:-0x06b1C5117591e2663bD83A66589165505f313c83}
ORACLE_KEY=${ORACLE_KEY:-0xA0963323D6FA2b721E4D5bf7001C82B460f41456}
SEQUENCER_UPTIME_FEED=${SEQUENCER_UPTIME_FEED:-0xBCF85224fc0756B9Fa45aA7892530B47e10b6433}

# anvil default #0 — `forge script --broadcast` requires a real local key;
# `--unlocked --sender X` doesn't work on top of `anvil_impersonateAccount`
# (forge errors "No Signer available"). Documented in ADR-027.
ANVIL_KEY=${ANVIL_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}
ANVIL_ADDR=${ANVIL_ADDR:-0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266}
DEPLOYER=$ANVIL_ADDR  # what the deploy actually uses; multisig stays impersonated

ETH_100=0x56BC75E2D63100000

# Operator-supplied address vars — multisig stand-ins for inert LBP/ops/founder
# (these end up as USDC custody addrs in production; for a paused-out-of-the-box
# deploy they are inert).
LBP_DEPOSIT=${LBP_DEPOSIT:-$MULTISIG}
OPS_WALLET=${OPS_WALLET:-$MULTISIG}
FOUNDER_RECIPIENT=${FOUNDER_RECIPIENT:-$MULTISIG}

# ─── helpers ──────────────────────────────────────────────────────────────────
say()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }
note() { printf '  \033[33m[note]\033[0m %s\n' "$*"; }
peek() { tail -n "$2" "$1" 2>&1 | sed 's/^/    │ /'; }

FAIL_COUNT=0

# `cast rpc` takes positional args, NOT a JSON-array string (subtle but the
# wrong form silently errors with "invalid type: string, expected u8"). See
# the ADR-027 commit history for the path that uncovered this.
anvil_rpc() {
  local m=$1; shift
  cast rpc --rpc-url $RPC "$m" "$@" 2>&1
}

extract_addr_after() {
  grep -F "$2" "$1" | grep -oE '0x[0-9a-fA-F]{40}' | head -1
}

# ─── start anvil ──────────────────────────────────────────────────────────────
say "STEP 0 — anvil --fork-url $RPC_UPSTREAM"
PIN_BLOCK=$(cast block-number --rpc-url $RPC_UPSTREAM 2>/dev/null)
note "pinning fork at block $PIN_BLOCK"

(lsof -i:$ANVIL_PORT 2>/dev/null | awk 'NR>1 {print $2}' | xargs -r kill -9) || true

anvil \
  --fork-url $RPC_UPSTREAM \
  --fork-block-number $PIN_BLOCK \
  --port $ANVIL_PORT \
  --chain-id 8453 \
  --silent \
  > "$LOG/00-anvil.log" 2>&1 &
ANVIL_PID=$!
echo $ANVIL_PID > "$WORK/anvil.pid"
note "anvil PID=$ANVIL_PID"

ready=0
for i in $(seq 1 30); do
  if cast block-number --rpc-url $RPC >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" -eq 0 ] && { bad "anvil never became ready"; exit 1; }
ok "anvil up — block=$(cast block-number --rpc-url $RPC)  chain=$(cast chain-id --rpc-url $RPC)"

# ─── impersonate + fund MULTISIG (anvil[0] is pre-funded with 10 000 ETH) ────
say "STEP 0b — impersonate + fund MULTISIG"
anvil_rpc anvil_impersonateAccount $MULTISIG > /dev/null && ok "impersonate $MULTISIG"
anvil_rpc anvil_setBalance $MULTISIG $ETH_100 > /dev/null && ok "fund MULTISIG 100 ETH"
ok "deployer (anvil[0]=$DEPLOYER) balance: $(cast balance $DEPLOYER --rpc-url $RPC --ether) ETH"

# ─── env vars for the deploy ─────────────────────────────────────────────────
export MULTISIG ORACLE_KEY SEQUENCER_UPTIME_FEED
export LBP_DEPOSIT OPS_WALLET FOUNDER_RECIPIENT
export RELAYER

# ─── ETAPA 1 — DeployLuminaV5Mainnet (the new wrapper does Complete + Phase C + handoff) ─
say "ETAPA 1 — DeployLuminaV5Mainnet (chained: Complete → PhaseC → final handoff)"
T1_START=$(date +%s)
forge script script/deploy/DeployLuminaV5Mainnet.s.sol:DeployLuminaV5Mainnet \
  --rpc-url $RPC \
  --private-key $ANVIL_KEY \
  --broadcast \
  --skip-simulation \
  > "$LOG/01-deploy.log" 2>&1
RC1=$?
T1_END=$(date +%s); T1_SECS=$((T1_END-T1_START))
if [ $RC1 -eq 0 ]; then
  ok "ETAPA 1 (full chain) complete in ${T1_SECS}s"
else
  bad "ETAPA 1 FAILED rc=$RC1 in ${T1_SECS}s"
  peek "$LOG/01-deploy.log" 60
fi

# Extract addresses
extract_log_addr() { extract_addr_after "$LOG/01-deploy.log" "$1"; }

LUMINA_TOKEN=$(extract_log_addr "LuminaTokenV2 (proxy):")
BOND_VAULT=$(extract_log_addr "BondVault (proxy):")
CLAIM_BOND=$(extract_log_addr "ClaimBond (proxy):")
CAPACITY_ORACLE=$(extract_log_addr "CapacityOracle (proxy):")
SOLVENCY_ORACLE=$(extract_log_addr "SolvencyOracle (proxy):")
LUMINA_ORACLE_V2=$(extract_log_addr "LuminaOracleV2:")
ADAPTIVE_FEE=$(extract_log_addr "AdaptiveFeeDistributor (proxy):")
TWAP_BURNER=$(extract_log_addr "TWAPBurner (proxy):")
POLICY_MANAGER=$(extract_log_addr "PolicyManagerV2 (proxy):")
COVER_ROUTER=$(extract_log_addr "CoverRouterV2 (proxy):")
SHIELD_KEEPER=$(extract_log_addr "ShieldKeeper (proxy):")
CEX_RESERVE=$(extract_log_addr "CEXLiquidityReserve (proxy):")
MAINTENANCE_RESERVE=$(extract_log_addr "MaintenanceReserve (proxy):")
FOUNDER_VESTING=$(extract_log_addr "FounderVesting:")
TREASURY_VESTING=$(extract_log_addr "TreasuryVesting (proxy):")
MARKETPLACE=$(extract_log_addr "LuminaBondMarketplace (proxy):")
BUYBACK_ENGINE=$(extract_log_addr "BuybackEngine (proxy):")
AERODROME_ADAPTER=$(extract_log_addr "AerodromeAdapter:")
UNISWAP_V3_ADAPTER=$(extract_log_addr "UniswapV3Adapter:")

# ─── ETAPA 2 — admin handoff (BondVault + LuminaToken roles, ADR-027 order) ──
say "ETAPA 2 — admin handoff (ADR-027 revoke order)"
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
AUTHORIZED_CALLER_ADMIN_ROLE=$(cast call "$BOND_VAULT" "AUTHORIZED_CALLER_ADMIN_ROLE()(bytes32)" --rpc-url $RPC 2>/dev/null)

# Grants (any order)
cast send "$BOND_VAULT"  "grantRole(bytes32,address)" $DEFAULT_ADMIN_ROLE $MULTISIG \
  --rpc-url $RPC --private-key $ANVIL_KEY >> "$LOG/02-handoff.log" 2>&1
cast send "$BOND_VAULT"  "grantRole(bytes32,address)" $AUTHORIZED_CALLER_ADMIN_ROLE $MULTISIG \
  --rpc-url $RPC --private-key $ANVIL_KEY >> "$LOG/02-handoff.log" 2>&1
cast send "$LUMINA_TOKEN" "grantRole(bytes32,address)" $DEFAULT_ADMIN_ROLE $MULTISIG \
  --rpc-url $RPC --private-key $ANVIL_KEY >> "$LOG/02-handoff.log" 2>&1

# Verify multisig holds all 3 before revoking anything
ms_bv_da=$(cast call "$BOND_VAULT"  "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN_ROLE $MULTISIG --rpc-url $RPC 2>/dev/null)
ms_bv_au=$(cast call "$BOND_VAULT"  "hasRole(bytes32,address)(bool)" $AUTHORIZED_CALLER_ADMIN_ROLE $MULTISIG --rpc-url $RPC 2>/dev/null)
ms_lt_da=$(cast call "$LUMINA_TOKEN" "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN_ROLE $MULTISIG --rpc-url $RPC 2>/dev/null)
if [ "$ms_bv_da" = "true" ] && [ "$ms_bv_au" = "true" ] && [ "$ms_lt_da" = "true" ]; then
  ok "multisig holds all 3 admin roles"
  # Revokes per ADR-027: AUTHORIZED first, DEFAULT_ADMIN_ROLE LAST on BondVault.
  cast send "$BOND_VAULT"  "revokeRole(bytes32,address)" $AUTHORIZED_CALLER_ADMIN_ROLE $DEPLOYER \
    --rpc-url $RPC --private-key $ANVIL_KEY >> "$LOG/02-handoff.log" 2>&1
  cast send "$BOND_VAULT"  "revokeRole(bytes32,address)" $DEFAULT_ADMIN_ROLE $DEPLOYER \
    --rpc-url $RPC --private-key $ANVIL_KEY >> "$LOG/02-handoff.log" 2>&1
  cast send "$LUMINA_TOKEN" "revokeRole(bytes32,address)" $DEFAULT_ADMIN_ROLE $DEPLOYER \
    --rpc-url $RPC --private-key $ANVIL_KEY >> "$LOG/02-handoff.log" 2>&1
  d_bv_da=$(cast call "$BOND_VAULT"  "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN_ROLE $DEPLOYER --rpc-url $RPC 2>/dev/null)
  d_bv_au=$(cast call "$BOND_VAULT"  "hasRole(bytes32,address)(bool)" $AUTHORIZED_CALLER_ADMIN_ROLE $DEPLOYER --rpc-url $RPC 2>/dev/null)
  d_lt_da=$(cast call "$LUMINA_TOKEN" "hasRole(bytes32,address)(bool)" $DEFAULT_ADMIN_ROLE $DEPLOYER --rpc-url $RPC 2>/dev/null)
  if [ "$d_bv_da" = "false" ] && [ "$d_bv_au" = "false" ] && [ "$d_lt_da" = "false" ]; then
    ok "deployer roles revoked — clean handoff"
  else
    bad "deployer still holds at least one admin role (phantom): bv_da=$d_bv_da bv_au=$d_bv_au lt_da=$d_lt_da"
  fi
else
  bad "multisig grant FAILED: bv_da=$ms_bv_da bv_au=$ms_bv_au lt_da=$ms_lt_da"
fi

# ─── ETAPA 3 — PreFlightCheckBootstrap ───────────────────────────────────────
say "ETAPA 3 — PreFlightCheckBootstrap"
export LUMINA_TOKEN BOND_VAULT CAPACITY_ORACLE COVER_ROUTER
export GNOSIS_SAFE="$MULTISIG"
export DEPLOYER

forge script script/PreFlightCheckBootstrap.s.sol:PreFlightCheckBootstrap \
  --rpc-url $RPC \
  > "$LOG/03-preflight.log" 2>&1
RC3=$?
if [ $RC3 -eq 0 ] && grep -q "BOOTSTRAP PRE-FLIGHT PASSED" "$LOG/03-preflight.log"; then
  ok "PreFlightCheckBootstrap PASSED"
else
  bad "PreFlightCheckBootstrap rc=$RC3"
  peek "$LOG/03-preflight.log" 30
fi

# ─── VALIDACIONES POST-DEPLOY ────────────────────────────────────────────────
say "VALIDATION — post-deploy state"

declare -A CONTRACTS=(
  [LuminaTokenV2]=$LUMINA_TOKEN
  [BondVault]=$BOND_VAULT
  [ClaimBond]=$CLAIM_BOND
  [CapacityOracle]=$CAPACITY_ORACLE
  [SolvencyOracle]=$SOLVENCY_ORACLE
  [LuminaOracleV2]=$LUMINA_ORACLE_V2
  [AdaptiveFeeDistributor]=$ADAPTIVE_FEE
  [TWAPBurner]=$TWAP_BURNER
  [PolicyManagerV2]=$POLICY_MANAGER
  [CoverRouterV2]=$COVER_ROUTER
  [ShieldKeeper]=$SHIELD_KEEPER
  [CEXLiquidityReserve]=$CEX_RESERVE
  [MaintenanceReserve]=$MAINTENANCE_RESERVE
  [FounderVesting]=$FOUNDER_VESTING
  [TreasuryVesting]=$TREASURY_VESTING
  [LuminaBondMarketplace]=$MARKETPLACE
  [BuybackEngine]=$BUYBACK_ENGINE
  [AerodromeAdapter]=$AERODROME_ADAPTER
  [UniswapV3Adapter]=$UNISWAP_V3_ADAPTER
)
code_ok=0
for name in "${!CONTRACTS[@]}"; do
  addr=${CONTRACTS[$name]}
  [ -z "$addr" ] && { bad "$name address NOT extracted from deploy log"; continue; }
  size=$(cast codesize "$addr" --rpc-url $RPC 2>/dev/null)
  if [ -n "$size" ] && [ "$size" -gt 0 ]; then code_ok=$((code_ok+1)); else bad "$name @ $addr has NO code"; fi
done
ok "code() != 0 for $code_ok/19 core contracts"

declare -A OWNABLES=(
  [TWAPBurner]=$TWAP_BURNER
  [CoverRouterV2]=$COVER_ROUTER
  [PolicyManagerV2]=$POLICY_MANAGER
  [CapacityOracle]=$CAPACITY_ORACLE
  [FounderVesting]=$FOUNDER_VESTING
  [TreasuryVesting]=$TREASURY_VESTING
  [ClaimBond]=$CLAIM_BOND
  [LuminaOracleV2]=$LUMINA_ORACLE_V2
  [AerodromeAdapter]=$AERODROME_ADAPTER
  [UniswapV3Adapter]=$UNISWAP_V3_ADAPTER
  [ShieldKeeper]=$SHIELD_KEEPER
)
owner_ok=0
for name in "${!OWNABLES[@]}"; do
  addr=${OWNABLES[$name]}
  [ -z "$addr" ] && continue
  o=$(cast call "$addr" "owner()(address)" --rpc-url $RPC 2>/dev/null)
  if [ "$(echo $o | tr 'A-F' 'a-f')" = "$(echo $MULTISIG | tr 'A-F' 'a-f')" ]; then
    owner_ok=$((owner_ok+1))
  else
    bad "$name owner=$o (expected $MULTISIG)"
  fi
done
ok "owner==MULTISIG for $owner_ok / 11 Ownable contracts"

PRODUCT_IDS=(
  $(cast keccak "FLASHBTC1H-001")
  $(cast keccak "FLASHBTC24-001")
  $(cast keccak "FLASHBTC48-001")
  $(cast keccak "FLASHETH1H-001")
  $(cast keccak "FLASHETH24-001")
  $(cast keccak "FLASHETH48-001")
)
LABELS=(FLASHBTC1H-001 FLASHBTC24-001 FLASHBTC48-001 FLASHETH1H-001 FLASHETH24-001 FLASHETH48-001)
prod_ok=0
for i in 0 1 2 3 4 5; do
  pid=${PRODUCT_IDS[$i]}
  shield=$(cast call "$POLICY_MANAGER" "productShield(bytes32)(address)" "$pid" --rpc-url $RPC 2>/dev/null)
  if [ -n "$shield" ] && [ "$shield" != "0x0000000000000000000000000000000000000000" ]; then
    prod_ok=$((prod_ok+1))
  else
    bad "${LABELS[$i]} NOT registered on PolicyManager (shield=$shield)"
  fi
done
ok "$prod_ok/6 products registered"

p=$(cast call "$COVER_ROUTER" "paused()(bool)" --rpc-url $RPC 2>/dev/null)
[ "$p" = "true" ] && ok "coverRouter.paused() == true" || bad "coverRouter.paused() = $p"

pool=$(cast call "$CAPACITY_ORACLE" "pool()(address)" --rpc-url $RPC 2>/dev/null)
[ "$pool" = "0x0000000000000000000000000000000000000000" ] \
  && ok "capacityOracle.pool() == 0 (bootstrap)" \
  || bad "capacityOracle.pool() = $pool (expected 0)"

# ─── INTEGRATION — purchase while paused MUST revert ContractPaused ──────────
say "INTEGRATION — purchase while paused (expect revert ContractPaused)"
BUYER=0x0000000000000000000000000000000000005555
anvil_rpc anvil_impersonateAccount $BUYER > /dev/null
anvil_rpc anvil_setBalance $BUYER $ETH_100 > /dev/null

PID=$(cast keccak "FLASHBTC1H-001")
ASSET=$(cast keccak "USDC")
cast call "$COVER_ROUTER" "purchasePolicy(bytes32,uint256,bytes32)" "$PID" 1000000000 "$ASSET" \
  --rpc-url $RPC --from $BUYER \
  > "$LOG/05-purchase.log" 2>&1
RC5=$?
if grep -q "ContractPaused\|0x84a1edb0\|reverted\|revert" "$LOG/05-purchase.log"; then
  ok "purchase reverted (expected) — paused gate works"
else
  bad "purchase did NOT revert as expected (rc=$RC5)"
  peek "$LOG/05-purchase.log" 20
fi

# ─── REPORT ──────────────────────────────────────────────────────────────────
say "REPORT"
{
  echo "# LUMINA Mainnet Dry-Run Report"
  echo "_generated $(date -u +%FT%TZ)_  fork-block=$PIN_BLOCK"
  echo ""
  echo "## Summary"
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| Steps failed | $FAIL_COUNT |"
  echo "| ETAPA 1 wall-time | ${T1_SECS}s |"
  echo "| Core contracts with code() | $code_ok / 19 |"
  echo "| Ownable contracts owner==MULTISIG | $owner_ok / 11 |"
  echo "| Products registered | $prod_ok / 6 |"
  echo "| coverRouter.paused() | $p |"
  echo "| capacityOracle.pool() | $pool |"
  echo ""
  echo "## Addresses (DRY-RUN — do NOT use in production)"
  echo "| Contract | Address |"
  echo "|---|---|"
  for name in LuminaTokenV2 BondVault ClaimBond CapacityOracle SolvencyOracle \
              LuminaOracleV2 AdaptiveFeeDistributor TWAPBurner PolicyManagerV2 \
              CoverRouterV2 ShieldKeeper CEXLiquidityReserve MaintenanceReserve \
              FounderVesting TreasuryVesting LuminaBondMarketplace BuybackEngine \
              AerodromeAdapter UniswapV3Adapter; do
    a=${CONTRACTS[$name]:-MISSING}
    echo "| $name | \`$a\` |"
  done
} > "$WORK/REPORT.md"

cat "$WORK/REPORT.md"
echo ""
echo "FAIL_COUNT_TOTAL=$FAIL_COUNT"
echo "logs: $LOG/"
echo "anvil PID still running ($(cat $WORK/anvil.pid)). kill with: kill $(cat $WORK/anvil.pid)"

exit $FAIL_COUNT
