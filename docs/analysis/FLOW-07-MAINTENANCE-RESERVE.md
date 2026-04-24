# FLOW-07 — MaintenanceReserve: current state & the rescue-function gap

---

## 7.1 What MaintenanceReserve is today

`src/treasury/MaintenanceReserve.sol` (139 lines). UUPS proxy, AccessControl-based, USDC-only storage/accounting.

Storage:
```solidity
IERC20 public usdc;
uint256 public monthlyCap;
uint256 public currentMonthSpent;
uint256 public currentMonth;
uint256 public totalSpent;
SpendRecord[] public spendHistory;
```

Roles:
```solidity
bytes32 public constant SPENDER_ROLE = keccak256("SPENDER_ROLE");
// + DEFAULT_ADMIN_ROLE (from AccessControlUpgradeable)
```

Both `DEFAULT_ADMIN_ROLE` and `SPENDER_ROLE` are granted to the same `_admin` at `initialize()` (lines 65-66). In V5.1 deployment scripts this is intended to be a Gnosis Safe.

## 7.2 Inflow

The only inflow path: plain ERC-20 `transfer` FROM `TWAPBurner._executeAdaptive` at `src/core/TWAPBurner.sol:163-165`:

```solidity
if (toMaint > 0 && maintenanceReserve != address(0)) {
    usdc.safeTransfer(maintenanceReserve, toMaint);
}
```

MaintenanceReserve has NO `receive`/`fallback` function and NO `depositUSDC` entry point. USDC just lands in its balance.

**This means:** its balance can grow via:
1. The 16-cell matrix maintenance bucket (baseline 500 bps of executed burns, higher during stress).
2. Any address doing a direct `usdc.transfer(maintenanceReserve, ...)`.

The second path is external/permissionless but carries no intent-signaling — it would look like an accidental transfer.

## 7.3 Outflow — today, one path only

`src/treasury/MaintenanceReserve.sol:69-91` (`spend`):

```solidity
function spend(address recipient, uint256 amount, SpendCategory category, string calldata memo)
    external
    onlyRole(SPENDER_ROLE)
    nonReentrant
{
    require(recipient != address(0), "Recipient zero");
    require(amount > 0, "Amount zero");

    _enforceMonthlycap(amount);

    currentMonthSpent += amount;
    totalSpent += amount;

    spendHistory.push(
        SpendRecord({
            recipient: recipient, amount: amount, category: category, memo: memo, timestamp: block.timestamp
        })
    );

    usdc.safeTransfer(recipient, amount);
    emit FundsSpent(recipient, amount, category, memo, block.timestamp);
}
```

Characteristics:
- `recipient` is arbitrary — admin chooses.
- `amount` is capped only by `monthlyCap` (configurable, zero = unlimited).
- `category` is an enum (Infrastructure/Audit/Tooling/Marketing/Legal/Other).
- `memo` is free-form string.
- History is recorded immutably on chain.
- Behind `SPENDER_ROLE` — a multisig in production.

## 7.4 `recoverToken`

`src/treasury/MaintenanceReserve.sol:130-134`:

```solidity
function recoverToken(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(token != address(usdc), "Cannot recover USDC");
    IERC20(token).safeTransfer(msg.sender, amount);
    emit TokenRecovered(token, amount);
}
```

Deliberately **blocks USDC recovery** to force admin to use `spend` (monthly-capped, categorized, event-logged). But it allows any non-USDC token to be withdrawn, including LUMINA — relevant if LUMINA ever accidentally lands here, an admin can extract it.

## 7.5 What MaintenanceReserve **cannot** do today

Exhaustive list of the functions ABSENT from the contract:

- No `swapToLumina(...)` — cannot swap accumulated USDC → LUMINA.
- No `depositToBondVault(...)` — cannot transfer USDC or LUMINA into BondVault.
- No `refillBondVault(...)` — no dedicated rescue path.
- No `setDexRouter(...)` — no DEX integration at all (MaintenanceReserve is USDC-only, no swap infrastructure).

So: **MaintenanceReserve cannot, by any on-chain mechanism, put LUMINA into BondVault.**

The only indirect workaround admin has today:
1. `spend(adminEOA, X, Other, "BondVault rescue")` → USDC goes to an EOA.
2. Admin manually swaps USDC → LUMINA on a DEX off-chain.
3. Admin calls `lumina.transfer(bondVault, amount)` from that EOA.

This is (a) off-chain, (b) 3 transactions, (c) relies on admin custody of the intermediate USDC/LUMINA, (d) inflight funds are vulnerable to admin-key compromise.

## 7.6 The rescue-function gap

There is a **structural gap** in V5.1:

| Scenario | Today's protocol response |
|---|---|
| BondVault LUMINA balance sufficient | redeemBond works — paid from initial 70M |
| BondVault LUMINA balance insufficient for matured claims | `redeemBond` reverts with "Insufficient reserve"; holders stuck; no automated or manual recovery path |

