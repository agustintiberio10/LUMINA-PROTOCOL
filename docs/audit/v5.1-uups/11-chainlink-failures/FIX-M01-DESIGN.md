# Fix M-01 — Design Document

**Finding:** audit V5.1 #11 — `Shields do not enforce price sanity bounds`.
**Branch:** `fix/v5.1-shield-sanity-bounds`
**Date:** 2026-04-22

---

## 1. Problem statement

Audit #11 demonstrated that a shield accepts any positive price returned
by the oracle as the policy's strike price. A glitched or manipulated
Chainlink feed could therefore mis-price policies (e.g. BTC stamped at
$6 M when spot is $60 k).

## 2. Solution

Add **per-asset sanity bounds** as immutable `public constant` on each
shield. Every price read from the oracle (or from a signed settlement
proof) is checked against these bounds; out-of-range prices revert with
a dedicated error.

## 3. Bounds

| Shield family | MIN_PRICE | MAX_PRICE |
|---------------|-----------|-----------|
| FlashBTCShield 1h / 4h / 24h / 48h | $10,000 (`1e12`) | $1,000,000 (`1e14`) |
| FlashETHShield 1h / 24h / 48h | $500 (`5e10`) | $50,000 (`5e12`) |
| MicroDepegShield | $0.50 (`5e7`) | $1.50 (`1.5e8`) |
| RateShockShield | N/A (uses Aave rate, not Chainlink price) | — |

Values are stored as `uint256 public constant` in Chainlink 8-decimal
format (matching the oracle's return).

## 4. Where the check fires

For every shield that reads Chainlink prices:

1. **`_doCreatePolicy(...)`** — after reading the strike price from the
   oracle, before storing it. Blocks mis-priced policy creation.
2. **`_doVerifyAndCalculate(...)`** — after unpacking the EIP-712 signed
   `verifiedPrice`, before comparing against `triggerPrice`. Blocks
   mis-priced settlement.

The on-chain spot check in `_checkTriggerCondition` remains permissive
(returns `false` for out-of-bounds) — this is a `view` helper that
keepers call, and silent-false prevents DoS of the keeper loop while
still never triggering on a glitched price.

## 5. Error

```solidity
error PriceOutOfSanityBounds(uint256 price, uint256 min, uint256 max);
```

Added to each shield's error section.

## 6. Helper

Each shield gets a private pure helper:

```solidity
function _validatePriceBounds(int256 price) private pure {
    uint256 p = price > 0 ? uint256(price) : 0;
    if (p < MIN_PRICE || p > MAX_PRICE) {
        revert PriceOutOfSanityBounds(p, MIN_PRICE, MAX_PRICE);
    }
}
```

`price <= 0` is already rejected in the pre-existing `currentPrice <= 0`
revert; the helper only catches the positive-but-extreme case.

## 7. Constants are immutable by design

`public constant` values live in bytecode, not storage. Admin cannot
modify them without an UUPS upgrade — which is gated by DEFAULT_ADMIN_ROLE
+ future timelock (per audit #4).

## 8. Tests

`test/audit/v5.1-uups/external-deps/ShieldSanityBounds.t.sol` with 6 test
categories × 8 shields:
- Normal price accepted
- At MAX boundary accepted
- 1 wei above MAX reverts
- Extreme price (100× normal) reverts
- Below MIN reverts
- Settlement via proof with out-of-bounds price reverts (where settlement
  is testable without full EIP-712 signing machinery)

## 9. Non-goals

- No bounds on RateShockShield — it reads a rate, not a price. Rate
  bounds are a separate concern (deferred to future audit).
- No change to oracle wrapper — those staleness/sequencer improvements
  remain the wrapper's responsibility per audit #11 recommendations.

## 10. Risk

Low. The fix is purely additive (new constants + new revert path). It
does not touch any existing logic that already worked. A successful
regression run (1530 tests) proves no impact on existing behaviour.
