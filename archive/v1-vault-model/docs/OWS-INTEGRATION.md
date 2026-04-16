# OWS Integration — Lumina Protocol

## What is OWS?

Open Wallet Standard (OWS) is a security layer between your AI agent and the blockchain. It ensures that your agent's private key is never exposed, and every transaction is validated by a policy engine before signing.

## Why use OWS with Lumina?

| Without OWS | With OWS |
|---|---|
| Private key in .env file | Key encrypted, decrypted only to sign |
| Agent can sign anything | Policy Engine validates every tx |
| No spending limits | Configurable daily/tx limits |
| No contract restrictions | Allowlist: only Lumina contracts |
| Key stolen = full access | Key stolen = limited by policies |

## Quick Setup

```bash
# Install OWS
curl -fsSL https://openwallet.sh/install.sh | bash

# Run Lumina agent setup
./ows/setup-lumina-agent.sh my-agent

# Add token to your agent
export OWS_TOKEN=ows_key_xxx
```

## Policies Included

1. **lumina-base-only** — Restricts signing to Base L2 (eip155:8453)
2. **lumina-agent-default** — Base only + auto-expires Jan 1, 2027
3. **lumina-full-protection** — Base only + contract allowlist + spending limit + expiry

### Contract Allowlist (lumina-contracts-allowlist.py)

Custom executable policy that only allows transactions to Lumina contracts:
- USDC token (production + test)
- CoverRouter
- PolicyManager
- 4 Vaults (VolatileShort, VolatileLong, StableShort, StableLong)
- 4 Shields (BSS, Depeg, ILIndex, Exploit)

Any transaction to an unknown address is denied.

### Spending Limit (lumina-spending-limit.py)

Custom executable policy that tracks daily spending and denies transactions that would exceed the configured limit. Default: $10,000/day.

## Architecture

```
Agent → OWS SDK → Policy Engine → Sign → Blockchain
         │              │
         │         ┌────┴────┐
         │         │ Rules:  │
         │         │ - Base  │
         │         │ - Expiry│
         │         └────┬────┘
         │              │
         │         ┌────┴─────────┐
         │         │ Executables: │
         │         │ - Allowlist  │
         │         │ - Spending   │
         │         └──────────────┘
         │
    Key decrypted ONLY if all policies pass
```

## API Integration

The Lumina API (`api/src/index.js`) integrates OWS with automatic fallback:

1. On startup: `owsSigner.initOWS()` — checks if OWS wallet exists
2. On signing: tries OWS first, falls back to ethers if OWS not available
3. Environment variables:
   - `OWS_WALLET_NAME` — wallet name (default: `lumina-relayer`)
   - `OWS_TOKEN` — API key token (`ows_key_xxx`)

Without OWS configured, the API uses `ethers.Wallet(ORACLE_PRIVATE_KEY)` as before — zero breaking changes.

## Credential Flow

```
Owner (human):
  passphrase → decrypt wallet → full access, no policies

Agent (AI):
  ows_key_xxx → resolve API key → evaluate policies → decrypt wallet → sign
```

The owner creates the wallet with a passphrase and creates API keys for agents. Each agent gets a token (`ows_key_xxx`) that provides limited, policy-gated access.

## Revoking Access

```bash
# Revoke an agent's API key (instant, no on-chain tx needed)
ows key revoke --name my-agent-key

# The agent can no longer sign. No funds at risk.
```

## Supported Chains

OWS supports EVM (Base), Solana, Bitcoin, Cosmos, Tron, TON, Sui, and more. Lumina uses EVM only (eip155:8453 = Base Mainnet).

## References

- [OWS Specification](https://github.com/open-wallet-standard/core)
- [Policy Engine Documentation](../OWS/core/docs/03-policy-engine.md)
- [Signing Interface](../OWS/core/docs/02-signing-interface.md)
- [Agent Access Layer](../OWS/core/docs/04-agent-access-layer.md)
