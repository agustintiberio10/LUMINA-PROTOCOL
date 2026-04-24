# Audit V5.1 #25 — Migration Scenarios

LUMINA Protocol V5.1 consists of **24 UUPS-upgradeable contracts** plus one
**immutable contract (FounderVesting)**. This document enumerates every kind of
migration the protocol will realistically encounter over its lifetime and the
invariants that must be preserved across each one.

Each scenario below has a matching test in
`test/audit/v5.1-uups/recovery/migration/MigrationPath.t.sol`.

---

## 1. Simple upgrade (V1 → V2, no storage changes)

**Description.** An implementation is deployed with the exact same storage
layout as V1 (same inherited contracts in the same order, same state variables
in the same order, same `__gap` size). Typical use case: a logic-only bugfix
or gas optimisation.

**Example.** A small rounding fix in `BondVault.redeemBond` that changes no
storage.

**Invariants.**
- All storage slots retain their pre-upgrade values.
- All cross-contract pointers (`policyManager`, `bondVault`, `claimBond`,
  `twapBurner`, `priceOracle`, etc.) still resolve.
- All role grants are preserved (`DEFAULT_ADMIN_ROLE`, `BURNER_ROLE`,
  `AUTHORIZED_CALLER_ADMIN_ROLE`, `FEE_MANAGER_ROLE`, `ALLOCATOR_ROLE`,
  `SPENDER_ROLE`).
- All user balances, committed/reserved USD, product configs, policy records,
  bond balances, and listings are preserved.
- Post-upgrade functional operations work unchanged.

**Procedure.** See `02-MIGRATION-PROCEDURES.md#procedure-a--simple-bugfix-upgrade`.

---

## 2. Upgrade with new storage variable (gap-consuming)

**Description.** V2 adds one or more state variables **at the end of
Vx storage**, reducing the reserved `__gap` by the number of new 32-byte slots.
No existing slot is renamed, repositioned, or retyped.

**Example.** Adding a `uint256 public newFeatureValue` to `ShieldKeeper` in V2.
Since V1 has `uint256[50] private __gap` at the end, V2's new slot lands at
the first gap position and the gap shrinks to `uint256[49]`.

**Invariants.**
- All V1 slots retain their values.
- The new variable reads `0` initially (EVM default) unless a reinitializer
  seeds it.
- Inherited-contract internal layouts (OpenZeppelin `AccessControl`, `ERC1155`,
  `ERC20`, `Ownable`, `ReentrancyGuard`) are unchanged because we only modify
  the trailing derived-contract region.

**Invariant at implementation-author time.** Appending the variable **before**
the gap (not after) is what makes it safe. Appending after an existing gap
would be a layout break.

---

## 3. Upgrade with reinitializer (state migration)

**Description.** V2 introduces a new variable that needs a non-zero initial
value for existing proxies. A `reinitializer(uint64 version)` function seeds
the value atomically with the upgrade via
`upgradeToAndCall(newImpl, abi.encodeWithSelector(reinitFn.selector, ...))`.

**Example.** `ClaimBond.reinitializeURI(version)` from fix #18 — it installs
the canonical `_baseURI` for proxies deployed before the metadata fix.
Another example is `PolicyManagerV2Reinit.reinitializeV2(flag)` in
`UpgradePathMigrations.t.sol`.

**Invariants.**
- The reinitializer runs **exactly once** per version. A second call with the
  same `version` reverts with OpenZeppelin's `InvalidInitialization` error.
- Lower versions cannot be replayed (`version = 1` after V2 is disallowed).
- `_disableInitializers` in the implementation constructor ensures the
  reinitializer cannot be invoked directly on the implementation.
- V1 state is not clobbered — the reinitializer only writes the new variable.

---

## 4. Multi-contract coordinated upgrade

**Description.** Several interconnected contracts upgrade as a group because
the new behaviour depends on new functions in each of them (for example,
`CoverRouterV2 + PolicyManagerV2 + BondVault` when a new field is added to
`IBondVault.reserveCapacity`).

