# LUMINA Protocol — Red Team + Manual Review V5.3/V5.4

**Sprint 7.2 (Red Team) + 7.3 (Manual Review)** · **Date:** 2026-05-27
**Scope:** deployed V5.4 contracts on Base Sepolia · **Type:** adversarial multi-step exploits + human line-by-line review
**Method:** 3 parallel red-team agents (economic / technical / governance-social) + a senior-auditor manual read of the 7 priority contracts; on-chain verification of the critical finding. Every finding cites `file:line`. No code modified.

> Third and final audit of Phase 5.5. Prior passes — **7.5 economic** (`economic-audit-v53-2026-05-27.md`) and **7.4 functional** (`functional-audit-v53-2026-05-27.md`) — both returned PASS WITH FINDINGS. This sprint targets what SAST, the economic audit, and the functional audit did **not** find: combined attack vectors, subtle cross-contract inconsistencies, and bugs that need human reasoning.
>
> **Already-known findings are NOT re-counted** (price-coupled capacity EC-C1, single-owner/no-timelock EC-C2, crash triple-failure EC-C3, CapacityOracle emergencyPrice gap FN-C1, USDC mock FN-H1, initialize front-run FN-H2, setters w/o timelock FN-H3, PolicyManagerV2 no ReentrancyGuard FN-M1). Where a result sharpens a known one, it is marked "confirms EC-x/FN-x".

---

## 1. Resumen Ejecutivo

### Veredicto: 🟠 **PASS WITH FINDINGS**

No new directly-profitable economic exploit and no new critical *technical* exploit (no theft, no reentrancy, no storage collision) were found — the margin (2.0×), multi-block barrier + 5-min dwell, oracle-only `minOut`, per-epoch/per-user throttle, and role-gated double-burn hold up under adversarial modelling. **But the red team found one verified CRITICAL governance fact and a cluster of genuinely new MEDIUM correctness bugs that the prior audits missed** because they require cross-contract human reasoning.

### Total findings NUEVOS: **1 🔴 · 1 🟠 · 7 🟡 · 6 🟢 · 6 ℹ️**

### Top 5 findings críticos NUEVOS (no conocidos)

1. 🚨 **RM-C1 (CRITICAL) — Token-confiscation + 70M-reserve admin live on a hot EOA, not the multisig.** Verified on-chain: the founder EOA `0xe585…fDa8` holds `DEFAULT_ADMIN_ROLE` on **both LuminaTokenV2 and BondVault** (`hasRole` = true on each). That role can grant `BURNER_ROLE` → `burnFrom(anyHolder)` with no allowance (confiscate/zero any balance, `LuminaTokenV2.sol:109-112`), and `_authorizeUpgrade` the token or the 70M-LUMINA vault to arbitrary logic (`BondVault.sol:841`). The deploy script *deliberately* keeps these two on the deployer EOA (ADR-012, `DeployLuminaV5Complete.s.sol:488-525`) while every other contract is handed to the Safe. This **sharpens EC-C2** from "no timelock" to "the two most dangerous contracts are governed by a single hot key — not even the multisig." *(Aggravating: that exact key was exposed in plaintext during ops — rotate immediately.)*
2. 🚨 **RM-H1 (HIGH) — `CapacityOracle.setPool` is not timelocked and validates nothing.** `setPool` (`oracles/CapacityOracle.sol:347`, `_setPool:480-487` only reads token0) lets the owner repoint the price source to an attacker-controlled Uniswap pool in one tx, forging the LUMINA price that drives BondVault redemptions, TWAPBurner `minOut`, BuybackEngine burn-sizing, and SolvencyOracle — fully bypassing the F-09 24h timelock that protects `emergencyPrice`. The one timelocked price path has an un-timelocked sibling.
3. 🚨 **RM-M1 (MEDIUM) — 730-day bonds become redeemable up to ~30 days early.** BondVault sets `epochId = _timestampToEpoch(block.timestamp + bondMaturitySeconds)` (truncates to the YYYYMM month bucket, `BondVault.sol:350-351,687-694`); ClaimBond then stores `maturityDate = start of that month` (`ClaimBond.sol:236-241`). The month-truncation means the actual redeemable date is the *start* of the maturity month — up to ~30 days before `issue + 730d`. Holders can redeem before the insured term the premium was priced for.
4. 🚨 **RM-M3 (MEDIUM) — Redeem-clamp burns the full bond but queues only the clamped USD.** In `BondVault.redeemBond` the "shouldn't happen" branch (`:417-435`), when `totalCommittedUSD < requestedUSD18` (reachable once a BuybackEngine double-burn has independently decremented committed), the code burns the holder's **entire** `usdAmount` of bonds but queues only the smaller clamped USD for payout → silent partial loss of redemption value.
5. 🚨 **RM-M4 (MEDIUM) — The R1 "LUMINA floor pause" mitigation is inert on-chain.** `BondVault.policiesPaused` (set by the floor-pause logic, `:162,820-830`) is **never read by the purchase path**; `CoverRouterV2._purchase` gates only on its own `capacityOracle` price check (`:253-259`) and a separate `autoPausedOnce` flag. The two pause systems are unconnected, so the economic-fix R1 floor pause does not actually block new policies.

