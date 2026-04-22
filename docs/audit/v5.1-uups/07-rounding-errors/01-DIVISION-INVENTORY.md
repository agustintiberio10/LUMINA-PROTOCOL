# V5.1 Division / Rounding Inventory

**Audit:** V5.1 #7 — Rounding Errors Re-audit
**Branch:** `audit/v5.1-07-rounding-errors`
**Date:** 2026-04-22

Every division in the protocol, the direction of the implicit floor, and
who benefits (protocol vs user) when rounding biases the result.

---

## Rounding Direction Matrix

| # | Operation | Formula | Floor favours | Acceptable? |
|---|-----------|---------|---------------|-------------|
| 1 | Premium (CoverRouterV2.quotePremium) | `(cov × p × t × m) / 10000³` | Neutral (user pays slightly less) | ✅ — `if premium == 0: premium = 1` guards against $0 quote |
| 2 | Payout (CoverRouterV2) | `(cov × payoutRatioBps) / 10000` | Protocol (pays less) | ✅ |
| 3 | Redemption (BondVault.previewRedemption) | `(usdAmount × 1e36) / price` | Protocol (holder gets less LUMINA) | ✅ |
| 4 | Capacity (BondVault.availableCapacityUSD) | `(reserveValueUSD18 × 5000) / 10000` then `/1e18` | Protocol (reports less available) | ✅ — conservative |
| 5 | Commitment (BondVault maxCommit18) | same as #4 | Protocol | ✅ |
| 6 | Solvency ratio (SolvencyOracle) | `(valueUSD × 10000) / obligations` | Conservative (reports less solvency) | ✅ |
| 7 | Distribution buckets (TWAPBurner._executeAdaptive) | `(amount × bucketBps) / 10000` per bucket | Protocol (remainder held in TWAPBurner USDC balance) | ✅ — dust accumulates in contract |
| 8 | Burn cap (BondVault.burnFromReserves) | `(balance × 5) / 100` | Conservative (allows less burn) | ✅ |
| 9 | Marketplace fees (LuminaBondMarketplace) | `(price × 150) / 10000` | Protocol (fee is floored) | ✅ |
| 10 | Buyback max price (BuybackEngine) | `(faceValueUSD × maxPct) / (100 × 1e12)` | Neutral | ✅ |

---

## Who Bears the Dust?

| Source | Destination of dust |
|--------|---------------------|
| Premium rounding | Protocol (user underpays by <1 unit USDC per policy) |
| Payout rounding | Holder (underpaid by <1 unit USDC) — protocol benefit |
| Redemption rounding | Holder (underpaid in LUMINA wei) — protocol benefit |
| Capacity rounding | Unissued capacity (shows less availableUSD than actual) |
| Distribution rounding | TWAPBurner USDC balance (used in next burn cycle) |
| Marketplace fees | Contract balance ([buyerFee + sellerFee] stays in marketplace, swept to TWAPBurner) |

**No wei is lost permanently.** Every residual stays in a protocol-controlled
balance, either consumed by the next operation or claimable by governance.

---

## Notes for V5.1 specifically

The UUPS migration did not alter any of these formulas. Rounding direction
is encoded in the `public constant` BPS values and the `(a × b) / c` integer
divisions — it cannot be changed without replacing the implementation.

See `REPORT.md` for the full test matrix and verdicts.
