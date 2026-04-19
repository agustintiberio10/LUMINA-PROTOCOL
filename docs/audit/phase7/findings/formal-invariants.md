# LUMINA V5.0 -- Formal Invariants Catalog

**Phase:** 7 (Security Audit)
**Date:** 2026-04-19
**Scope:** 28 Solidity source files, ~4700 LOC
**Methodology:** Manual proof sketches + Foundry invariant fuzzing + static analysis

---

## I-01: Token Supply Conservation

**Formal Statement:**

```
forall t > t_deploy:
    totalSupply(t) <= totalSupply(t_deploy)
    AND totalSupply(t_deploy) == 100_000_000 * 1e18
```

No function exists that can increase `totalSupply()` after the constructor completes.

**Proof Sketch:**

1. `LuminaTokenV2` inherits `ERC20` and `ERC20Burnable` from OpenZeppelin. The `ERC20` base contract exposes `_mint()` as `internal`, meaning only the contract itself can call it.
2. The constructor calls `_mint()` exactly five times, distributing 70M + 14M + 8M + 5M + 3M = 100M LUMINA. An `assert(totalSupply() == MAX_SUPPLY)` confirms this at deploy time.
3. After the constructor, no function in `LuminaTokenV2` invokes `_mint()`. There is no public/external `mint()` function.
4. The only supply-modifying functions post-deploy are `burn()` (inherited from `ERC20Burnable`, callable by token holders on their own balance) and `burnFrom()` (restricted to `BURNER_ROLE`, which burns from a specified account).
5. Both `burn()` and `burnFrom()` call `_burn()`, which decreases `totalSupply()`.
6. The contract is not upgradeable (no proxy pattern, no `delegatecall`, no `selfdestruct` with redeploy).

**Test References:**

- `test/token/LuminaTokenV2Test.t.sol` -- verifies supply == 100M at deploy
- `test/invariants/SystemInvariants.t.sol` -- invariant `totalSupply() <= initialSupply`
- `test/fuzz/LuminaTokenFuzz.t.sol` -- fuzz burn operations never increase supply

**Counterexamples Considered:**

- Could `BURNER_ROLE` somehow mint? No -- `burnFrom()` calls `_burn()`, not `_mint()`.
- Could `DEFAULT_ADMIN_ROLE` grant a role that mints? No role maps to a mint function because none exists.
- Could a constructor re-entrancy issue lead to extra mints? No -- the constructor mints to EOAs/contracts that do not call back, and `assert(totalSupply() == MAX_SUPPLY)` would catch any discrepancy.

---

## I-02: Distribution Matrix Consistency

**Formal Statement:**

```
forall (sLevel in [0..3], mLevel in [0..3]):
    let (burn, buyback, ops, maint) = _lookupDistribution(sLevel, mLevel)
    burn + buyback + ops + maint == 10000
```

All 16 quadrant entries in `AdaptiveFeeDistributor._lookupDistribution()` sum to exactly 10000 BPS (100%).

**Proof Sketch:**

1. The function is `pure` with hardcoded return values for each of the 16 (sLevel, mLevel) combinations.
2. Manual verification of all 16 tuples:

| sLevel | mLevel | burn | buyback | ops | maint | SUM |
|--------|--------|------|---------|-----|-------|-----|
| 0 | 0 | 9500 | 0 | 0 | 500 | 10000 |
| 0 | 1 | 9000 | 500 | 0 | 500 | 10000 |
| 0 | 2 | 8500 | 1000 | 0 | 500 | 10000 |
| 0 | 3 | 7500 | 2000 | 0 | 500 | 10000 |
| 1 | 0 | 9000 | 500 | 0 | 500 | 10000 |
| 1 | 1 | 8500 | 800 | 200 | 500 | 10000 |
| 1 | 2 | 7000 | 2100 | 200 | 700 | 10000 |
| 1 | 3 | 5500 | 3500 | 200 | 800 | 10000 |
| 2 | 0 | 7500 | 1800 | 200 | 500 | 10000 |
| 2 | 1 | 5500 | 3500 | 200 | 800 | 10000 |
| 2 | 2 | 3800 | 5500 | 200 | 500 | 10000 |
| 2 | 3 | 1800 | 7500 | 200 | 500 | 10000 |
| 3 | 0 | 4800 | 4500 | 200 | 500 | 10000 |
| 3 | 1 | 2800 | 6500 | 200 | 500 | 10000 |
| 3 | 2 | 800 | 8500 | 200 | 500 | 10000 |
| 3 | 3 | 0 | 9600 | 200 | 200 | 10000 |

