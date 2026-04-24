# Audit V5.1 #25 — Migration Procedures

Step-by-step runbooks for every kind of migration LUMINA Protocol V5.1 may
perform. Each procedure assumes the proxy owner is a multisig (Gnosis Safe)
behind a `TimelockController`, as configured in production deployments.

---

## Procedure A — Simple bugfix upgrade

**When to use.** Logic-only change. No storage changes, no new variables, no
reinitialization needed.

### Preconditions
- Bug confirmed in production.
- Fix implemented in a new implementation contract (same filename, same storage
  declarations, same `__gap` size).
- Unit tests + regression suite pass on CI.

### Steps
1. **Deploy the new implementation contract.**
   - `forge create src/.../ContractV2.sol:ContractV2 --rpc-url <rpc> ...`
   - Record the new implementation address.
2. **Verify storage layout compatibility.**
   ```
   forge inspect src/.../ContractV2.sol:ContractV2 storageLayout > new.json
   forge inspect src/.../ContractV1.sol:ContractV1 storageLayout > old.json
   diff <(jq '.storage' old.json) <(jq '.storage' new.json)
   ```
   Any diff must be reviewed and rejected unless it is a strictly-appended
   trailing variable matched by a `__gap` reduction.
3. **Verify impl is initialized-disabled.** Confirm
   `ContractV2.constructor` calls `_disableInitializers()`.
4. **Queue the upgrade in the timelock.** Call
   `TimelockController.schedule(target = proxy, data = upgradeToAndCall(newImpl, ""), delay = MIN_DELAY)`.
5. **Wait out the timelock delay** (monitored by the community).
6. **Execute the upgrade.** `TimelockController.execute(...)` — this invokes
   the proxy's `upgradeToAndCall(newImpl, "")`.
7. **Post-upgrade verification.**
   - `IERC1967.getImplementation()` returns new impl.
   - All public getters return their pre-upgrade values (spot-check committed
     USD, reserved USD, product configs, balances).
   - Run smoke tests: one write operation per contract (e.g., configure a
     test product, then revert the config).
8. **Announce publicly.** Link the tx hash, new impl address, changelog.

### Rollback window
Keep V1 implementation tracked for **30 days minimum** after deployment; a
single `upgradeToAndCall(V1_IMPL, "")` tx brings the proxy back.

---

## Procedure B — Upgrade with state migration (reinitializer)

**When to use.** V2 adds one or more new state variables that need a non-zero
initial value for already-deployed proxies (e.g. a new fee, a new URL, a new
mode flag).

### Preconditions
- `ContractV2` declares a function with the exact signature
  `reinitializeV2(...) external reinitializer(2)` (or any version `> 1`).
- The new variables are **appended** to V1's derived-contract region, ahead of
  the existing `__gap`.
- Reinitializer logic is idempotent-by-version: it writes only to the new
  variables and never reads/writes V1 state.

### Steps
1. Deploy new implementation. Same as Procedure A.
2. Verify layout. Same as Procedure A — expect trailing additions only.
3. **Build the reinitialization calldata.**
   ```solidity
   bytes memory initData = abi.encodeWithSelector(
       ContractV2.reinitializeV2.selector,
       value1, value2, ...
   );
   ```
4. **Queue the upgrade with init data in the timelock.** Call
   `upgradeToAndCall(newImpl, initData)`.
5. Wait out the timelock delay.
6. Execute. The proxy delegatecalls `reinitializeV2` atomically with the
   implementation switch — there is no window in which V2 code runs against
   un-seeded V2 state.
7. **Post-upgrade verification.**
   - New variables read the expected seeded values.
   - Pre-existing getters return their pre-upgrade values.
   - `reinitializeV2` cannot be called again — revert test in CI.
8. **Deprecate any old state** that the new variable replaces (if any),
   documenting the deprecation in the changelog.

### Failure modes to watch
- `InvalidInitialization` on step 6 ⇒ the reinitializer version is ≤ the
  contract's current version. Choose a higher version.
- Calldata mismatch ⇒ the tx reverts; proxy still points at V1 until execute
  succeeds. Safe to retry.

---

## Procedure C — Multi-contract coordinated upgrade

**When to use.** Two or more contracts change *and* the new behaviour of one
depends on new functions/fields of the other (e.g. `PolicyManager + BondVault`
when a new reservation field is added to both sides).

### Preconditions
- All new implementations compile together. Run
  `forge test --match-path "test/audit/v5.1-uups/recovery/migration/**"` against
  a local deployment that upgrades everything.
- Integration fork test passes on a Base mainnet fork.

