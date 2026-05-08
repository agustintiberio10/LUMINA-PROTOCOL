# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Lumina Protocol, please report it responsibly.

**Email**: security@lumina-org.com
**Response time**: acknowledgement within 24 hours; detailed response within 72 hours.

**Please do NOT**:
- Open a public GitHub issue for security vulnerabilities
- Exploit the vulnerability on mainnet
- Share details publicly before a fix is deployed

## Architecture in scope (V5.1, Base Sepolia)

V5.1 is currently deployed on **Base Sepolia testnet** (chainId 84532). Mainnet deployment is on the roadmap; addresses below will change when V5.1 lands on Base mainnet.

### Core contracts

| Contract | Role | Sepolia address |
|---|---|---|
| `LuminaTokenV2` (`src/token/LuminaTokenV2.sol`) | ERC-20, 100M fixed supply, deflationary via TWAPBurner | `0x7D3E392Bdb3258cF92C257C90391957d7b0Aff02` |
| `ClaimBond` (`src/bonds/ClaimBond.sol`) | ERC-1155, 1 token = $1, 730-day maturity, epoch-fungible | `0xde85056F155d3F18e559Fa63d5861ab3D1318cF0` |
| `BondVault` (`src/bonds/BondVault.sol`) | **Single** USD-collateral vault. Issues + redeems bonds. (V4 had 4 vaults; V5.1 collapsed to 1.) | `0x9EfdD63B13543B30B49b2b423903233220B3726c` |
| `PolicyManagerV2` (`src/core/PolicyManagerV2.sol`) | Issues policies, settles triggers, marks expirations | `0xD97bFC2959f0673851348b60DF2Eb3376eF612BE` |
| `CoverRouterV2` (`src/core/CoverRouterV2.sol`) | User-facing: `purchasePolicy` (human direct) + `purchasePolicyFor` (relayer) + `quotePremium` | `0xFA6d57CA87a26F08d68f2123e86990E2fD70B7AE` |
| `LuminaBondMarketplace` (`src/marketplace/LuminaBondMarketplace.sol`) | Secondary market for ClaimBonds. 3% fee (1.5% each side) → 100% burn. | `0xFa4Af36A4af7e6691bD1906D83a15792257d80de` |
| `BuybackEngine` (`src/marketplace/BuybackEngine.sol`) | Marketplace fee burn path | `0xC824309B1c02A2E57044b15527a53BBb8c3aAD5a` |
| `ShieldKeeper` (`src/automation/ShieldKeeper.sol`) | Permissionless trigger submission helper | `0x474C9F3819328d919f827deA3f738F71302DdbcF` |
| `TWAPBurner` (`src/core/TWAPBurner.sol`) | Routes 100% of premiums + marketplace fees → buy LUMINA → burn to 0xdead | `0xc838BEDE6BE624f6b7b69be71b7587ce51186D75` |
| `LuminaOracleV2` (`src/oracles/LuminaOracleV2.sol`) | EIP-712 shield price oracle. Verifies signed PriceProofs from the off-chain signer; the 9 shields call it inside `_doVerifyAndCalculate`. Replaces the launch-day `MockShieldOracle`. See [`docs/architecture/ORACLE-V2.md`](./docs/architecture/ORACLE-V2.md). | `0x61918822856ADFB5C4C98f4605bF9c0367ad2E0d` |
| `FounderVesting` (`src/token/FounderVesting.sol`) | 8M LUMINA founder lock with 2-of-3 AltSeason conditions or 4-year fallback | `0xa3e7685E21A141930F63432E927D679fD3FDE876` |

### 9 shields (parametric products)

