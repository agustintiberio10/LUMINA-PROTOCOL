# Lumina Protocol V2 — Smart Contracts

> Parametric insurance for autonomous AI agents on Base L2.
> Machine-to-Machine (M2M). Chainlink + Phala TEE oracles. Automatic payouts.

## Architecture

```
src/
├── interfaces/         7 interfaces (IShield, ICoverRouter, IPolicyManager, IVault, IOracle, IPhalaVerifier, IAggregatorV3)
├── core/               CoverRouter v6 (UUPS, EIP-712) + PolicyManager v3 (waterfall, ALM, TOCTOU)
├── vaults/             BaseVault (ERC-4626, Cooldown, Soulbound) + 4 child vaults
├── products/           BaseShield + 4 Shield products (BSS, Depeg, IL Index, Exploit)
├── oracles/            LuminaOracle (Chainlink + L2 Sequencer) + LuminaPhalaVerifier (TEE)
└── libraries/          PremiumMath (Kink Model) + ILMath (Babylonian sqrt) + USDYConverter
```

## Products

| Product | Risk Type | Trigger | Payout | Duration |
|---------|-----------|---------|--------|----------|
| BlackSwanShield | VOLATILE | ETH/BTC crash >30% | Binary 80% | 7-30d |
| DepegShield | STABLE | Stablecoin <$0.95 | Binary 85-90% | 14-365d |
| ILIndexCover | VOLATILE | IL >2% at expiry | Proportional (cap 11.7%) | 14-90d |
| ExploitShield | STABLE | Dual: gov -25% + receipt -30% | Binary 90% | 90-365d |

## Vaults (Cooldown Pattern)

| Vault | Cooldown | Products | Target APY |
|-------|----------|----------|------------|
| VolatileShort | 30d | BSS 7-30d, IL 14-30d | 9-11% |
| VolatileLong | 90d | IL 60-90d, BSS overflow | 12-14% |
| StableShort | 90d | Depeg 14-90d | 8-10% |
| StableLong | 365d | Depeg 365d, Exploit 90-365d | 15-22% |

## Audit Status

| Phase | Files | Lines | Audit Rounds | Result |
|-------|-------|-------|-------------|--------|
| Phase 1: Core | 16 | ~3000 | 12+ dual | 0C/0H/0M |
| Phase 2: Shields | 5 | ~1300 | 3 dual | 0C/0H/0M/0L |
| Phase 3: Oracles | 3 | ~580 | 2 dual | 0C/0H/0M/0L |

Dual audit = Claude Code + Gemini, independent findings cross-verified.

## Build

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
forge install OpenZeppelin/openzeppelin-contracts
forge install OpenZeppelin/openzeppelin-contracts-upgradeable
forge install smartcontractkit/chainlink

# Build
forge build

# Test
forge test -vvv
```

## Key Design Decisions

- **CLAIM_GRACE_PERIOD = 24h**: Agents can submit claims up to 24h after policy expiry, but oracle proof must show event occurred during coverage (`verifiedAt <= expiresAt`). Protects against L2 sequencer downtime.
- **L2 Sequencer Uptime Feed**: `getLatestPrice()` checks Chainlink Sequencer Feed with 1h grace period after restart. Prevents stale-price attacks.
- **Waterfall vault selection**: PolicyManager tries shortest-cooldown vault first, spills to longer vaults if full.
- **Soulbound shares**: Vault shares are non-transferable (prevents cooldown bypass via DEX).
- **Dual oracle**: Chainlink for prices (BSS, Depeg, IL) + Phala TEE for receipt token attestation (Exploit only).

## Chain

- **Network**: Base L2 (chain 8453)
- **Settlement**: USDY (Ondo Finance)
- **Solidity**: 0.8.20

## License

Lumina Protocol © 2026. All rights reserved.
