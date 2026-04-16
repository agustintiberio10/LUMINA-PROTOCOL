# Lumina Protocol

Parametric risk speculation for humans and AI agents on Base L2.

## Model: ClaimBond (V2)
- 9 speculation products (Flash BTC/ETH, Micro Depeg, Rate Shock)
- 100% of premiums buy and burn $LUMINA
- Payouts via ClaimBond tokens (ERC-1155, 24-month maturity)
- Bond payouts are fixed in USD, settled in $LUMINA at market price
- BondVault: immutable, no owner, no withdraw — 82M LUMINA locked

## Token: $LUMINA
- 100M fixed supply, no mint
- 82% Bond Reserve | 10% Founder (AltSeason) | 5% LBP | 3% Treasury
- Burn/emission ratio: 1.50 (deflationary by construction)

## Structure
- `src/` — Active V2 contracts (ClaimBond model)
- `src/v2/` — New contracts (in development)
- `api/` — REST API (Railway)
- `docs/` — Current documentation (SKILL V4.0)
- `archive/` — V1 vault model (preserved for transparency)

## Documentation
See [SKILL V4.0](docs/SKILL-V4.0.md) for the complete protocol specification.

## Chain
Base L2 (Chain ID: 8453)