| Shield | Trigger | Sepolia address |
|---|---|---|
| `FlashBTCShield1h` | BTC −5% / 1h | `0xfE0A40B31C4a8D20239345B1133d8A4495A1C788` |
| `FlashBTCShield4h` | BTC −8% / 4h | `0x1Ab1be79659098fEbA0CC8D196F2BBaD87572DA1` |
| `FlashBTCShield24h` | BTC −10% / 24h | `0x8b3Aa2dbfb6FF39C560A92dB51FD023Ca92E4f8a` |
| `FlashBTCShield48h` | BTC −15% / 48h | `0x75ee42090C40D3a2fdd84937Eeba53fdE7c1bD18` |
| `FlashETHShield1h` | ETH −7% / 1h | `0xdd4Dad66D0ADCf7C413ce39b2DfDBBDB11e11dC7` |
| `FlashETHShield24h` | ETH −12% / 24h | `0x6D232eAE5221B0C445Af30d16976d2A55C8f5A03` |
| `FlashETHShield48h` | ETH −18% / 48h | `0xBDd8937f740B12A8b1bf9f758cb264f138E2aB26` |
| `MicroDepegShield` | USDT < $0.995 / 7d | `0x62a2452A2B52C8D3AaC0CEeEb5107159A604adc4` |
| `RateShockShield` | Aave V3 USDC variable borrow rate > 10% APY | `0x0BEf02A107f374139F466828a0a8A4B9faA501Ff` |

All shields inherit from `BaseShield` (`src/products/BaseShield.sol`). Default minimum cover: $100 USDC.

## Aave V3 dependency

Lumina V5.1 uses Aave V3 in **read-only oracle mode** in exactly two places:

1. **RateShockShield** — queries `aavePool.getReserveData(USDC).currentVariableBorrowRate` as the parametric trigger condition. See `src/products/RateShockShield.sol:131-132`. Threshold: 10% APY in RAY (27 decimals). No oracle proof required — Aave rates are first-class on-chain data.

2. **FounderVesting** — Condition C of the 2-of-3 AltSeason unlock uses Aave V3 USDC borrow rate > 7% APY. See `src/token/FounderVesting.sol:48` (constant `BORROW_RATE_THRESHOLD = 7e25`) and `:198-200` (the read).

**Lumina does NOT deposit funds into Aave or generate yield from Aave**. There are no `supply()`, `borrow()`, `withdraw()`, or `aUSDC` interactions anywhere in `src/`. See [`docs/architecture/AAVE-INTEGRATION.md`](./docs/architecture/AAVE-INTEGRATION.md) for the full breakdown and migration history from V4.

## Audit history

- ✅ Internal audit pass: 40/40 invariants verified, 12 fixes applied
- ✅ PR #1 audit fix `bfa7b04` mergeado a main 2026-04-28: CHAIN-1, XSS-1, WC-1, SIM-1, DEAD-1
- ✅ Phase 4 internal audit: see [`docs/audit/PHASE4-AUDIT-REPORT.md`](./docs/audit/PHASE4-AUDIT-REPORT.md)
- ✅ Threat model: [`docs/audit/THREAT-MODEL.md`](./docs/audit/THREAT-MODEL.md)
- ⏳ **External Tier-1 audit**: NOT pursued for V5.1 testnet (founder decision May 2026). Bug bounty + multisig at T+30d post-mainnet deploy.

For the full audit + remediation history see [`docs/SECURITY-AUDIT-V5.md`](./docs/SECURITY-AUDIT-V5.md) (renamed from `SECURITY-AUDIT-V5.md` — the file's content was already V5.1).

## Bug bounty

A formal Immunefi program will launch with mainnet. Until then, responsible disclosures are rewarded based on severity:

- **Critical**: up to $50,000
- **High**: up to $10,000
- **Medium**: up to $2,000
- **Low**: case-by-case acknowledgement

Disclosure window: 30 days from acknowledgement before public write-up.

## Known issues & accepted risks

See [`docs/SECURITY-AUDIT-V5.md`](./docs/SECURITY-AUDIT-V5.md) for documented accepted risks (oracle dependency on Aave V3 + Chainlink, single-vault concentration, no Tier-1 audit pre-mainnet).

## Related docs

- [`docs/ACCESS-CONTROL-MATRIX.md`](./docs/ACCESS-CONTROL-MATRIX.md) — privileged roles
- [`docs/ANTI-FRAUD-PLAYBOOK.md`](./docs/ANTI-FRAUD-PLAYBOOK.md) — operational fraud detection
- [`docs/runbooks/INCIDENT-RESPONSE-RUNBOOK.md`](./docs/runbooks/INCIDENT-RESPONSE-RUNBOOK.md) — response playbook
- [`docs/V1-DEPRECATED-CONTRACTS.md`](./docs/V1-DEPRECATED-CONTRACTS.md) — historical legacy contracts (DO NOT USE)