3. Input validation: `require(sLevel < 4)` and `require(mLevel < 4)` reject out-of-range inputs.
4. The `TWAPBurner._executeAdaptive()` also has a runtime check: `require(burnBps + buybackBps + opsBps + maintBps <= 10000)`.

**Test References:**

- `test/core/AdaptiveFeeDistributorTest.t.sol` -- tests all 16 quadrants explicitly
- `test/fuzz/AdaptiveFeeDistributorFuzz.t.sol` -- fuzz `(sLevel, mLevel)` and assert sum == 10000

**Counterexamples Considered:**

- Could a future upgrade change the values? No -- the function is `pure` and the contract is not upgradeable.
- Could integer overflow corrupt the sum? No -- all values are well within `uint256` range.

---

## I-03: Maintenance Floor

**Formal Statement:**

```
forall (sLevel in [0..3], mLevel in [0..3]):
    let (_, _, _, maint) = _lookupDistribution(sLevel, mLevel)
    maint >= 200
```

The maintenance bucket receives at least 200 BPS (2%) in every quadrant configuration.

**Proof Sketch:**

1. From the exhaustive table in I-02, the minimum `maint` value is 200 BPS, occurring in exactly two quadrants: (3,3) and an inspection of all rows shows values are 500, 500, 500, 500, 500, 500, 700, 800, 500, 800, 500, 500, 500, 500, 500, 200.
2. The absolute minimum is 200 BPS at quadrant (3,3) -- the most extreme crisis scenario, where buyback receives 96% priority.
3. All other quadrants maintain 500+ BPS for maintenance.

**Test References:**

- `test/core/AdaptiveFeeDistributorTest.t.sol` -- verifies minimum maintenance in crisis quadrant
- `test/fuzz/AdaptiveFeeDistributorFuzz.t.sol` -- asserts `maint >= 200` for all fuzzed inputs

**Counterexamples Considered:**

- Could maintenance be set to 0? Only if the hardcoded values were wrong. Verified by enumeration.
- Does the TWAPBurner fallback maintain this floor? Yes -- `FALLBACK_MAINTENANCE_BPS = 500`.

---

## I-04: Burn Cap Per Transaction

**Formal Statement:**

```
forall calls to burnFromReserves(amount):
    amount <= (lumina.balanceOf(bondVault) * 5) / 100
```

Each call to `BondVault.burnFromReserves()` is limited to at most 5% of the vault's current LUMINA balance.

**Proof Sketch:**

1. `burnFromReserves()` (line 288-298 of `BondVault.sol`) reads `currentBalance = lumina.balanceOf(address(this))`.
2. It computes `maxBurnPerTx = (currentBalance * 5) / 100`.
3. It requires `amount <= maxBurnPerTx` before proceeding with the burn.
4. The `onlyAuthorized` modifier restricts callers to addresses explicitly approved via `setAuthorizedCaller()`, which itself requires `AUTHORIZED_CALLER_ADMIN_ROLE`.
5. The balance check is performed against the live `balanceOf()`, so sequential burns in the same block each reference the updated (post-burn) balance.

**Test References:**

- `test/bonds/BondVaultTest.t.sol` -- tests 5% cap enforcement and revert on excess
- `test/fuzz/BondVaultFuzz.t.sol` -- fuzz amounts against vault balance

**Counterexamples Considered:**

