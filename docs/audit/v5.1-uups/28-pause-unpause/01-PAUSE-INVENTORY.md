# Audit V5.1 #28 — Pause/Unpause Inventory

Catalogue of every pause-like mechanism (manual toggle + automatic circuit breaker) across the 24 UUPS contracts + FounderVesting (immutable).

---

## 1. Contracts WITH pause mechanisms (3 of 25)

### 1.1 CoverRouterV2 (`src/core/CoverRouterV2.sol`)

**Pattern:** `bool public paused` + `setPaused(bool)` + `whenNotPaused` modifier.

| Field | Value |
|---|---|
| Access | `onlyOwner` |
| Blocked ops | `purchasePolicy` (line 137), `purchasePolicyFor` (line 149) |
| Allowed ops | `submitTrigger` (no modifier), `quotePremium`, `getProductConfig`, all views |
| Event | `Paused(bool state)` (line 85) |
| Idempotency | **Idempotent** — setPaused(true) twice is a no-op (not revert) |

### 1.2 ShieldKeeper (`src/automation/ShieldKeeper.sol`)

**Pattern:** `bool public paused` + `pause()` + `unpause()`.

| Field | Value |
|---|---|
| Access | `onlyOwner` |
| Blocked ops | `checkUpkeep` returns `(false, "")`; `performUpkeep` reverts with `KeeperPausedError` |
| Allowed ops | All view functions |
| Event | `KeeperUnpaused(address indexed by)` (line 47) — but **pause() emits NOTHING** (observability gap documented as INFO-6 below) |
| Idempotency | **Idempotent** (same plain-bool pattern) |

### 1.3 SolvencyOracle (`src/oracles/SolvencyOracle.sol`)

**Pattern:** `bool public emergencyPaused` + `setEmergencyPause(bool)`.

| Field | Value |
|---|---|
| Access | `ADMIN_ROLE` (AccessControl) |
| Blocked ops | `evaluate()` reverts with "Oracle paused" (line 72) |
| Allowed ops | `getSolvencyRatio`, `getCurrentQuadrant`, `isHealthy` (returns false when paused) |
| Event | `EmergencyPauseToggled(bool paused)` (line 46) |
| Idempotency | Idempotent (bool setter) |

---

## 2. Circuit breaker (automatic pause via price)

### CoverRouterV2.MIN_PRICE_FOR_NEW_POLICIES

`src/core/CoverRouterV2.sol:47`:

```solidity
uint256 public constant MIN_PRICE_FOR_NEW_POLICIES = 5e15;   // $0.005
uint256 public constant RESET_PRICE_FOR_NEW_POLICIES = 8e15; // $0.008
```

Evaluated at `_purchase` (line 175):

```solidity
if (address(capacityOracle) != address(0)) {
    uint256 luminaPrice = capacityOracle.getLuminaPrice();
    if (luminaPrice < MIN_PRICE_FOR_NEW_POLICIES) {
        revert("Protocol auto-paused: LUMINA price below safety threshold");
    }
}
```

- Blocks: new policy purchases (via `purchasePolicy` and `purchasePolicyFor`).
- Allows: triggers, redemptions, marketplace ops, everything else.
- Threshold check is `<` (strict), so price exactly at 5e15 is allowed.
- There is NO explicit "resume" code — auto-pause self-clears as soon as the oracle reports a price >= 5e15. `RESET_PRICE_FOR_NEW_POLICIES = 8e15` is defined but NOT used as a hysteresis check in V5.1 (potential improvement area).
- `isProtocolAutoPaused()` view function lets integrators inspect the state.

---

## 3. Contracts WITHOUT pause mechanisms (22 of 25)

### Fund-holding contracts — pause intentionally absent

| Contract | Rationale |
|---|---|
| **BondVault** | Must allow redemption at all times — locking holder funds is not a valid admin action. |
| **ClaimBond** | ERC-1155 transfers are user-controlled; admin cannot gate them. |
| **LuminaBondMarketplace** | Sellers must always be able to `cancel(listingId)` to reclaim escrowed bonds. |
| **TWAPBurner** | Burns are time-cooldown-gated, not pause-gated; admin cannot halt fee routing. |
| **BuybackEngine** | Role-gated (`BUYBACK_OPERATOR_ROLE`); admin revokes role instead of pausing. |
| **CEXLiquidityReserve** | Allocations are role-gated + monthly-cap-limited; no pause needed. |
| **TreasuryVesting** | Monthly-cap-limited; admin cannot gate the beneficiary's legitimate release. |
| **FounderVesting** | Immutable contract by design. |
| **MaintenanceReserve** | `spend()` is role+cap-gated; no pause needed. |

### Logic contracts — pause not applicable

