# V5.1 UUPS Admin Powers Inventory

**Audit:** V5.1 #4 — Admin Key Risk
**Branch:** `audit/v5.1-04-admin-key-risk`
**Date:** 2026-04-22 (refreshed 2026-04-30 for audit-fix M-1 sync)

This document catalogues **every admin-only function** on every UUPS
upgradeable contract, the **worst-case impact** if the admin key is
compromised or behaves maliciously, and the **existing + recommended
mitigations**.

> **See also:** `ACCESS-CONTROL-MATRIX-V5.1.md` is the auditor-facing master
> matrix of *function × role* for the post-fix codebase, including every
> admin function added or modified during the C/H audit-fix sprints. This
> document focuses on **risk + mitigation narrative**; the matrix focuses
> on **call gating**.

---

## Per-Contract Breakdown

### 1. LuminaTokenV2
- **Auth model:** AccessControlUpgradeable. `msg.sender` (deployer) receives
  `DEFAULT_ADMIN_ROLE`. `BURNER_ROLE` is granted to TWAPBurner at deploy
  time as a legacy/reserved hook; **post [Fix H-1] no in-protocol path
  consults it** (TWAPBurner and BondVault burn their own balance via
  `burn(uint256)`).
- **Admin-only functions:**
  - `_authorizeUpgrade(newImpl)` — `DEFAULT_ADMIN_ROLE`
  - `grantRole / revokeRole / renounceRole` — role admin
  - `burnFrom(account, amount)` — **standard ERC20Burnable allowance check
    [Fix H-1]**; caller must hold `account`'s prior `approve` for `amount`.
    Not gated by BURNER_ROLE.
- **Max risk:**
  - Upgrade to malicious impl that mints unlimited LUMINA → dilution to zero.
  - ~~Grant `BURNER_ROLE` to arbitrary address → burn user balances.~~
    **[Fix H-1] No longer reachable** — `burnFrom` requires the holder's
    allowance regardless of role membership. Granting BURNER_ROLE alone no
    longer authorizes burning third-party balances.
- **Impact:** CRITICAL — $LUMINA supply is the monetary anchor of the
  protocol. Total affected supply: 100M LUMINA. (The `burnFrom`-via-role
  vector is closed by [Fix H-1]; the residual CRITICAL is the upgrade
  authority.)
- **Existing mitigations:** `constructor { _disableInitializers(); }`; roles
  are namespaced; `BURNER_ROLE` separate from admin and **no longer
  load-bearing for `burnFrom` after [Fix H-1]**.
- **Recommended mitigations (pre-mainnet):** 48h timelock on upgrade; 3-of-5
  multisig for admin; on-chain monitoring of `Upgraded` and `RoleGranted`
  events; eventual `renounceRole(DEFAULT_ADMIN_ROLE)` once burner is stable.

### 2. BondVault
- **Auth:** AccessControlUpgradeable. `msg.sender` receives
  `DEFAULT_ADMIN_ROLE` and `AUTHORIZED_CALLER_ADMIN_ROLE`.
- **Admin-only functions:**
  - `_authorizeUpgrade` — `DEFAULT_ADMIN_ROLE`
  - `setAuthorizedCaller(address, bool)` — `AUTHORIZED_CALLER_ADMIN_ROLE`
  - `grantRole / revokeRole / renounceRole`
- **Max risk:**
  - Authorize an attacker address as caller → attacker invokes
    `burnFromReserves()` or `decreaseObligations()` and drains the 70M LUMINA
    reserve.
  - Upgrade to drain-impl.
- **Impact:** CRITICAL — $70M LUMINA at 100% reserve ratio.
- **Existing mitigations:** 5% cap per burn; ReentrancyGuard; only authorized
  callers can reduce obligations.
- **Recommended:** 48h timelock; multisig; monitor `AuthorizedCallerSet`.

