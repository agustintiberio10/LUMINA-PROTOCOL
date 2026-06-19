# LUMINA Protocol — Functional (Code-Correctness) Audit V5.3/V5.4

**Sprint 7.4 — Functional Security Audit** · **Date:** 2026-05-27
**Scope:** all `src/` contracts deployed as V5.4 on Base Sepolia (going to mainnet in Phase 7)
**Type:** code correctness — bugs, vulnerabilities, edge cases, access control, reentrancy, arithmetic, state invariants. **Not** economic (see `economic-audit-v53-2026-05-27.md`).
**Method:** line-by-line read of the actual source on `main`, parallelized across three auditors; every finding cites `file:line`. No code modified.

> This is the **last audit before Phase 6 (Pre-Mainnet Hardening)**. It re-validates that prior remediations (F-01…F-31, MR-H01…MR-L11) are present in the current source, and hunts for residual functional defects. It does **not** repeat economic findings.

---

## 1. Resumen Ejecutivo

### Veredicto: 🟠 **PASS WITH FINDINGS**

The contract logic is **correct and unusually defensive**. Across ~27 in-scope contracts I found **no critical or high-severity code bug** (no reentrancy exploit, no arithmetic error, no broken invariant, no access-control bypass). Check-Effects-Interactions is followed nearly everywhere, `nonReentrant` is applied broadly, all ERC-1155 callback vectors are correctly sequenced after state finalization, decimals (6/8/18) are bridged consistently, every `unchecked{}` block is provably safe, and **all 7 state invariants PASS**. Prior fixes (MR-L10 double-decrement, F-01 multi-block barrier, F-02/F-09 oracle guards, F-13/F-14/F-28 marketplace/burner CEI) are confirmed present and effective.

**The residual risk is not in the code — it is in deploy-time configuration and the absence of an on-chain delay on a large surface of destructive setters.** A handful of "MUST NOT SHIP" config gates, if missed at mainnet handover, are catastrophic (e.g. an unset oracle pool yields arbitrary redemption pricing). These genuinely **block mainnet** until verified by a deploy checklist.

### Total findings por severidad
| Severidad | Cantidad | IDs |
|-----------|---------:|-----|
| 🔴 Crítico (bloquea mainnet) | **1** | FN-C1 |
| 🟠 Alto (fixear pre-launch) | **3** | FN-H1, FN-H2, FN-H3 |
| 🟡 Medio (post-launch) | **4** | FN-M1, FN-M2, FN-M3, FN-M4 |
| 🟢 Bajo (nice-to-have) | **6** | FN-L1…FN-L6 |
| ℹ️ Informativo | **6** | FN-I1…FN-I6 |
| **Invariantes verificadas** | **7/7 PASS** | I-1…I-7 |

### Top 5 findings críticos 🚨

