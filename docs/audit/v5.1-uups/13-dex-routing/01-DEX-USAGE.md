# V5.1 DEX Routing Inventory

**Audit:** V5.1 #13 — DEX Routing
**Branch:** `audit/v5.1-13-dex-routing`
**Date:** 2026-04-22

---

## 1. Where DEXes are consumed

### 1.1 TWAPBurner — swap USDC → LUMINA and burn
- `_swapAndBurn(uint256 usdcAmount)` is the single swap site.
- Iterates `IDexRouter[] public dexRouters` (array of adapters).
- Uses `getQuote` to pick the highest-LUMINA-per-USDC adapter, falls
  back to `dexRouters[0]` if every `getQuote` reverts or returns 0.
- Computes `minOut` as `max(quote-based, oracle-based)`:
  - Quote-based: `bestQuote × (10_000 − maxSlippageBps) / 10_000`
  - Oracle-based (via CapacityOracle): `(usdcAmount × 1e12 × 1e18 /
    oraclePrice) × (10_000 − maxSlippageBps) / 10_000`
- Calls `bestRouter.swap(...)`, verifies `luminaReceived > 0`, and burns.

### 1.2 CapacityOracle — read LUMINA price
- `getLuminaPrice()` reads Uniswap V3 pool via `_getTwapPrice()` wrapped
  in try/catch. Falls back to `emergencyPrice` on revert or zero.
- `_getTwapPrice()` calls `observe()` + computes sqrtPriceX96 from tick
  difference.

### 1.3 CoverRouterV2 — USDC transfers (no DEX swap)
- Uses USDC `safeTransferFrom` + `forceApprove` to move premiums to
  TWAPBurner. No swap on this path.

---

## 2. DEX adapters

### UniswapV3Adapter (`src/dex/UniswapV3Adapter.sol`)
- Wraps Uniswap V3 `SwapRouter.exactInputSingle`.
- `poolFee` is adjustable by owner.
- `getQuote()` returns **0** (stub — see §5).

### AerodromeAdapter (`src/dex/AerodromeAdapter.sol`)
- Wraps Aerodrome `swapExactTokensForTokens` with a single hop.
- `factory` + `stable` owner-adjustable.
- Deadline = `block.timestamp` (same-block only).
- `getQuote()` returns **0** (stub — see §5).

Both adapters:
- `swap(...)` pulls `tokenIn` via `safeTransferFrom(msg.sender, ...)`,
  forceApproves the router, executes, and returns `amountOut`.
- Adapters themselves do NOT keep balances or charge fees; they are
  pure adapters.

---

## 3. TWAPBurner configuration

| Parameter | Default | Range |
|-----------|---------|-------|
| `maxSlippageBps` | 500 (5%) | 50..1000 (0.5%..10%) |
| `burnCooldown` | 900 s | 60..86400 (1min..24h) |
| `minBurnAmount` | 1e6 ($1) | ≥ 1e5 ($0.10) |
| `maxBurnAmount` | 10_000e6 ($10k) | ≥ minBurnAmount |
| `poolFee` | 10_000 (1%) | {500, 3000, 10000} |
| `adaptiveModeEnabled` | false | bool |

---

## 4. Failure modes mapped to contract behaviour

| Failure | TWAPBurner behaviour |
|---------|----------------------|
| No routers configured | `require(dexRouters.length > 0)` — revert "No DEX routers configured" |
| All adapters' `getQuote` revert / return 0 | `bestQuote == 0` — swap proceeds using **oracle-based minOut only** |
| CapacityOracle unavailable AND no quotes | `minOut == 0` — swap accepts any non-zero output ⚠️ |
| Router's `swap` reverts | Revert propagates to `executeBurn` caller |
| Router returns 0 | `require(luminaReceived > 0, "Swap returned 0")` |
| Router returns below minOut | Swap reverts inside router (slippage check inside router) |
| Pool has no liquidity | Router reverts with pool-specific error |
| Pool fee tier wrong | Router can't find pool → revert |
| Uniswap V3 TWAP cardinality insufficient | CapacityOracle's `try/catch` → emergencyPrice fallback |
| Aerodrome route invalid | Router reverts inside `swapExactTokensForTokens` |
| Approval race | `forceApprove` guarantees reset-to-zero-then-set — no leftover |

---

## 5. Known design choices

- **`getQuote` is stubbed at zero** on both adapters. The audit-plan
  "best price selection" path is therefore disabled in practice;
  TWAPBurner always uses `dexRouters[0]` with **oracle-based minOut**
  for slippage protection.
- **Oracle-based minOut is the primary safeguard.** If CapacityOracle
  pool is unset or TWAP unavailable, minOut can degrade to 0. The
  `maxSlippageBps` range [50..1000] is the second-line defence when the
  quote path ever produces a non-zero value.
- **Aerodrome deadline = `block.timestamp`** means the swap must execute
  in the same block it was submitted — no mempool delay attack possible.

---

## 6. Per-test mitigation mapping

See `REPORT.md` §4 for failure-mode → test mapping.