### 3. ClaimBond (ERC-1155)
- **Auth:** OwnableUpgradeable. Owner = deployer.
- **Admin-only functions:**
  - `_authorizeUpgrade` — owner
  - `setBondVault(address)` — owner (one-shot; `_bondVaultSet` gate)
  - `setBaseURI(string)` — owner (metadata)
  - `setAuthorizedOperator(addr, bool)` — owner (per-bond NFT operator allowlist)
  - `setMinRedeemPrice(price)` — owner *(post-fix C-3)*
  - `setMarketplaceEscape(addr)` — owner *(post-fix H-12)*
- **Other gating (not admin-bound):**
  - `escapeTransfer(from, to, id, amt)` — gated by mutex
    `_escapeInProgress` set by Marketplace during `emergencyCancel`
    *(post-fix H-12 fu²)*. Bypasses normal transfer rules but is
    callable only inside one Marketplace transaction.
- **Max risk:** Upgrade to malicious impl that re-mints NFT claims for
  attackers. `setBondVault` is gated to single use so it cannot be changed
  once set. `setMarketplaceEscape` could redirect to attacker — but
  `escapeTransfer` only runs while Marketplace asserts the mutex, so the
  bypass window is the duration of one tx.
- **Impact:** HIGH — attackers could mint claim tokens and redeem them
  against BondVault.
- **Existing mitigations:** `_bondVaultSet` one-shot; ERC-1155 namespace;
  `_escapeInProgress` mutex narrows the H-12 bypass to a single Marketplace
  transaction.
- **Recommended:** Same as BondVault.

### 4. PolicyManagerV2
- **Auth:** OwnableUpgradeable. Owner = deployer.
- **Admin-only functions:**
  - `_authorizeUpgrade` — owner
  - `setRouter(address)` — owner
  - `registerProduct(bytes32, address)` — owner
  - `deactivateProduct(bytes32)` — owner (post-H-5: gates both
    `recordPolicy` for new policies **and** `triggerPayout` for pre-existing
    policies; flips `productActive[productId] = false`)
  - `reactivateProduct(bytes32)` — owner. Symmetric pair to
    `deactivateProduct`; same modifier (`onlyOwner`), no timelock (consistent
    with deactivate). Emits `ProductReactivated(productId)`. Reverts if the
    product was never registered or is already active. Mitigates the
    "deactivation is irreversible / false-positive in crisis" risk: a product
    deactivated in error (e.g. mistaken trigger, transient oracle anomaly) can
    now be restored without redeploying or re-registering. Post-H-5
    `triggerPayout` checks `productActive`, so reactivation is also the only
    path to restore payout capability for legacy policies that became
    "stuck" after a deactivation.
- **Max risk:** Register malicious shield that mints claims; deactivate
  legitimate products to halt user claims; set router to attacker EOA.
  `reactivateProduct` does not add new max-risk surface — it can re-enable a
  previously deactivated product, but it cannot register new products or
  bypass the existing shield-registration controls.
- **Impact:** HIGH — policy lifecycle can be hijacked.
- **Existing mitigations:** `productActive` flag (checked in both
  `recordPolicy` and `triggerPayout` post-H-5 fix; bonds already minted
  remain redeemable via BondVault — out of scope for the gate); event
  emissions on every state change (`ProductDeactivated` /
  `ProductReactivated`).
- **Recommended:** Multisig + 48h timelock on `setRouter` and
  `registerProduct`. `deactivateProduct` / `reactivateProduct` may stay
  timelock-free as emergency / corrective levers, but both should fire from
  the multisig and be monitored on-chain.

### 5. CoverRouterV2
- **Auth:** OwnableUpgradeable. Owner = deployer.
- **Admin-only functions:**
  - `_authorizeUpgrade` — owner
  - `setRelayer(address, bool)` — owner
  - `setPaused(bool)` — owner. Gates 3 user-facing surfaces via the
    `whenNotPaused` modifier: `purchasePolicy`, `purchasePolicyFor`, **and
    `submitTrigger` (post-H-4)**. Bond redemption on BondVault is
    intentionally **not** gated, so legitimate already-triggered policies
    can still be redeemed by users while the router is paused.
  - `setPolicyManager(address)` — owner
  - `setTwapBurner(address)` — owner
  - `setCapacityOracle(address)` — owner
  - `configureProduct(...)` — owner (with `active` flag)
  - `recoverToken(token, amt)` — owner
