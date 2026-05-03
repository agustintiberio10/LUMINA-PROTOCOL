# LUMINA V5.1 — Access Control Matrix (Master)

**Audit:** V5.1 #4 Admin Key Risk · #29 Role Rotation
**Status:** Post-fix consolidated (commits behind audit fixes C-3, H-1..H-13)
**Branch:** `fix/m1-access-control-doc`
**Date:** 2026-04-30
**Supersedes (does NOT delete):** `01-ADMIN-POWERS-INVENTORY.md` (still authoritative
for risk + mitigations); `02-RISK-MATRIX.md`; `29-role-rotation/01-ROLES-INVENTORY.md`
(still authoritative for the role rotation runbook).

---

## 0. Reading guide

This document is the **single source of truth for "which call requires which role"**.
It is auditor-facing — Trail of Bits / Zellic read it first to map admin power → on-chain
function. The other docs in this folder zoom into:
- `01-ADMIN-POWERS-INVENTORY.md`: per-contract impact + mitigations narrative.
- `02-RISK-MATRIX.md`: ranked risk table.
- `03-PUBLIC-ADMIN-DISCLOSURE.md`: outward-facing summary for whitepaper / docs site.
- `04-PRE-MAINNET-RECOMMENDATIONS.md`: timelock / multisig recommendations.
- `29-role-rotation/`: role rotation runbook + onboarding/offboarding playbook.

**Each function-row marks** `[POST-FIX X-Y]` if the function or modifier landed
during the audit-fix sprints (C/H series). Absence of that marker means the
function existed in the pre-audit V5.1 baseline.

---

## 1. Scope (18 core contracts + 9 shield products)

| # | Contract | File | Auth model | Notes |
|---|---|---|---|---|
| 1 | `LuminaTokenV2` | `src/token/LuminaTokenV2.sol` | AccessControl | DEFAULT_ADMIN + BURNER |
| 2 | `BondVault` | `src/bonds/BondVault.sol` | AccessControl | Two role admins + authorizedCallers map |
| 3 | `ClaimBond` | `src/bonds/ClaimBond.sol` | Ownable | + per-bond authorizedOperator + marketplaceEscape (post-H12) |
| 4 | `PolicyManagerV2` | `src/core/PolicyManagerV2.sol` | Ownable | onlyRouter on hot path |
| 5 | `CoverRouterV2` | `src/core/CoverRouterV2.sol` | Ownable | relayer allowlist, paused gate |
| 6 | `TWAPBurner` | `src/core/TWAPBurner.sol` | Ownable | many setters, recoverToken |
| 7 | `AdaptiveFeeDistributor` | `src/core/AdaptiveFeeDistributor.sol` | Ownable | recoverToken only |
| 8 | `BuybackEngine` | `src/marketplace/BuybackEngine.sol` | AccessControl | DEFAULT_ADMIN + BUYBACK_OPERATOR |
| 9 | `LuminaBondMarketplace` | `src/marketplace/LuminaBondMarketplace.sol` | AccessControl | DEFAULT_ADMIN + FEE_MANAGER + emergencyCancel (post-H12) |
| 10 | `ShieldKeeper` | `src/automation/ShieldKeeper.sol` | Ownable | pause/unpause |
| 11 | `CapacityOracle` | `src/oracles/CapacityOracle.sol` | Ownable | setEmergencyPrice / setPool / setTwapWindow |
| 12 | `SolvencyOracle` | `src/oracles/SolvencyOracle.sol` | AccessControl | DEFAULT_ADMIN + ADMIN (pause) |
| 13 | `ChainlinkGraceOracle` | `src/oracles/ChainlinkGraceOracle.sol` | **AccessControl** | NEW post-H13: feed mgmt (`ADMIN_ROLE`) + permissionless mark up/down (self-validating) |
| 14 | `CEXLiquidityReserve` | `src/treasury/CEXLiquidityReserve.sol` | AccessControl | DEFAULT_ADMIN + ALLOCATOR + initializeV2 + setMonthlyCap (post-H2, on `feat/cex-reserve-mutable-cap`) |
| 15 | `MaintenanceReserve` | `src/treasury/MaintenanceReserve.sol` | AccessControl | DEFAULT_ADMIN + SPENDER |
| 16 | `TreasuryVesting` | `src/token/TreasuryVesting.sol` | Ownable | release + nonReentrant (post-H9) |
| 17 | `FounderVesting` | `src/token/FounderVesting.sol` | **Immutable** | recipient-only; OracleFailure events post-H7 |
| 18 | `BaseShield` (abstract, parent of 9 shields) | `src/products/BaseShield.sol` | Ownable | onlyRouter on policy lifecycle; chainlinkGraceAsset() getter post-H13 |

