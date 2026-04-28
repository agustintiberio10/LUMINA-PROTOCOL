# 01 — Base Mainnet dependency addresses

The V5.1 deploy on Base mainnet must wire to **real, already-deployed** primitives — no mocks. Every address below was verified live with `cast call --rpc-url https://mainnet.base.org` at audit time (2026-04-28). Any deviation in the deploy script vs this table will be flagged as a finding by `MainnetForkDeploy.t.sol`.

## Stablecoin

| Field | Value |
|---|---|
| `USDC` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `decimals()` | **6** ✓ |
| Issuer | Circle (Base canonical USDC) |
| Notes | Used as premium currency by `CoverRouterV2.purchasePolicy*` and as denominator for `quotePremium`, `MaintenanceReserve`, `Marketplace` fees. |

## Chainlink price feeds (Base)

| Pair | Address | Decimals | Live answer at audit time |
|---|---|---|---|
| `BTC/USD` | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` | 8 | 76 419.53 USD |
| `ETH/USD` | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | 8 | 2 297.10 USD |
| `USDC/USD` | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | 8 | 0.9998 USD |

All return `int256 latestAnswer()` and `uint8 decimals()`. The `MicroDepegShield` reads `USDC/USD` to detect depegs; `RateShockShield` and the Flash{BTC,ETH} shields read `{BTC,ETH}/USD` for trigger detection.

## Aave V3 (Base)

| Field | Value |
|---|---|
| `Pool` | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| Used by | `RateShockShield` (reads `getReserveData(usdc).currentVariableBorrowRate`); `FounderVesting` (reads same value as condition C of AltSeason gate) |
| Live USDC borrow rate at audit time | `1.183e27` ray ≈ **11.83 % APY** (within the 0.1 % – 30 % expected band) |

## DEX routers

### Uniswap V3 (Base)

| Field | Value |
|---|---|
| `SwapRouter02` | `0x2626664c2603336E57B271c5C0b26F421741e481` |
| Used by | `TWAPBurner` (configurable; the deploy passes this as `swapRouter` for USDC→LUMINA buyback swaps) |

### Aerodrome (Base)

| Field | Value |
|---|---|
| `Router` | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` |
| Used by | Optional alternative `swapRouter` for `TWAPBurner`. Not the default; production deploy can pick either. |

## Verification commands (read-only)

```bash
RPC=https://mainnet.base.org

# USDC
cast call --rpc-url $RPC 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 "decimals()(uint8)"
# → 6

# Chainlink BTC/USD
cast call --rpc-url $RPC 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F "latestAnswer()(int256)"
# → > 0

# Aave V3 Pool — variableBorrowRate (4th return field of getReserveData)
cast call --rpc-url $RPC 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5 \
  "getReserveData(address)(uint256,uint128,uint128,uint128,uint128,uint128,uint40,uint16,address,address,address,address,uint128,uint128,uint128)" \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
# → currentVariableBorrowRate at index 3, ~ 1e26 to 3e26 (10 % – 30 %)
```

If any of these returns `0`, reverts, or yields data outside the documented ranges, the deploy script must NOT be run on production. The fork test in this audit (`MainnetForkDeploy.t.sol`) re-runs these checks before exercising the deploy itself.
