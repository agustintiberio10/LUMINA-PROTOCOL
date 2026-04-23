# Fix M-02 — Design Document

**Finding:** audit V5.1 #13 — M-02 (DEX adapters' `getQuote` returns 0).
**Branch:** `fix/v5.1-dex-getquote-real`
**Date:** 2026-04-23

---

## 1. Problem

Audit #13 observed that `UniswapV3Adapter.getQuote` and
`AerodromeAdapter.getQuote` are stubs returning 0. Combined with a
failing `CapacityOracle`, `TWAPBurner._swapAndBurn` derives
`minOut = 0` — a sandwich attacker could return 1 wei of LUMINA and the
swap would succeed.

## 2. Fix plan

1. **IDexRouter interface** — change `getQuote` from `external view` to
   `external`. Uniswap V3's `QuoterV2.quoteExactInputSingle` is
   non-view (it reverts internally for quoting), so we can't call it
   from a `view` function. Aerodrome's `getAmountsOut` remains view —
   a more-restrictive implementation is still valid against a
   non-restrictive interface.

2. **UniswapV3Adapter**
   - Add constructor param `address _quoter` (Base mainnet:
     `0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a`).
   - Store as `immutable IQuoterV2 public quoter`.
   - Implement `getQuote` with try/catch around
     `quoter.quoteExactInputSingle(...)`; return 0 on any revert.

3. **AerodromeAdapter**
   - Add `factoryForQuotes` constructor param (may equal the same
     factory already used; kept configurable for forks).
   - Implement `getQuote` using `router.getAmountsOut(amountIn, routes)`
     via try/catch.

4. **TWAPBurner._swapAndBurn**
   - After all minOut computation, add:
     `require(minOut > 0, "TWAPBurner: minOut must be > 0");`
     before calling `bestRouter.swap(...)`. Defense-in-depth: even if
     every quote AND the oracle fail, we refuse to swap without a
     protective floor.

## 3. Rationale for non-view interface

Uniswap V3's `QuoterV2` is a "revert-to-query" pattern: it performs a
partial swap internally and reads the mid-swap state. This mutates
state transiently but reverts at the end, leaving nothing on-chain. It
cannot be called from a `view` function because the static-call gate
on views forbids state-mutating ops even if they revert. Making our
interface non-view allows UniV3's adapter to use the canonical
quoter; Aerodrome can remain view-compatible because its router exposes
a view `getAmountsOut`.

## 4. Tests

`test/audit/v5.1-uups/external-deps/dex/AdapterGetQuoteReal.t.sol`
with ~15 tests:

- **Uniswap V3 adapter**:
  - Normal quote returns non-zero (via mock quoter).
  - Zero amount returns 0.
  - Quoter reverts → adapter returns 0 (try/catch).
  - Large amount does not overflow.
- **Aerodrome adapter**:
  - Normal quote returns non-zero.
  - Zero amount returns 0.
  - Router reverts → adapter returns 0.
  - Large amount ok.
- **TWAPBurner guard**:
  - All quotes + oracle fail → `minOut > 0` check reverts before swap.
  - Quote-only fallback works.
  - Oracle-only fallback works.
  - Best-router selection still picks the higher quote.

## 5. Changes to existing audit #13 tests

Some tests in `DEXRouting.t.sol` relied on the degenerate minOut=0 path
(specifically `test_DEX_BothQuotesRevert_FallsBackToFirst` which
implicitly used minOut=0). Those tests are updated to provide at least
one non-zero reference (quote or oracle) so the new `minOut > 0` guard
does not mis-fire.

## 6. Risk

Low. Pure additive:
- Interface mutability relax is backwards-compatible (clients expecting
  `view` would break, but the only in-repo client is TWAPBurner's
  non-view `_swapAndBurn`).
- `getQuote` impls preserve try/catch-return-0 semantics, same as the
  existing stubs.
- `minOut > 0` guard is a strict-upgrade addition.