| Contract | Rationale |
|---|---|
| PolicyManagerV2 | Stateless call path between router → shield → vault. |
| CapacityOracle | View-only price feed. |
| AdaptiveFeeDistributor | Pure view function returning distribution tuple. |
| LuminaTokenV2 | Token itself; pause would affect LUMINA transfers — rejected as design. |
| 9 Shields + BaseShield | Stateless; only `createPolicy` / `verifyAndCalculate` delegates. |
| 2 DEX Adapters | Stateless swap pass-through. |

---

## 4. Critical operations — ALWAYS allowed (regardless of pause state)

CRITICAL invariant: **no combination of admin pauses can prevent** the following user-initiated operations:

1. **`BondVault.redeemBond(epoch, usdAmount)`** — matured bonds always redeemable if vault has LUMINA and price >= MIN_REDEEM_PRICE. No pause on BondVault.

2. **`LuminaBondMarketplace.cancel(listingId)`** — sellers can always reclaim their escrowed bonds. No pause on Marketplace.

3. **`ClaimBond.safeTransferFrom` and `safeBatchTransferFrom`** — bond NFTs transferrable subject to authorizedOperators whitelist (Fix #18), but no pause.

4. **`MaintenanceReserve.spend()`** — still callable by SPENDER_ROLE. No pause.

5. **`CoverRouterV2.submitTrigger(productId, policyId, proof)`** — trigger submission is permissionless and NOT pause-gated. Users can always force a payout-computation if they have a matured trigger.

6. **All view / getter functions** on all contracts.

## 5. Operations BLOCKED by admin-pause

| Pause target | Ops blocked |
|---|---|
| `CoverRouterV2.setPaused(true)` | `purchasePolicy`, `purchasePolicyFor` |
| Auto-pause (price < 5e15) | Same (inside `_purchase`) |
| `ShieldKeeper.pause()` | `checkUpkeep` returns no upkeep; `performUpkeep` reverts |
| `SolvencyOracle.setEmergencyPause(true)` | `evaluate()` — quadrant updates halt |

## 6. Capability matrix

| Contract | Manual Pause? | Auto Pause? | Blocks | Allows | Who |
|---|---|---|---|---|---|
| CoverRouterV2 | ✅ setPaused | ✅ (price < 5e15) | purchase ops | triggers, views | onlyOwner |
| ShieldKeeper | ✅ pause/unpause | ❌ | upkeep | views | onlyOwner |
| SolvencyOracle | ✅ setEmergencyPause | ❌ | evaluate | views | ADMIN_ROLE |
| BondVault | ❌ | ❌ | — | **redeem always** | — |
| Marketplace | ❌ | ❌ | — | **cancel always** | — |
| TWAPBurner | ❌ | ❌ | — | burns always | — |
| BuybackEngine | ❌ | ❌ | — | role-gated ops | — |
| MaintenanceReserve | ❌ | ❌ | — | spend (role+cap) | — |
| CEXLiquidityReserve | ❌ | ❌ | — | allocate (role+cap) | — |
| TreasuryVesting | ❌ | ❌ | — | release (cap) | — |
| FounderVesting | ❌ (immutable) | ❌ | — | vesting always | — |

## 7. Gaps / observations

### INFO-6 — ShieldKeeper.pause() emits no event

**Where:** `src/automation/ShieldKeeper.sol:67-69`.

```solidity
function pause() external onlyOwner {
    paused = true;
}
```

Unlike `unpause()` (which emits `KeeperUnpaused`), `pause()` is silent. Monitors can detect unpauses but not pauses from events alone.

**Fix:** add `event KeeperPaused(address indexed by)` and emit in `pause()`.

### INFO-7 — CoverRouterV2 RESET_PRICE_FOR_NEW_POLICIES is unused

**Where:** `src/core/CoverRouterV2.sol:48`.

```solidity
uint256 public constant RESET_PRICE_FOR_NEW_POLICIES = 8e15; // 0.008 USD
```

Declared but never referenced in `_purchase`. The auto-pause re-enables the moment price crosses back above 5e15, rather than the documented intent of requiring 8e15 for resume (hysteresis). Low-impact design inconsistency; functional consequences: the protocol may flap between paused/unpaused near $0.005 instead of waiting for a clear recovery.

**Fix:** either implement hysteresis (track a `_autoPausedAt` state and require `price >= RESET_PRICE_FOR_NEW_POLICIES` to re-enable) or remove the unused constant.

## 8. Summary

- **3 contracts** have pause mechanisms (CoverRouterV2, ShieldKeeper, SolvencyOracle).
- **1 circuit breaker** (price-based auto-pause on CoverRouterV2).
- **22 contracts** are pause-free by design — users' critical ops (redeem, cancel) are always available.
- **2 observability/design gaps** (INFO-6, INFO-7) — both low-severity, non-security.
