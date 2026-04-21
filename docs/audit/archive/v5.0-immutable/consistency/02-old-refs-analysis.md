# 02 — Old References Analysis

**Audit:** V5.0 Consistency Check  
**Date:** 2026-04-19  
**Branch:** `audit/consistency-check-v5`  
**Scope:** All references to pre-V5.0 concepts (values, naming, comments) across `src/`, `test/`, and `docs/`.

---

## Classification Legend

| Symbol | Meaning | Action Required |
|--------|---------|-----------------|
| :x: MUST FIX | Wrong value in executable code | Fix before Phase 7.5 |
| :warning: STALE COMMENT | Code is correct, comment is outdated | Fix before mainnet |
| :white_check_mark: OK | Historical doc or valid V5.0 usage | No action |

---

## 1. Bond Reserve Value (82M vs 70M)

### :x: MUST FIX — `src/oracles/CapacityOracle.sol:44`

```solidity
uint256 public constant BOND_RESERVE = 82_000_000 * 1e18;
```

**Expected (V5.0):** `70_000_000 * 1e18`

**Context:** V5.0 changed distribution from 82/10/5/3 to 70/14/8/5/3. The `BOND_RESERVE` constant is used only in the `maxPoliciesPerDay()` view function. Actual capacity checks in BondVault use `lumina.balanceOf(vault)` directly, so this does not affect solvency or payouts. However, capacity estimates returned by the view function are inflated by ~17%.

**Impact:** Low (view-only). No security risk. Causes incorrect off-chain capacity estimates.

### :white_check_mark: OK — `docs/SECURITY-AUDIT-V4.md` (lines 231, 308, 311, 406)

Multiple references to "82M LUMINA" in the V4 security audit document. These are correct for the V4 version they describe. The document title explicitly marks it as V4.

### :white_check_mark: OK — `docs/SKILL-V4.1.md` (lines 32, 63, 71, 238)

References to "82,000,000" and "82M" in V4.1 documentation. Correct for the version described.

### :warning: STALE COMMENT — `test/oracles/CapacityOracleTest.t.sol:62`

```solidity
// 82M * 0.50 * 0.036 / (500 * 730 * 0.01) = ~404
```

Test comment references 82M. The test uses `BOND_RESERVE` constant from CapacityOracle, so when the constant is fixed to 70M, this comment and expected values will need updating.

### :warning: STALE COMMENT — `test/bonds/BondVaultTest.t.sol:76`

```solidity
// 82M * $0.036 = $2.952M, 50% = $1.476M
```

Comment references 82M in arithmetic explanation. The test itself uses deal() to fund the vault so the value is independent, but the comment is misleading.

### :warning: STALE COMMENT — `test/fuzz/BondVaultFuzz.t.sol:47`

```solidity
deal(address(token), address(vault), 82_000_000 * 1e18);
```

Fuzz test seeds vault with 82M instead of 70M. Not a correctness issue (fuzz tests can use any amount) but inconsistent with V5.0 deployment parameters.

### :warning: STALE COMMENT — `test/fuzz/BondVaultFuzzV2.t.sol:48`

```solidity
deal(address(token), address(vault), 82_000_000 * 1e18);
```

Same issue as BondVaultFuzz.t.sol above.

### :warning: STALE COMMENT — `test/audit/CertiKSimulation.t.sol` (lines 448, 670, 676)

Multiple comments reference "82M" in simulation descriptions. These are narrative comments within test logic; they do not affect test correctness but are misleading.

### :white_check_mark: OK — `docs/audit/phase7/PHASE7-AUDIT-REPORT.md:132`

Already identifies the 82M issue as finding I-02. This is the audit tracking the problem.

---

## 2. Founder Vesting Amount (10M vs 8M)

### :warning: STALE COMMENT — `src/token/FounderVesting.sol:8`

```solidity
/// @notice 10M LUMINA locked until AltSeason conditions or 4-year fallback.
```

**Code is correct:** `TOTAL_AMOUNT = 8_000_000 * 1e18` (line 50).

Additionally, line 50 has a trailing comment `// 10M LUMINA` that contradicts the value:

```solidity
uint256 public constant TOTAL_AMOUNT = 8_000_000 * 1e18; // 10M LUMINA
```

