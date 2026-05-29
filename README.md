# LUMINA Protocol V5.4

Parametric insurance protocol on Base L2 for AI agents and humans.

## Status
- **V5.4**: 🟢 LIVE on Base mainnet (chainId 8453) since 2026-05-28. Currently in **BOOTSTRAP state** — `CoverRouterV2.paused() == true` until the LBP completes (2026-05-30 → 2026-06-03). After the LBP seeds the LUMINA/USDC Uniswap V3 pool and the multisig calls `capacityOracle.setPool(realPool)` + `coverRouter.setPaused(false)`, policy purchases open.
- **V1**: Deprecated, archived in branch `legacy/v1-archive`.

## Deployed contracts (Base mainnet, 8453)

Live addresses are published at [docs.lumina-org.com/contracts/deployed](https://docs.lumina-org.com/contracts/deployed). The protocol's `lumina-api` exposes them dynamically at `GET /health` (the single source of truth — never hardcode in integrations).

Quick reference for the user-facing six:

| Contract | Address |
|---|---|
| LuminaTokenV2 | `0xa35766202444d1d3D6d09Cf687B29D3C2632223C` |
| BondVault | `0x1C50d05eEF138aAa9df22a001db4a75343a604E4` |
| ClaimBond | `0x8203435Bc108FaBE1beB1fe40F66a7C8B42529F1` |
| PolicyManagerV2 | `0x8c20dfE07a5679b8DE8376361Bc9f63eD081C268` |
| CoverRouterV2 | `0x7A49B31DC3540E037cdCEb95765eD46f6a515aa2` |
| LuminaBondMarketplace | `0xfB3ec1B507DE8a7dB50691a26f872360F0EF71AB` |
| USDC (Circle, mainnet) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Multisig (Gnosis Safe, admin of all UUPS proxies): `0xa9aE612fD97f5e33B5829d16B6408ebD8422C783`.

## Architecture

19 core contracts + 6 Phase C adapter proxies on the ClaimBond model: bond-based payouts (ERC-1155), 85% premium burn through AdaptiveFeeDistributor, BondVault throttle (1.08%/week + FIFO queue), UUPS upgradeable.

## Products (6 active flash shields)
- Flash BTC 1h, 24h, 48h
- Flash ETH 1h, 24h, 48h

Retired in V5.3/V5.4: Flash BTC 4h, Micro Depeg USDT, Rate Shock.

## Token Distribution (100M LUMINA)
- 70% BondVault (immutable)
- 14% CEX/DEX Liquidity Reserve (multisig 2-of-3)
- 8% Founder (FounderVesting / AltSeason 2-of-3 mechanism)
- 5% LBP (Fjord Foundry)
- 3% Treasury

## Structure
```
src/
├── core/           CoverRouterV2, PolicyManagerV2, TWAPBurner, AdaptiveFeeDistributor
├── token/          LuminaTokenV2, FounderVesting, TreasuryVesting
├── bonds/          BondVault, ClaimBond
├── oracles/        LuminaOracleV2 (EIP-712 shield oracle), CapacityOracle, SolvencyOracle
├── products/       BaseFlashShield + 6 shields (FlashBTC 1h/24h/48h + FlashETH 1h/24h/48h)
├── interfaces/     IShield, IOracle, IOracleV2
├── treasury/       CEXLiquidityReserve, MaintenanceReserve
└── marketplace/    LuminaBondMarketplace, BuybackEngine
```

## Development

```bash
forge install
forge build
forge test
```

For mainnet deploy rehearsal, see `script/dry-run/run.sh` (ADR-027 — mandatory T-1-day pre-flight against a Base mainnet fork).

## RPC Configuration (Sprint F — multi-provider redundancy)

`foundry.toml` exposes RPC aliases for both Base mainnet (production) and Base Sepolia (fork rehearsals + sandbox). Use any with `forge script` / `cast` via `--rpc-url <alias>`:

| Alias | Source | Notes |
|---|---|---|
| `base_mainnet` | `BASE_MAINNET_RPC` env (Alchemy) | **Default for production**. Highest rate limits. |
| `base_mainnet_public` | `https://mainnet.base.org` (no key) | Last-resort failover |
| `base_sepolia` | `BASE_SEPOLIA_RPC` env (Alchemy) | Fork rehearsals + sandbox testing |
| `base_sepolia_public` | `https://sepolia.base.org` | Sepolia failover |

Setup once at User scope (PowerShell):
```powershell
[Environment]::SetEnvironmentVariable("BASE_MAINNET_RPC", "https://base-mainnet.g.alchemy.com/v2/<KEY>", "User")
[Environment]::SetEnvironmentVariable("BASE_SEPOLIA_RPC", "https://base-sepolia.g.alchemy.com/v2/<KEY>", "User")
```

In CI / deploy scripts, always pass the alias rather than the raw URL — that lets ops swap provider without code changes.

**Off-chain redundancy** (FallbackProvider in `lumina-api`, wagmi `fallback` in landing) is configured in those repos; the protocol-side change here is just the alias surface.

## Documentation
- [SKILL](docs/SKILL.md) — Protocol specification
- [Risk Disclosures](docs/RISK-DISCLOSURES.md)
- [Security Audit V5](docs/SECURITY-AUDIT-V5.md)
- [V1 Deprecated Contracts](docs/V1-DEPRECATED-CONTRACTS.md)
- [Mainnet runbook](docs/runbooks/DEPLOY-MAINNET-RUNBOOK.md)
- [ADR-027 — post-dry-run deploy fixes](tracking/architectural-decisions.md)
- Live state docs (integrator-facing): [docs.lumina-org.com](https://docs.lumina-org.com)

## Chain
- 🟢 **LIVE** (mainnet): Base, Chain ID `8453` — V5.4 deployed 2026-05-28, BOOTSTRAP-paused pre-LBP
- ⚙️ **Sandbox** (testnet): Base Sepolia, Chain ID `84532` — wallet-less integration testing via `/sandbox/*` on lumina-api

## Legacy V1
The previous version is preserved in branch `legacy/v1-archive` for historical reference.
