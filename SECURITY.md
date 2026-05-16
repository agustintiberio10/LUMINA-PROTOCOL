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

> ⚠️ OBSOLETO — Las direcciones Sepolia citadas en las tablas siguientes fueron invalidadas
> por el bug L476-477 (multisig grant+revoke) que bricked LuminaTokenV2 0x7D3E…Aff02.
> Direcciones se reemplazarán en el redeploy post-Sprint Z.2. Tabla conservada como
> registro de la arquitectura V5.1 testnet, con address-cells blanqueadas.

V5.1 was deployed on **Base Sepolia testnet** (chainId 84532); deployment was bricked
pre-Sprint Z.2. Mainnet deployment is on the roadmap; addresses below will be repopulated
in the redeploy.

### Core contracts

| Contract | Role | Sepolia address |
|---|---|---|
| `LuminaTokenV2` (`src/token/LuminaTokenV2.sol`) | ERC-20, 100M fixed supply, deflationary via TWAPBurner | `0x0000000000000000000000000000000000000000` |
| `ClaimBond` (`src/bonds/ClaimBond.sol`) | ERC-1155, 1 token = $1, 730-day maturity, epoch-fungible | `0x0000000000000000000000000000000000000000` |
| `BondVault` (`src/bonds/BondVault.sol`) | **Single** USD-collateral vault. Issues + redeems bonds. (V4 had 4 vaults; V5.1 collapsed to 1.) | `0x0000000000000000000000000000000000000000` |
| `PolicyManagerV2` (`src/core/PolicyManagerV2.sol`) | Issues policies, settles triggers, marks expirations | `0x0000000000000000000000000000000000000000` |
| `CoverRouterV2` (`src/core/CoverRouterV2.sol`) | User-facing: `purchasePolicy` (human direct) + `purchasePolicyFor` (relayer) + `quotePremium` | `0x0000000000000000000000000000000000000000` |
| `LuminaBondMarketplace` (`src/marketplace/LuminaBondMarketplace.sol`) | Secondary market for ClaimBonds. 3% fee (1.5% each side) → 100% burn. | `0x0000000000000000000000000000000000000000` |
| `BuybackEngine` (`src/marketplace/BuybackEngine.sol`) | Marketplace fee burn path | `0x0000000000000000000000000000000000000000` |
| `ShieldKeeper` (`src/automation/ShieldKeeper.sol`) | Permissionless trigger submission helper | `0x0000000000000000000000000000000000000000` |
| `TWAPBurner` (`src/core/TWAPBurner.sol`) | Routes 100% of premiums + marketplace fees → buy LUMINA → burn to 0xdead | `0x0000000000000000000000000000000000000000` |
| `LuminaOracleV2` (`src/oracles/LuminaOracleV2.sol`) | EIP-712 shield price oracle. Verifies signed PriceProofs from the off-chain signer; the 9 shields call it inside `_doVerifyAndCalculate`. Replaces the launch-day `MockShieldOracle`. See [`docs/architecture/ORACLE-V2.md`](./docs/architecture/ORACLE-V2.md). | `0x0000000000000000000000000000000000000000` |
| `FounderVesting` (`src/token/FounderVesting.sol`) | 8M LUMINA founder lock with 2-of-3 AltSeason conditions or 4-year fallback | `0x0000000000000000000000000000000000000000` |

<!-- SPRINT_Z2 cleared (was old testnet SET B/C addresses for: LuminaTokenV2, ClaimBond, BondVault, PolicyManagerV2, CoverRouterV2, LuminaBondMarketplace, TWAPBurner, LuminaOracleV2, FounderVesting). SPRINT_Z2 B.1 sweep additionally blanked: BuybackEngine (was 0xC824309B1c02A2E57044b15527a53BBb8c3aAD5a), ShieldKeeper (was 0x474C9F3819328d919f827deA3f738F71302DdbcF), and all 9 shield addresses (FlashBTCShield1h/4h/24h/48h, FlashETHShield1h/24h/48h, MicroDepegShield, RateShockShield) — see the 9-shields table below. -->


### 9 shields (parametric products)

| Shield | Trigger | Sepolia address |
|---|---|---|
| `FlashBTCShield1h` | BTC −5% / 1h | `0x0000000000000000000000000000000000000000` |
| `FlashBTCShield4h` | BTC −8% / 4h | `0x0000000000000000000000000000000000000000` |
| `FlashBTCShield24h` | BTC −10% / 24h | `0x0000000000000000000000000000000000000000` |
| `FlashBTCShield48h` | BTC −15% / 48h | `0x0000000000000000000000000000000000000000` |
| `FlashETHShield1h` | ETH −7% / 1h | `0x0000000000000000000000000000000000000000` |
| `FlashETHShield24h` | ETH −12% / 24h | `0x0000000000000000000000000000000000000000` |
| `FlashETHShield48h` | ETH −18% / 48h | `0x0000000000000000000000000000000000000000` |
| `MicroDepegShield` | USDT < $0.995 / 7d | `0x0000000000000000000000000000000000000000` |
| `RateShockShield` | Aave V3 USDC variable borrow rate > 10% APY | `0x0000000000000000000000000000000000000000` |

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