- Could an authorized caller call `burnFromReserves()` multiple times in one transaction to drain more? Yes, but each subsequent call references the reduced balance. After 14 sequential 5% burns in one tx, ~51.3% remains. Full drain via this path requires ~90 calls, each burning progressively less. This is by design -- the cap prevents catastrophic single-call loss.
- Could `amount` overflow? No -- `uint256` multiplication of balance (max ~70M * 1e18) by 5 is well within range.

---

## I-05: Marketplace Fee Constancy

**Formal Statement:**

```
SELLER_FEE_BPS == 150 AND BUYER_FEE_BPS == 150
totalFee = 3% of listing price (1.5% seller + 1.5% buyer)
```

Marketplace fees are hardcoded constants, not configurable by any role.

**Proof Sketch:**

1. In `LuminaBondMarketplace.sol`, lines 27-28:
   - `uint256 public constant SELLER_FEE_BPS = 150;`
   - `uint256 public constant BUYER_FEE_BPS = 150;`
2. Both are declared `constant`, meaning their values are embedded in bytecode at compilation and cannot be changed at runtime.
3. `executeBuy()` computes fees using only these constants:
   - `sellerFee = (l.priceUSDC * SELLER_FEE_BPS) / BPS_DENOMINATOR;`
   - `buyerFee = (l.priceUSDC * BUYER_FEE_BPS) / BPS_DENOMINATOR;`
4. All fees are forwarded to `twapBurner` (line 119): `usdc.safeTransfer(twapBurner, sellerFee + buyerFee)`.
5. There is no admin function to modify fee BPS values.

**Test References:**

- `test/marketplace/LuminaBondMarketplaceTest.t.sol` -- verifies exact fee amounts
- `test/fuzz/MarketplaceFuzz.t.sol` -- fuzz price values and verify fee consistency

**Counterexamples Considered:**

- Could `FEE_MANAGER_ROLE` change fees? No -- the role only controls `setTwapBurner()` (fee destination), not fee amounts.
- Could rounding cause fees to deviate? For very small prices (< 67 USDC units), the fee truncates to 0. This is documented and acceptable.

---

## I-06: CEX Reserve Bucket Limits

**Formal Statement:**

```
(a) allocatedFromImmediate <= IMMEDIATE_AMOUNT (2.8M LUMINA)
(b) allocatedFromVesting <= getVestedAmount() at time of allocation
(c) allocatedFromStrategic == 0 when block.timestamp < deploymentTimestamp + STRATEGIC_LOCK (547 days)
```

**Proof Sketch:**

1. **ImmediateUse**: `getAvailableInBucket(ImmediateUse)` returns `IMMEDIATE_AMOUNT - allocatedFromImmediate`. The `allocate()` function requires `amount <= available`, so `allocatedFromImmediate` can never exceed `IMMEDIATE_AMOUNT` (2,800,000 * 1e18).

2. **VestingLinear**: `getAvailableInBucket(VestingLinear)` returns `getVestedAmount() - allocatedFromVesting` (or 0 if already exceeded). `getVestedAmount()` returns `(VESTING_AMOUNT * elapsed) / VESTING_DURATION`, capped at `VESTING_AMOUNT` (8.4M). The `allocate()` function checks availability before incrementing `allocatedFromVesting`.

3. **StrategicReserve**: `getAvailableInBucket(StrategicReserve)` returns 0 when `block.timestamp < deploymentTimestamp + STRATEGIC_LOCK` (547 days ~ 18 months). The require check `amount <= available` in `allocate()` ensures no strategic tokens can be allocated before the lock expires.

4. All allocations additionally enforce a monthly cap of 1,000,000 * 1e18 via `monthlyAllocations[currentMonth]`.

**Test References:**

- `test/treasury/CEXLiquidityReserveTest.t.sol` -- tests bucket limits and time locks
- `test/fuzz/CEXReserveFuzz.t.sol` -- fuzz allocations against bucket availability

**Counterexamples Considered:**

