# FLOW-04 — BondVault: content and interactions

---

## 4.1 What the BondVault holds

**Only LUMINA.** No USDC. No other tokens.

Evidence: `src/bonds/BondVault.sol` declares only `IERC20 public lumina` (the LUMINA token proxy) in its storage. Every read of balance uses `lumina.balanceOf(address(this))` — never USDC.

## 4.2 Initial funding

At `LuminaTokenV2.initialize()` (`src/token/LuminaTokenV2.sol`), **70,000,000 LUMINA** is minted and sent to BondVault. This is the ONLY LUMINA the vault ever receives.

- `bondVault` receives 70M (70% of total supply).
- `cexReserve` receives 14M (14%).
- `founderVesting` receives 8M (8%).
- `lbpDeposit` receives 5M (5%).
- `treasuryVesting` receives 3M (3%).

Total: 100M LUMINA — matches constant in the token contract.

## 4.3 Inflow paths to BondVault

**There are NONE.** Besides the one-shot initial mint, no function in V5.1 sends LUMINA (or any token) to the BondVault.

Exhaustively checked:
- `src/bonds/BondVault.sol` — no `deposit`, `fund`, `refill`, or any function that accepts tokens.
- No contract in `src/` calls `lumina.transfer(bondVault, ...)` or equivalent.

The only way the BondVault balance increases would be a direct `lumina.transfer(bondVault, ...)` initiated by an external caller. Since LUMINA can only be minted by DEFAULT_ADMIN_ROLE on LuminaTokenV2 (and transfers from other holders reduce those holders' balances), this is a governance-level action, not a protocol-automated one.

## 4.4 Outflow paths from BondVault

Two:

### 4.4.1 `redeemBond(epochId, usdAmount)` — `src/bonds/BondVault.sol:187-211`

Requirements:
- `usdAmount > 0`
- `claimBond.isMatured(epochId)` — epoch has passed maturity.
- `claimBond.balanceOf(msg.sender, epochId) >= usdAmount` — holder owns the bonds.
- `currentPrice >= MIN_REDEEM_PRICE` (0.001e18 = $0.001).
- `lumina.balanceOf(bondVault) >= luminaAmount` — vault has enough LUMINA.

Effect:
- `totalCommittedUSD -= usdAmount × 1e18` (or zeroed if underflow).
- `claimBond.burn(msg.sender, epochId, usdAmount)` — destroy the bond tokens.
- `lumina.transfer(msg.sender, luminaAmount)` — pay holder.
- `luminaAmount = usdAmount × 1e36 / currentPrice`.

### 4.4.2 `burnFromReserves(amount)` — `src/bonds/BondVault.sol:288-298`

Requirements:
- Caller has `AUTHORIZED_CALLER_ROLE` (`onlyAuthorized` modifier).
- `amount > 0`.
- `currentBalance >= amount`.
- `amount <= 5% × currentBalance` — per-tx cap.

Effect:
- `lumina.burn(amount)` — destroys LUMINA from vault + reduces total supply.

**Only BuybackEngine (authorized at deploy time) invokes this function today.**

## 4.5 Internal state changes — `reserveCapacity` / `commitReservation` / `releaseReservation` / `decreaseObligations`

These mutate only the `totalReservedUSD` and `totalCommittedUSD` counters. No token movement.

- `reserveCapacity(amount)` (line 127): onlyPolicyManager — increases `totalReservedUSD`.
- `commitReservation(amount)` (line 136): onlyPolicyManager — converts reserved to committed.
- `releaseReservation(amount)` (line 146): onlyPolicyManager — reduces `totalReservedUSD`.
- `decreaseObligations(amount)` (`src/bonds/BondVault.sol` — called by BuybackEngine): reduces `totalCommittedUSD` when bonds are bought off-market and burned.

## 4.6 Mathematical model

### Capacity formula

`issueBond` (line 159-180) enforces:

```solidity
uint256 reserveBalance = lumina.balanceOf(address(this));
uint256 reserveValueUSD = (reserveBalance * currentPrice) / 1e18;           // 18-dec USD-wei
uint256 maxCommitUSD = (reserveValueUSD * SAFETY_FACTOR_BPS) / 10000;       // 50%
require(totalCommittedUSD + (usdPayout * 1e18) <= maxCommitUSD, "Exceeds capacity");
```

Where:
- `SAFETY_FACTOR_BPS = 5000` (50%) — `src/bonds/BondVault.sol:49`.
- `currentPrice` is read from `priceOracle` (which is `CapacityOracle`).

So: `maxCapacity_USD = lumina_balance × price × 0.5`.

For the initial state (70M LUMINA, $0.036 emergency price): `maxCapacity ≈ 70M × 0.036 × 0.5 = $1,260,000`.

### `bondReserve` is NOT fixed

It starts at 70M but shrinks over time via:
- `redeemBond` (LUMINA transferred out to holders).
- `burnFromReserves` (LUMINA destroyed).

It does NOT refill. The 50% safety factor is meant to accommodate a certain amount of price drop and redemption pressure — but it is a soft cushion, not an on-chain refill mechanism.

## 4.7 Solvency and its relation to BondVault

`SolvencyOracle.getSolvencyRatio()` (`src/oracles/SolvencyOracle.sol:105-107, 123-130`) computes:

```solidity
uint256 valueUSD = (lumina.balanceOf(bondVault) × capacityOracle.getLuminaPrice()) / 1e18;
return (valueUSD × 10000) / totalCommittedUSD;
```

- `≥ 20000` (200%): ULTRA — sLevel 0.
- `≥ 10000` (100%): HEALTHY — sLevel 1.
- `≥ 7000` (70%): STRESSED — sLevel 2.
- `< 7000`: CRISIS — sLevel 3.

Note: this ratio is READ-ONLY. SolvencyOracle never writes to BondVault or adjusts its balance; it only observes and reports a quadrant for AdaptiveFeeDistributor.

## 4.8 Conclusion

The BondVault is a **one-shot-funded, drain-only** contract in V5.1.

- Receives LUMINA once at deploy (70M).
- Drains via `redeemBond` (LUMINA out to holders) and `burnFromReserves` (LUMINA destroyed).
- No automatic or admin refill path exists.
- The 16-cell adaptive distribution reads vault state (via SolvencyOracle) but never writes back to it.

If the vault is ever insufficient to cover obligations, there is **no on-chain function** to replenish it. The only mitigations available today are:

1. Admin sends LUMINA directly (via `lumina.transfer(bondVault, ...)` from an address that holds LUMINA).
2. Wait for natural supply contraction via burns to increase LUMINA price → reduce LUMINA needed per redemption.

Both require off-chain / governance action.