The 50% safety factor (SAFETY_FACTOR_BPS=5000 at `src/bonds/BondVault.sol:49`) is a **soft cushion**, not an on-chain refill mechanism. Once the vault runs low (e.g. after many redemptions at a depressed price), there is no protocol-level way to pay it back up.

## 7.7 Proposed architecture for a rescue function

This section is design-only. No code changes in this task.

### 7.7.1 Minimum viable rescue function

Add a function on MaintenanceReserve (or a new `BondVaultReplenisher` contract):

```solidity
function swapAndReplenishBondVault(
    uint256 usdcAmount,
    uint256 minLuminaOut,
    address dexRouter
) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
    require(usdcAmount > 0 && usdcAmount <= usdc.balanceOf(address(this)), "Bad amount");
    require(minLuminaOut > 0, "minOut = 0");
    require(isAllowedRouter[dexRouter], "Router not whitelisted");
    // optional: require timelock has passed if queued-rescue pattern is used

    usdc.forceApprove(dexRouter, usdcAmount);
    uint256 luminaReceived = IDexRouter(dexRouter).swap(
        address(usdc), address(lumina), usdcAmount, minLuminaOut
    );
    require(luminaReceived >= minLuminaOut, "Slippage");

    require(lumina.transfer(address(bondVault), luminaReceived), "Transfer failed");

    // Also bump a rescue counter for accounting
    totalRescued += usdcAmount;
    totalLuminaSentToVault += luminaReceived;

    emit BondVaultReplenished(usdcAmount, luminaReceived, dexRouter, block.timestamp);
}
```

Characteristics:
- **onlyRole(DEFAULT_ADMIN_ROLE)** — behind multisig 3-of-5.
- **nonReentrant** — standard.
- **DEX router whitelist** — mitigates "admin keys compromised → router drains funds" risk.
- **minLuminaOut** — mandatory slippage floor.
- **No swapping path for LUMINA itself** — contract never holds LUMINA except transiently.

### 7.7.2 Access model — layered defense

For highest safety:

1. **Multisig (3-of-5 Gnosis Safe)** holds `DEFAULT_ADMIN_ROLE`.
2. **Timelock (48h)** is required for anything that touches BondVault.
3. **Optional Guardian role** with a one-way "veto" right during the timelock delay — can cancel a queued rescue if it smells like an attack, but cannot initiate one.

Worked flow:
1. Signer 1 queues `swapAndReplenishBondVault(X USDC, minLumina, allowed router)` in Timelock.
2. Timelock 48h delay starts.
3. If malicious: Guardian calls `cancel()` on the Timelock's queued tx.
4. If legitimate: after 48h, any multisig signer (or the Timelock itself) executes.

### 7.7.3 Storage / UUPS implications

- MaintenanceReserve is already UUPS. Adding new storage slots requires respecting the existing `__gap[50]` at line 138. Use slots from the gap.
- New function + event can be added via `upgradeTo(newImplementation)` behind the admin role.
- `isAllowedRouter` mapping can be added as new storage consuming 1 slot.
- A `totalRescued` counter consumes 1 slot.
- No changes to the existing USDC/monthlyCap/history storage — backwards compatible.

### 7.7.4 Alternative: a dedicated `BondVaultReplenisher` proxy

Instead of overloading MaintenanceReserve, a cleaner separation is a new single-purpose contract:

- Holds no USDC or LUMINA of its own.
- Has a `rescue(X)` function that: pulls X USDC from MaintenanceReserve (via `spend` or a delegate-allow pattern), swaps it on a whitelisted DEX, deposits the LUMINA into BondVault.
- Single-responsibility, easier to audit, easier to pause.

Trade-offs: extra contract to deploy, extra approval flow. But strongly recommended if the rescue pattern is ever expected to run more than a handful of times (e.g., during extended bear markets).

### 7.7.5 What NOT to include

- No daily/monthly CAP on the rescue path — in a crisis you want admin able to move the whole USDC balance in one tx. The monthly cap exists on `spend()` to prevent slow-drain leaks of ops budget; a rescue is a crisis action, not an operating action.
- No automatic triggering (keeper-based) — the decision of WHEN to rescue is subjective (it requires trusting that the market price is a good entry point, that vault replenishment is preferable to bond-side supply reduction, etc.). Keep it manual.
- No direct admin-chooses-recipient path — rescue should hardcode `bondVault` as the destination. Admin picks the USDC amount and slippage only.

## 7.8 Summary

- **MaintenanceReserve today**: USDC-in (via 16-cell matrix maint bucket), USDC-out (via `spend` to arbitrary recipients). USDC-only. No swap. No BondVault linkage.
- **Gap**: no function anywhere in the protocol can move value INTO BondVault in response to vault shortfall.
- **Proposal**: add a single admin-gated, whitelist-constrained, timelocked `swapAndReplenishBondVault` function. Behind multisig + timelock this achieves ~95% of the operational need with ~50 lines of code.
