# FLOW-05 — Adaptive Distribution (the 4×4 / 16-cell matrix)

---

## 5.1 Overview

**The 16-cell matrix** is defined by `AdaptiveFeeDistributor._lookupDistribution(sLevel, mLevel)` in `src/core/AdaptiveFeeDistributor.sol:50-80`. It is a **pure function** that maps one of 16 (solvency, momentum) combinations to one of 16 distribution tuples `(burnBps, buybackBps, opsBps, maintenanceBps)`.

Each tuple allocates an incoming USDC amount across FOUR buckets — **burn / buyback / ops / maintenance**. None of the buckets feed BondVault.

## 5.2 The two input axes

### 5.2.1 Solvency level (`sLevel`)

Produced by `SolvencyOracle._classifySolvency(bps)` at `src/oracles/SolvencyOracle.sol:132-137`:

| sLevel | Label | Threshold |
|---|---|---|
| 0 | ULTRA | ≥ 20000 bps (≥ 200%) |
| 1 | HEALTHY | ≥ 10000 bps (≥ 100%) |
| 2 | STRESSED | ≥ 7000 bps (≥ 70%) |
| 3 | CRISIS | < 7000 bps |

Solvency ratio = `(luminaBalanceOfBondVault × price) / totalCommittedUSD` × 10000.

### 5.2.2 Momentum level (`mLevel`)

Produced by `_classifyMomentum(bps)` at `src/oracles/SolvencyOracle.sol:139-144`:

| mLevel | Label | Threshold |
|---|---|---|
| 0 | RALLY | ≥ 11000 bps (price up ≥ 10%) |
| 1 | STABLE | ≥ 9500 bps (price flat) |
| 2 | DECLINE | ≥ 8500 bps (price down 5–15%) |
| 3 | CRASH | < 8500 bps (price down > 15%) |

**⚠ V5.1 state:** Momentum is currently **hardcoded to 10000** in `SolvencyOracle.evaluate()` (`src/oracles/SolvencyOracle.sol:75`). The momentum wiring is present but inert — `mLevel` is effectively always 1 (STABLE) in the deployed protocol until a price-history source is wired.

## 5.3 The full 16-cell table

Rows: sLevel (solvency, 0=ULTRA→3=CRISIS). Columns: mLevel (momentum, 0=RALLY→3=CRASH).

Each cell is `(burnBps, buybackBps, opsBps, maintBps)` from `AdaptiveFeeDistributor._lookupDistribution`:

| | RALLY (0) | STABLE (1) | DECLINE (2) | CRASH (3) |
|---|---|---|---|---|
| **ULTRA (0)** | (9500, 0, 0, 500) | (9000, 500, 0, 500) | (8500, 1000, 0, 500) | (7500, 2000, 0, 500) |
| **HEALTHY (1)** | (9000, 500, 0, 500) | (8500, 800, 200, 500) | (7000, 2100, 200, 700) | (5500, 3500, 200, 800) |
| **STRESSED (2)** | (7500, 1800, 200, 500) | (5500, 3500, 200, 800) | (3800, 5500, 200, 500) | (1800, 7500, 200, 500) |
| **CRISIS (3)** | (4800, 4500, 200, 500) | (2800, 6500, 200, 500) | (800, 8500, 200, 500) | (0, 9600, 200, 200) |

### 5.3.1 Sanity checks

- Every cell sums to exactly 10000 bps (100%). Verified by inspection.
- Ops bucket is 0 for ULTRA (luxury of not paying infra out of every premium) and 200 for all other cells.
- Maintenance bucket is 500 or higher in every cell (baseline rainy-day).
- Burn bucket monotonically decreases as you move right (momentum worsens) OR down (solvency worsens).
- Buyback bucket monotonically increases as you move right OR down.

## 5.4 Semantics of each bucket

### 5.4.1 `burnBps` — Deflationary pressure

USDC in this bucket → `_swapAndBurn` → DEX buys LUMINA with USDC → LUMINA gets burned via `IBurnable.burn`.

**Net:** USDC leaves protocol. LUMINA total supply decreases. Per-token USD value rises if market price holds.

### 5.4.2 `buybackBps` — Bond-buyback reserve

USDC in this bucket → `safeTransfer(buybackReserve, ...)`.

`buybackReserve` is BuybackEngine's address (set by admin via `setReserves`). BuybackEngine uses those USDC to buy bonds off the marketplace → burn the bonds AND burn matching LUMINA from BondVault (see `_executeDoubleBurn` in `src/marketplace/BuybackEngine.sol:151-168`).