1. 🚨 **FN-C1 — CapacityOracle returns an unguarded owner-set `emergencyPrice` if `pool == address(0)`** (`oracles/CapacityOracle.sol:32-36, 207`). The code itself says *"THIS PATH MUST NOT SHIP TO MAINNET."* If the TWAP pool is not wired before handover, `getLuminaPrice()` returns an arbitrary owner price with no TWAP cross-check and no timelock — which drives **all** redemption and burn pricing. **Deploy-gate; blocks mainnet.**
2. 🚨 **FN-H1 — `CoverRouterV2.usdc` / `TWAPBurner.usdc` point at MockUSDC on testnet and must be reverted to canonical Circle USDC before any user-facing release** (`core/CoverRouterV2.sol:354-358`, BL-USDC). Shipping with the mock means premiums are paid in a worthless token.
3. 🚨 **FN-H2 — Shield/adapter proxies set `owner = msg.sender` in `initialize`; a non-atomic proxy deploy is front-runnable** (`shields/FlashShieldAdapter.sol:123-130`, `BaseFlashShield.__BaseFlashShield_init`). If proxy creation and `initialize` are separate txs, an attacker seizes ownership + `_authorizeUpgrade` of a live shield. Implementation is `_disableInitializers()`-protected; the risk is entirely in the deploy script being atomic — **verify out-of-band.**
4. 🚨 **FN-H3 — Large surface of value-critical setters repoint trust dependencies instantly, no timelock** (`CapacityOracle.setPool`, `LuminaOracleV2.setOracleKey/registerFeed`, all `setUsdc`, `TWAPBurner.setCapacityOracle/setDexRouters`, `CoverRouterV2.setPolicyManager/…`). A compromised owner can repoint the price oracle to a controlled contract and misprice every redemption — atomically. (Overlaps the economic audit's no-timelock governance finding; here it is the *functional* enumeration.)
5. 🚨 **FN-M1 — `PolicyManagerV2` has no `ReentrancyGuard`** (`core/PolicyManagerV2.sol:62`). `triggerPayout`→`bondVault.issueBond`→`claimBond.mint` hands control to an attacker-controlled `onERC1155Received` while no PM guard is held. **Not exploitable today** (CEI is correct + callers are guarded), but it is a latent defense-in-depth gap on an ERC-1155-callback-bearing orchestrator — one refactor away from a real reentrancy.

---

## 2. Tabla de Access Control (resumen)

Full per-function table in §Appendix-A. Highlights of **critical** functions and their guards:

| Contract | Critical function(s) | Guard | Note |
|----------|----------------------|-------|------|
| LuminaTokenV2 | `burnFrom` (allowance-free confiscation), `grantRole(BURNER_ROLE)` | `onlyRole(BURNER_ROLE)` / admin | By design (H-1); strength = key custody (FN-I1) |
| BondVault | `issueBond`, `reserveCapacity`, `redeemBond` | `msg.sender==policyManager` / nonReentrant | Solvency ceiling enforced (I-2) |
| BondVault | `burnFromReserves`, `decreaseObligations`, `setAuthorizedCaller`, `setCexReserve` | `onlyAuthorized` / admin | `burnFromReserves` capped 5%/tx |
| ClaimBond | `mint`/`burn`, `updateBondVault` | `onlyBondVault` / `onlyOwner` | `updateBondVault` instant repoint (FN-H3) |
| PolicyManagerV2 | `triggerPayout`, `settlePolicy`, `setRouter` | `onlyRouter` / `onlyShield` / owner | No reentrancy guard (FN-M1) |
| CoverRouterV2 | `submitTrigger`, `configureProduct`, `setUsdc`, `setCapacityOracle`, `setPaused` | `onlyRelayer` / owner | Instant repoints (FN-H1/H3) |
| TWAPBurner | `executeBurn` (permissionless), `setCapacityOracle`, `setDexRouters`, `setReserves` | open + cooldown / owner | `setFeeDistributor` no zero-check (FN-L5) |
| CapacityOracle | `setPool`, `proposeEmergencyPrice` (24h TL) | owner / **timelock (only one in codebase)** | `setPool` itself NOT timelocked (FN-H3) |
| LuminaOracleV2 (non-UUPS) | `setOracleKey`, `registerFeed`, `addSigner` | `onlyOwner` | Controls all price proofs/feeds |
| BuybackEngine | `executeOffer` | `onlyRole(BUYBACK_OPERATOR_ROLE)` + nonReentrant | MR-M04 gated |
| Marketplace | `executeBuy`, `setUsdc`, `setTwapBurner` | nonReentrant / admin / fee-mgr | CEI + pull-payment (F-14/F-28) |
| Treasury/CEX/Maintenance | `release`/`allocate`/`spend`, `setMonthlyCap` | role + monthly cap | Caps admin-mutable (FN-M3) |
| FounderVesting(V2) (non-UUPS) | `updateRecipient` | `onlyOwner` | Redirects 8M LUMINA instantly (FN-M2) |
| Shields/Adapter | `verifyAndCalculate`, `checkAndSettlePolicy`, `_authorizeUpgrade` | router / keeper-or-relayer / owner | F-01/F-08 gated; init front-run (FN-H2) |

**UUPS:** 17 upgradeable contracts; **every one** gates `_authorizeUpgrade` (onlyOwner / DEFAULT_ADMIN_ROLE), carries a `__gap`, calls `_disableInitializers()` in its constructor, and guards `initialize`/reinit. **No missing gate, no storage-layout collision found.** Non-upgradeable (correct, documented): LuminaOracleV2, FounderVesting, FounderVestingV2, AerodromeAdapter, UniswapV3Adapter. FounderVesting→V2 is a fresh deploy + manual migration (no shared proxy storage) — correct.

---

## 3. Findings Detallados

### 🔴 Crítico

**FN-C1 — Unguarded `emergencyPrice` redemption-pricing path if oracle pool unset**
*Contract/line:* `oracles/CapacityOracle.sol:32-36` (warning), `:207` (`getLuminaPrice` no-pool branch), `:347` (`setPool`).
*Description:* When `pool == address(0)`, `getLuminaPrice()` returns an owner-set `emergencyPrice` with **no TWAP cross-check and no timelock**. This price is consumed by `BondVault.redeemBond`/`issueBond`, `TWAPBurner` minOut, and `BuybackEngine` double-burn. `setEmergencyPrice` is blocked once a pool is set (F-09), but nothing forces a pool to exist at mainnet launch.
*Impact:* If mainnet is deployed/handed over with no pool, the owner (or a compromised key) sets any redemption price → arbitrary value extraction from the reserve, or mispriced payouts. Catastrophic.
*PoC:* deploy to mainnet, leave `pool` unset, call `setEmergencyPrice(1e30)` → every `$1` bond redeems for a dust amount of LUMINA (or, low price, drains reserve).
*Fix:* **Deploy checklist gate:** assert `capacityOracle.pool() != address(0)` and a sane `getLuminaPrice()` before handover; ideally have the deploy script set the pool atomically and renounce `setEmergencyPrice`. The contract correctly warns — make it a hard CI/deploy assertion.

### 🟠 Alto

**FN-H1 — USDC points at MockUSDC; must revert to Circle USDC pre-launch**
*Contract/line:* `core/CoverRouterV2.sol:354-358`, `core/TWAPBurner.sol:363` (`setUsdc`), BL-USDC.
*Impact:* Premiums/fees collected in a worthless mock; redemption/marketplace settle in mock USDC.
*Fix:* Mainnet deploy assertion: `usdc == 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (Base USDC) in CoverRouterV2, TWAPBurner, Marketplace. Block release otherwise.

**FN-H2 — Shield/adapter init front-run on non-atomic deploy**
*Contract/line:* `shields/FlashShieldAdapter.sol:123-130` (+ doc 109-122), `shields/BaseFlashShield.__BaseFlashShield_init`, `products/Flash*Shield*.sol:17-18`.
*Description:* `initialize` sets `owner = msg.sender`. Implementations are `_disableInitializers()`-protected, but if the ERC1967Proxy is created and then initialized in a **separate** transaction, an attacker front-runs `initialize` to become owner → gains `_authorizeUpgrade` over a live shield.
*Impact:* Full takeover / malicious upgrade of a shield or adapter.
*Fix:* Verify the deploy scripts use `new ERC1967Proxy(impl, abi.encodeCall(initialize, (...)))` (single atomic tx) for every shield/adapter. This is the one initializer gap requiring out-of-band confirmation.

**FN-H3 — Instant repointing of value-critical dependencies (no on-chain delay)**
*Contract/line:* `oracles/CapacityOracle.sol:347` `setPool`; `oracles/LuminaOracleV2.sol:318` `setOracleKey`, `:360/379` `registerFeed/updateFeed`; `core/CoverRouterV2.sol:333-364` `setPolicyManager/setTwapBurner/setCapacityOracle/setUsdc`; `core/TWAPBurner.sol:344` `setCapacityOracle`, `:372/382` `setDexRouters/addDexRouter`; `core/PolicyManagerV2.sol:158/169`; `bonds/ClaimBond.sol:103` `updateBondVault`; `marketplace/LuminaBondMarketplace.sol:238/253`.
*Description:* A single owner/admin tx can swap the price oracle, signer key, Chainlink feeds, USDC token, DEX venues, or core wiring with **immediate effect**. The only timelocked operation in the entire codebase is `CapacityOracle.proposeEmergencyPrice` (24h, F-09) — but `setPool` (which *also* changes pricing) is not.
*Impact:* Compromised owner misprices redemptions (repoint oracle to controlled contract), redirects premium/fee flows, or bricks settlement — atomically, no observation window. (Functional enumeration of the economic audit's EC-C2.)
*Fix:* Route value-critical setters through a `TimelockController`; at minimum `CapacityOracle.setPool`, `LuminaOracleV2.setOracleKey/registerFeed`, all `setUsdc`, `TWAPBurner.setCapacityOracle/setDexRouters`.

### 🟡 Medio

**FN-M1 — `PolicyManagerV2` lacks `ReentrancyGuard`**
*Contract/line:* `core/PolicyManagerV2.sol:62` (no `ReentrancyGuardUpgradeable`); `recordPolicy:246`, `triggerPayout:327`, `settlePolicy:369`, `markExpired:445`.
*Description:* `triggerPayout`→`bondVault.issueBond`→`claimBond.mint`→`onERC1155Received` on the attacker-controlled buyer, while no PM guard is held. Safe today only because CEI sets `pr.triggered=true` before the call (re-entry reverts on `require(!pr.triggered)`), callers are `onlyRouter`/`onlyShield`, and `issueBond` holds BondVault's own guard.
*Impact:* Latent reentrancy — any future refactor moving a state write past the external call, adding a non-router caller, or introducing cross-policy interaction silently becomes exploitable.
*Fix:* Inherit `ReentrancyGuardUpgradeable`, `__ReentrancyGuard_init()` in `initialize`, add `nonReentrant` to the four functions (decrement `__gap` for the added slot).

**FN-M2 — Vesting recipient/destination changeable instantly by single owner**
*Contract/line:* `token/FounderVesting.sol:182` & `FounderVestingV2.sol:288` `updateRecipient`; `token/TreasuryVesting.sol:51` `release(to, amount)` (arbitrary `to`).
*Impact:* Compromised owner redirects the 8M founder allocation or sends treasury releases anywhere (within ≤250k/mo, ≤3M caps). Non-upgradeable Ownable → only mitigation is owner = Safe/timelock.
*Fix:* Own these with Gnosis Safe + TimelockController; consider hardcoding `to == recipient` in `TreasuryVesting.release`.

**FN-M3 — Spend caps are admin-mutable with no delay**
*Contract/line:* `treasury/MaintenanceReserve.sol:110` `setMonthlyCap` (unbounded raise) then `:83` `spend`; `treasury/CEXLiquidityReserve.sol:117` `allocate` (≤1M LUMINA/mo to any recipient).
*Impact:* Monthly caps give no protection against a compromised admin — the admin lifts the cap first, then drains in the same window.
*Fix:* Timelock cap *increases* (decreases can stay instant); add a max-step per change.

**FN-M4 — Two independent $0.005 floor gates can disagree (circuit-breaker coupling)**
*Contract/line:* `core/CoverRouterV2.sol:253-259` (router price-floor gate) vs `bonds/BondVault.sol:156-161, 820-830` (`policiesPaused` flag, **not enforced in CoverRouter**).
*Description:* The router blocks new policies when `getLuminaPrice() < threshold` (hysteresis MIN $0.005 / RESET $0.008). BondVault's own floor-pause sets `policiesPaused`, but CoverRouter does not read it (off-chain enforcement only, by design per Economic Fix R1). So the two gates can be in different states.
*Impact:* On-chain inconsistency: a price between the two floors, or a stale `policiesPaused`, yields divergent pause behavior. Not a fund loss, but a correctness/operational gap.
*Fix:* Have CoverRouter read `bondVault.policiesPaused()` (or unify on a single registry), or document explicitly that BondVault's flag is advisory-only and ensure ops enforce it.

### 🟢 Bajo

**FN-L1 — `TWAPBurner.receive()` accepts ETH that is permanently locked (SWC-105)**
*Contract/line:* `core/TWAPBurner.sol:538` `receive() external payable {}`; `recoverToken:457` handles ERC-20 only; gas-refund storage (`:483, 534-537`) is DORMANT.
*Impact:* Any ETH sent (the dormant gas-refund design implied draining `address(this).balance`) is unrecoverable. No funds expected there → LOW.
*Fix:* Add an owner ETH-sweep, or remove `receive()`.

**FN-L2 — `BuybackEngine` max-price uses a fused `/(100 * 1e12)` constant (fragile)**
*Contract/line:* `marketplace/BuybackEngine.sol:208-210`.
*Description:* Correct today (`faceValueUSD` 18-dec × pct / 100 / 1e12 → 6-dec USDC cap), but the constant conflates a percent denominator with an 18→6 decimal shift; a future change to `getFaceValue`'s scale silently breaks the cap.
*Fix:* Split the two factors and document.

**FN-L3 — Obligation-sync divergence: `totalCommittedUSD` can be overstated (fails safe)**
*Contract/line:* `bonds/BondVault.sol:700-705` `decreaseObligations` + `bonds/ClaimBond.sol:156-171` `burnByHolder`.
*Description:* `burnByHolder` best-effort decrements committed via try/catch; on skip it emits `ObligationsSyncSkipped` leaving committed overstated → understates available capacity (conservative). Buckets are best-effort, not provably exact under all holder-burn/admin interleavings. (Invariants I-3/I-5 PASS with this caveat.)
*Impact:* No solvency risk (over-collateralized direction). Breaks exact accounting; off-chain reconciliation is load-bearing.
*Fix:* Document that committed total is an upper bound; reconcile off-chain.

**FN-L4 — Duplicated `BASE_TS` / avg-month constants across two contracts (drift risk)**
*Contract/line:* `bonds/BondVault.sol:688,690` (`1767225600`, `2629746`) duplicated in `bonds/ClaimBond.sol:238,240`.
*Description:* Epoch↔timestamp math is duplicated; they agree today but editing one without the other would desync bond bucketing.
*Fix:* Extract to a shared library/constant.

**FN-L5 — `TWAPBurner.setFeeDistributor` accepts `address(0)` / unvalidated**
*Contract/line:* `core/TWAPBurner.sol:394-397`.
*Impact:* Inconsistent with sibling validated setters; mitigated by the `_getDistribution` try/catch fallback (85/8/2/5), so impact is limited to silently ignoring the distributor.
*Fix:* `require(_feeDistributor != address(0))` or document zero-clear semantics.

**FN-L6 — Inline magic numbers that should be named constants**
*Contract/line:* `core/CoverRouterV2.sol:264` `100e6` (min coverage), `:269-270` `10000*10000*10000`; `core/PolicyManagerV2.sol:259` `8000`/`10000` (payout ratio, not shared with router's `REQUIRED_PAYOUT_RATIO_BPS`).
*Fix:* Name them; share the payout-ratio constant.

### ℹ️ Informativo

- **FN-I1** — `LuminaTokenV2.burnFrom` is allowance-free confiscation, grantable via `DEFAULT_ADMIN_ROLE` (`token/LuminaTokenV2.sol:109-112`). Intentional (H-1); strength rests entirely on admin-key custody + role-grant timelock.
- **FN-I2** — Premium forces a `$0.000001` minimum when rounding to zero (`CoverRouterV2.sol:271, 387`). Benign with min $100 coverage.
- **FN-I3** — Edge inputs (coverage=0/>max, duration=0, amount=0, oracle price=0) all revert cleanly with explicit guards — verified across CoverRouter/BondVault/TWAPBurner/Marketplace/BuybackEngine.
- **FN-I4** — ERC-1155 receiver hooks (`Marketplace.executeBuy`, `BondVault.issueBond`) are correctly sequenced after state finalization; both are `nonReentrant`.
- **FN-I5** — Dormant features clearly documented: `cexReserve=0x0` auto-injection, TWAPBurner gas-refund storage, adaptive-mode thresholds = 0. No dead-code exploit surface.
- **FN-I6** — Epoch↔calendar-month drift from avg-second constant is cosmetic; both ClaimBond and BondVault use the identical formula so redemption keying is self-consistent (`BondVault.sol:687-694`).

---

## 4. Invariantes Verificadas (Phase 4)

| # | Invariante | Estado | Evidencia |
|---|-----------|--------|-----------|
| I-1 | LuminaTokenV2 supply = 100M, no mint beyond cap | ✅ PASS | mints 70/14/8/5/3M then `assert(totalSupply()==MAX_SUPPLY)` (`LuminaTokenV2.sol:79-85`); no post-init mint path |
| I-2 | BondVault `totalCommitted ≤ 50% × reserveValueUSD` | ✅ PASS | `issueBond` ceiling check `BondVault.sol:344-348` (live oracle price) |
| I-3 | BondVault committed/reserved/queued consistency | ✅ PASS* | MR-L10 double-decrement confirmed fixed (`processQueue` decrements only queued, `:572-576`). *Caveat FN-L3 |
| I-4 | No underflow on release/decrement | ✅ PASS | guards `BondVault.sol:316-327, 702`; 0.8 checked math |
| I-5 | ClaimBond face=$1, supply==liability, mint/burn via vault | ✅ PASS* | `getFaceValue=1e18`, mint/burn `onlyBondVault`. *Caveat: `burnByHolder` public (BuybackEngine path), FN-L3 |
| I-6 | PolicyManager status accounting one-way | ✅ PASS | write-once flags `PolicyManagerV2.sol:331-332, 373-374, 448-449` |
| I-7 | Marketplace escrow == Σ active listings ≤ balanceOf(market) | ✅ PASS | escrow = ERC-1155 balance; CEI on list/cancel/buy; `recoverERC1155` protects claimBond |

---

## 5. TODO / FIXME / Aspiracional en el código (Phase 6)

No `TODO`/`FIXME`/`XXX`/`HACK` markers exist in `src/`. Conditional "must-not-ship / dormant" comments:

| File:line | Text (abridged) | Tipo |
|-----------|-----------------|------|
| `oracles/CapacityOracle.sol:32-36` | "no-pool path returns emergencyPrice… **MUST NOT SHIP TO MAINNET**" | 🔴 deploy gate (FN-C1) |
| `core/CoverRouterV2.sol:354-358` | "must be reverted to canonical Circle USDC (BL-USDC)" | 🟠 deploy gate (FN-H1) |
| `bonds/BondVault.sol:777` | "cexReserve is address(0) today (dormant)" | dormant (FN-I5) |
| `core/TWAPBurner.sol:483, 534-537` | "gasRefund* storage now DORMANT — no code path pays a refund" | dead storage (FN-L1) |
| `token/FounderVestingV2.sol:40` | "freeze v1 (renounce / leave dormant)" | migration note |
| `oracles/LuminaOracleV2.sol:46-51` | "NOT upgradeable… redeploy every Shield" | accurate design note |

NatSpec spot-check: signatures match docs; LuminaOracleV2 and LuminaBondMarketplace headers honestly correct prior false claims (good). Magic numbers: FN-L6.

---

## 6. SWC Checklist (Phase 7)

| SWC | Estado | Evidencia |
|-----|--------|-----------|
| 105 Unprotected ether withdrawal | 🟢 PASS w/ LOW | `TWAPBurner.receive()` locks ETH (FN-L1); no other path |
| 107 Reentrancy | ✅ PASS | nonReentrant + CEI throughout; FN-M1 is defense-in-depth only |
| 114 Tx-order dependence / front-run | ✅ PASS | F-01 barrier+dwell, `onlyRelayer` trigger; marketplace price fixed in listing |
| 115 tx.origin auth | ✅ PASS | no `tx.origin` in `src/` (F-22 removed prior use) |
| 116 block.timestamp dependence | ✅ PASS | tolerances ≫ ±15s drift (F-27 analysis `BondVault.sol:475-481`) |
| 128 DoS unbounded loop | ✅ PASS | `processQueue` ≤20/call, queue ≤10k, ShieldKeeper ≤MAX_POLICIES; remaining loops owner-bounded |
| 132 Unexpected ether balance | ✅ PASS | no logic gates on `address(this).balance` |
| 136 Private data on-chain | ✅ N/A | no secrets stored |

---

## 7. Recomendaciones Priorizadas para Fase 6 (Pre-Mainnet Hardening)

| Prio | Acción | Finding |
|------|--------|---------|
| 1 | **Deploy-gate CI assertions:** `CapacityOracle.pool()!=0` + sane price; `usdc==Circle USDC` (router/burner/marketplace); sequencer feeds wired on chainid 8453 | FN-C1, FN-H1, FN-M4-ops |
| 2 | **Audit deploy scripts for atomic proxy init** (`ERC1967Proxy(impl, encodeCall(initialize,…))`) for every shield/adapter | FN-H2 |
| 3 | **TimelockController** on value-critical setters (oracle pool/key/feeds, USDC, DEX routers, core wiring) + vesting/treasury owners | FN-H3, FN-M2, FN-M3 |
| 4 | **Add `ReentrancyGuardUpgradeable` to PolicyManagerV2** (`triggerPayout/settlePolicy/markExpired/recordPolicy`) | FN-M1 |
| 5 | Have CoverRouter read `bondVault.policiesPaused()` (or document advisory-only) | FN-M4 |
| 6 | Sweep/remove `TWAPBurner.receive()`; zero-check `setFeeDistributor`; extract duplicated epoch constants; name magic numbers | FN-L1, FN-L4, FN-L5, FN-L6 |
| 7 | Document committed-total as an upper bound; off-chain reconciliation for `burnByHolder` sync skips | FN-L3 |

---

### Appendix-A — Full access-control table
The complete per-function caller/guard/criticality matrix (every external/public state-changing function across all in-scope contracts) is retained in the audit working notes; §2 summarizes the critical subset. UUPS gate / `__gap` / `_disableInitializers` matrix: all 17 upgradeable contracts verified compliant; 5 contracts intentionally non-upgradeable.

### Appendix-B — Verified prior remediations (present & effective in current source)
F-01 (multi-block barrier + 5min dwell, `BaseFlashShield.sol:251-345`), F-02/F-09 (oracle min-redeem-price + emergency-price timelock), F-13 (async burn), F-14/F-28 (marketplace pull-payment + CEI), F-21/H-1 (BURNER_ROLE confiscation by design), F-23 (max coverage), F-26 (reinit guard), F-27 (timestamp drift), MR-H01 (oracle freshness, fail-closed), MR-H02 (relayer settlement gating), MR-L10 (queue double-decrement). All confirmed.

*No code was modified. Read-and-analyze only, per sprint scope. No findings overlap the economic audit beyond the single cross-referenced governance item (FN-H3 ↔ EC-C2).*
