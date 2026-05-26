# Sprint UUPS Upgrade — Manual Review Fixes On-Chain — 2026-05-26

**Result:** ✅ **8 UUPS upgrades broadcast on Base Sepolia (84532), all successful.** The
Sprint Fix 7.3 Manual-Review fixes (PR #158) are now ACTIVE on-chain. Dry-run clean,
storage layout verified append-only, selectors + smoke tests green post-upgrade.

Used the **canonical V5.4 addresses** (derived on-chain, PR #160) — NOT the stale V5.0
repo manifest values that reverted the earlier attempt. Script: `script/deploy/UpgradeManualReviewV54.s.sol`
(8 proxies hardcoded). Founder `0xe585…fDa8` (owner of all proxies). Total gas **18,204,164** (~0.0002 ETH @ 0.011 gwei).

## Upgrades (proxy → new implementation + upgrade tx)

| Contract | Proxy | New impl | upgradeToAndCall tx | Fix |
|---|---|---|---|---|
| CapacityOracle | `0xd52aef11…6545` | `0x8991Ae04…9966` | `0x64da8642…4bca` | MR-H01 |
| CoverRouterV2 | `0xcdB70B40…F566` | `0x161f9d80…8180` | `0x4f9dc7fe…dfd1` | MR-M01 |
| PolicyManagerV2 | `0x546C07e0…cDd8` | `0x63586DA3…fA61` | `0x7df58c8d…2e93` | MR-M01/L01/L03 |
| BondVault | `0x193acBc1…B6EC` | `0x3D5f4329…9e3E` | `0x7c7af82e…d514` | MR-M02/M03/L04/L10 |
| BuybackEngine | `0x56B5a111…d8B4` | `0x93b05984…dF0F` | `0x9f5d28f3…4a3e` | MR-M04/L11 |
| TWAPBurner | `0x242d7608…1bC0` | `0xAe327b5c…001e` | `0xfe5afabc…58d6` | MR-M07 |
| ClaimBond | `0xaa57Ab52…1FB4` | `0x8Fd6b84a…30a0` | `0x0dc2e755…0b74` | (no MR change — same-source refresh) |
| AdaptiveFeeDistributor | `0xeC7841A4…59D54` | `0x9E2859AB…455B` | `0x7a3e872c…ebe9` | (no MR change — same-source refresh) |

(8 CREATE impl txs + 8 CALL upgrade txs = 16 total; full hashes in `broadcast/UpgradeManualReviewV54.s.sol/84532/run-latest.json`.)

## Storage layout — verified append-only ✅
Only **CapacityOracle** changed storage: `maxObservationAge`(slot 7), `minCardinality`(slot 8)
appended after the F-09 slots; `__gap` 48→46. The other 7 are **logic-only** (no storage change).
`upgradeToAndCall(impl, "")` swaps only the ERC1967 impl pointer (no re-init, no storage writes).

## Dry-run ✅
`forge script … --rpc-url` (no broadcast): SIMULATION COMPLETE, all 8 upgrades authorized
(founder = owner), no reverts.

## Selectors verified post-upgrade
| Call | Result |
|---|---|
| `CoverRouterV2.REQUIRED_PAYOUT_RATIO_BPS()` | **8000** ✅ |
| `BondVault.MAX_USER_REDEEM_BPS()` | **1000** ✅ |
| `BuybackEngine.spentThisWindow()` | 0 ✅ (new MR-L11 getter exists ⇒ upgraded) |
| `BuybackEngine.BUYBACK_OPERATOR_ROLE()` | `0x7888…1198` ✅ |
| `CapacityOracle.maxObservationAge()` / `minCardinality()` | **0 / 0** — storage uninitialized post-upgrade; the gate uses `DEFAULT_MAX_OBSERVATION_AGE`(3600) / `DEFAULT_MIN_CARDINALITY`(10) by design |
| `CapacityOracle.DEFAULT_MAX_OBSERVATION_AGE()` | 3600 ✅ |

## Smoke tests ✅
- **G.1 Purchase (MR-M01)** — `POST /sandbox/try {FLASHBTC1H-001}` → `ok:true`, policyId **2**, coverage $100, premium 0.288, tx `0x50530d1a…83ad5d`. Full CoverRouter→PolicyManager→shield→BondVault flow works on the upgraded contracts.
- **G.2 Permissions (MR-M04)** — `executeOffer(1)` from `0x…dead` reverts `AccessControlUnauthorizedAccount` (`0xe2517d3f`, role `BUYBACK_OPERATOR_ROLE`). ✅
- **G.3 Oracle (MR-H01)** — `getLuminaPrice()` = `0.036e18`, no fail-closed. `pool()==0x0` (no-pool bootstrap) ⇒ freshness gate **dormant** until a real Uniswap pool is wired (mainnet). No regression.

## Descoped (per scope / gaps)
- **ShieldKeeper** — gap: `adapter.keeper()==0x0`; settlement via relayer. Not upgraded.
- **CEXLiquidityReserve** — gap: `cexReserve()==0x0` (dormant); **MR-M03 reserve-side cap NOT on-chain** until deployed.
- **2 DEX adapters (MR-M06)** — non-upgradeable Ownable → require **redeploy** (separate sprint).
- **MR-H02** — lumina-api off-chain (PR lumina-api#42), no contract upgrade.

## Follow-ups
- Pre-mainnet: when wiring the live LUMINA/USDC Uniswap pool, call `CapacityOracle.setFreshnessParams(maxAge, minCardinality)` to set explicit freshness values (defaults 3600/10 apply meanwhile; gate dormant while `pool==0x0`).
- Deploy + wire ShieldKeeper and CEXLiquidityReserve (or keep descoped).
- Redeploy the 2 DEX adapters for MR-M06.