**Context:** V4 allocated 10% (10M) to founder. V5.0 changed to 8% (8M). The constant was updated but both comments were left from V4.

**Impact:** None. Code behavior is correct. Comments are confusing for auditors.

### :white_check_mark: OK — `src/token/LuminaTokenV2.sol:51`

```solidity
_mint(founderVesting, 8_000_000 * 1e18); // 8% - Founder (AltSeason)
```

Correctly mints 8M. Consistent with V5.0 distribution.

---

## 3. Shield Naming References

### :warning: STALE COMMENT — `src/interfaces/IShield.sol:15`

```solidity
*   Example: DepegShield 30d policy -> PM tries StableShort, if full -> StableLong.
```

"StableShort" and "StableLong" are vault tier names from the V3/V4 waterfall architecture. V5.0 uses a single BondVault. The example is illustrative but references concepts that no longer exist in the protocol.

"DepegShield" is also a V3/V4 product name. V5.0 has `MicroDepegShield` instead.

**Impact:** None. This is a comment-only example explaining the interface design rationale.

---

## 4. PolicyManager / CoverRouter References Without "V2" Suffix

### :white_check_mark: OK — Multiple files in `src/`

Files referencing `PolicyManager` or `CoverRouter` without the "V2" suffix:
- `src/bonds/BondVault.sol`
- `src/core/TWAPBurner.sol`
- `src/core/PolicyManagerV2.sol`
- `src/core/CoverRouterV2.sol`
- `src/products/BaseShield.sol`
- `src/interfaces/IShield.sol`

These references are to the V2 contract instances. The "V2" is part of the contract name (e.g., `PolicyManagerV2`), but variables, interfaces, and comments referencing the concept use the shorter form. This is standard Solidity practice (interface names and variable names do not need to mirror the contract name suffix).

---

## 5. BSS (Binary Settlement Shield) Naming

### :white_check_mark: OK — Shield product files

All shield products use `BaseShield` as base class with Binary Settlement pattern. This IS the V5.0 naming convention. The BSS architecture is a V5.0 feature.

---

## Summary Table

| # | Location | Issue | Classification | Priority |
|---|----------|-------|----------------|----------|
| 1 | `src/oracles/CapacityOracle.sol:44` | BOND_RESERVE = 82M, should be 70M | :x: MUST FIX | Before Phase 7.5 |
| 2 | `src/token/FounderVesting.sol:8` | NatSpec says "10M", code is 8M | :warning: STALE COMMENT | Before mainnet |
| 3 | `src/token/FounderVesting.sol:50` | Inline comment says "10M LUMINA" on 8M constant | :warning: STALE COMMENT | Before mainnet |
| 4 | `src/interfaces/IShield.sol:15` | Example references "StableShort" / "StableLong" | :warning: STALE COMMENT | Before mainnet |
| 5 | `test/oracles/CapacityOracleTest.t.sol:62` | Comment references 82M math | :warning: STALE COMMENT | With fix #1 |
| 6 | `test/bonds/BondVaultTest.t.sol:76` | Comment references 82M math | :warning: STALE COMMENT | Low |
| 7 | `test/fuzz/BondVaultFuzz.t.sol:47` | deal() uses 82M | :warning: STALE COMMENT | Low |
| 8 | `test/fuzz/BondVaultFuzzV2.t.sol:48` | deal() uses 82M | :warning: STALE COMMENT | Low |
| 9 | `test/audit/CertiKSimulation.t.sol` | Multiple 82M comments | :warning: STALE COMMENT | Low |
| 10 | `docs/SECURITY-AUDIT-V4.md` | Multiple 82M references | :white_check_mark: OK | N/A |
| 11 | `docs/SKILL-V4.1.md` | Multiple 82M references | :white_check_mark: OK | N/A |
| 12 | `docs/audit/phase7/PHASE7-AUDIT-REPORT.md:132` | Tracks 82M issue | :white_check_mark: OK | N/A |
| 13 | PolicyManager/CoverRouter no "V2" | Variable naming convention | :white_check_mark: OK | N/A |
| 14 | BSS struct naming | V5.0 convention | :white_check_mark: OK | N/A |

**Totals:** 1 MUST FIX, 8 STALE COMMENTS, 5 OK
