# LUMINA Protocol V5.0

Parametric insurance protocol on Base L2 for AI agents and humans.

## Status
- **V5.0**: In active development (this branch)
- **V1**: Deprecated, archived in branch `legacy/v1-archive`

## Architecture

16 contracts on the ClaimBond model: bond-based payouts (ERC-1155), 100% premium burn, immutable BondVault.

## Products (9 shields)
- Flash BTC 1h (333x), 4h (190x), 24h (44x), 48h (83x)
- Flash ETH 1h (266x), 24h (33x), 48h (74x)
- Micro Depeg USDT (19x)
- Rate Shock (17x)

## Token Distribution (100M LUMINA)
- 70% BondVault (immutable)
- 14% CEX/DEX Liquidity Reserve (multisig 2-of-3)
- 8% Founder (FounderVesting / AltSeason 2-of-3 mechanism)
- 5% LBP (Fjord Foundry)
- 3% Treasury

## Structure
```
src/
├── core/           CoverRouterV2, PolicyManagerV2, TWAPBurner
├── token/          LuminaTokenV2, FounderVesting, TreasuryVesting
├── bonds/          BondVault, ClaimBond
├── oracles/        CapacityOracle
├── products/       BaseShield + 5 shields (1h/4h BTC, 1h ETH, MicroDepeg, RateShock)
├── interfaces/     IShield, IOracle, IOracleV2
├── treasury/       (CEXLiquidityReserve — planned)
└── governance/     (planned)
```

## Development

```bash
forge install
forge build
forge test
```

## Documentation
- [SKILL V4.1](docs/SKILL.md) — Protocol specification
- [Risk Disclosures](docs/RISK-DISCLOSURES.md)
- [Security Audit V4](docs/SECURITY-AUDIT-V5.md)
- [V1 Deprecated Contracts](docs/V1-DEPRECATED-CONTRACTS.md)

## Legacy V1
The previous version is preserved in branch `legacy/v1-archive` for historical reference. V1 contracts on Base mainnet are deprecated and will be paused after V5.0 launch.

## Chain
Base L2 (Chain ID: 8453)