**Net:** USDC leaves protocol (via seller). Circulating bonds decrease. LUMINA supply decreases. Critically: LUMINA flows OUT of BondVault (via `burnFromReserves`) and is destroyed.

### 5.4.3 `opsBps` — Team operating costs

USDC in this bucket → `safeTransfer(opsReserve, ...)`.

`opsReserve` is an EOA / Safe controlled by the operations team. USDC leaves protocol immediately to that address. Nothing tracks spend.

### 5.4.4 `maintenanceBps` — Maintenance reserve

USDC in this bucket → `safeTransfer(maintenanceReserve, ...)`.

`maintenanceReserve` is the `MaintenanceReserve` proxy. USDC accumulates and can be spent later by a `SPENDER_ROLE` holder via `spend(recipient, amount, category, memo)` with a monthly cap.

## 5.5 Policy intent behind the 16 cells

Reading the cell progression:

- **ULTRA-RALLY (9500 burn):** Protocol is massively over-collateralized and price is pumping. Burn aggressively — convert premium revenue into permanent supply reduction.
- **HEALTHY-STABLE (8500 / 800 / 200 / 500):** Default steady-state. Mostly burn, small buyback rainy-day, minimal ops & maint.
- **CRISIS-CRASH (0 burn, 9600 buyback):** Protocol is under-collateralized and price is collapsing. STOP burning (burning LUMINA with USDC at a depressed price is wasteful — you pay with USDC and get less deflation per dollar). Use nearly all incoming USDC to buy mature bonds on the marketplace cheaply and double-burn them, which also draws down obligations.

## 5.6 Does any cell refill BondVault?

**NO.**

Read `TWAPBurner._executeAdaptive` at `src/core/TWAPBurner.sol:148-171`:

```solidity
if (toBuyback > 0 && buybackReserve != address(0)) {
    usdc.safeTransfer(buybackReserve, toBuyback);     // → BuybackEngine
}
if (toOps > 0 && opsReserve != address(0)) {
    usdc.safeTransfer(opsReserve, toOps);             // → ops EOA
}
if (toMaint > 0 && maintenanceReserve != address(0)) {
    usdc.safeTransfer(maintenanceReserve, toMaint);   // → MaintenanceReserve
}
if (toBurn > 0) {
    _swapAndBurn(toBurn);                             // → DEX then burn
}
```

Four destinations. None are `bondVault`. None swap USDC → LUMINA and **deposit** it anywhere; `_swapAndBurn` hardcodes a `burn` at line 240.

## 5.7 The "buyback" cell is the closest thing to a vault-helper

If the protocol is under-collateralized, `buybackBps` rises (see CRISIS row). Those USDC go to BuybackEngine which does this (`src/marketplace/BuybackEngine.sol:151-168`):

```solidity
function _executeDoubleBurn(uint256 listingId, uint256 epochId, uint256 amount) internal {
    uint256 faceValueUSD = amount;
    claimBond.burnByHolder(address(this), epochId, amount);
    bondVault.decreaseObligations(faceValueUSD);
    ...
    bondVault.burnFromReserves(luminaToBurn);  // <-- LUMINA LEAVES BondVault
}
```

**The double-burn reduces `totalCommittedUSD` (obligations) and also reduces `lumina.balanceOf(bondVault)` (reserves).** This is the only mechanism through which the adaptive matrix indirectly touches BondVault.

The ratio effect on solvency:
- Numerator (vault LUMINA × price) decreases by `luminaToBurn × price`.
- Denominator (totalCommittedUSD) decreases by `faceValueUSD × 1e18`.
- Whether the ratio improves or worsens depends on whether `luminaToBurn × price < faceValueUSD × 1e18`, i.e. whether the marketplace price ≤ face value. In practice yes — bonds on the marketplace trade at discount, so buyback at discount followed by double-burn improves the ratio.

**But this still only makes the ratio LOOK BETTER by subtracting from both sides — not by adding LUMINA to the vault.**

## 5.8 Implication for the founder's question

> "Does the 16-cell system make the protocol buy USDC into BondVault when price drops?"

**No.**

1. The 16 cells route USDC to 4 destinations — burn / buyback / ops / maintenance. BondVault is not one of them.
2. There is no "maintenance → swap → deposit to BondVault" path anywhere in the source tree.
3. The only adaptive response to a falling solvency ratio is **reducing obligations** (via buyback + double-burn), never **adding LUMINA** to the vault.

The 16-cell matrix is a **stabilization-by-supply-reduction** mechanism, not a **stabilization-by-replenishment** mechanism.