- **Hot-path gating (post-fix H-4):** `submitTrigger` is now
  `whenNotPaused` *and* relayer-only. Pause therefore short-circuits
  trigger submission even if a relayer key is compromised.
- **Max risk:** Set `policyManager`/`twapBurner` to attacker contracts;
  configure products with zero payout; pause forever.
- **Impact:** HIGH — user-facing router can be misdirected.
- **Existing mitigations:** Event emissions on every setter; `setPaused`
  acts as the multisig's circuit breaker covering policy purchase **and**
  trigger submission (audit V5.1 fix H-4).
- **Recommended:** Timelock + multisig.

### 6. TWAPBurner
- **Auth:** OwnableUpgradeable. Owner = deployer.
- **Admin-only functions:** `_authorizeUpgrade`, `setPoolFee`, `setMaxSlippageBps`, `setMinBurnAmount`, `setMaxBurnAmount`, `setBurnCooldown`, `setAuthorizedSender`, `setCapacityOracle`, `setDexRouters`, `addDexRouter`, `setFeeDistributor`, `setReserves`, `setMaintenanceReserve`, `setAdaptiveMode`, `recoverToken`.
- **Max risk:** `recoverToken(lumina, MAX)` could drain pre-burn balance;
  set `maxSlippageBps` very high so burns accept bad prices; point DEX
  routers to attacker contracts.
- **Impact:** HIGH — protocol fees pass through this contract.
- **Existing mitigations:** Ranges on slippage/cooldown; ReentrancyGuard;
  `setReserves` zero-address checks.
- **Recommended:** Disable `recoverToken` for LUMINA via timelock hook;
  governance-only `setDexRouters`.

### 7. AdaptiveFeeDistributor
- **Auth:** OwnableUpgradeable.
- **Admin-only:** `_authorizeUpgrade`.
- **Max risk:** Upgrade to malicious distribution logic.
- **Impact:** MEDIUM — affects only fee-split ratios.
- **Existing:** Trivial layout; no setters beyond upgrade.
- **Recommended:** Timelock.

### 8. BuybackEngine
- **Auth:** AccessControlUpgradeable. `_multisigOwner` param receives
  `DEFAULT_ADMIN_ROLE` + `BUYBACK_OPERATOR_ROLE`.
- **Admin-only functions:**
  - `_authorizeUpgrade` — `DEFAULT_ADMIN_ROLE`
  - `setDailyBuyback(budget, maxPct, hours)` — `BUYBACK_OPERATOR_ROLE`
  - `grantRole / revokeRole / renounceRole`
- **Max risk:** Operator sets absurdly high `maxPricePercent` (capped at 95%)
  and large `dailyBudget` → overpays for claim bonds relative to face value.
- **Impact:** HIGH — drains USDC budget.
- **Existing:** `maxPct ≤ 95`, `duration ≤ 72h`, nonReentrant execution.
- **Recommended:** Hard per-day USDC ceiling; multisig for `setDailyBuyback`.

### 9. LuminaBondMarketplace
- **Auth:** AccessControl. `_admin` param receives
  `DEFAULT_ADMIN_ROLE` + `FEE_MANAGER_ROLE`.
- **Admin-only:** `_authorizeUpgrade` (DAR), `setTwapBurner` (FEE_MANAGER),
  `emergencyCancel(listingId)` (DAR) *(post-fix H-12)*.
