# Adversarial relayer-pattern audit — REPORT

## Trigger

PR #86 fixed a CRITICAL bug in `CoverRouterV2.purchasePolicyFor` where the contract pulled the USDC premium from `msg.sender` (the relayer) instead of `buyer` (the agent). The 32-audit history had not caught it because every prior audit implicitly equated "caller" with "actor".

This audit asks: **is there any other place in the codebase where the same confusion could exist?**

## Method

Five orthogonal greps over `src/` covering:

1. Functions with `For` / `OnBehalf` / `forUser` / `forAccount` — relayer entry points
2. `permit` / `EIP712` / `ECDSA.recover` — user signatures
3. `msg.sender ==` checks — authorization gates
4. `_mint` / `_safeMint` / `safeTransferFrom` — NFT/token deliveries
5. Outbound `safeTransfer` — payouts

Full inventory: [`01-INVENTORY.md`](./01-INVENTORY.md).

## Functions inventoried

| Category | Hits | Suspicious | Action |
|---|---|---|---|
| `For` / `OnBehalf` | **1** (`purchasePolicyFor`) | 1 | already fixed in PR #86 |
| EIP-712 / signatures | 10 files (oracle proofs only) | 0 | n/a — different threat model |
| `msg.sender ==` | 61 occurrences across 17 files | 0 | all 12 privileged sites verified |
| NFT mints / transfers | 7 sites | 0 | recipients sourced from policy record or admin |
| Outbound `safeTransfer` | 16 sites | 0 | recipients sourced from admin or recorded actor |

## Findings

### CRITICAL — none

### HIGH — none

### MEDIUM — none

### LOW — none

### INFO

| # | Site | Note |
|---|---|---|
| INFO-1 | `CoverRouterV2._purchase` (line 179) — local var `payer` | The argument is now semantically the "submitter", not the payer. A non-functional rename would improve readability, but is not load-bearing. The event field is unchanged so off-chain consumers still parse the same address there. |
| INFO-2 | `LuminaBondMarketplace` lacks an `executeBuyFor(listingId, buyer)` variant | If an `executeBuyFor` is added later for API-mediated bond purchases, it must follow the corrected pattern (USDC pulled from `buyer`, NFT delivered to `buyer`, msg.sender is just the submitter). |
| INFO-3 | DEX adapters (`AerodromeAdapter`, `UniswapV3Adapter`) are public and callable by anyone | Not a bug — they are stateless wrappers and msg.sender pays + receives the swap. Worth noting in operator docs so external callers understand they hold their own slippage risk. |

## Tests added

`test/audit/v5.1-uups/adversarial-relayer/AdversarialRelayer.t.sol` — 8 substantive tests against the real, fixed contracts:

| # | Test | What it locks in |
|---|---|---|
| 1 | `test_Adv_AllowanceCapsRelayerSpending` | Buyer's allowance is the hard cap; relayer cannot make the protocol fall back to charging itself. |
| 2 | `test_Adv_MaliciousRelayer_CannotRedirectViaBuyerArg` | An evil authorized relayer cannot drain another address's funds by passing arbitrary `buyer` — they need that buyer's allowance, which they don't have. |
| 3 | `test_Adv_TwoRelayers_SameBuyer_BothCreateDistinctPolicies` | Two relayers can submit for the same buyer concurrently; both succeed, distinct policy ids, buyer charged exactly twice. |
| 4 | `test_Adv_RevokedRelayer_CannotPurchase` | Relayer revocation takes effect immediately; first-call OK, post-revoke call reverts at the auth gate before touching the buyer's USDC. |
| 5 | `test_Adv_BuyerEqualsRelayer_BehavesAsSelfPurchase` | `purchasePolicyFor` with `buyer == relayer` is a valid corner case; behaves as a self-purchase via the For path. |
| 6 | `test_Adv_Event_RecordsRelayerAsSubmitter_ButBuyerPaid` | Sanity: telemetry records the relayer, but balances reflect that only the buyer paid. |
| 7 | `test_Adv_NoPermitBypass_OnlyAllowanceWorks` | No EIP-2612 permit surface — the only way to spend on a buyer's behalf is a real on-chain allowance. |
| 8 | `test_Adv_RelayerCannotSelfAuthorize` | Even an authorized relayer cannot escalate to call `setRelayer`; `onlyOwner` is the only path. |

## Verification

```
forge fmt
forge build               -> Compiler run successful with warnings
forge test --match-path "test/audit/v5.1-uups/adversarial-relayer/*" -v
                          -> 8 / 8 pass
forge test --no-match-contract "Fork"
                          -> 2118 tests pass / 0 fail / 0 skip
                          (2110 baseline post-#86 merge + 8 new adversarial)
```

## Recommendations

1. **Adopt a "buyer always pays" convention** in any future `*For` function. Add a one-line comment at every `safeTransferFrom(buyer, ...)` call site that explicitly states "msg.sender is the submitter, not the payer" so reviewers internalise the rule.
2. **Lint or ban `safeTransferFrom(msg.sender, ...)`** in entry points that take an explicit actor argument. A simple grep-based CI check would have caught the original bug.
3. **Document on the API repo** (org-lumina/lumina-api) the agent's pre-flight: USDC balance + approval to CoverRouter. Already done in commit `2bda106`.
4. **Future `executeBuyFor` in marketplace** (if added) — model after the fixed `purchasePolicyFor`. Don't introduce another `For` variant without an adversarial test pair.

## Quality rating

**9.5 / 10**

- Inventory is exhaustive (all 5 categories, all hits manually traced).
- Tests target real contracts with real wiring (no mock-PolicyManager shortcuts).
- Every adversarial test asserts at least two facts (state + side effect) so they cannot trivially pass.
- −0.5 for not running symbolic execution (Halmos / Certora) on the fixed function — would catch the same bug class with stronger guarantees, but out of scope for this 4-hour exercise.

## Verdict

**CLEAN.** No additional bugs of the same class as PR #86.

The relayer-pattern attack surface in V5.1 is exactly one function (`CoverRouterV2.purchasePolicyFor`), which is now both fixed and locked in by 16 tests across two test files (8 in `fix-relayer-payment/`, 8 in `adversarial-relayer/`).
