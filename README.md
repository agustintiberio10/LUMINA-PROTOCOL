# Lumina Protocol

Parametric risk speculation for humans and AI agents on Base L2.

**Status: Tier 1 Audit Ready** | **Risk Score: 9/10**

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

## Validation Status

| Check | Result |
|---|---|
| Unit tests | 168 passing |
| Adversarial audit | 41 attack scenarios |
| CertiK simulation | 22 attack vectors |
| BondVault invariants | 5/5 (250K call sequences) |
| BondVault fuzz tests | 5 × 256 runs |
| Fork tests (Base mainnet) | 5/5 passing |
| Slither static analysis | 0 HIGH, 0 MEDIUM |
| License consistency | MIT + ^0.8.20 (36/36 files) |
| UUPS storage gaps | Verified (47/49 slots) |

## Structure
- `src/` — Active V2 contracts (ClaimBond model)
- `src/v2/` — New contracts (in development)
- `api/` — REST API (Railway)
- `docs/` — Current documentation
- `archive/` — V1 vault model (preserved for transparency)

## Documentation
- [SKILL V4.1](docs/SKILL-V4.1.md) — Complete protocol specification
- [Risk Disclosures](docs/RISK-DISCLOSURES.md) — Smart contract, oracle, depletion, upgrade, liquidity, regulatory risks
- [Security Audit V4](docs/SECURITY-AUDIT-V4.md) — Full audit report with fixes applied
- [Line-by-line Audit](docs/LINE-BY-LINE-AUDIT.md) — 14 contracts, 5 auditor agents
- [Slither Findings](docs/SLITHER-FINDINGS.md) — Static analysis triage
- [Coverage Report](docs/COVERAGE.md) — Test coverage by contract

## Run tests

```bash
# Install
forge install

# Build
forge build

# Unit + adversarial + CertiK tests
forge test --no-match-contract "Fork|Invariant" -vvv

# Invariant tests (1000 runs, 50 depth)
forge test --match-contract Invariant -vvv

# Fork tests (requires Base RPC URL)
BASE_RPC_URL=xxx forge test --match-contract Fork --fork-url $BASE_RPC_URL -vvv

# Slither
pip install slither-analyzer
slither . --exclude-dependencies
```

## Chain
Base L2 (Chain ID: 8453)