### Steps
1. **Lock-in deployment.** Freeze new-feature work for both contracts.
2. **Deploy every new implementation first.** In a single multisend bundle if
   possible; record every impl address.
3. **Determine upgrade order.**
   - For ABI-compatible changes (no caller expects a new function from the
     callee) ⇒ any order is safe.
   - For non-ABI-compatible changes (caller V2 calls a new callee-V2-only
     method) ⇒ **upgrade callees first, callers last**. Callers still on V1
     will not invoke the new selector; callers once on V2 will only ever see a
     callee that has already been upgraded.
4. **Batch the upgrade calls in a single multisig tx** when possible. For
   timelock-gated upgrades, schedule each upgrade as a separate Operation but
   execute them in the above order in back-to-back txs.
5. **Integration smoke-test after each upgrade.** Run the end-to-end lifecycle
   (buy policy → trigger → redeem) after each contract upgrade. A break means
   rollback immediately.
6. **After the last contract is upgraded, run the full regression suite** on a
   mainnet fork.

### Failure modes
- Callee fails to upgrade mid-batch ⇒ the caller is now stranded with a V1
  callee but V2-expectations-in-code; rollback the caller.
- A new mandatory field is missing in an older caller that hasn't been
  upgraded yet ⇒ revert. Roll back the callee or rush the caller upgrade.

---

## Procedure D — Emergency rollback

**When to use.** V2 is live, a critical bug or exploit is identified, and we
must revert to V1 immediately.

### Preconditions
- V1 implementation address is tracked (in a file or multisig records).
- The bug is deterministic and reproducible. (If not, consider pausing rather
  than rolling back — every rollback loses any V2-specific state.)

### Steps
1. **PAUSE first.** If the contract has `paused` / `setPaused` (`CoverRouterV2`,
   `ShieldKeeper`, `TWAPBurner`), pause immediately via the multisig. This
   limits exposure while the rollback is prepared.
2. **Confirm rollback safety.** The V1 implementation must still be
   deployed at its known address (`vm.load` the implementation slot vs the
   recorded address).
3. **Skip timelock if possible.** Emergency rollback typically uses a
   time-locked `EMERGENCY_ROLE` (optional) or a fast-track multisig sign-off.
   Base behaviour with only a timelock means users endure the full delay; this
   is why **known-good rollback impls must be pre-authorized**.
4. **Call `upgradeToAndCall(V1_IMPL, "")`.** No calldata is passed — V1 runs
   with V1 code against existing storage. V2-only variables remain in storage
   but are unreadable via V1's ABI.
5. **Re-initialize if V1 contract needed seeding that V2 changed.** Normally
   V1→V2 only adds variables; the downgrade path needs no re-init. If V2
   *changed* a V1 variable's semantic meaning (a bug!), this is the hard part
   — manual state repair via admin functions may be required.
6. **Communicate.** Publish the rollback tx hash, impacted users (if any), and
   the remediation plan. Schedule a post-mortem.
7. **Unpause** once the rollback is confirmed healthy.

### Important: reinitializer-version bookkeeping
If V2 ran `reinitializer(2)`, the OpenZeppelin `_initialized` counter is now 2.
A future V2-v2 (bugfix of the upgrade itself) must use `reinitializer(3)` or
higher. The counter is monotonic and **cannot be reset**.

### Hard failure — rollback is impossible
If V2 destroyed V1 state (e.g. reinitializer overwrote a V1 variable), the
only path forward is fix-forward (deploy V3 that restores the state). Document
this in the post-mortem and add a regression test to the migration suite.

---

## Appendix — FounderVesting migration (non-upgradeable)

FounderVesting is deployed via `new FounderVesting(...)` — not a proxy — and
has no upgrade mechanism. "Migration" means deploying a **new** FounderVesting
instance at a new address.

1. Deploy `FounderVesting2` with updated parameters.
2. The old instance is untouched; it keeps all its state (`triggerTimestamp`,
   `tranchesReleased`, etc.). Already-released tranches cannot be reclaimed.
3. If the old instance still holds LUMINA that must move to the new instance,
   the LUMINA token must be paused / drained via an admin mechanism — this
   currently has no on-chain path, so it would require a governance-level
   intervention (DAO vote + token contract rescue code) which is **outside
   scope of normal operations**.
4. `deployedAt` resets on the new contract ⇒ a fresh 4-year
   `FALLBACK_DURATION` clock starts.

**Practical implication.** Any behaviour change that is not covered by the
owner-level `updateRecipient` function requires a fresh deploy and manual
asset handling. This is by design: the founder allocation is deliberately
rigid for credibility.
