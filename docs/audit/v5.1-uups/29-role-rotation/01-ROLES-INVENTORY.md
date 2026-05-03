# Audit V5.1 #29 — Roles Inventory

Every admin-gated role + ownership pattern across the UUPS contracts + FounderVesting.

> **Post-fix M-1 sync (2026-04-30):** added `ChainlinkGraceOracle`
> (Ownable, post-H13) to the Ownable contracts table. See
> `04-admin-key-risk/ACCESS-CONTROL-MATRIX-V5.1.md` for the master
> function × role matrix that includes every admin function added or
> changed during the C/H audit-fix sprints (post-fix C-3, H-1..H-13).

---

## 1. AccessControl contracts (8)

| # | Contract | Roles | Admin of role | Granted at init |
|---|---|---|---|---|
| 1 | `BondVault` | `DEFAULT_ADMIN_ROLE`, `AUTHORIZED_CALLER_ADMIN_ROLE` | DEFAULT admins itself + AUTHORIZED_CALLER_ADMIN_ROLE | deployer (both) |
| 2 | `BuybackEngine` | `DEFAULT_ADMIN_ROLE`, `BUYBACK_OPERATOR_ROLE` | DEFAULT admins both | `_multisigOwner` (both) |
| 3 | `LuminaBondMarketplace` | `DEFAULT_ADMIN_ROLE`, `FEE_MANAGER_ROLE` | DEFAULT admins both | `_admin` (both) |
| 4 | `CEXLiquidityReserve` | `DEFAULT_ADMIN_ROLE`, `ALLOCATOR_ROLE` | DEFAULT admins both | `_multisigOwner` (both) |
| 5 | `MaintenanceReserve` | `DEFAULT_ADMIN_ROLE`, `SPENDER_ROLE` | DEFAULT admins both | `_admin` (both) |
| 6 | `SolvencyOracle` | `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE` | DEFAULT admins both | `_admin` (both) |
| 7 | `LuminaTokenV2` | `DEFAULT_ADMIN_ROLE`, `BURNER_ROLE` | DEFAULT admins both | deployer (DEFAULT only) |
| 8 | `ChainlinkGraceOracle` *(post-H13)* | `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE` | DEFAULT admins both | `_admin` (both) |

### 1.1 Role details per contract

**BondVault** (`src/bonds/BondVault.sol`)
- `DEFAULT_ADMIN_ROLE`: grants all roles, gates `_authorizeUpgrade`, `recoverToken`, `recoverERC1155`.
- `AUTHORIZED_CALLER_ADMIN_ROLE`: gates `setAuthorizedCaller`. Separate so daily ops (whitelisting BuybackEngine) don't need DEFAULT admin.
- Plus `authorizedCallers` mapping (not a role) for call-gating `decreaseObligations` / `burnFromReserves`.

**BuybackEngine** (`src/marketplace/BuybackEngine.sol`)
- `DEFAULT_ADMIN_ROLE`: upgrades, rescue.
- `BUYBACK_OPERATOR_ROLE`: gates `setDailyBuyback`, `executeOffer`. Rotatable for ops-team changes.

**LuminaBondMarketplace** (`src/marketplace/LuminaBondMarketplace.sol`)
- `DEFAULT_ADMIN_ROLE`: upgrades, rescue.
- `FEE_MANAGER_ROLE`: gates `setTwapBurner`.

**CEXLiquidityReserve** (`src/treasury/CEXLiquidityReserve.sol`)
- `DEFAULT_ADMIN_ROLE`: upgrades, `setMonthlyCap` ([Fix H-2]), `recoverToken`, grant/revoke allocator.
- `ALLOCATOR_ROLE`: gates `allocate`. Rotatable.

**MaintenanceReserve** (`src/treasury/MaintenanceReserve.sol`)
- `DEFAULT_ADMIN_ROLE`: upgrades, `recoverToken`, `setMonthlyCap`, grant/revoke spender.
- `SPENDER_ROLE`: gates `spend`.

**SolvencyOracle** (`src/oracles/SolvencyOracle.sol`)
- `DEFAULT_ADMIN_ROLE`: upgrades.
- `ADMIN_ROLE`: gates `setEmergencyPause`.

