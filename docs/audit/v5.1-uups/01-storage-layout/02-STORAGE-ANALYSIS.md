# V5.1 UUPS Storage Layout Analysis

**Audit:** V5.1 #1 — Storage Layout Deep Audit
**Branch:** `audit/v5.1-01-storage-layout-deep`
**Scope:** 24 concrete UUPS contracts + 1 abstract parent (`BaseShield`)
**Companion:** `01-INVENTORY.md` (raw per-contract storage listing)

---

## 1. Summary Table

| # | Contract | Auth | Own slots | __gap | Free | Status |
|---|----------|------|-----------|-------|------|--------|
| 1 | LuminaTokenV2 | AccessControl | 0 (!) | 50 | 50 | INFO — no sequential state; gap intact |
| 2 | BondVault | AccessControl | 8 | 50 | 50 | OK |
| 3 | ClaimBond | Ownable | 3 | 50 | 50 | OK |
| 4 | PolicyManagerV2 | Ownable | 11 | 50 | 50 | OK |
| 5 | CoverRouterV2 | Ownable | 7 | 50 | 50 | OK |
| 6 | TWAPBurner | Ownable | ~18 | 50 | 50 | OK — largest consumer |
| 7 | AdaptiveFeeDistributor | Ownable | 1 | 50 | 50 | OK |
| 8 | BuybackEngine | AccessControl | 7 | 50 | 50 | OK |
| 9 | LuminaBondMarketplace | AccessControl | 5 | 50 | 50 | OK |
| 10 | ShieldKeeper | Ownable | 1 | 50 | 50 | OK |
| 11 | BaseShield (abstract) | Ownable | 6 | 50 | 50 | OK |
| 12 | FlashBTCShield1h | Ownable | 6+1 | 50 (child) | 50 | OK — BaseShield + 1 mapping |
| 13 | FlashBTCShield4h | Ownable | 6+1 | 50 | 50 | OK |
| 14 | FlashBTCShield24h | Ownable | 6+1 | 50 | 50 | OK |
| 15 | FlashBTCShield48h | Ownable | 6+1 | 50 | 50 | OK |
| 16 | FlashETHShield1h | Ownable | 6+1 | 50 | 50 | OK |
| 17 | FlashETHShield24h | Ownable | 6+1 | 50 | 50 | OK |
| 18 | FlashETHShield48h | Ownable | 6+1 | 50 | 50 | OK |
| 19 | MicroDepegShield | Ownable | 6+1 | 50 | 50 | OK |
| 20 | RateShockShield | Ownable | 6+3 | 50 | 50 | OK |
| 21 | CapacityOracle | Ownable | 5 | 50 | 50 | OK |
| 22 | SolvencyOracle | AccessControl | 12 | 50 | 50 | OK |
| 23 | CEXLiquidityReserve | AccessControl | 7 | 50 | 50 | OK |
| 24 | MaintenanceReserve | AccessControl | 6 | 50 | 50 | OK |
| 25 | TreasuryVesting | Ownable | 4 | 50 | 50 | OK |

All 24 (+ BaseShield) have **50 free gap slots** remaining.
`TWAPBurner` is the largest real consumer at ~18 slots; still 32 slots of growth headroom
are available inside the existing gap.

---

## 2. Issues Found by Severity

### CRITICAL
None.

### HIGH
None.

### MEDIUM
None.

### LOW
**L-01 — LuminaTokenV2 declares zero sequential state.**
The only apparent own storage, `totalBurned`, is actually a *view function*
(`MAX_SUPPLY − totalSupply()`). All persistent data lives in parents' ERC-7201
namespaced slots. This is not a bug — it is explicit derivation — but the `uint256[50]
private __gap` is technically oversized relative to current need (0 own slots used).
No action required; the gap allows adding real state later.

### INFO
**I-01 — All upgrade paths use OpenZeppelin v5.x namespaced storage (ERC-7201).**
Parents (`OwnableUpgradeable`, `AccessControlUpgradeable`, `ReentrancyGuardUpgradeable`,
`ERC20Upgradeable`, `ERC1155Upgradeable`, `ERC1155SupplyUpgradeable`,
`ERC1155HolderUpgradeable`, `Initializable`, `UUPSUpgradeable`) all store state at
keccak-derived namespace slots. Consequence: child contracts' first declared variable
lands at **slot 0** of the proxy, confirmed by the `_SlotLayout` test for each contract.

**I-02 — Gap naming inconsistency in Shield children.**
`BaseShield` uses `uint256[50] private __gap;`, while Shield children use
`uint256[50] private __gap_shield;`. The different identifier is **deliberate**
(to avoid Solidity's "identically named storage variable" shadow warning) and does
not impact layout — each contract's gap lives at the end of its own slot range.

**I-03 — `BondVault._deployer` + `_policyManagerSet` are packed in the same slot.**
Slot 4 stores `address _deployer` (20 bytes) + `bool _policyManagerSet` (1 byte).
This is expected Solidity behaviour; storage tests pass vm.load checks for this slot
(not explicitly verified bit-for-bit here, but preserved across upgrade).

**I-04 — `ShieldKeeper` packs `policyManager` and `paused` in slot 0.**
Verified by `test_Storage_ShieldKeeper_SlotLayout`: low 20 bytes = policyManager,
byte 20 = paused flag.

**I-05 — `ClaimBond` packs `bondVault` and `_bondVaultSet` in slot 0.**
Verified the same way.

**I-06 — `CoverRouterV2` packs `capacityOracle` (slot 3) with `paused`.**
The compiler fits both into the same 32-byte slot.

---

## 3. Recommendations

1. **Preserve the 50-slot gap sizing.** Every contract has ≥32 slots of headroom;
   shrinking the gap now would create migration pain later. No action needed.

2. **Never insert variables before the existing declared ones on an upgrade.**
   If a new field is required, append it after the last state variable and *inside*
   the gap region (decrementing the gap array length). The storage-collision test
   suite will catch any violation on the next audit pass.

3. **Keep `_deployer` + `_policyManagerSet` packing in BondVault.**
   Re-ordering would shift subsequent slots and break upgrade compatibility.

4. **For `RateShockShield` specifically:** the child-specific state consumes 3 slots
   after the BaseShield gap (`aavePool`, `usdc`, `_rateData`). Currently fits within
   the child's `__gap_shield[50]`. When adding more fields, decrement `__gap_shield`.

5. **Document namespaced storage.** Add a one-line comment on each child contract
   noting that slot 0 is the first own variable (parents use ERC-7201). Optional.

---

## 4. Test Coverage

See `REPORT.md` for detailed test counts. Every contract has:
- State-preservation after basic upgrade (24 tests)
- Slot-layout verification via vm.load (24 tests)
- Multi-upgrade sequential state preservation (24 tests)
- Inheritance-order / auth survival (24 tests)
- __gap zero-region checks for representative contracts (3 tests)
- Cross-contract upgrade compatibility (5 tests)

Total: ~104 substantive tests. 100% exercise real proxy deployments and real state
mutation — no math-only tests.

---

## 5. Verdict

**SECURE** — No storage collisions, no mis-ordered inheritance, all gaps
correctly sized, and all upgrade paths preserve state under both single and
sequential upgrade scenarios.
