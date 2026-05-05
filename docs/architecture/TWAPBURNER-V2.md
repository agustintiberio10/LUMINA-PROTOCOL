# TWAPBurner V2 — Auto-burn on purchase

## Overview

`TWAPBurner` accepts USDC premiums from `CoverRouterV2.receivePremium()` and converts
them into LUMINA buybacks-and-burns through one of the registered DEX routers.

V2 introduces **auto-burn**: instead of waiting for someone to call `executeBurn()`
manually, the contract triggers a burn from inside `receivePremium` once a
configured threshold is reached.

The proxy address (`0x357BAF511383be70d1F3A5de7D3b07561Eec7d99` on Base Sepolia)
is unchanged — only the implementation behind it.

## Trigger thresholds

A burn fires when **either** of these is true after a `receivePremium` call:

- `purchaseCounter ≥ maxPurchasesBeforeBurn` (default **50**)
- `accumulatedUSDCSinceBurn ≥ maxAccumulatedUSDCBeforeBurn` (default **500 USDC**)

Both counters reset on a successful or attempted burn. If `maxPurchasesBeforeBurn`
is `0` the auto-burn pathway is disabled (this is the state immediately after the
upgrade and before `initializeV2` runs, so the protocol cannot accidentally burn
mid-deploy).

## Per-purchase flow

1. Buyer pays the USDC premium to `CoverRouterV2`.
2. `CoverRouterV2._purchase()` forwards the premium to `TWAPBurner.receivePremium()`.
3. `receivePremium`:
   - records the premium (`totalUSDCReceived`, `PremiumReceived` event),
   - increments `purchaseCounter` and `accumulatedUSDCSinceBurn`,
   - if a threshold is reached, calls `_autoBurn(tx.origin)`.
4. `_autoBurn`:
   - returns silently if the contract holds less USDC than `minBurnAmount`,
     leaving counters in place so the next premium retries immediately;
   - otherwise resets counters, snaps `lastBurnTimestamp`, emits
     `AutoBurnTriggered(amount, msg.sender, gasRecipient)`, and runs the actual
     swap-and-burn through a `try/catch` self-call (`_executeBurnExternal`);
   - on a swap failure the catch emits `AutoBurnFailed(amount, reason)` and
     returns without reverting the parent purchase;
   - on success, refunds gas (capped) to `tx.origin` from the contract's own ETH
     balance if `gasRefundEnabled` and `gasRefundTreasury != 0`.

## Configuration (owner-only)

| Function                | Effect                                                      |
|-------------------------|-------------------------------------------------------------|
| `setAutoBurnConfig`     | Update `maxPurchasesBeforeBurn` and `maxAccumulatedUSDCBeforeBurn`. |
| `setGasRefundConfig`    | Toggle `gasRefundEnabled`, set `gasRefundCap`, set `gasRefundTreasury`. |
| `initializeV2`          | One-shot via `reinitializer(2)` during the UUPS upgrade.    |

## Trade-offs

- **Gas distribution.** 49 of every 50 purchases pay normal gas; the 50th pays
  the burn cost. The gas refund (capped at `0.001 ETH` by default) flattens that
  spike for the unlucky buyer who triggered the burn.
- **Treasury must be pre-funded.** Refunds drain `address(this).balance`. The
  contract must hold enough ETH for the expected burn frequency. The
  `gasRefundTreasury` field is stored as a sentinel — the actual ETH source is
  always the contract balance, so on mainnet the multisig should top up the
  burner periodically rather than rely on a separate treasury contract.
- **Burn failures are non-blocking.** If the DEX swap reverts (no liquidity,
  oracle outage, slippage), `AutoBurnFailed` is emitted but the parent purchase
  succeeds. Counters reset, so the *next* batch of premiums will retry.
- **Manual fallback.** `executeBurn()` is still callable permissionlessly with
  the original 15-minute cooldown, so anyone can clear a stuck balance even if
  the auto-burn path is failing repeatedly.

## Storage layout note

V2 added 7 storage slots between `authorizedSenders` and the gap:
`maxPurchasesBeforeBurn`, `maxAccumulatedUSDCBeforeBurn`, `purchaseCounter`,
`accumulatedUSDCSinceBurn`, `gasRefundEnabled`, `gasRefundCap`,
`gasRefundTreasury`. The reserved gap shrunk from `[50]` to `[43]` to keep the
total layout size identical.

## Events

```solidity
event AutoBurnTriggered(uint256 amount, address indexed router, address indexed gasRecipient);
event AutoBurnFailed(uint256 amount, bytes reason);
event GasRefunded(address indexed recipient, uint256 amount);
event AutoBurnConfigUpdated(uint256 maxPurchases, uint256 maxAccumulatedUSDC);
event GasRefundConfigUpdated(bool enabled, uint256 cap, address indexed treasury);
```

## Mainnet checklist

- [ ] Tune thresholds — 50 purchases / 500 USDC is calibrated for Sepolia volume.
- [ ] Rotate `gasRefundTreasury` to the multisig.
- [ ] Pre-fund the burner with enough ETH for expected refund frequency.
- [ ] Have an audit reviewer confirm storage-layout compatibility before
      pushing to the mainnet proxy.
