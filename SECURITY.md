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
| `LuminaTokenV2` (`src/token/LuminaTokenV2.sol`) | ERC-20, 100M fixed supply, deflationary via TWAPBurner | `0x17db45491561F7538e4E14449DCC34799758465D` |
| `ClaimBond` (`src/bonds/ClaimBond.sol`) | ERC-1155, 1 token = $1, 730-day maturity, epoch-fungible | `0x5304f6732a51995651f1B666525CFeC5Af74A541` |
| `BondVault` (`src/bonds/BondVault.sol`) | **Single** USD-collateral vault. Issues + redeems bonds. (V4 had 4 vaults; V5.1 collapsed to 1.) | `0x1747CDA7F84BEc4f2002ff0dcdb3c51c1C02cf6A` |
| `PolicyManagerV2` (`src/core/PolicyManagerV2.sol`) | Issues policies, settles triggers, marks expirations | `0x04f94Bc24aAA87aDFA643EE1e55a35C683f30804` |
| `CoverRouterV2` (`src/core/CoverRouterV2.sol`) | User-facing: `purchasePolicy` (human direct) + `purchasePolicyFor` (relayer) + `quotePremium` | `0x60447F880Fad94fe1E17DBe9A0Cb39923bC9f316` |
| `LuminaBondMarketplace` (`src/marketplace/LuminaBondMarketplace.sol`) | Secondary market for ClaimBonds. 3% fee (1.5% each side) → 100% burn. | `0x863A7fB4A676106db4b03449b01AC5615c6C9D51` |
| `BuybackEngine` (`src/marketplace/BuybackEngine.sol`) | Marketplace fee burn path | `0x5a74f8A6A11679b12aDAE479C686880CCf8720b3` |
| `ShieldKeeper` (`src/automation/ShieldKeeper.sol`) | Permissionless trigger submission helper | `0xB5dE54F34deC8309bD8C1B8c1eF854C88D386Bca` |
| `TWAPBurner` (`src/core/TWAPBurner.sol`) | Routes 100% of premiums + marketplace fees → buy LUMINA → burn to 0xdead | `0x357BAF511383be70d1F3A5de7D3b07561Eec7d99` |
| `LuminaOracleV2` (`src/oracles/LuminaOracleV2.sol`) | EIP-712 shield price oracle. Verifies signed PriceProofs from the off-chain signer; the 9 shields call it inside `_doVerifyAndCalculate`. Replaces the launch-day `MockShieldOracle`. See [`docs/architecture/ORACLE-V2.md`](./docs/architecture/ORACLE-V2.md). | `0x8cAbC4645a3981FF59d39328f9F65FdFD19Bd194` |
| `FounderVesting` (`src/token/FounderVesting.sol`) | 8M LUMINA founder lock with 2-of-3 AltSeason conditions or 4-year fallback | (deploy-time) |

### 9 shields (parametric products)

| Shield | Trigger | Sepolia address |
|---|---|---|
| `FlashBTCShield1h` | BTC −5% / 1h | `0x77c2A7cA53ED5cbDe66cE220647d2c213133f2a9` |
| `FlashBTCShield4h` | BTC −8% / 4h | `0xb5b21f7c02C15B5D73e63538BC917825Ebcb8122` |
| `FlashBTCShield24h` | BTC −10% / 24h | `0xAc53Bf7Bb85Fcfb6d3c831F3AD9f6f79ebeeF99f` |
| `FlashBTCShield48h` | BTC −15% / 48h | `0xf2D3Fe86Ad8BB96600bB5fdF21159bb6255e95f2` |
| `FlashETHShield1h` | ETH −7% / 1h | `0xa63237a0fd57443D73F9ED36CBE15E2792D4a170` |
| `FlashETHShield24h` | ETH −12% / 24h | `0x6D6E250bc936D92F64d70262d14D6b020107Ee26` |
| `FlashETHShield48h` | ETH −18% / 48h | `0xcCbE9CCCD887D67f4bfD833c2431DD2B4e1f864D` |
| `MicroDepegShield` | USDT < $0.995 / 7d | `0x06DF0608c7256c8Df0723538574Babad1a7fd53d` |
| `RateShockShield` | Aave V3 USDC variable borrow rate > 10% APY | `0x7287E55380ee877279ef2e390e2528F772e7Da2f` |

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