**Plus 9 concrete Shield products** (FlashBTC 1h/4h/24h/48h, FlashETH 1h/24h/48h,
MicroDepeg, RateShock) — they inherit BaseShield; admin surface is identical except
each one returns a different `chainlinkGraceAsset()` constant.

---

## 2. Master Function × Role Matrix

Legend:
- **`OW`** = `onlyOwner` (Ownable)
- **`DAR`** = `DEFAULT_ADMIN_ROLE`
- **`AC=X`** = `onlyRole(X)` for any other role X
- **`oR`** = `onlyRouter` (custom modifier — `msg.sender == router`)
- **`oA`** = `onlyAuthorizedOperator` / `authorizedCallers` map check
- **`R`** = `recipient` literal address (FounderVesting only)
- Multiple gates separated by `+`.

### 2.1 token/

#### `LuminaTokenV2.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `DAR` | UUPS admin |
| `grantRole`, `revokeRole`, `renounceRole` | role admin (DAR for all) | OZ default |
| `burnFrom(addr, amt)` | `AC=BURNER_ROLE` | Granted to TWAPBurner only post-deploy. **`[POST-FIX H-1]`** now requires `allowance(holder, sender) >= amt` (was unchecked). |

#### `TreasuryVesting.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `release(address to, uint256 amount)` | `OW` + `nonReentrant` | **`[POST-FIX H-9]`** added `nonReentrant`. Signature is `(to, amount)` — the owner specifies destination + how much to release. Internal accumulator uses delta updates rather than overwrite. |
| `recoverToken(token, amt)` | `OW` | rescue path (cannot rescue LUMINA via guard) |

#### `FounderVesting.sol` (immutable)

| Function | Gate | Notes |
|---|---|---|
| `claim()` | `R` (= recipient) | only the configured recipient can pull vested tokens |
| `updateRecipient(addr)` | `R` (= recipient) | self-transfer |
| **`OracleFailure(...)` event** | n/a — emitted | **`[POST-FIX H-7]`** vesting halts emit `OracleFailure` so off-chain monitoring can detect oracle drops; no admin gate (the contract is immutable, no admin exists). |

### 2.2 bonds/

#### `BondVault.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `DAR` | UUPS admin |
| `setAuthorizedCaller(addr, bool)` | `AC=AUTHORIZED_CALLER_ADMIN_ROLE` | privilege-separated from DAR |
| `decreaseObligations(addr, amt)` | `oA` (`authorizedCallers[msg.sender]`) | ClaimBond + Marketplace |
| `burnFromReserves(amt)` | `oA` (`authorizedCallers[msg.sender]`) | 5% per-tx cap |
| `recoverToken / recoverERC1155` | `DAR` | rescue path |

#### `ClaimBond.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `setBondVault(addr)` | `OW` | one-shot via `_bondVaultSet` |
| `setBaseURI(string)` | `OW` | metadata only |
| `setAuthorizedOperator(addr, bool)` | `OW` | per-bond NFT operator allowlist |
| `setMarketplaceEscape(addr)` | `OW` | **`[POST-FIX H-12]`** sets the marketplace addr that may invoke `escapeTransfer` during emergencyCancel flow |
| `escapeTransfer(to, id, amt)` | `msg.sender == marketplaceEscape` + mutex `_escapeInProgress` | **`[POST-FIX H-12]`** bypass-transfer used by marketplace's `emergencyCancel`; only callable by the configured marketplace address (set via `setMarketplaceEscape`), and redesigned post-FUv2 to mutex via `_escapeInProgress` flag instead of a global address bypass (narrows the bypass window to the duration of one Marketplace transaction). The `from` address is implicit — escape pulls from the listing's seller, recorded in the Marketplace listing struct. |

