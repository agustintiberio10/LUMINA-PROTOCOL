# Slither Static Analysis — V2 Contracts
## Date: 2026-04-17
## Tool: slither-analyzer 0.11.5 + solc 0.8.20

### Summary

| Contract | HIGH | MEDIUM | LOW/INFO | Status |
|---|---|---|---|---|
| BondVault.sol | 0 | 0 | 4 | **CLEAN** (all false positives) |
| PolicyManagerV2.sol | 0 | 0 | 0 | **CLEAN** |
| CoverRouterV2.sol | 0 | 0 | 0 | **CLEAN** |
| TWAPBurner.sol | 0 | 0 | 4 | **CLEAN** (nonReentrant mitigates) |
| ClaimBond.sol | 0 | 0 | 9 | **CLEAN** (all in OZ Math lib) |
| LuminaTokenV2.sol | 0 | 0 | 0 | **CLEAN** |

**0 HIGH, 0 MEDIUM. All findings are false positives or OZ library internals.**

### Detailed triage

#### BondVault.sol (4 findings, all LOW)
1. `weak-prng`: `block.timestamp` used in `_timestampToEpoch` — deterministic mapping, not randomness. **Accepted (false positive).**
2-4. `divide-before-multiply`: `reserveValueUSD = (balance * price) / 1e18` then `maxCommit = reserveValueUSD * 5000 / 10000`. Slither flags sequential div→mul but this is the intended fixed-point pattern. **Accepted.**

#### TWAPBurner.sol (4 findings, all LOW)
1. `reentrancy-balance`: stale balance after swap. **Mitigated by `nonReentrant`.**
2. `reentrancy-no-eth`: state write after external call (swap → burn → state update). **Mitigated by `nonReentrant`.**
3. `unused-return`: `usdc.forceApprove` return unchecked. **SafeERC20 handles revert internally.**
4. `divide-before-multiply`: slippage calculation. **Accepted (standard pattern).**

#### ClaimBond.sol (9 findings, all LOW)
All 9 are `divide-before-multiply` inside OpenZeppelin's `Math.mulDiv` library function. Not our code. **Accepted (OZ internal).**