**LuminaTokenV2** (`src/token/LuminaTokenV2.sol`)
- `DEFAULT_ADMIN_ROLE`: upgrades, grant/revoke burner.
- `BURNER_ROLE`: declared on the contract and granted to TWAPBurner at deploy as a reserved/legacy hook. **Post [Fix H-1] it does NOT gate `burnFrom`** — that function uses the standard ERC20Burnable allowance check (caller must hold the holder's prior `approve`). The two existing burn paths (`TWAPBurner._executeBurn` and `BondVault.burnFromReserves` → `IBurnable.burn`) both call `burn(uint256)` on the contract's own balance and therefore never required `burnFrom`. BURNER_ROLE is preserved on-storage for potential future privileged burn paths.

**ChainlinkGraceOracle** (`src/oracles/ChainlinkGraceOracle.sol`) *(post-H13)*
- `DEFAULT_ADMIN_ROLE`: gates `_authorizeUpgrade`.
- `ADMIN_ROLE`: gates `setFeed`, `setHeartbeat`, `setSequencerFeed`, `setOracleKey`.
- **Permissionless** (no role): `markChainlinkDown`, `markChainlinkUp` — caller-side checks reject calls when feed state doesn't match.

---

## 2. Ownable contracts (13)

All use **OpenZeppelin v5 `OwnableUpgradeable`** — **1-step** `transferOwnership`. No `pendingOwner()` mechanism. `renounceOwnership` is permanent.

| Contract | Current owner at init | Admin-gated fns |
|---|---|---|
| `TWAPBurner` | deployer | setPoolFee, setMaxSlippageBps, setMinBurnAmount, setMaxBurnAmount, setBurnCooldown, setAuthorizedSender, setCapacityOracle, setDexRouters, addDexRouter, setFeeDistributor, setReserves, setMaintenanceReserve, setAdaptiveMode, recoverToken, upgradeToAndCall |
| `CoverRouterV2` | deployer | configureProduct, setRelayer, setPaused, setPolicyManager, setTwapBurner, setCapacityOracle, recoverToken, syncCircuitBreaker (*permissionless*), upgradeToAndCall |
| `PolicyManagerV2` | deployer | setRouter, registerProduct, deactivateProduct, **reactivateProduct** *(branch `feat/reactivate-product`, pending merge — see note below)*, upgradeToAndCall |
| `ClaimBond` | deployer | setBondVault, setAuthorizedOperator, setBaseURI, upgradeToAndCall |
| `TreasuryVesting` | deployer | release, recoverToken, upgradeToAndCall |
| `CapacityOracle` | deployer | setEmergencyPrice, setTwapPeriod, setFallbackTolerance, upgradeToAndCall |
| `AdaptiveFeeDistributor` | deployer | recoverToken, upgradeToAndCall |
| `ShieldKeeper` | deployer | pause, unpause, upgradeToAndCall |
| `BaseShield` (inherited by 9 shields) | deployer | setBeneficiary, setOracle, upgradeToAndCall |
| 9 Shields (BTC/ETH 1h/4h/24h/48h, MicroDepeg, RateShock) | deployer | (via BaseShield) |

Total: 13 Ownable-style proxies + 9 shield instances sharing BaseShield semantics.

> ⚠️ **PRE-MAINNET RELEASE NOTE — `PolicyManagerV2.reactivateProduct`**
>
> The `reactivateProduct(bytes32)` admin function is implemented on
> branch `feat/reactivate-product`, NOT yet on `main`. It will land via
> the V5.1 consolidated squash-merge before mainnet deploy. It is the
> intended counterpart of `deactivateProduct` (post-H-5, `triggerPayout`
> hard-checks `productActive`).
>
> **Workaround pre-merge** (NOT official pattern): re-call
> `registerProduct` to set `productActive = true` as a side-effect — but
> this re-emits `ProductRegistered` and may confuse indexers.

---

## 3. Immutable / non-upgradeable

| Contract | Role model |
|---|---|
| `FounderVesting` | **Immutable** — no upgrade, no admin. Only `recipient` can call vesting fns. Constructor-fixed. |

---

## 4. Role rotation matrix

| Contract | Role | Type | Grant by | Revoke by | Rotation risk |
|---|---|---|---|---|---|
| BondVault | DEFAULT_ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe (multi-admin possible) |
| BondVault | AUTHORIZED_CALLER_ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe |
| BondVault | authorizedCallers (mapping) | bool | AUTHORIZED_CALLER_ADMIN | AUTHORIZED_CALLER_ADMIN | Safe |
| BuybackEngine | DEFAULT_ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe |
| BuybackEngine | BUYBACK_OPERATOR | AC | DEFAULT admin | DEFAULT admin | Safe |
| Marketplace | DEFAULT_ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe |
| Marketplace | FEE_MANAGER | AC | DEFAULT admin | DEFAULT admin | Safe |
| CEXReserve | DEFAULT_ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe |
| CEXReserve | ALLOCATOR | AC | DEFAULT admin | DEFAULT admin | Safe |
| MaintenanceReserve | DEFAULT_ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe |
| MaintenanceReserve | SPENDER | AC | DEFAULT admin | DEFAULT admin | Safe |
| SolvencyOracle | DEFAULT_ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe |
| SolvencyOracle | ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe |
| LuminaTokenV2 | DEFAULT_ADMIN | AC | DEFAULT admin | DEFAULT admin | Safe |
| LuminaTokenV2 | BURNER | AC | DEFAULT admin | DEFAULT admin | Safe |
| TWAPBurner | owner | Ownable | owner (transferOwnership) | — (renounce only) | 1-step — requires care |
| CoverRouterV2 | owner | Ownable | owner | — | 1-step |
| PolicyManagerV2 | owner | Ownable | owner | — | 1-step |
| ClaimBond | owner | Ownable | owner | — | 1-step |
| TreasuryVesting | owner | Ownable | owner | — | 1-step |
| CapacityOracle | owner | Ownable | owner | — | 1-step |
| ChainlinkGraceOracle *(post-H13)* | DEFAULT_ADMIN_ROLE + ADMIN_ROLE | AccessControl | DEFAULT admin | DEFAULT admin | Safe (multi-admin allowed) |
| AdaptiveFeeDistributor | owner | Ownable | owner | — | 1-step |
| ShieldKeeper | owner | Ownable | owner | — | 1-step |
| 9 Shields | owner | Ownable (via BaseShield) | owner | — | 1-step |

## 5. Risks identified

### RISK-1 — Ownable is 1-step (no Ownable2Step)

13 contracts + 9 shields use `OwnableUpgradeable` from OZ v5 — **transferOwnership is 1-step**. If admin typos a transfer destination, the intended new owner immediately has full control. There is no `acceptOwnership` safety.

**Mitigation:** perform ownership transfers behind a multisig + timelock. The transfer is then reviewable by multiple signers during the 48h delay window.

### RISK-2 — `renounceRole` / `renounceOwnership` are permanent

Calling `renounceRole(DEFAULT_ADMIN_ROLE, self)` when `self` is the sole admin permanently locks the contract. Same for `renounceOwnership` on Ownable.

**Mitigation:** runbook (see `02-ROTATION-RUNBOOK.md`) explicitly forbids renouncing without a verified successor.

### RISK-3 — Single EOA admin = single point of failure

At deploy, admin/owner is a single EOA (`msg.sender`). Losing the key = losing the contract forever.

**Mitigation:** transition to multisig (Rotation A in runbook) BEFORE any meaningful value is deployed.

### RISK-4 — AUTHORIZED_CALLER_ADMIN_ROLE can grant authorization without DEFAULT admin

`BondVault.setAuthorizedCaller(addr, true)` authorizes `addr` to call `decreaseObligations` and `burnFromReserves` (which burns LUMINA). The role gate is `AUTHORIZED_CALLER_ADMIN_ROLE`, not `DEFAULT_ADMIN_ROLE`. This is a **privilege separation** (operations don't need full admin), but if the role is compromised, attacker can authorize a malicious caller to burn up to 5% LUMINA per tx.

**Mitigation:** grant this role sparingly; ideally to the same multisig as DEFAULT_ADMIN_ROLE; consider merging the two roles if separation is unnecessary.

### RISK-5 — No separate "admin transfer initiated" / "admin transfer accepted" events

`grantRole` / `revokeRole` emit OZ's `RoleGranted` / `RoleRevoked` events. For Ownable, `transferOwnership` emits `OwnershipTransferred(old, new)`. No explicit "pending" state — all transfers are immediate.

Adequate for monitoring but means UIs must read live state after each block.

## 6. Observations (non-findings)

- **Consistent role hierarchy**: every role's admin is `DEFAULT_ADMIN_ROLE` — simpler than alternatives (no sub-admin trees).
- **Permissionless sync** (`CoverRouterV2.syncCircuitBreaker`): no role gate by design. Anyone can call. Documented in audit #28 fix.
- **Authorized-caller mapping in BondVault**: per-address bool, not a role. Provides the same pattern but with `AuthorizedCallerUpdated` event (cleaner than a generic `RoleGranted`).