### Fortalezas confirmadas
- No new **profitable** economic exploit: all 8 modelled attacks (MEV sandwich, correlated-trigger arb, pump/dump, marketplace wash, bond chaining, epoch dilution, epoch-timing, double-burn) are net-negative or mitigated.
- No new **technical** exploit: cross-contract reentrancy (marketplace↔ClaimBond↔BondVault↔BuybackEngine) is clean (CEI + nonReentrant), UUPS storage layouts are append-only with correct `__gap`, EIP-712 is replay/malleability-safe, oracle edge cases fail closed.
- **Scoping corrections (reduce assumed risk):** a compromised **relayer cannot fabricate payouts** (the shield's multi-block barrier gates settlement regardless of caller) nor pull un-approved funds; an **oracle-signer key does NOT unlock V5.4 flash-shield triggers** (shields read Chainlink directly, ignoring the EIP-712 proof path).

---

## 2. Parte A — Red Team

### Agente 1 — Atacante Económico ($1M quant)
| Attack | Capital | Expected profit | Success | Current mitigation (file:line) | Severity | New/confirms |
|---|---|---|---|---|---|---|
| MEV sandwich on `TWAPBurner.executeBurn` | $10k–100k | ≈0 today | Very low | oracle-only `minOut` (`TWAPBurner.sol:267-285`); size cap `maxBurnAmount` 10k (`:114`); cooldown 900s | Low | confirms |
| Cross-product correlated trigger arb | High | Negative EV | Very low | margin 2.0× (`CoverRouterV2.sol:269`); 80% payout; barrier+dwell (`BaseFlashShield.sol:251-345`); $10k cap | Low | confirms EC-C1 |
| Pump/dump around mass redemption | Very high | Negative | Low | throttle 1.08%/epoch + 10%/user; fail-closed `_redeemPrice`; deviation breaker | Med | confirms EC-C3 |
| Marketplace spam / wash trading | Low | Negative (3% fee burned/cycle) | n/a | floor `minPricePerUnit` (`LuminaBondMarketplace.sol:142`); transfer-gating (`ClaimBond.sol:256-266`) | Low | confirms |
| Bond chaining (buy discounted → redeem) | Med | Positive but slow/capped | Low-Med | 730d maturity + throttle + LUMINA price risk | Low | confirms |
| Mass-buy single epoch to dilute holders | High | ≈0 | Very low | bonds are $1-fixed face, not pro-rata pool shares; global oracle price | Low | NEW (theoretical) |
| Trigger right before epoch close | Gas | ≈0 | Very low | bond epoch fixed at mint (`BondVault.sol:350-351`); ±15s drift negligible | Low | confirms |
| BuybackEngine double-burn extraction | role-gated | None to outsider | Very low | role-gated (`BuybackEngine.sol:196`); oracle-sized, 2× cap, 150% gate; 5%/tx | Low | confirms |

**New economic observations:** N-1 per-user throttle is Sybil-bypassable (→ RM-L1); N-2 `processQueue` pays at processing-time price = a timing option (concrete on-chain expression of EC-C3); N-3 `burnByHolder` is self-harm only. No standalone money-printer. Pivot: every "mitigated" row inherits safety from the price oracle — re-validate the F-02 deviation breaker + MR-H01 freshness gate the moment a real pool is wired (today `pool==0x0` makes price a constant = FN-C1).

### Agente 2 — Atacante Técnico (white-hat)
| Vuln | Contract:line | PoC | Severity | New/confirms | Fix |
|---|---|---|---|---|---|
| Sequencer `startedAt==0` guard missing | `CoverRouterV2.sol:436-439`; `BaseFlashShield.sol:156-159` | mainnet feed: a round with `answer=0`,`startedAt=0` → `block.timestamp-0` ≫ grace → reports "active" in a degenerate round | Medium | NEW (→ RM-M6) | add `if(startedAt==0) return false;` (LuminaOracleV2:481 already has it) |
| `processQueue` head-of-line stall | `BondVault.sol:535-603` | a queued entry whose `usdAmount` > shrinking per-epoch cap pins the FIFO head; entries past head+20 unreachable; bonds already burned → permanent lock | Medium | NEW (→ RM-M5) | partial-pay over-cap entries / advance index |
| Double-burn obligation desync if ClaimBond unauthorized | `BuybackEngine.sol:250`+`ClaimBond.sol:163-170` | missing `setAuthorizedCaller` → `decreaseObligations` reverts → caught → committed stays inflated → solvency overstated | Low/Med (config) | NEW (→ RM-M2/L7) | hard deploy invariant |
| Per-user throttle Sybil-bypass | `BondVault.sol:398-400` | split bonds across N EOAs, each gets 10%/user cap | Low | NEW (→ RM-L1) | global cap bounds drain; accept or gate by bond-age |
| cross-contract reentrancy; UUPS layout; EIP-712 replay; oracle edges; minOut | (multiple) | — | **SAFE** | confirms prior CEI/clearance | — |

### Agente 3 — Atacante Governance / Social
| Capture vector | Key holder | Capability (file:line) | Impact | New? | Mitigation |
|---|---|---|---|---|---|
| **LuminaToken DEFAULT_ADMIN on EOA** | founder EOA (verified on-chain) | grant BURNER_ROLE→`burnFrom(any)` (`LuminaTokenV2.sol:109-112`); upgrade token (`:114`) | total token capture / confiscation | **YES → RM-C1** | move to Safe+timelock |
| **BondVault DEFAULT_ADMIN on EOA** | founder EOA (verified) | upgrade vault (`BondVault.sol:841`); `setAuthorizedCaller`→attacker `burnFromReserves` 5%/tx + `decreaseObligations` (`:700,709,724`) | drain/insolvency of 70M reserve | **YES → RM-C1** | Safe+timelock |
| **CapacityOracle.setPool untimelocked** | oracle owner (Safe) | repoint price to attacker pool (`:347,480-487`) | forge LUMINA price downstream | **YES → RM-H1** | timelock + pool validation |
| CoverRouter repoints `twapBurner`/`usdc` | router owner (Safe) | redirect 100% premiums / worthless USDC (`:340,359`) | premium theft / griefing | YES (sharpens FN-H3) | timelock value-critical setters |
| Oracle signer-key forgery | `_oracleKey`/signers | forge EIP-712 proofs; **does NOT unlock flash-shield triggers** (Chainlink-direct) | limited to legacy/signed-proof consumers | YES (scoping) | `requiredSignatures>1` |
| Relayer key | relayers | **cannot fake payouts** (shield-gated); cannot pull un-approved funds; power = censorship/timing | low theft, settlement timing | YES (scoping) | permissionless keeper backstop |
| No first-party self-settle | — | payout depends on keeper being wired+unpaused per adapter (`ShieldKeeper.performUpkeep` permissionless but `setKeeper` optional) | payout censorship if keeper unwired | **YES → RM-M7** | add user-callable `settle()` |

---

## 3. Parte B — Manual Review (por contrato)

**ClaimBond** — implicit `1 token=$1=1e18` never asserted; `burnByHolder` NatSpec promises obligation-sync but try/catch silently degrades (`:156-171`); fee-capture "all trades via marketplace" not guaranteed via `authorizedOperators[from]` (`:256-267`, → RM-L6); duplicated epoch constants (`:238,240`, → Info).
**BondVault** — solvency ceiling is price-dependent (EC-C1); redeem-clamp branch reachable and lossy (`:417-435`, → RM-M3); throttle cap uses floored display price during oracle degradation (`:500-504,664-670`, → RM-L2); `policiesPaused` never read on-chain (`:162`, → RM-M4); `processQueue` head-of-line stall (`:535-603`, → RM-M5).
**PolicyManagerV2** — FN-M1 (no guard) confirmed; `markExpired` mutates shield state before setting `pr.expired` (`:466`, CEI gap, relies on trusted shield + atomic rollback, Low); reservation/commit/mint truncation is consistent end-to-end (ADR-017 sound).
**CoverRouterV2** — payout-ratio invariant (8000 = 10000−2000) correctly asserted across router/shield (good); oracle-stuck liveness: a triggered policy during >5% deviation can be neither triggered nor expired (`:253-259`, → RM-L3, ties EC-C3).
**TWAPBurner** — `setUsdc` comment promises 6-dec but only checks balance==0, not `decimals()` (`:356-368`, → RM-L4); best-execution silently degrades to router[0] (safe via minOut); dead auto-burn/gas-refund events (Info).
**LuminaBondMarketplace** — escrow accounting sound; fee leg robust to non-standard USDC; near-maturity listings recoverable via `cancel`. No new finding.
**CapacityOracle** — FN-C1 referenced; value-bearing read can fall back to `emergencyPrice` (no deviation check) when the long-window `observe()` reverts despite passing freshness (`:222,234,236`, → RM-L5); `maxPoliciesPerDay()` view + its economic constants never consumed on-chain (Info).

**Cross-contract:** epoch truncation asymmetry BondVault↔ClaimBond (→ RM-M1, headline); `totalCommittedUSD` not a conserved quantity across redeem/queue/`burnByHolder` → SolvencyOracle misreport (→ RM-M2); decimal boundaries (6→18→18, 8-dec in shields) otherwise consistent; all ERC-1155 callback paths nonReentrant.

---

## 4. Findings Consolidados (NUEVOS)

### 🔴 Crítico
- **RM-C1** (governance, verified on-chain) — `DEFAULT_ADMIN_ROLE` of LuminaTokenV2 + BondVault held by the founder EOA (not the multisig). Confiscation (BURNER_ROLE) + 70M-reserve upgrade behind one hot key. `LuminaTokenV2.sol:109-114`, `BondVault.sol:841`, `DeployLuminaV5Complete.s.sol:488-525`. **Fix:** transfer both admins to Gnosis Safe + TimelockController before mainnet; rotate the exposed key now. *Sharpens EC-C2.*

### 🟠 Alto
- **RM-H1** (governance/technical) — `CapacityOracle.setPool` not timelocked + no pool validation → one-tx price forgery bypassing the F-09 emergencyPrice timelock. `oracles/CapacityOracle.sol:347,480-487`. **Fix:** route `setPool` through the timelock; validate pool tokens == (lumina, usdc) and a minimum liquidity.

### 🟡 Medio
- **RM-M1** (manual, exploitable) — 730d bond redeemable ~30d early via epoch month-truncation. `BondVault.sol:350-351,687-694` ↔ `ClaimBond.sol:236-241`. Fix: store exact maturity timestamp, or `maturityDate = max(monthStart, issueTs+duration)`.
- **RM-M2** (manual/technical) — `totalCommittedUSD` not conserved: `burnByHolder` try/catch silently skips the decrement when committed<amount → SolvencyOracle (`_calculateSolvencyRatio`) misreports. `BondVault.sol:700-705`, `ClaimBond.sol:156-171`. Fix: authoritative per-epoch committed accounting; revert (not skip) on inconsistency in prod.
- **RM-M3** (manual, exploitable) — redeem-clamp burns full bond, queues clamped USD → partial loss. `BondVault.sol:417-435`. Fix: burn only the clamped amount, or revert.
- **RM-M4** (manual/cross-contract) — R1 floor-pause `policiesPaused` not wired to the purchase path → inert mitigation. `BondVault.sol:162,820-830` vs `CoverRouterV2.sol:253-259`. Fix: have `_purchase` read `bondVault.policiesPaused()` (or unify flags).
- **RM-M5** (technical/manual) — `processQueue` head-of-line stall: an over-cap queued entry pins the FIFO head → permanent lock for that holder (bonds already burned). `BondVault.sol:535-603`. Fix: partial-pay over-cap entries.
- **RM-M6** (technical) — sequencer `startedAt==0` guard missing in CoverRouter + BaseFlashShield (MR-L07 not propagated); dormant until a mainnet sequencer feed is wired. `CoverRouterV2.sol:436-439`, `BaseFlashShield.sol:156-159`. Fix: add the `startedAt==0` guard.
- **RM-M7** (governance) — no first-party user self-settle; payout settlement depends on the permissionless keeper being wired (`setKeeper`) and unpaused per adapter. Where unwired, the relayer is the sole settlement authority → payout censorship. Fix: add a user-callable `settle(policyId)` behind the same shield gate; verify `keeper` on every live adapter.

### 🟢 Bajo
- **RM-L1** per-user redeem throttle Sybil-bypassable (`BondVault.sol:398-400`) — global cap still bounds aggregate drain.
- **RM-L2** throttle cap uses floored display price during oracle degradation (`BondVault.sol:500-504,664-670`).
- **RM-L3** triggered policy stuck during >5% oracle deviation — neither triggerable nor expirable (`CoverRouterV2`/`PolicyManagerV2.sol:466`/BondVault); ties EC-C3.
- **RM-L4** `TWAPBurner.setUsdc` lacks a `decimals()==6` check despite the comment (`:356-368`).
- **RM-L5** CapacityOracle can return `emergencyPrice` (no deviation check) when the long-window `observe()` reverts despite passing freshness (`:222,234,236`).
- **RM-L6** ClaimBond fee-capture not guaranteed (`authorizedOperators[from]` enables fee-free P2P) (`:256-267`).

### ℹ️ Info
- RM-I1 duplicated epoch constants ClaimBond↔BondVault (drift risk) — extract a shared `EpochMath`.
- RM-I2 dead events `AutoBurnTriggered/AutoBurnFailed/GasRefunded` (TWAPBurner:486-488).
- RM-I3 `CapacityOracle.maxPoliciesPerDay()` view + constants never consumed on-chain.
- RM-I4 `PolicyManagerV2.settlePolicy` comment says "shield or keeper"; code is shield-only.
- RM-I5 `markExpired` CEI gap (external call before `pr.expired`), Low/theoretical (trusted shield).
- RM-I6 `burnByHolder` self-harm + `processQueue` processing-time-price timing option (concrete EC-C3 expressions).

---

## 5. Trust Assumptions (resumen)

| Contract | Trusts | For |
|---|---|---|
| LuminaTokenV2 | DEFAULT_ADMIN (**EOA today**) | benign BURNER_ROLE grants + upgrades — *violated by EOA custody (RM-C1)* |
| BondVault | policyManager / priceOracle / authorizedCallers / cexReserve / DEFAULT_ADMIN (**EOA**) | capacity, valuation, ≤5%/tx burns, injection, upgrades |
| CoverRouterV2 | policyManager / twapBurner / capacityOracle / usdc / relayers / owner | wiring + relayed purchase/trigger timing |
| PolicyManagerV2 | router (sole recorder) / bondVault / registered shield / owner | lifecycle + atomic `markExpired` semantics |
| CapacityOracle | owner (legit pool, **no validation**) + Uniswap pool observations | all USD valuation; bootstrap emergencyPrice (FN-C1) |
| LuminaOracleV2 | `_oracleKey`+signers (quorum 1 default) / owner / Chainlink feeds | signed proofs (NOT flash-shield triggers) |
| FlashShieldAdapter/BaseFlashShield | router=adapter / policyManager / keeper / relayer / owner | settlement; reads Chainlink directly (isolated from OracleV2) |
| TWAPBurner | capacityOracle (minOut) / owner / authorizedSenders | burn floor, DEX set, premium accrual |
| ClaimBond | bondVault (sole mint/burn) / owner | supply control, operator whitelist, baseURI |
| BuybackEngine | operator role / capacityOracle / solvencyOracle / marketplace / bondVault auth | budgeted offers + double-burn sizing |
| Marketplace | FEE_MANAGER / DEFAULT_ADMIN / ClaimBond operator whitelist | fees + settlement token |
| SolvencyOracle | ADMIN (emergency pause) / capacityOracle / bondVault reads | quadrant + 150% gate |
| ShieldKeeper | permissionless `performUpkeep` (censorship backstop) / owner (pause) | automated settlement |

---

## 6. Recomendaciones Priorizadas para Fase 6

| Prio | Acción | Finding |
|------|--------|---------|
| 1 | Transfer LuminaTokenV2 + BondVault `DEFAULT_ADMIN_ROLE` to **Gnosis Safe + TimelockController**; rotate the exposed founder key | RM-C1 |
| 2 | Timelock + validate `CapacityOracle.setPool` (and re-verify deviation/freshness gates before wiring a real pool) | RM-H1, FN-C1 |
| 3 | Fix bond maturity truncation (RM-M1); fix redeem-clamp loss (RM-M3) and `processQueue` over-cap stall (RM-M5) — these silently lose/lock holder value | RM-M1, RM-M3, RM-M5 |
| 4 | Make `totalCommittedUSD` authoritative (RM-M2); wire BondVault floor-pause to the purchase path (RM-M4) | RM-M2, RM-M4 |
| 5 | Add a permissionless user-callable `settle()`; verify `keeper` wired on every live adapter (RM-M7); add sequencer `startedAt==0` guard before mainnet (RM-M6) | RM-M7, RM-M6 |
| 6 | Add `decimals()==6` check in `setUsdc`; cap-math on fail-closed price; CapacityOracle long-window fail-closed; clean dead code/comments | RM-L2/L4/L5, RM-I* |

*No code was modified. Read-and-analyze only, per sprint scope. New findings do not overlap 7.5/7.4 except where explicitly marked "confirms/sharpens".*
