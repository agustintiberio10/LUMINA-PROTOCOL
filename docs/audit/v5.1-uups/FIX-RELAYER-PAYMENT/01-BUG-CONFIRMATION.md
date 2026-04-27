# 01 — Bug confirmation: `purchasePolicyFor` charges relayer, not buyer

## Summary

`CoverRouterV2.purchasePolicyFor(productId, coverage, asset, buyer)` pulls the USDC premium from `msg.sender` (the relayer), not from `buyer` (the agent). The relayer ends up subsidising every policy purchase — the inverse of the intended Stripe-style flow where the relayer only pays gas.

## Where the bug lives

File: `src/core/CoverRouterV2.sol`

The two public entry points dispatch to a shared internal helper, passing distinct arguments for the buyer and the payer:

```solidity
// line 146-153
function purchasePolicy(bytes32 productId, uint256 coverageAmount, bytes32 asset)
    external nonReentrant whenNotPaused returns (uint256 policyId)
{
    return _purchase(productId, coverageAmount, asset, msg.sender, msg.sender);
    //                                                  ^^^^^^^^^^  ^^^^^^^^^^
    //                                                  buyer       payer  (== same person — OK)
}

// line 158-167
function purchasePolicyFor(
    bytes32 productId, uint256 coverageAmount, bytes32 asset, address buyer
) external nonReentrant whenNotPaused returns (uint256 policyId) {
    if (!authorizedRelayers[msg.sender]) revert NotAuthorizedRelayer(msg.sender);
    require(buyer != address(0), "Zero buyer");
    return _purchase(productId, coverageAmount, asset, buyer, msg.sender);
    //                                                 ^^^^^  ^^^^^^^^^^
    //                                                 buyer  payer  (== relayer — BUG)
}
```

Inside `_purchase` the premium is pulled from `payer`:

```solidity
// line 205-206
// Transfer USDC from payer
usdc.safeTransferFrom(payer, address(this), premium);
```

In the relayer flow `payer == msg.sender == relayer`, so the relayer's USDC balance is debited every time it submits a policy on behalf of an agent.

## Why this is wrong

The relayer pattern's whole purpose is to let agents transact without holding ETH for gas — the relayer signs the tx, the agent pays the on-chain economic cost. Here the design is inverted:

- The relayer must hold and continually replenish USDC.
- Any griefing party that holds an authorized API key can drain the relayer's USDC by spamming purchases for a buyer who has approved nothing.
- The buyer's USDC approval to `CoverRouterV2` is unused in the For-flow, which makes the auth model confusing.

## Live evidence

During the API E2E smoke test (Sepolia, 2026-04-27 18:44 UTC) the contract reverted with `Panic 0x11 (overflow)` whenever the relayer (`0x168dC710…`) had no USDC balance. Funding the relayer with 1 000 USDC + max approval to `CoverRouter` made the call succeed (tx `0xb565111d…`, policy ID 2), confirming that the contract pulls USDC from `msg.sender`, not from `buyer`.

After the fix the same call should succeed when `buyer` holds USDC + approval and the relayer holds zero USDC.

## Fix sketch

Change one line in `_purchase` so that the USDC is always pulled from `buyer`, regardless of who submitted the tx. The `payer` variable (= `msg.sender`) keeps its role as the event's record of who submitted the tx, but no longer pays the premium.

```diff
- usdc.safeTransferFrom(payer, address(this), premium);
+ usdc.safeTransferFrom(buyer, address(this), premium);
```

That is the entire functional change — same storage layout, same ABI, same events, same return value. The semantic rename of the third arg's role is documented in code comments. See `02-FIX-DESIGN.md`.