> **C-3 note:** The fix C-3 modifies `BondVault` (not ClaimBond) — see
> `BondVault.sol` row below. C-3 is **constants-only** (`MIN_REDEEM_PRICE`
> raised, `MAX_REDEEM_PRICE` added) plus a stricter `_getSafePrice()`
> internal that reverts on oracle failure. **No new admin function** was
> added by C-3.

### 2.3 core/

#### `PolicyManagerV2.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `setRouter(addr)` | `OW` | one-shot |
| `registerProduct(bytes32 id, addr)` | `OW` | adds shield to allowlist |
| `deactivateProduct(bytes32)` | `OW` | sets `productActive = false` |
| `reactivateProduct(bytes32)` | `OW` | **`[POST-FIX H-5 follow-up]`** ⚠️ **PENDING MERGE** — implemented on branch `feat/reactivate-product`, not yet on `main`. Reverses `deactivateProduct` so triggers on existing policies become callable again. |
| `recordPolicy(...)` | `oR` | only Router |
| `triggerPayout(...)` | `oR` + `productActive == true` | **`[POST-FIX H-5]`** added the `productActive` check via `revert ProductNotActive` |

> ⚠️ **PRE-MAINNET RELEASE NOTE — `reactivateProduct`**
>
> This function is **NOT in `main` yet**. It is implemented on branch
> `feat/reactivate-product` (created as a follow-up to FIX #9 / H-5) and
> is pending the consolidated squash-merge of all 16+ V5.1 audit-fix
> branches before mainnet deploy.
>
> **Workaround pre-merge** (NOT recommended as official pattern): re-call
> `registerProduct(productId, shieldAddress)` — its side-effect sets
> `productActive = true`, but it also re-emits `ProductRegistered`,
> which downstream indexers may treat as a brand-new product. Operators
> should wait for the merge and use `reactivateProduct` post-mainnet.

#### `CoverRouterV2.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `configureProduct(...)` | `OW` | per-product params |
| `setRelayer(addr, bool)` | `OW` | relayer allowlist |
| `setPaused(bool)` | `OW` | global circuit breaker |
| `setPolicyManager(addr)` | `OW` | rewire |
| `setTwapBurner(addr)` | `OW` | rewire fee sink |
| `setCapacityOracle(addr)` | `OW` | rewire capacity feed |
| `recoverToken(token, amt)` | `OW` | rescue |
| `submitTrigger(...)` | relayer + `whenNotPaused` | **`[POST-FIX H-4]`** added `whenNotPaused`; previously only relayer-gated |
| `syncCircuitBreaker()` | permissionless (by design — sync from solvency oracle) | documented as intentional in audit #28 |

#### `TWAPBurner.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `setPoolFee`, `setMaxSlippageBps`, `setMinBurnAmount`, `setMaxBurnAmount`, `setBurnCooldown`, `setAuthorizedSender`, `setCapacityOracle`, `setDexRouters`, `addDexRouter`, `setFeeDistributor`, `setReserves`, `setMaintenanceReserve`, `setAdaptiveMode` | `OW` | all setters |
| `recoverToken(token, amt)` | `OW` | rescue. **`[POST-FIX H-10]`** TWAP momentum logic added behind setters — same gates, no new admin surface. |

#### `AdaptiveFeeDistributor.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `recoverToken(token, amt)` | `OW` | rescue |

### 2.4 marketplace/

#### `BuybackEngine.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `DAR` | UUPS admin |
| `setDailyBuyback(budget, maxPct, hours)` | `AC=BUYBACK_OPERATOR_ROLE` | maxPct ≤ 95, hours ≤ 72 |
| `executeOffer(bondId, ...)` | `AC=BUYBACK_OPERATOR_ROLE` + `nonReentrant` | settles a bond purchase |
| `grantRole/revokeRole/renounceRole` | role admin | OZ default |

#### `LuminaBondMarketplace.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `DAR` | UUPS admin |
| `setTwapBurner(addr)` | `AC=FEE_MANAGER_ROLE` | rewire fee sink |
| `emergencyCancel(listingId)` | `seller-of-listing OR DAR` + `nonReentrant` | **`[POST-FIX H-12]`** cancels a listing and returns the bond NFT to the original seller via `ClaimBond.escapeTransfer`. Destination is hard-coded to `l.seller` so admin cannot redirect to a third party. Mutex-protected on ClaimBond's side. |

### 2.5 automation/

#### `ShieldKeeper.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `pause()` | `OW` | freezes Chainlink Automation upkeep |
| `unpause()` | `OW` | thaws |

### 2.6 oracles/

#### `CapacityOracle.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `setPool(addr)` | `OW` | Uniswap V3 pool target |
| `setTwapWindow(uint32)` | `OW` | bounded `[5min, 2h]` |
| `setEmergencyPrice(uint256)` | `OW` | non-zero invariant |

#### `SolvencyOracle.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `DAR` | UUPS admin |
| `setEmergencyPause(bool)` | `AC=ADMIN_ROLE` | guardian pause path |
| `getSolvencyRatio()`, `_calculateSolvencyRatio()` (internal) | view (permissionless) | **`[POST-FIX H-11]`** when total obligations == 0, the internal calc returns `SOLVENCY_HEALTHY_BPS` (10_000) instead of dividing by zero; surfaced via `getSolvencyRatio`, `getCurrentQuadrant`, `isHealthy`. |
| `grantRole/revokeRole/renounceRole` | role admin | OZ default |

#### `ChainlinkGraceOracle.sol` (NEW post-H-13, AccessControl)

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `DAR` | UUPS admin |
| `setFeed(bytes32 asset, addr feed, uint256 heartbeat)` | `AC=ADMIN_ROLE` | **`[POST-FIX H-13]`** binds an asset symbol (`BTC`, `ETH`, `USDC`) to a Chainlink aggregator + sets its heartbeat in the same call |
| `setHeartbeat(bytes32 asset, uint256 sec)` | `AC=ADMIN_ROLE` | **`[POST-FIX H-13]`** per-asset staleness bound (overrides the value set by setFeed) |
| `setSequencerFeed(addr)` | `AC=ADMIN_ROLE` | **`[POST-FIX H-13]`** L2 sequencer uptime feed (Chainlink) |
| `setOracleKey(addr)` | `AC=ADMIN_ROLE` | **`[POST-FIX H-13]`** rotates the oracle's signing key |
| `markChainlinkDown(bytes32 asset)` | **permissionless** + `_isFeedDown(asset)` self-check | **`[POST-FIX H-13]`** opens a downtime window. Caller does **not** need a role; the function reverts unless the feed is independently observable as down (revert / stale round). Idempotent. |
| `markChainlinkUp(bytes32 asset)` | **permissionless** + `!_isFeedDown(asset)` self-check | **`[POST-FIX H-13]`** closes the downtime window. Caller does not need a role; reverts unless the feed has independently recovered. |
| `getLatestPrice`, `isInGracePeriod`, `getDowntime`, etc. | view (permissionless) | shields call these |
| `grantRole/revokeRole/renounceRole` | role admin | OZ default |

> ### Design Decision: Grace Period is Derived (NOT Configurable)
>
> The grace period extended to policies after a Chainlink / sequencer
> downtime is **NOT an admin-configurable parameter**. It is computed
> automatically from:
>
> 1. The actual on-chain downtime duration (delta between
>    `markChainlinkDown` timestamp and `markChainlinkUp` timestamp).
> 2. The protocol-wide cap `MAX_GRACE_EXTENSION = 30 days` (constant on
>    `BaseShield`).
>
> There is **no `setGracePeriod`** function and none will be added. The
> rationale is deliberate:
>
> - **No admin abuse vector** — admin cannot extend policy maturity
>   arbitrarily. The extension is bounded by observable downtime.
> - **Proportional remediation** — the extension granted to users is
>   proportional to the actual time during which their oracle was
>   unreadable, not a flat negotiated number.
> - **Operational simplicity** — no parameter to tune post-deploy, no
>   timelocked governance proposal needed during an incident.
>
> Admin functions actually present on `ChainlinkGraceOracle` (all gated
> on `ADMIN_ROLE`) are limited to:
>
> - `setFeed(asset, aggregator, heartbeat)` — bind asset symbol to a
>   Chainlink aggregator.
> - `setHeartbeat(asset, sec)` — adjust per-asset staleness bound.
> - `setSequencerFeed(addr)` — point the L2 sequencer uptime feed.
> - `setOracleKey(addr)` — rotate the oracle's signing key.
>
> `markChainlinkDown` / `markChainlinkUp` are **permissionless** — they
> self-validate against `latestRoundData` from the actual Chainlink
> feed, so no caller (admin or otherwise) can fabricate a downtime
> window.

### 2.7 treasury/

#### `CEXLiquidityReserve.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `DAR` | UUPS admin |
| `initializeV2()` | `DAR` + `reinitializer(2)` | **`[POST-FIX H-2]`** seeds the new mutable `monthlyCap` storage when upgrading from V1; one-shot via OZ reinitializer. Lives on branch `feat/cex-reserve-mutable-cap` (`/tmp/cap-mod`), not on a `fix-h2/` branch. |
| `setMonthlyCap(uint256 newCap)` | `DAR` | **`[POST-FIX H-2]`** previously a hardcoded `MONTHLY_CAP` constant; now mutable storage so multisig can adjust without an upgrade. Per memory, follow-up F-REVERSE-H2-1 asks whether to allow decrement or monotonic-only — **founder decision pending**. |
| `allocate(subBucket, amt, recipient)` | `AC=ALLOCATOR_ROLE` + `nonReentrant` | bucket-limited; consumes `totalAllocated` against `monthlyCap` |
| `recoverToken(token, amt, to)` | `DAR` + `nonReentrant` | rescue path |
| `grantRole/revokeRole/renounceRole` | role admin | OZ default |

#### `MaintenanceReserve.sol`

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `DAR` | UUPS admin |
| `setMonthlyCap(uint256)` | `DAR` | preserved from V1 |
| `recoverToken(token, amt)` | `DAR` | rescue |
| `spend(addr, amt)` | `AC=SPENDER_ROLE` + `nonReentrant` | enforces monthly cap |
| `grantRole/revokeRole/renounceRole` | role admin | OZ default |

### 2.8 products/ (BaseShield + 9 concrete shields)

`BaseShield` is abstract; each of the 9 concrete shields inherits it. The admin
surface below is identical for every shield instance.

| Function | Gate | Notes |
|---|---|---|
| `_authorizeUpgrade` | `OW` | UUPS admin |
| `setBeneficiary(addr)` | `OW` | recipient of shield's collected premia |
| `setOracle(addr)` | `OW` | per-shield Chainlink price feed wrapper |
| `chainlinkGraceAsset() returns (bytes32)` | view (`pure`-like override per child) | **`[POST-FIX H-13]`** added on BaseShield as `view`; each concrete shield overrides to return its asset symbol (`BTC` / `ETH` / `USDC`). Used by relayer + router to pick the right grace-period feed. **Not admin-gated.** |
| `createPolicy(...)` | `oR` | only Router |
| `verifyAndCalculate(...)` | `oR` | only Router |
| `markPaidOut`, `markExpired` | `oR` | only Router |

---

## 3. Roles inventory (consolidated)

| Role | Contracts | Granted at deploy to | Rotatable? | Risk if compromised |
|---|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | LuminaTokenV2, BondVault, BuybackEngine, Marketplace, CEXReserve, MaintenanceReserve, SolvencyOracle, ChainlinkGraceOracle *(post-H13)* | deployer or `_admin` ctor param | yes (multi-admin allowed) | upgrade to malicious impl, grant any role |
| `BURNER_ROLE` | LuminaTokenV2 | TWAPBurner (granted post-deploy) | yes | burn user balances up to allowance (post-H1) |
| `AUTHORIZED_CALLER_ADMIN_ROLE` | BondVault | deployer | yes | authorize attacker to drain reserves (5%/tx cap) |
| `BUYBACK_OPERATOR_ROLE` | BuybackEngine | `_multisigOwner` | yes | drain USDC budget (capped 95% maxPct, 72h duration) |
| `FEE_MANAGER_ROLE` | Marketplace | `_admin` | yes | redirect fee flow only (no listing drain) |
| `ADMIN_ROLE` | SolvencyOracle, ChainlinkGraceOracle *(post-H13)* | `_admin` | yes | SolvencyOracle: pause; ChainlinkGraceOracle: feed mgmt + key rotation |
| `ALLOCATOR_ROLE` | CEXLiquidityReserve | `_multisigOwner` | yes | allocate within bucket limits |
| `SPENDER_ROLE` | MaintenanceReserve | `_admin` | yes | spend within monthly cap |
| `Ownable.owner` | ClaimBond, PolicyManagerV2, CoverRouterV2, TWAPBurner, AdaptiveFeeDistributor, ShieldKeeper, 9 Shields, CapacityOracle, TreasuryVesting | deployer | 1-step `transferOwnership` (no Ownable2Step) | full setter surface + upgrade |
| `recipient` (literal address) | FounderVesting | constructor `_recipient` | self-transfer via `updateRecipient` | drain own vesting only |
| `authorizedCallers` (mapping) | BondVault | granted post-deploy by `AUTHORIZED_CALLER_ADMIN_ROLE` to ClaimBond + Marketplace | yes | `decreaseObligations` / `burnFromReserves` (5%/tx cap) |
| `authorizedOperator` (per-bond) | ClaimBond | per-bond by owner | yes | NFT-level operator |
| `marketplaceEscape` (single addr) | ClaimBond | `setMarketplaceEscape` (owner) | yes | trigger `escapeTransfer` only inside its own mutex |

---

## 4. Risk analysis by role

### DEFAULT_ADMIN_ROLE
- **Powers:** UUPS upgrade, role grant/revoke. Can grant itself any other role on the same contract.
- **Worst case:** upgrade to malicious impl on any of 7 AC contracts → drain reserves, mint LUMINA, redirect fees.
- **Mitigations recommended pre-mainnet:** 48h timelock + 3-of-5 multisig (see `04-PRE-MAINNET-RECOMMENDATIONS.md`). Until then, deployer EOA is sole admin — explicitly flagged in `03-PUBLIC-ADMIN-DISCLOSURE.md`.

### Ownable.owner
- **Powers:** UUPS upgrade + every `setX` setter on 13 contracts + 9 shields = 22 distinct `transferOwnership` boundaries.
- **Worst case:** `recoverToken(LUMINA, MAX)` on TWAPBurner before a burn settles; redirect `setPolicyManager` → attacker; etc.
- **Mitigation:** same as DEFAULT_ADMIN_ROLE. **Open risk RISK-1:** OZ uses 1-step `transferOwnership` — typo is irreversible if the destination is a contract that cannot call accept. Deferred to C-5 (Timelock) — see §6.

### Operational roles (BUYBACK_OPERATOR, ALLOCATOR, SPENDER, BURNER, FEE_MANAGER, ADMIN_ROLE, AUTHORIZED_CALLER_ADMIN_ROLE)
- **Designed for daily ops** — rotated more frequently than admin.
- **Caps in place** — every operational role has hard upper bounds in code (5% per tx, 95% maxPct, monthly cap, etc).
- **Compromise blast radius is bounded** by those caps; admin role is required to *bypass* a cap (via upgrade).

### Permissionless functions (intentional, not findings)
- `CoverRouterV2.syncCircuitBreaker()` — anyone can sync the breaker from SolvencyOracle. Documented as design in audit #28.
- `ChainlinkGraceOracle.isInGracePeriod()` — public view; relayer + shields read it. **`[POST-FIX H-13]`**

---

## 5. Post-fix function index (added/changed during audit fixes)

For auditor cross-reference. Each entry: function → fix that introduced or modified it.

| Function | Contract | Fix | Status | Change |
|---|---|---|---|---|
| `burnFrom` | LuminaTokenV2 | H-1 | ✅ implemented | **changed:** now requires `allowance(holder, sender) >= amt` |
| `MIN_REDEEM_PRICE` (constant) + `_getSafePrice` | BondVault | C-3 | ✅ implemented | **changed:** floor raised 0.001→0.005 USD; oracle failure now reverts (was silent fallback) |
| `triggerPayout` | PolicyManagerV2 | H-5 | ✅ implemented | **changed:** added `productActive` check via `revert ProductNotActive` |
| `reactivateProduct` | PolicyManagerV2 | H-5 fu | ⚠️ **PENDING MERGE** | implemented on branch `feat/reactivate-product`; pending the V5.1 consolidated squash-merge. See pre-mainnet release note in §2.3. |
| `submitTrigger` | CoverRouterV2 | H-4 | ✅ implemented | **changed:** added `whenNotPaused` modifier |
| `OracleFailure` event | FounderVesting | H-7 | ✅ implemented | **new event** (no admin gate) |
| `release` | TreasuryVesting | H-9 | ✅ implemented | **changed:** added `nonReentrant` (signature changed: now `release(address to, uint256 amt)`) |
| (TWAP momentum logic) | TWAPBurner | H-10 | ✅ implemented | **internal change** — no new admin surface |
| `getSolvencyRatio` (+ internal `_calculateSolvencyRatio`) | SolvencyOracle | H-11 | ✅ implemented | **changed:** zero-obligation branch returns `SOLVENCY_HEALTHY_BPS` (10_000) instead of div-by-zero |
| `emergencyCancel` | LuminaBondMarketplace | H-12 | ✅ implemented | **new** |
| `setMarketplaceEscape` | ClaimBond | H-12 | ✅ implemented | **new** |
| `escapeTransfer` | ClaimBond | H-12 fu² | ✅ implemented | **new** (mutex-redesigned in fu²) |
| `initializeV2` | CEXLiquidityReserve | H-2 | ✅ implemented (in `/tmp/cap-mod`, branch `feat/cex-reserve-mutable-cap`) | DAR reinitializer; seeds `monthlyCap` storage |
| `setMonthlyCap` | CEXLiquidityReserve | H-2 | ✅ implemented (same branch) | DAR-gated mutable cap |
| `setFeed`, `setHeartbeat`, `setSequencerFeed`, `setOracleKey` | ChainlinkGraceOracle | H-13 | ✅ implemented | **new contract** (AccessControl, `ADMIN_ROLE`) |
| `markChainlinkDown`, `markChainlinkUp` | ChainlinkGraceOracle | H-13 | ✅ implemented | **permissionless by design** — feed-down self-check inside |
| `setGracePeriod` | ChainlinkGraceOracle | H-13 | ✅ **by design — derived, not a setter** | Grace period is auto-computed from `markChainlinkDown` / `markChainlinkUp` timestamps, capped by `BaseShield.MAX_GRACE_EXTENSION = 30 days`. No admin parameter exists; see Design Decision box in §2.6. |
| `chainlinkGraceAsset()` | BaseShield + 9 shields | H-13 fu | ✅ implemented | **new view** (not admin-gated) |

---

## 5b. Implementation gaps discovered during M-1 doc sync

The doc sync surfaced three items the M-1 input listed as "fixes already
done" that are **not actually implemented in any branch**. This is a
finding of the doc-sync sprint itself: the audit-fix inventory the
founder is reasoning from has drifted from on-chain reality.

| ID | Spec'd in | Spec'd as | Actual state in `/tmp/fix-*` |
|---|---|---|---|
| ~~**GAP-1**~~ (resolved) | M-1 input bullet "Follow-up FIX #9: reactivateProduct nueva función" | New `reactivateProduct(bytes32)` on PolicyManagerV2 | ✅ **Implemented** on branch `feat/reactivate-product` (separate from the H-5 branch, which is why initial M-1 grep against `fix-h5/` missed it). Pending the V5.1 consolidated squash-merge to `main` before mainnet deploy. **No additional code change needed.** Pre-mainnet release note added to §2.3 + per-doc disclaimer. |
| ~~**GAP-2**~~ (resolved) | M-1 input bullet "FIX #4 (H-2): CEXReserve initializeV2 + setMonthlyCap mutable" | Reinitializer + mutable monthly cap on `CEXLiquidityReserve` | ✅ **Implemented** — but on branch `feat/cex-reserve-mutable-cap` (`/tmp/cap-mod`), not the assumed `/tmp/fix-h2/`. Initial M-1 validation looked only at `/tmp/fix-*` paths and missed it. Memory `lumina_audit_fixes_status.md` correctly listed the path. **No follow-up code change needed.** Pending operational follow-ups (per that memory): F-AUDIT-1 (gate `initializeV2` — already gated in actual code, audit suggestion is cosmetic), F-AUDIT-2 (atomic upgrade-and-init script), F-REVERSE-H2-1 (decrement vs monotonic-only — founder decision). |
| ~~**GAP-3**~~ (resolved — design decision) | M-1 input bullet "FIX #16 (H-13): … `setGracePeriod`" | `setGracePeriod` setter on ChainlinkGraceOracle | ✅ **By design, no such setter exists.** Grace period is auto-computed from observable downtime (`markChainlinkDown`/`Up` timestamps), bounded by `BaseShield.MAX_GRACE_EXTENSION = 30 days`. Founder-confirmed design decision: avoid admin abuse vector + proportional remediation + operational simplicity. **No code change.** Full rationale documented in §2.6 (Design Decision box). |
| **GAP-4** | (none — discovered during validation) | ChainlinkGraceOracle is **AccessControl**, not Ownable as the M-1 input implied | Confirmed: `setFeed`/`setHeartbeat`/`setSequencerFeed`/`setOracleKey` use `onlyRole(ADMIN_ROLE)`; `_authorizeUpgrade` uses `DEFAULT_ADMIN_ROLE`. `markChainlinkDown`/`markChainlinkUp` are **permissionless** (self-validating). Documented correctly in §2.6. |

**Recommendation:** before the next audit-fix sprint, the founder should
either implement GAP-1 and GAP-2 inline, or formally move them out of
the post-audit fix list. The M-1 doc reflects current reality (gap
flagged), not the aspirational state.

---

## 6. Deferred risks (NOT fixed in this sprint — tracked for future audit)

These are documented here so the matrix is unambiguous about what is **NOT** mitigated at the contract level. They are gated to follow-up audits or operational controls.

| ID | Title | Where it surfaces | Mitigation path |
|---|---|---|---|
| **C-2** | MaintenanceReserve has no hard balance ceiling | `MaintenanceReserve.spend` enforces only monthly cap | Operational: multisig refuses funding > `(monthlyCap × N months)`. To be revisited if a hardcoded ceiling is added. |
| **C-4** | BondVault has no manual `pause()` | `BondVault` uses authorizedCallers-list as kill-switch instead | Operational: revoke all `authorizedCallers` → effective pause. |
| **C-5** | No on-chain Timelock contract — admin actions execute immediately | Every `OW` / `DAR` row in §2 | Pre-mainnet: deploy 48h Timelock as the actual owner of every Ownable + holder of every DEFAULT_ADMIN. See `04-PRE-MAINNET-RECOMMENDATIONS.md`. |
| **H-3** | (covered by C-5) | n/a | n/a |
| **H-8** | (covered by C-5) | n/a | n/a |
| **M-4** | (covered by C-5) | n/a | n/a |
| **F-REVERSE-H-1** | After H-1 fix, an attacker who later gains DEFAULT_ADMIN_ROLE could re-introduce un-allowance-checked `burnFrom` via UUPS upgrade | LuminaTokenV2 upgrade path | Same as C-5 — Timelock + multisig on the upgrade gate. Code-level mitigation would require renouncing DAR, which is a separate decision (RISK-2 in `29-role-rotation/01-ROLES-INVENTORY.md`). |

---

## 7. Validation snapshot

This document was generated by:
1. `scripts/extract_acl.py` — parses every `function … modifier {` from `src/**/*.sol`
   on the post-fix branch and emits a function × modifier table.
2. Manual annotation of `[POST-FIX X-Y]` rows from the per-fix sprint reports
   (commit messages on `fix/c3-*`, `fix/h1-*` … `fix/h13-*`).
3. Cross-reference with the prior `01-ADMIN-POWERS-INVENTORY.md` and
   `29-role-rotation/01-ROLES-INVENTORY.md` to make sure no contract was
   silently dropped.

Re-run command (post-merge):
```bash
python3 scripts/extract_acl.py > /tmp/acl_check.md
diff <(awk '/^### /,0' docs/audit/v5.1-uups/04-admin-key-risk/ACCESS-CONTROL-MATRIX-V5.1.md) /tmp/acl_check.md
```

Any new admin function added to `src/` should appear in the diff if this matrix
is not updated alongside.
