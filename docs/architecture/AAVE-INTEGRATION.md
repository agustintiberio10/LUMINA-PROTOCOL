# Aave V3 integration in Lumina V5.1

## Summary

Lumina V5.1 uses Aave V3 in a **read-only oracle role** in exactly two places. Lumina does **not** deposit funds into Aave or generate yield from Aave.

This doc exists to clear up persistent confusion: the old V4 architecture deposited USDC into Aave for LP yield via 4 vaults; V5.1 removed that entirely. The Aave references that remain are oracle reads only.

## Where Aave IS used

### 1. RateShockShield (one of 9 V5.1 shields)

Parametric insurance product that pays out 80% of cover when the Aave V3 USDC variable borrow rate exceeds 10% APY for the configured duration.

- **Contract**: `src/products/RateShockShield.sol`
- **Aave interface**: `IAaveV3Pool` (declared at `RateShockShield.sol:26-46`)
- **Storage**: `aavePool` immutable address (`:60-61`)
- **Function called**: `aavePool.getReserveData(usdc)` (`:131-132` and `:162-163`)
- **Threshold**: 10% APY in RAY (27 decimals). Source: hardcoded comparison in trigger logic.
- **Why no oracle proof**: Aave V3 rates are first-class on-chain data. Anyone can read `getReserveData(USDC).currentVariableBorrowRate` deterministically — no off-chain signing required (`RateShockShield.sol:16` comment).

### 2. FounderVesting (founder token lock)

Locks 8M LUMINA until **2-of-3** AltSeason conditions hold for 7 sustained days, OR a 4-year fallback elapses. One of the three conditions is an Aave V3 read.

- **Contract**: `src/token/FounderVesting.sol`
- **Aave interface**: `IAaveV3PoolReader` (declared at `:20-39`)
- **Storage**: `aavePool` immutable address (`:62`)
- **Function called**: `IAaveV3PoolReader(aavePool).getReserveData(usdc)` (`:198-200`, wrapped in `try/catch`)
- **Three conditions** (`:_evaluateConditions()` `:188-203`):
  - **A**: ETH/BTC ratio > **0.050** (threshold `ETH_BTC_THRESHOLD = 50e15` in 18-dec, `:43`)
  - **B**: ETH > **$4,000** (threshold `ETH_USD_THRESHOLD = 400_000_000_000` in 8-dec, `:44`)
  - **C**: Aave V3 USDC variable borrow rate > **7% APY** (threshold `BORROW_RATE_THRESHOLD = 7e25` in RAY, `:45`)
- **Sustained duration**: 7 days (`SUSTAINED_DURATION = 7 days`, `:46`)
- **Tranche schedule**: 3 equal tranches every 31 days post-trigger (`:47-49`)
- **Fallback**: `FALLBACK_DURATION = 1460 days` from deploy if conditions never hold (`:50`)
- **Total amount locked**: `TOTAL_AMOUNT = 8_000_000 * 1e18` (`:51`)

## Where Aave is NOT used

The following V4 patterns are **not present** in V5.1 — confirmed by `grep -rE "supply|deposit.*aUSDC|withdraw.*aUSDC|aUSDC" src/` returning zero hits in the contract code:

- ❌ No LP / yield vaults — V4's 4-vault model (VolatileShort, VolatileLong, StableShort, StableLong) is gone
- ❌ No `aUSDC` token interactions
- ❌ No `IPool.supply()`, `IPool.borrow()`, `IPool.withdraw()` calls
- ❌ Premiums collected in USDC are 100% burned via `TWAPBurner` — they never touch Aave
- ❌ `BondVault` holds USDC reserves directly — never deposited anywhere

## Migration from V4

| | V4 | V5.1 |
|---|---|---|
| Vaults | 4 (VolatileShort/Long, StableShort/Long) | 1 (BondVault) |
| LP yield | Via Aave aUSDC supply | None — premiums burn |
| Aave role | Yield generation + oracle | **Oracle only** |
| Cooldown | stkAAVE-style cooldown windows | None |
| Bond mechanics | N/A (V4 had no bonds) | ClaimBond ERC-1155, $1 face, 730d maturity |

## Security implications

If Aave V3 is compromised or the borrow-rate read is manipulated:

- **RateShockShield** could trigger incorrectly (false positive → unjustified payouts; false negative → buyers don't get paid when they should). No off-chain protection.
- **FounderVesting Condition C** could activate incorrectly. Mitigation: 2-of-3 logic — the founder unlock requires at least one of A or B in addition to C. A single Aave manipulation cannot unlock alone.

## Source files

- `src/products/RateShockShield.sol` — RateShock product
- `src/token/FounderVesting.sol` — founder vesting
- `src/products/BaseShield.sol` — common shield base (no Aave dependency)
- `src/core/CoverRouterV2.sol` — purchase routing (no Aave dependency)
- `src/bonds/BondVault.sol` — single bond vault (no Aave dependency)

## Related docs

- [`SECURITY.md`](../../SECURITY.md) — full security overview
- [`audit/THREAT-MODEL.md`](../audit/THREAT-MODEL.md) — adversarial framing including oracle assumptions
- [`V1-DEPRECATED-CONTRACTS.md`](../V1-DEPRECATED-CONTRACTS.md) — historical V1/V2/V4 contracts (kept for reference only)