- Could `ALLOCATOR_ROLE` bypass the vesting schedule? No -- `getVestedAmount()` is computed from `block.timestamp` which cannot be manipulated on-chain.
- Could the monthly cap be bypassed? No -- `monthlyAllocations` is incremented before transfer and checked with `require`.
- Could an allocator front-run the month boundary to double-spend? No -- `getCurrentMonth()` is deterministic based on `block.timestamp`, and each month's spending is independently tracked.

---

## I-07: BondVault One-Shot (PolicyManager)

**Formal Statement:**

```
setPolicyManager() can be called at most once.
After the call: _policyManagerSet == true AND policyManager != address(0)
```

**Proof Sketch:**

1. `BondVault.setPolicyManager()` (lines 103-110) checks:
   - `require(msg.sender == _deployer)` -- only the original deployer
   - `require(!_policyManagerSet)` -- only if not already set
   - `require(_pm != address(0))` -- non-zero address
2. On success, it sets `policyManager = _pm` and `_policyManagerSet = true`.
3. Any subsequent call reverts with "PolicyManager already set" because `_policyManagerSet` is `true` and there is no function that resets it to `false`.
4. The `_policyManagerSet` flag is `private`, preventing external contracts from reading or modifying it (not that they could modify storage anyway).
5. Alternative path: if `_policyManager != address(0)` is passed to the constructor, the flag is set there, also permanently.

**Test References:**

- `test/bonds/BondVaultTest.t.sol` -- tests one-shot setter and revert on second call
- `test/integration/attacks/AccessControlAttacks.t.sol` -- verifies deployer-only restriction

**Counterexamples Considered:**

- Could a re-entrancy during `setPolicyManager()` set it twice? No -- the function has no external calls before setting the flag, and the flag is checked first (CEI pattern).
- Could storage collision overwrite `_policyManagerSet`? Solidity 0.8.20 storage layout is deterministic and collision-free for standard contracts.

---

## I-08: ClaimBond One-Shot (BondVault)

**Formal Statement:**

```
setBondVault() can be called at most once.
After the call: _bondVaultSet == true AND bondVault != address(0)
```

**Proof Sketch:**

1. `ClaimBond.setBondVault()` (lines 38-44) checks:
   - `onlyOwner` modifier -- only contract owner
   - `require(!_bondVaultSet)` -- only if not already set
   - `require(_bondVault != address(0))` -- non-zero address
2. On success: `bondVault = _bondVault`, `_bondVaultSet = true`.
3. No function exists to reset `_bondVaultSet` to `false`.
4. The `onlyBondVault` modifier (lines 27-31) checks both `_bondVaultSet` and `msg.sender == bondVault`, ensuring all mint/burn operations go through the authorized vault.

**Test References:**

- `test/bonds/ClaimBondTest.t.sol` -- tests one-shot setter and revert on second call
- `test/integration/scenarios/DeploymentFlow.t.sol` -- verifies deployment wiring sequence

**Counterexamples Considered:**

- Could a front-running attack set the BondVault before the legitimate deployer? Addressed by `[V1/SR2]` fix: `onlyOwner` prevents mempool observers from calling `setBondVault()`.
- Could the owner transfer ownership and the new owner reset it? No -- `_bondVaultSet` has no reset function regardless of who owns the contract.

---

## I-09: Circuit Breaker Safety

**Formal Statement:**

```
forall states where paused == true:
    issueBond() reverts
    AND redeemBond() succeeds (if other preconditions met)
```

The circuit breaker blocks new bond issuance but NEVER blocks redemption of matured bonds.

**Proof Sketch:**

1. `issueBond()` (line 121): `require(!paused, "Circuit breaker active")` -- reverts when paused.
2. `redeemBond()` (lines 155-183): contains NO check on `paused`. The function only requires:
   - `usdAmount > 0`
   - Bond is matured (`claimBond.isMatured(epochId)`)
   - Caller has sufficient bond balance
   - Price is above `MIN_REDEEM_PRICE`
   - Sufficient LUMINA in reserve
3. The `triggerBreaker()` function sets `paused = true` when price drops below `MIN_PRICE` ($0.005).
4. The `resetCircuitBreaker()` function sets `paused = false` when price recovers to `RESET_PRICE` ($0.008) and cooldown has elapsed.
5. Neither function touches any redemption-related state.

