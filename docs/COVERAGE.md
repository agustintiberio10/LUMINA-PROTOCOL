# Test Coverage — Lumina Protocol V2
## Date: 2026-04-17

### Coverage tool limitations

`forge coverage --report summary` fails with "stack too deep" on V1 `CoverRouter.sol` (UUPS, 294-line function). Using `--ir-minimum` resolves compilation but does not produce the coverage table in the current Foundry version (1.5.1). Coverage numbers below are estimated from test-to-contract mapping.

### Test count

| Test suite | Tests | Status |
|---|---|---|
| Unit tests (token, bonds, core, oracle, products) | 104 | PASS |
| Adversarial audit (AdversarialAuditTest) | 41 | PASS |
| CertiK simulation (CertiKSimulation) | 22 | PASS |
| Salt mining (SaltMining) | 3 | PASS (from PR branch) |
| Fuzz tests (BondVaultFuzz) | 5 (256 runs each) | PASS (from PR branch) |
| Invariant tests (BondVaultInvariants) | 5 (1000 runs) | PASS (from PR branch) |
| Fork tests (CapacityOracleFork) | 5 | PASS on Base mainnet |
| **Total** | **~185** | |

### Coverage by contract (estimated from test-to-function mapping)

| Contract | Functions tested | Estimated coverage |
|---|---|---|
| BondVault.sol | issueBond, redeemBond, triggerBreaker, resetCircuitBreaker, availableCapacityUSD, previewRedemption, getStatus | >90% |
| PolicyManagerV2.sol | recordPolicy, triggerPayout, markExpired, registerProduct, deactivateProduct, getStats | >85% |
| CoverRouterV2.sol | purchasePolicy, purchasePolicyFor, submitTrigger, configureProduct, quotePremium | >90% |
| TWAPBurner.sol | receivePremium, receiveMarketplaceFee, executeBurn, canBurn, getStats, recoverToken | >85% |
| ClaimBond.sol | setBondVault, mint, burn, isMatured, getEpochInfo, safeTransferFrom | >90% |
| LuminaTokenV2.sol | constructor (distribution), totalBurned, burn, burnFrom | >90% |
| FounderVesting.sol | checkAltSeason, triggerFallback, releaseTranche, updateRecipient | >85% |
| TreasuryVesting.sol | release, isLocked, available, getStatus | >85% |
| CapacityOracle.sol | getLuminaPrice, maxPoliciesPerDay, setPool, setTwapWindow, setEmergencyPrice | >80% |

### Untested paths (known gaps)

1. **CapacityOracle `_getTwapPrice()`** — real TWAP path requires live Uniswap V3 pool (deferred to issue #4). Emergency fallback path tested.
2. **CapacityOracle `!isToken0Lumina` branch** — requires pool where LUMINA > USDC address. Mitigated by CREATE2 salt mining.
3. **V1 contracts** (`CoverRouter.sol`, `PolicyManager.sol`) — 119 original tests in `archive/v1-vault-model/test/` cover these, but they're excluded from the V2 test run.

### How to run

```bash
# Unit + adversarial + CertiK
forge test --no-match-contract "Fork|Invariant" -vvv

# Invariants (1000 runs)
forge test --match-contract Invariant -vvv

# Fork tests (requires BASE_RPC_URL)
BASE_RPC_URL=xxx forge test --match-contract Fork --fork-url base -vvv

# Coverage (may require --ir-minimum on some systems)
forge coverage --no-match-path "archive/**" --ir-minimum
```
