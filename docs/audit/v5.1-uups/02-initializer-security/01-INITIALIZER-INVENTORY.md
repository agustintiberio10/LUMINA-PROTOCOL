# V5.1 UUPS Initializer Inventory

**Audit:** V5.1 #2 — Initializer Security Audit
**Branch:** `audit/v5.1-02-initializer-security`
**Scope:** 24 concrete UUPS contracts + 1 abstract parent (`BaseShield`)
**Date:** 2026-04-22

---

## Summary

| # | Contract | `_disableInitializers()` | Auth grantee | Role grants | Zero-addr checks |
|---|----------|--------------------------|--------------|-------------|------------------|
| 1 | LuminaTokenV2 | ✓ | `msg.sender` | DEFAULT_ADMIN | 5 + 10 dup checks |
| 2 | BondVault | ✓ | `msg.sender` | DEFAULT_ADMIN, AUTHORIZED_CALLER_ADMIN | 3 strict + 1 opt |
| 3 | ClaimBond | ✓ | `msg.sender` (Ownable) | — | 0 (no addr params) |
| 4 | PolicyManagerV2 | ✓ | `msg.sender` (Ownable) | — | 1 |
| 5 | CoverRouterV2 | ✓ | `msg.sender` (Ownable) | — | 3 |
| 6 | TWAPBurner | ✓ | `msg.sender` (Ownable) | — | 3 |
| 7 | AdaptiveFeeDistributor | ✓ | `msg.sender` (Ownable) | — | 1 |
| 8 | BuybackEngine | ✓ | `_multisigOwner` (param) | DEFAULT_ADMIN, BUYBACK_OPERATOR | 7 |
| 9 | LuminaBondMarketplace | ✓ | `_admin` (param) | DEFAULT_ADMIN, FEE_MANAGER | 4 |
| 10 | ShieldKeeper | ✓ | `msg.sender` (Ownable) | — | 1 |
| 11 | BaseShield (abstract) | ✓ | `msg.sender` (Ownable) | — | 2 |
| 12 | FlashBTCShield1h | ✓ | `msg.sender` (Ownable via BS) | — | 2 (via BS) |
| 13 | FlashBTCShield4h | ✓ | `msg.sender` | — | 2 (via BS) |
| 14 | FlashBTCShield24h | ✓ | `msg.sender` | — | 2 (via BS) |
| 15 | FlashBTCShield48h | ✓ | `msg.sender` | — | 2 (via BS) |
| 16 | FlashETHShield1h | ✓ | `msg.sender` | — | 2 (via BS) |
| 17 | FlashETHShield24h | ✓ | `msg.sender` | — | 2 (via BS) |
| 18 | FlashETHShield48h | ✓ | `msg.sender` | — | 2 (via BS) |
| 19 | MicroDepegShield | ✓ | `msg.sender` | — | 2 (via BS) |
| 20 | RateShockShield | ✓ | `msg.sender` | — | 2 (via BS) + 2 direct |
| 21 | CapacityOracle | ✓ | `msg.sender` (Ownable) | — | 2 + range(emergencyPrice>0) + cond pool |
| 22 | SolvencyOracle | ✓ | `_admin` (param) | DEFAULT_ADMIN, ADMIN_ROLE | 3 |
| 23 | CEXLiquidityReserve | ✓ | `_multisigOwner` (param) | DEFAULT_ADMIN, ALLOCATOR | 2 |
| 24 | MaintenanceReserve | ✓ | `_admin` (param) | DEFAULT_ADMIN, SPENDER | 2 |
| 25 | TreasuryVesting | ✓ | `msg.sender` (Ownable) | — | 1 |

**All 24 concrete + BaseShield have `constructor() { _disableInitializers(); }`** — impl cannot be init'd directly.

**All `initialize()` functions carry the `initializer` modifier** (implicit via OZ 5.x patterns) — init can only run once per proxy.

---

## Key design observations

1. **Param-based admin grantees (5 contracts):** `BuybackEngine`, `LuminaBondMarketplace`, `SolvencyOracle`, `CEXLiquidityReserve`, `MaintenanceReserve` accept an `_admin`/`_multisigOwner` parameter and grant that address DEFAULT_ADMIN_ROLE. These are designed for multisig setup at deploy time. Tests must verify that (a) the param value receives the role, (b) `msg.sender` does NOT receive the role unless param == sender, and (c) a different address cannot re-run init.

2. **`msg.sender` grantees (19 contracts):** All Ownable-based contracts and `LuminaTokenV2` + `BondVault` grant control to `msg.sender`. Since deployment is atomic through `ProxyDeployer` (the ERC1967Proxy constructor invokes `initialize` in the same tx), `msg.sender` inside initialize is the DEPLOYING contract, not an attacker. This is the intended pattern.

3. **BaseShield-derived contracts (9):** All 9 concrete Shield children defer initialization to `__BaseShield_init(router_, oracle_)`, which performs the same two zero-address checks and calls the Ownable/UUPS init helpers. `RateShockShield` adds two direct zero-address checks for `_aavePool` and `_usdc`.

4. **`BondVault._policyManager` is optional at init.** Passed as `address(0)`, `_policyManagerSet` stays false and a later `setPolicyManager()` call completes configuration. This design means the init-time validation for `_policyManager` is intentionally NOT a zero-address check.

5. **`CapacityOracle._pool` is optional at init.** Conditional path — if zero, pool is left unset for later `setPool()` call; `emergencyPrice` alone is used by the price function in that case.

---

## Front-running posture

All proxies are deployed via `ProxyDeployer`, which encodes the `initialize` call into the ERC1967Proxy constructor payload. The proxy is initialized atomically in the same transaction as its deployment — no window exists between deployment and initialization during which a front-runner could call `initialize`. This is the standard, safe pattern.

An implementation contract (un-proxied) is protected against hostile initialization by the `_disableInitializers()` call in its constructor.

---

See `REPORT.md` for the audit verdict and per-contract test results.
