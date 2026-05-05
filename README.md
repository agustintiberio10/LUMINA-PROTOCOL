# LUMINA Protocol V5.1

Parametric insurance protocol on Base L2 for AI agents and humans.

## Status
- **V5.1**: Live on Base Sepolia testnet (this branch); mainnet launch pending
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
├── oracles/        LuminaOracleV2 (EIP-712 shield oracle), CapacityOracle, SolvencyOracle
├── products/       BaseShield + 9 shields (FlashBTC ×4 [1h/4h/24h/48h] + FlashETH ×3 [1h/24h/48h] + MicroDepeg + RateShock)
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
- [SKILL](docs/SKILL.md) — Protocol specification
- [Risk Disclosures](docs/RISK-DISCLOSURES.md)
- [Security Audit V5](docs/SECURITY-AUDIT-V5.md)
- [V1 Deprecated Contracts](docs/V1-DEPRECATED-CONTRACTS.md)

## Legacy V1
The previous version is preserved in branch `legacy/v1-archive` for historical reference. V1 contracts on Base mainnet are deprecated and will be paused after the V5.1 mainnet launch.

## Chain
- **Current** (testnet): Base Sepolia, Chain ID `84532` — V5.1 deployed and live
- **Planned** (mainnet): Base, Chain ID `8453` — pending launch
