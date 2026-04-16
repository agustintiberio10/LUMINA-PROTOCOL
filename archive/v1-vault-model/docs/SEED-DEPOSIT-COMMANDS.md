# Lumina Vault Seed Deposit — Cast Commands

**Status:** Generated 2026-04-07 by ops audit. **NOT YET EXECUTED.**

## Background

All four production vaults currently have `totalAssets() = 0`. BCS and EAS are
correctly registered in CoverRouter, but cannot emit any policy because the
underlying `VolatileShort`/`VolatileLong` vaults have no liquidity to lock as
collateral. Quotes from `/api/v2/quote` therefore return `VAULT_EMPTY` (after
the 2026-04-07 fix). Seeding the vaults with a small amount of USDC unblocks
this.

## Vault facts (verified on-chain at block 44,410,649)

| Vault         | Address                                       | asset() | maxDepositPerUser | maxTotalDeposit | depositsPaused | paused |
|---------------|-----------------------------------------------|---------|-------------------|-----------------|----------------|--------|
| VolatileShort | `0xbd44547581b92805aAECc40EB2809352b9b2880d`  | USDC    | 100,000 USDC      | 500,000 USDC    | false          | false  |
| VolatileLong  | `0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904`  | USDC    | 100,000 USDC      | 500,000 USDC    | false          | false  |
| StableShort   | `0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC`  | USDC    | 200,000 USDC      | 1,000,000 USDC  | false          | false  |
| StableLong    | `0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c`  | USDC    | 200,000 USDC      | 1,000,000 USDC  | false          | false  |

USDC on Base mainnet: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (6 decimals)

## Deposit function

`BaseVault` exposes two entry points; both share the same `MIN_DEPOSIT = 100e6`
($100) check. Use the standard ERC-4626 `deposit(uint256,address)` for tooling
compatibility:

```solidity
function deposit(uint256 assets, address receiver) public returns (uint256 shares);
```

There is no extra parameter, no on-chain quote needed. The vault will pull
`assets` USDC from `msg.sender` (you must approve first), mint shares to
`receiver`, and immediately deposit the USDC into Aave V3 to start earning
yield. Shares are soulbound (non-transferable).

## Minimum-to-emit-one-policy math

Using `coverage / maxAllocBps` per `canAllocate`:

| Product       | Trigger | maxAllocBps | Min vault TVL for $100 coverage |
|---------------|---------|-------------|---------------------------------|
| BCS (BTCCAT)  | -50%    | 3000 (30%)  | $100 / 0.30 ≈ **$334**          |
| EAS (ETHAPOC) | -60%    | 2500 (25%)  | $100 / 0.25 = **$400**          |

Recommended seed: **$1,000 USDC per vault** — covers the minimum + leaves
room for one or two test policies, well below all caps, and is well above
the $100 `MIN_DEPOSIT` floor.

## Pre-flight checks

Before running any of the commands below, set:

```bash
export BASE_RPC_URL="https://mainnet.base.org"   # or your Alchemy/Infura URL
export AGENT_PRIVATE_KEY="0x..."                  # signer of the seed deposit
export MY_WALLET="0x..."                          # destination of the shares (receiver)
```

Verify your USDC balance:

```bash
cast call 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  "balanceOf(address)(uint256)" $MY_WALLET --rpc-url $BASE_RPC_URL
```

You need at least 1,000,000,000 (1,000 USDC in 6 decimals) per vault you plan
to seed.

## Commands

### Seed VolatileShort with $1,000 USDC

```bash
# 1) Approve VolatileShort to pull 1,000 USDC
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  "approve(address,uint256)" \
  0xbd44547581b92805aAECc40EB2809352b9b2880d \
  1000000000 \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $BASE_RPC_URL

# 2) Deposit 1,000 USDC, receiver = MY_WALLET
cast send 0xbd44547581b92805aAECc40EB2809352b9b2880d \
  "deposit(uint256,address)" \
  1000000000 \
  $MY_WALLET \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $BASE_RPC_URL
```

### Seed VolatileLong with $1,000 USDC

```bash
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  "approve(address,uint256)" \
  0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904 \
  1000000000 \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $BASE_RPC_URL

cast send 0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904 \
  "deposit(uint256,address)" \
  1000000000 \
  $MY_WALLET \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $BASE_RPC_URL
```

### Seed StableShort with $1,000 USDC

```bash
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  "approve(address,uint256)" \
  0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC \
  1000000000 \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $BASE_RPC_URL

cast send 0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC \
  "deposit(uint256,address)" \
  1000000000 \
  $MY_WALLET \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $BASE_RPC_URL
```

### Seed StableLong with $1,000 USDC

```bash
cast send 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  "approve(address,uint256)" \
  0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c \
  1000000000 \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $BASE_RPC_URL

cast send 0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c \
  "deposit(uint256,address)" \
  1000000000 \
  $MY_WALLET \
  --private-key $AGENT_PRIVATE_KEY --rpc-url $BASE_RPC_URL
```

## Verification after seeding

```bash
for v in 0xbd44547581b92805aAECc40EB2809352b9b2880d \
         0xFee5d6DAdA0A41407e9EA83d4F357DA6214Ff904 \
         0x429b6d7d6a6d8A62F616598349Ef3C251e2d54fC \
         0x1778240E1d69BEBC8c0988BF1948336AA0Ea321c; do
  echo "$v:"
  cast call $v "totalAssets()(uint256)" --rpc-url $BASE_RPC_URL
done
```

Then re-quote BCS to confirm the API moves from `VAULT_EMPTY` to a real quote:

```bash
curl -sS -X POST https://lumina-protocol-production.up.railway.app/api/v2/quote \
  -H "Content-Type: application/json" \
  -d '{"productId":"BTCCAT-001","coverageAmount":"100000000","durationSeconds":604800,"buyer":"0xYOUR_WALLET","asset":"BTC"}'
```

A successful response will include `quote.premiumAmount`, `signature`, and
`signedQuote`.

## Notes

- Seeding only `VolatileShort` (~$1,000) is enough for BCS and EAS to start
  emitting policies — both shields use VolatileShort as their primary vault.
  StableShort/StableLong are only needed once Depeg/Exploit shields are
  registered (currently blocked, see `script/safe-tx-register-depeg-il-exploit.json`).
- Shares received are soulbound. To withdraw later, call
  `requestWithdrawal(shares)` then wait for the vault's cooldown
  (37/97/97/372 days) before calling `completeWithdrawal()`.
- Performance fee (3%) is charged on positive yield only, deducted at
  withdrawal time.