- **`emergencyCancel` semantics:** cancels an active listing and returns
  the bond NFT to the seller via `ClaimBond.escapeTransfer`. The escape
  path is mutex-protected (`_escapeInProgress`) on ClaimBond's side, so
  Marketplace cannot use it for arbitrary transfers — only inside its own
  `emergencyCancel` tx.
- **Max risk:** Redirect fee flow by pointing `twapBurner` at attacker.
  `emergencyCancel` is admin-only and the bond returns to the *original
  seller*, so the worst case is a forced no-op cancellation rather than
  fund movement.
- **Impact:** MEDIUM — affects burn stream only; doesn't drain listings.
- **Recommended:** Timelock on `setTwapBurner`. `emergencyCancel` should
  remain admin-immediate (the whole point is fast unwinding).

### 10. ShieldKeeper
- **Auth:** OwnableUpgradeable.
- **Admin-only:** `_authorizeUpgrade`, `pause`, `unpause`.
- **Max risk:** Pause indefinitely — blocks automated policy settlement.
- **Impact:** LOW — does not lose funds, just freezes ops.
- **Recommended:** Emergency-guardian pattern (pause-only role separate from
  admin).

### 11. BaseShield (abstract) + 9 concrete Shield products
- **Auth:** OwnableUpgradeable on each child.
- **Admin-only:** `_authorizeUpgrade` on every shield.
- **Max risk:** Upgrade shield to impl that mis-computes triggers (false
  positives drain BondVault via PolicyManager; false negatives deny users).
- **Impact:** HIGH — payouts go through shields.
- **Existing:** onlyRouter gate on policy-lifecycle functions; Oracle-
  anchored triggers.
- **Recommended:** Timelock + multisig for shield upgrades specifically.

### 12. CapacityOracle
- **Auth:** OwnableUpgradeable.
- **Admin-only:** `_authorizeUpgrade`, `setPool`, `setTwapWindow`,
  `setEmergencyPrice`.
- **Max risk:** Set `emergencyPrice` to attacker-chosen value (e.g. 0) to
  manipulate `capacity` calculation in BondVault; point pool to manipulated
  Uniswap V3 pool.
- **Impact:** HIGH — governs available capacity for new policies.
- **Existing:** Range `twapWindow ∈ [5min, 2h]`; emergency price non-zero at
  init.
- **Recommended:** Timelock on `setEmergencyPrice` and `setPool`.

### 13. SolvencyOracle
- **Auth:** AccessControl. `_admin` param receives `DEFAULT_ADMIN_ROLE`
  and `ADMIN_ROLE`.
- **Admin-only:** `_authorizeUpgrade` (DAR), `setEmergencyPause`
  (`ADMIN_ROLE`).
- **Behavior change post-fix H-11:** `getSolvencyState()` returns
  `SOLVENCY_HEALTHY_BPS` (10_000) when total obligations == 0, instead of
  reverting on division-by-zero. No new admin surface.
- **Max risk:** Pause solvency oracle indefinitely; upgrade to force a
  specific solvency quadrant.
- **Impact:** HIGH — affects adaptive fee distribution and upgrade
  sequencing.
- **Recommended:** Timelock; pause separated into guardian role.

