# LUMINA Tokenomics — V5.1

Canonical reference for the $LUMINA token economy. Every numeric claim
below cites the exact `file:line` of the V5.1 contract source on this
branch (`main`). If a source file disagrees with this document, the
source wins — open a PR to fix the doc.

---

## 1. Token Overview

| Property | Value | Source |
|---|---|---|
| Name | `Lumina Protocol` | [`src/token/LuminaTokenV2.sol:46`](../src/token/LuminaTokenV2.sol#L46) |
| Symbol | `LUMINA` | [`src/token/LuminaTokenV2.sol:46`](../src/token/LuminaTokenV2.sol#L46) |
| Decimals | 18 (default OZ ERC20) | OpenZeppelin `ERC20Upgradeable` |
| Standard | ERC-20 + ERC-20Burnable + UUPS proxy | [`src/token/LuminaTokenV2.sol:25-30`](../src/token/LuminaTokenV2.sol#L25-L30) |
| Max supply | `100_000_000 * 1e18` (100M, fixed) | [`src/token/LuminaTokenV2.sol:31`](../src/token/LuminaTokenV2.sol#L31) |
| Mint function | None — supply only decreases | [`src/token/LuminaTokenV2.sol`](../src/token/LuminaTokenV2.sol) |
| Burn role | `BURNER_ROLE` granted to TWAPBurner | [`src/token/LuminaTokenV2.sol:32`](../src/token/LuminaTokenV2.sol#L32), [`:91-94`](../src/token/LuminaTokenV2.sol#L91-L94) |

The constructor enforces `assert(totalSupply() == MAX_SUPPLY)` after
all mints — see [`LuminaTokenV2.sol:77`](../src/token/LuminaTokenV2.sol#L77).
A `totalBurned()` view returns `MAX_SUPPLY - totalSupply()` — see
[`:84`](../src/token/LuminaTokenV2.sol#L84).

---

## 2. Initial Distribution

100M LUMINA are minted exactly once in `initialize()` and split across
five immutable address arguments. Source:
[`src/token/LuminaTokenV2.sol:71-75`](../src/token/LuminaTokenV2.sol#L71-L75).

| Allocation | Tokens | % | Recipient | Behaviour |
|---|---|---|---|---|
| Bond Reserve | 70,000,000 | 70% | `bondVault` | Locked in BondVault; only leaves via `redeemBond()` at maturity ([`BondVault.sol:198`](../src/bonds/BondVault.sol#L198)) |
| CEX/DEX Liquidity | 14,000,000 | 14% | `cexLiquidityReserve` | Earmarked for centralized + decentralized exchange listings at launch |
| Founder | 8,000,000 | 8% | `founderVesting` | Locked behind AltSeason 2-of-3 oracle gates — see §6 |
| LBP | 5,000,000 | 5% | `lbpDeposit` | Liquidity Bootstrapping Pool (Fjord Foundry) at TGE |
| Treasury | 3,000,000 | 3% | `treasuryVesting` | 6-month lock, then 250k/month drip — see §7 |
| **Total** | **100,000,000** | **100%** | | |

Constructor guards (zero-address + pairwise duplicate checks) live at
[`src/token/LuminaTokenV2.sol:53-69`](../src/token/LuminaTokenV2.sol#L53-L69).

---

## 3. Burn Mechanics — TWAPBurner

The TWAPBurner is the **only** mechanism that reduces supply. It
receives USDC from premiums (`CoverRouterV2`) and from secondary
marketplace fees (`LuminaBondMarketplace`), buys $LUMINA on multi-DEX
routes (Uniswap V3 + Aerodrome), and burns the proceeds.

Source: [`src/core/TWAPBurner.sol`](../src/core/TWAPBurner.sol).

### 3.1 Default distribution (fallback, when adaptive mode is off)

USDC arriving at the burner is split four ways. Source:
[`src/core/TWAPBurner.sol:61-64`](../src/core/TWAPBurner.sol#L61-L64).

| Bucket | BPS | % | Constant |
|---|---|---|---|
| Burn (USDC → buy LUMINA → burn) | 8500 | **85%** | `FALLBACK_BURN_BPS` |
| Buyback Reserve | 800 | **8%** | `FALLBACK_BUYBACK_BPS` |
| Maintenance Reserve | 500 | **5%** | `FALLBACK_MAINTENANCE_BPS` |
| Ops Reserve | 200 | **2%** | `FALLBACK_OPS_BPS` |
| **Total** | **10000** | **100%** | |

### 3.2 Adaptive distribution

When `adaptiveModeEnabled == true`, the four ratios come from
[`AdaptiveFeeDistributor.getDistribution()`](../src/core/AdaptiveFeeDistributor.sol)
instead. The burner falls back to the fixed ratios above whenever the
distributor reports `isHealthy() == false`.

### 3.3 Execution

`executeBurn()` (callable by authorized senders, see
[`:140`](../src/core/TWAPBurner.sol#L140)) performs the swap and burn
atomically. Each successful burn emits:

```solidity
event BurnExecuted(
    uint256 usdcSpent,
    uint256 luminaBurned,
    uint256 effectivePrice,
    uint256 timestamp
);
```
Defined at [`src/core/TWAPBurner.sol:75`](../src/core/TWAPBurner.sol#L75).
This event is what the frontend `BurnEngine` reads via
`watchContractEvent` to render the live burned counter.

---

## 4. Premium Math

Premiums are computed and charged in `CoverRouterV2.purchasePolicy()`.
The full formula and rounding rule live at
[`src/core/CoverRouterV2.sol:200-203`](../src/core/CoverRouterV2.sol#L200-L203):

```solidity
// Calculate premium: coverage × payoutRatio × triggerProb × margin / (10000^3)
uint256 premium = (coverageAmount * config.payoutRatioBps
                  * config.triggerProbBps * config.marginBps)
                  / (10000 * 10000 * 10000);
if (premium == 0) premium = 1; // minimum 1 unit USDC ($0.000001)
```

| Term | Description |
|---|---|
| `coverageAmount` | Cover face value in USDC (6 decimals) |
| `payoutRatioBps` | What share of cover pays out on trigger (per shield) |
| `triggerProbBps` | Modeled probability the parametric event fires |
| `marginBps` | Protocol margin / risk loading |

The premium USDC is pulled from the buyer at
[`:210`](../src/core/CoverRouterV2.sol#L210) and routed to the
TWAPBurner — **100% of premiums go to the burn engine**, as stated in
the contract NatSpec at
[`src/core/CoverRouterV2.sol:14`](../src/core/CoverRouterV2.sol#L14).

Edge cases are catalogued in the audit chapter
[`docs/audit/v5.1-uups/05-math-edge-cases/REPORT.md`](audit/v5.1-uups/05-math-edge-cases/REPORT.md).

---

## 5. Bond Economics

### 5.1 ClaimBond (ERC-1155)

Source: [`src/bonds/ClaimBond.sol`](../src/bonds/ClaimBond.sol).

| Property | Value | Source |
|---|---|---|
| Token standard | ERC-1155, grouped by monthly maturity epoch | [`ClaimBond.sol:14`](../src/bonds/ClaimBond.sol#L14) |
| Face value | **1 token = $1 USD at maturity** (integer dollars) | [`ClaimBond.sol:15`](../src/bonds/ClaimBond.sol#L15) |
| Vesting | 100% at maturity — no linear vesting, no partial unlock | [`ClaimBond.sol:19`](../src/bonds/ClaimBond.sol#L19) |
| Maturity check | `block.timestamp >= maturityDate[epochId]` | [`ClaimBond.sol:132`](../src/bonds/ClaimBond.sol#L132) |

> **Integration note for builders**: `balanceOf(holder, epochId)` returns
> the integer count of `$1` claims for that holder in that epoch. It is
> **not** denominated in 6-decimal USDC. Treating it as USDC will
> overestimate by 1,000,000×.

### 5.2 BondVault

Source: [`src/bonds/BondVault.sol`](../src/bonds/BondVault.sol).

| Property | Value | Source |
|---|---|---|
| Holds | 70M LUMINA reserve backing every claim | [`LuminaTokenV2.sol:71`](../src/token/LuminaTokenV2.sol#L71) |
| Bond maturity | `BOND_MATURITY_SECONDS = 730 days` (24 months) | [`BondVault.sol:54`](../src/bonds/BondVault.sol#L54) |
| Issue path | New bonds get an `epochId` derived from `block.timestamp + 730 days` | [`BondVault.sol:183-184`](../src/bonds/BondVault.sol#L183-L184) |
| Redeem path | `redeemBond(uint256 epochId, uint256 usdAmount)` — holder-called, post-maturity, `nonReentrant` | [`BondVault.sol:198`](../src/bonds/BondVault.sol#L198) |

A solvency floor (~125% of outstanding claims) is enforced by
`SolvencyOracle` and consumed by `burnFromReserves` to block burns that
would compromise solvency.

---

## 6. Founder Vesting

Source: [`src/token/FounderVesting.sol`](../src/token/FounderVesting.sol).

| Constant | Value | Source |
|---|---|---|
| `TOTAL_AMOUNT` | 8,000,000 LUMINA | [`FounderVesting.sol:50`](../src/token/FounderVesting.sol#L50) |
| `TOTAL_TRANCHES` | 3 | [`:48`](../src/token/FounderVesting.sol#L48) |
| `TRANCHE_AMOUNT` | `TOTAL_AMOUNT / 3` ≈ 3.333M | [`:51`](../src/token/FounderVesting.sol#L51) |
| `TRANCHE_INTERVAL` | 31 days | [`:47`](../src/token/FounderVesting.sol#L47) |
| `SUSTAINED_DURATION` | 7 days | [`:46`](../src/token/FounderVesting.sol#L46) |
| `FALLBACK_DURATION` | 1460 days (4 years from deploy) | [`:49`](../src/token/FounderVesting.sol#L49) |

### 6.1 Trigger — 2-of-3 oracle conditions

Tokens unlock only after **at least 2 of these 3 conditions hold for
≥ 7 consecutive days** (or via the fallback path below):

| Condition | Threshold | Constant | Source line |
|---|---|---|---|
| **A** — ETH/BTC ratio | > 0.050 | `ETH_BTC_THRESHOLD = 50e15` | [`:43`](../src/token/FounderVesting.sol#L43) |
| **B** — ETH/USD price | > $4,000 | `ETH_USD_THRESHOLD = 400_000_000_000` (8 dec) | [`:44`](../src/token/FounderVesting.sol#L44) |
| **C** — Aave V3 USDC borrow rate | > 7% APY | `BORROW_RATE_THRESHOLD = 7e25` (RAY, 27 dec) | [`:45`](../src/token/FounderVesting.sol#L45) |

The Aave V3 dependency for Condition C is documented in
[`docs/architecture/AAVE-INTEGRATION.md`](architecture/AAVE-INTEGRATION.md).
Aave V3 is **read-only** — the protocol never deposits or borrows.

### 6.2 Release path

`checkAltSeason()` is permissionless. When ≥ 2 conditions are met it
records `conditionsMetSince`. Once 7 days elapse without breaking the
2-of-3 invariant, it sets `altSeasonTriggered = true` and `triggerTimestamp`
([`FounderVesting.sol:107-109`](../src/token/FounderVesting.sol#L107-L109)).
From that moment, one tranche unlocks every 31 days for the recipient
to claim ([`:133-142`](../src/token/FounderVesting.sol#L133-L142)).

### 6.3 Fallback

If conditions never trigger, `triggerFallback()` becomes callable
1460 days after deployment ([`:123`](../src/token/FounderVesting.sol#L123)).
This protects the protocol from indefinite founder lock-out without
giving the founder an early exit.

---

## 7. Treasury Vesting

Source: [`src/token/TreasuryVesting.sol`](../src/token/TreasuryVesting.sol).

| Constant | Value | Source |
|---|---|---|
| `TOTAL_AMOUNT` | 3,000,000 LUMINA | [`TreasuryVesting.sol:17`](../src/token/TreasuryVesting.sol#L17) |
| `LOCK_DURATION` | 180 days (6 months) | [`:18`](../src/token/TreasuryVesting.sol#L18) |
| `MAX_MONTHLY_RELEASE` | 250,000 LUMINA | [`:19`](../src/token/TreasuryVesting.sol#L19) |
| `MONTH` | 30 days | [`:20`](../src/token/TreasuryVesting.sol#L20) |

`release(to, amount)` is `onlyOwner`. Math implication: with the
250k/month cap, the full 3M takes a minimum of **12 months of releases**
on top of the 6-month lock — i.e. the treasury is fully drawable no
sooner than **18 months from deploy**.

---

## 8. Cross-Reference — Every Tokenomics Contract

| Contract | Path | Role |
|---|---|---|
| LuminaTokenV2 | [`src/token/LuminaTokenV2.sol`](../src/token/LuminaTokenV2.sol) | Token, supply, distribution, BURNER_ROLE |
| FounderVesting | [`src/token/FounderVesting.sol`](../src/token/FounderVesting.sol) | 8M founder allocation + AltSeason gates |
| TreasuryVesting | [`src/token/TreasuryVesting.sol`](../src/token/TreasuryVesting.sol) | 3M treasury drip |
| BondVault | [`src/bonds/BondVault.sol`](../src/bonds/BondVault.sol) | 70M LUMINA reserve, redeem path |
| ClaimBond | [`src/bonds/ClaimBond.sol`](../src/bonds/ClaimBond.sol) | ERC-1155 bonds, $1 face value |
| CoverRouterV2 | [`src/core/CoverRouterV2.sol`](../src/core/CoverRouterV2.sol) | Premium calc, USDC → TWAPBurner |
| TWAPBurner | [`src/core/TWAPBurner.sol`](../src/core/TWAPBurner.sol) | Buy & burn engine |
| AdaptiveFeeDistributor | [`src/core/AdaptiveFeeDistributor.sol`](../src/core/AdaptiveFeeDistributor.sol) | Dynamic 4-bucket distribution |
| BuybackEngine | [`src/marketplace/BuybackEngine.sol`](../src/marketplace/BuybackEngine.sol) | MEV-protected buybacks from buyback bucket |
| LuminaBondMarketplace | [`src/marketplace/LuminaBondMarketplace.sol`](../src/marketplace/LuminaBondMarketplace.sol) | 3% secondary fee → TWAPBurner |
| SolvencyOracle | [`src/oracles/SolvencyOracle.sol`](../src/oracles/SolvencyOracle.sol) | 125% solvency floor for `burnFromReserves` |
| CapacityOracle | [`src/oracles/CapacityOracle.sol`](../src/oracles/CapacityOracle.sol) | TWAP-priced available capacity |

---

## 9. Roadmap items — explicitly not part of V5.1 today

These are tracked in [`docs/ROADMAP-V5.md`](ROADMAP-V5.md) and are
**not yet active** on testnet:

- Governance / voting (no on-chain governor yet)
- NFT-based membership tiers
- Cross-chain expansion beyond Base

This document only describes what is deployed on Base Sepolia today.