**Test References:**

- `test/bonds/BondVaultTest.t.sol` -- tests issuance blocked + redemption allowed while paused
- `test/integration/scenarios/EmergencyResponse.t.sol` -- full circuit breaker lifecycle
- `test/audit/AdversarialAuditTest.t.sol` -- adversarial pause scenarios

**Counterexamples Considered:**

- Could `redeemBond()` fail indirectly when paused? Only if `lumina.transfer()` fails (insufficient balance) or if price drops below `MIN_REDEEM_PRICE` ($0.001). These are independent of the `paused` flag.
- Could a re-entrancy in `triggerBreaker()` corrupt the paused state? No -- `triggerBreaker()` requires `!paused` and sets `paused = true` atomically. The `ReentrancyGuard` on other functions prevents nested state changes.

---

## I-10: Solvency Cooldown

**Formal Statement:**

```
forall quadrant changes in SolvencyOracle:
    block.timestamp >= lastQuadrantChange + COOLDOWN_BETWEEN_QUADRANT_CHANGES (7 days)
```

Quadrant transitions in `SolvencyOracle` require a minimum 7-day cooldown between changes.

**Proof Sketch:**

1. `SolvencyOracle.evaluate()` (lines 58-85) computes new solvency/momentum levels from 3-sample moving averages.
2. Line 73-74: quadrant changes only occur when:
   ```
   (newS != currentSolvencyLevel || newM != currentMomentumLevel)
   && block.timestamp >= lastQuadrantChange + COOLDOWN_BETWEEN_QUADRANT_CHANGES
   ```
3. On a successful change, `lastQuadrantChange = block.timestamp` (line 80), resetting the cooldown.
4. `COOLDOWN_BETWEEN_QUADRANT_CHANGES` is a `public constant` set to `7 days` (604800 seconds).
5. Additionally, `evaluate()` itself has a `EVALUATION_INTERVAL` of `1 days`, preventing rapid re-evaluation.
6. The 3-sample moving average further dampens rapid transitions -- it takes at least 3 evaluations (3 days minimum) to fully shift the average.

**Test References:**

- `test/oracles/SolvencyOracleTest.t.sol` -- tests cooldown enforcement
- `test/fuzz/BondVaultFuzzV2.t.sol` -- fuzz oracle state transitions

**Counterexamples Considered:**

- Could `emergencyPaused` bypass the cooldown? No -- `emergencyPaused` blocks `evaluate()` entirely, preventing any quadrant change.
- Could block.timestamp manipulation on L2 circumvent the cooldown? L2 sequencers have limited timestamp flexibility (typically < 15 minutes), far below the 7-day threshold.
- Could an attacker call `evaluate()` 3 times rapidly to shift the average? No -- `EVALUATION_INTERVAL = 1 days` enforces minimum spacing.

---

## Summary

| ID | Invariant | Status | Verification Method |
|----|-----------|--------|-------------------|
| I-01 | Token Supply Conservation | VERIFIED | Code review + invariant fuzz |
| I-02 | Distribution Matrix Consistency | VERIFIED | Exhaustive enumeration + fuzz |
| I-03 | Maintenance Floor | VERIFIED | Exhaustive enumeration + fuzz |
| I-04 | Burn Cap Per Tx | VERIFIED | Code review + fuzz |
| I-05 | Marketplace Fee Constancy | VERIFIED | Constant analysis + fuzz |
| I-06 | CEX Reserve Bucket Limits | VERIFIED | Code review + fuzz |
| I-07 | BondVault One-Shot | VERIFIED | Code review + attack tests |
| I-08 | ClaimBond One-Shot | VERIFIED | Code review + attack tests |
| I-09 | Circuit Breaker Safety | VERIFIED | Code review + integration tests |
| I-10 | Solvency Cooldown | VERIFIED | Code review + fuzz |

All 10 invariants hold under the current implementation. No counterexamples were found that violate any invariant.