### 13b. ChainlinkGraceOracle (NEW post-fix H-13)
- **Auth:** **AccessControl** (not Ownable as originally spec'd).
  `_admin` ctor param receives `DEFAULT_ADMIN_ROLE` + `ADMIN_ROLE`.
- **Admin-only functions:**
  - `_authorizeUpgrade` — `DEFAULT_ADMIN_ROLE`
  - `setFeed(asset, feed, heartbeat)` — `ADMIN_ROLE`
  - `setHeartbeat(asset, sec)` — `ADMIN_ROLE`
  - `setSequencerFeed(addr)` — `ADMIN_ROLE`
  - `setOracleKey(addr)` — `ADMIN_ROLE`
- **Permissionless functions (self-validating, by design):**
  - `markChainlinkDown(asset)` — anyone can open a downtime window, BUT
    only when the feed is independently observable as down (revert /
    stale round). Idempotent. Reverts otherwise.
  - `markChainlinkUp(asset)` — anyone can close, but only after the feed
    has independently recovered.
- **No `setGracePeriod`** — the grace window is derived from the
  observable downtime, not an admin parameter (founder-confirmed
  design decision; see box below).

> ### Design Decision: Grace Period is Derived (NOT Configurable)
>
> The grace period extended to policies after a Chainlink / sequencer
> downtime is **NOT an admin-configurable parameter**. It is computed
> automatically from:
>
> 1. The actual on-chain downtime duration (delta between
>    `markChainlinkDown` and `markChainlinkUp` timestamps).
> 2. The protocol-wide cap `MAX_GRACE_EXTENSION = 30 days` (constant on
>    `BaseShield`).
>
> There is **no `setGracePeriod`** and none will be added. Rationale:
>
> - **No admin abuse vector** — admin cannot extend policy maturity
>   arbitrarily; extension is bounded by observable downtime.
> - **Proportional remediation** — extension is proportional to actual
>   time the oracle was unreadable, not a negotiated flat number.
> - **Operational simplicity** — no parameter to tune post-deploy, no
>   governance proposal needed mid-incident.
>
> Admin functions on `ChainlinkGraceOracle` (all `ADMIN_ROLE`-gated) are
> limited to `setFeed`, `setHeartbeat`, `setSequencerFeed`,
> `setOracleKey`. `markChainlinkDown`/`Up` are permissionless and
> self-validate against `latestRoundData`.
- **Max risk:** Set a feed to attacker-controlled aggregator → shields
  read manipulated price; set heartbeat to MAX → stale prices accepted.
  Mark up/down are self-validating so admin compromise can't fake them.
- **Impact:** HIGH — every Chainlink-anchored shield (BTC, ETH, MicroDepeg,
  RateShock) routes its grace-period check through this oracle.
- **Existing mitigations:** mark up/down are events-emitting;
  permissionless side keeps incident response open even if the admin
  multisig is unreachable.
- **Recommended:** Same as other oracles — multisig + timelock on
  `setFeed`, `setHeartbeat`, `setSequencerFeed`, `setOracleKey`.

### 14. CEXLiquidityReserve
- **Auth:** AccessControl. `_multisigOwner` receives `DEFAULT_ADMIN_ROLE` +
  `ALLOCATOR_ROLE`.
- **Admin-only:** `_authorizeUpgrade` (DAR), `initializeV2()` (DAR — gated
  in the Tier-1 redesign so a stranger cannot front-run the multisig and
  reset the cap to default mid-upgrade), `setMonthlyCap(uint256)` (DAR),
  `recoverToken(...)` (DAR), `allocate(...)` (`ALLOCATOR_ROLE`).
- **Max risk:** Allocate tokens to attacker address before multisig is
  finalized; or [Fix H-2] DAR raises `monthlyCap` to `MAX_MONTHLY_CAP` (14M)
  and ALLOCATOR drains the entire reserve in a single 30-day bucket.
- **Impact:** HIGH — CEX reserve (14M LUMINA).
- **Existing:** Single flat 14M reserve gated by lifetime ceiling
  `totalAllocated <= TOTAL_AMOUNT`; monthly cap (mutable storage,
  default `DEFAULT_MONTHLY_CAP = 1M`, ceiling `MAX_MONTHLY_CAP = 14M`,
  enforced `0 < newCap <= MAX_MONTHLY_CAP`); `MonthlyCapUpdated` event;
  nonReentrant. **Tier-1 redesign:** the V1 sub-bucket model (Immediate
  2.8M / Vesting 8.4M linear-730d / Strategic 2.8M locked-547d) has been
  removed; legacy storage slots 2/3/4 are preserved as
  `__deprecated_allocatedFrom*` for upgrade safety and seed `totalAllocated`
  exactly once via `initializeV2`.
- **Recommended:** Multisig at deploy; timelock on `allocate`,
  `setMonthlyCap`, and `initializeV2`; off-chain monitor on
  `MonthlyCapUpdated`.

### 15. MaintenanceReserve
- **Auth:** AccessControl. `_admin` param receives `DEFAULT_ADMIN_ROLE` +
  `SPENDER_ROLE`.
- **Admin-only:** `_authorizeUpgrade` (DAR), `setMonthlyCap(uint256)` (DAR),
  `recoverToken(...)` (DAR), `spend(...)` (`SPENDER_ROLE`).
- **Max risk:** `recoverToken` drain + `setMonthlyCap(MAX)` + spend → drain
  entire maintenance balance.
- **Impact:** MEDIUM — USDC maintenance budget.
- **Existing:** Monthly cap enforcement; nonReentrant.
- **Recommended:** Timelock on `recoverToken`; hardcoded cap of last-resort.

### 16. TreasuryVesting
- **Auth:** OwnableUpgradeable.
- **Admin-only:** `_authorizeUpgrade`, `release(uint256)`, `recoverToken`.
- **Behavior change post-fix H-9:** `release` now `nonReentrant` and
  uses delta accumulation (was: overwrite). This blocks the
  reentrancy-into-release attack and prevents accumulator under-counting.
  No new admin surface.
- **Max risk:** Release all vested tokens in a single call (capped by
  `lastReleaseMonth` schedule).
- **Impact:** HIGH — 3M LUMINA vest pool.
- **Existing:** Monotonic `lastReleaseMonth`; schedule-based release;
  `nonReentrant` (post-H-9).
- **Recommended:** Timelock on `release`; multisig.

### 17. FounderVesting (immutable, no admin)
- **Auth:** none — contract is **immutable**, no admin / no owner. Only
  the configured `recipient` address can call vesting fns.
- **Admin-bound functions:** none (recipient is *not* an admin role —
  it controls only its own vested tokens).
- **Behavior change post-fix H-7:** the contract emits an `OracleFailure`
  event when an oracle read fails during vesting calculation. No admin
  gate (impossible — no admin exists). The event is for off-chain
  monitoring so a stuck vesting can be diagnosed without a contract
  upgrade.
- **Impact:** N/A — no admin surface.
- **Recommended:** keep monitoring `OracleFailure` events; if they
  recur, the upgrade-path conversation has to go through governance and
  redeploy.

---

## Role Inventory (by role)

| Role | Contracts | Deployed grantees |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | LuminaTokenV2, BondVault, BuybackEngine, LuminaBondMarketplace, SolvencyOracle, CEXLiquidityReserve, MaintenanceReserve | deployer or `_admin` param |
| `AUTHORIZED_CALLER_ADMIN_ROLE` | BondVault | deployer |
| `BURNER_ROLE` | LuminaTokenV2 | TWAPBurner (set post-deploy; legacy grant — **not load-bearing post [Fix H-1]**, see §1) |
| `BUYBACK_OPERATOR_ROLE` | BuybackEngine | `_multisigOwner` param |
| `FEE_MANAGER_ROLE` | LuminaBondMarketplace | `_admin` param |
| `ADMIN_ROLE` | SolvencyOracle | `_admin` param |
| `ALLOCATOR_ROLE` | CEXLiquidityReserve | `_multisigOwner` param |
| `SPENDER_ROLE` | MaintenanceReserve | `_admin` param |
| `Ownable.owner` | ClaimBond, PolicyManagerV2, CoverRouterV2, TWAPBurner, AdaptiveFeeDistributor, ShieldKeeper, 9 Shields, CapacityOracle, TreasuryVesting | deployer |
| `ADMIN_ROLE` *(extended post-H13)* | SolvencyOracle, ChainlinkGraceOracle | `_admin` param |
| `recipient` (literal addr, not a role) | FounderVesting | constructor `_recipient` |

See `02-RISK-MATRIX.md` for the consolidated risk ranking.
