# Lumina Protocol Subgraph

The Graph subgraph for indexing Lumina Protocol events on Base mainnet (chain 8453).

## Indexed Contracts

| Contract | Address | Events |
|----------|---------|--------|
| CoverRouter | `0xd5f8678A...` | PolicyPurchased, PayoutTriggered, PolicyCleanedUp |
| PolicyManager | `0xCCA07e06...` | AllocationRecorded, AllocationReleased, ProductFreezeChanged |
| EmergencyPause | `0xc7ac8c19...` | ProtocolPaused, ProtocolUnpaused |
| VolatileShort | `0xbd445475...` | Deposited, WithdrawalCompleted, WithdrawalRequested |
| VolatileLong | `0xFee5d6DA...` | Deposited, WithdrawalCompleted, WithdrawalRequested |
| StableShort | `0x429b6d7d...` | Deposited, WithdrawalCompleted, WithdrawalRequested |
| StableLong | `0x1778240E...` | Deposited, WithdrawalCompleted, WithdrawalRequested |

## Entities

- **Policy** — Insurance policies (linked to Shield)
- **Vault** — Vault aggregate stats (total deposits/withdrawals)
- **Shield** — Product shields (total policies)
- **Deposit** — Individual LP deposits
- **Withdrawal** — Individual LP withdrawals
- **CooldownRequest** — Pending withdrawal cooldowns
- **Claim** — Payout claims
- **ProtocolEvent** — Emergency pause, product freeze events

## Deploy

```bash
# Install dependencies
cd subgraph
npm install

# Generate types from schema + ABIs
npm run codegen

# Build
npm run build

# Deploy to The Graph Studio
npm run deploy:studio
```

## Prerequisites

- Node.js 18+
- [Graph CLI](https://thegraph.com/docs/en/developing/creating-a-subgraph/)
- The Graph Studio account with a subgraph created for Base network