**Invariants during the sequence.**
- Order matters for non-ABI-compatible changes. Typical order:
  1. Deploy all new implementations.
  2. Verify each independently against the storage layout with
     `forge inspect <ContractV2> storageLayout`.
  3. Upgrade "callees" first (`BondVault`, then `PolicyManagerV2`), callers
     last (`CoverRouterV2`).
- For ABI-compatible changes, order is irrelevant and the group can upgrade
  in any sequence or even in parallel txs.
- A **partial upgrade** (A on V2, B still V1) is safe iff the V1↔V2 interface
  boundary is unchanged.

**Test coverage.** `test_Migration_UUPS_MultiContract_CoordinatedUpgrade`,
`test_Migration_UUPS_Partial_UpgradeOk`.

---

## 5. Downgrade / Rollback

**Description.** V2 ships a bug. Admin re-points the proxy back to the
previously-deployed V1 implementation via another `upgradeToAndCall`. No
constructor or reinitializer runs — proxies reuse storage as is.

**Invariants.**
- V1 logic once again governs operations.
- Storage slots allocated by V2 but not V1 **still exist in storage**. They
  are orphaned from V1's perspective (no getter/setter), but they are not
  erased. Upgrading forward to V2 again reads them back.
- Pre-V2 V1 state is untouched through the V2→V1 downgrade.
- If V2 had a reinitializer that consumed version 2, **the counter cannot be
  reset**; a future "V2 attempt 2" must use version ≥ 3.

**Operational note.** Rolling back a reinitializer-version upgrade is
asymmetric: the code is reverted but the initialization counter is not.

**Test coverage.** `test_Migration_UUPS_DowngradeV2ToV1_StatePreserved`,
`test_Migration_UUPS_Rollback_AfterBugInV2`.

---

## 6. FounderVesting: immutable contract migration

**Description.** `FounderVesting` is **not upgradeable** — it has no
`UUPSUpgradeable`, no proxy, and its constructor sets immutables. If logic
must change, the only path is **deploying a new contract** and transferring
the LUMINA balance.

**Invariants / procedure.**
- `upgradeTo(X)` has no selector on FounderVesting — any attempt via the
  standard UUPS pattern simply reverts (no matching function).
- Owner-controlled fields (`recipient`) can still be rotated inside the same
  contract via `updateRecipient`.
- To migrate logic (hypothetically):
  1. Deploy a second FounderVesting with updated logic.
  2. Pause / disallow further releases from the old contract (owner disables
     `updateRecipient` by transferring ownership to a burner — outside-scope).
  3. Transfer remaining LUMINA balance from old to new (requires the old
     contract to have a transfer function; the current code has none, so an
     emergency DAO vote + token-level rescue would be required).
  4. All already-released tranches **remain with the original recipient** —
     cannot be clawed back.
- Immutable fields (`oracle`, `aavePool`, `luminaToken`, `usdc`, `deployedAt`)
  are permanent for the instance; a new deploy starts a fresh
  `deployedAt` → a fresh 4-year `FALLBACK_DURATION` clock.

**Test coverage.** `test_Migration_UUPS_FounderVesting_Immutable_CannotUpgrade`,
`test_Migration_UUPS_FounderVesting_NewDeploy_IfNeeded`.

---

## Cross-cutting rules (apply to all scenarios)

1. **Never reorder storage variables.** Append at the end of the derived
   contract, between existing state and `__gap`.
2. **Never change the type of an existing variable** (e.g. `uint256 → uint128`
   inside a packed slot) without analysing every slot that would shift.
3. **Every new variable takes a gap slot.** Mapping/array headers also take
   exactly one slot, so `uint256[50] __gap` is reduced by the *number of
   declared state variables*, not by the number of values stored.
4. **Reinitializers must be guarded with `reinitializer(version)`.** Using
   `initializer` after the first initialization is blocked by OZ and would
   revert.
5. **Rollback readiness** — keep V1 implementation addresses tracked somewhere
   durable (multisig records, deployment manifest) so a `upgradeToAndCall` back
   to V1 is always a single tx away.
6. **FounderVesting is out-of-band.** All upgrade procedures apply only to the
   24 UUPS contracts; FounderVesting is a full redeploy.
