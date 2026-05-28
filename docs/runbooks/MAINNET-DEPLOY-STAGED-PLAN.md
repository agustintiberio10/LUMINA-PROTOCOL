# LUMINA Base Mainnet — Staged Deploy Plan

**Date:** 2026-05-28 · **Status:** plan only, NOT executed.
**Inputs given by founder:**
- Deployer (NEW hardware wallet): `0x130377f9dE9f0134Fa82e24273C0225fB23B9040`
- Safe admin: `0xa9aE612fD97f5e33B5829d16B6408ebD8422C783`
- Pre-flight check live: `script/PreFlightCheck.s.sol` (PR #181 merged)

> **Reading guide.** This plan reconciles the deploy script (`script/deploy/DeployLuminaV5Mainnet.s.sol` → `DeployLuminaV5Complete.s.sol`), the runbook (`docs/runbooks/DEPLOY-MAINNET-RUNBOOK.md`), the Phase 5.5 audit findings (FN-C1 / FN-H1 / RM-C1 / OP-DEPLOY-1..10), and the operational reality that the LUMINA/USDC Uniswap pool *does not exist* until the LBP (Phase 7.3). Everything below is analysis; no transactions.

---

## 1. The chicken-and-egg: the pool problem (FN-C1)

**The conflict.**
- `CapacityOracle.getLuminaPrice()` (src/oracles/CapacityOracle.sol:205-219): when `pool == address(0)` returns `emergencyPrice` unconditionally — owner-set, no TWAP cross-check, no timelock on the bootstrap setter. The contract's own NatSpec at line 32-35 says **"THIS PATH MUST NOT SHIP TO MAINNET — a pool MUST be set"**.
- `PreFlightCheck.s.sol` (PR #181) asserts `capacityOracle.pool() != 0` (CRIT 1).
- But the **LUMINA/USDC pool does not exist** until the LBP creates it (Phase 7.3, *after* the deploy).

So you cannot satisfy CRIT 1 at deploy time. The system has to be deployed `pool=0`, run the LBP, then wire the pool, then pass the full pre-flight.

**The structural resolution (no code change, uses what's already in the contracts):**

1. **Deploy with `pool = address(0)`** — `CapacityOracle.initialize(_pool=0, ..., _emergencyPrice=<initial>)` allowed by line 174 (`require(_emergencyPrice > 0)` only — pool can be 0). At this point `getLuminaPrice()` returns `emergencyPrice`.
2. **Hard-pause CoverRouter:** `coverRouter.setPaused(true)` (src/core/CoverRouterV2.sol:328) → `_purchase` reverts `ContractPaused()` (line 152). **While paused, no policy can be bought, so no premium math touches the manipulable `emergencyPrice`.** This is the safety net.
3. Other surfaces also touch `getLuminaPrice()` while paused (BondVault redeem, TWAPBurner minOut, BuybackEngine sizing). But in a fresh deploy *no bonds exist yet* (vault is empty of obligations), the burner has nothing to burn (no premiums yet), and the buyback operator is the Safe (will not act). So the practical risk during the pre-LBP window is zero, and it is bounded by ops discipline (Safe doesn't act).
4. **Run the LBP** (external, Phase 7.3). The LBP creates a Uniswap V3 LUMINA/USDC pool with initial liquidity.
5. **Wait for the TWAP windows to fill.** `CapacityOracle` enforces a long window of `7200s = 2h` for the deviation breaker (line 104-105). Need ≥2h of swap activity in the new pool before the long-TWAP check is meaningful.
6. **Safe calls `capacityOracle.setPool(newPoolAddress)`** (src/oracles/CapacityOracle.sol:347). `getLuminaPrice()` now reads the live TWAP with the F-02/MR-H01 staleness + deviation guards.
7. **Run `PreFlightCheck` (PR #181) — now CRIT 1 passes.** All four criticals + the two BONUS checks green.
8. **Safe calls `coverRouter.setPaused(false)`** — protocol live for purchases.

So the pre-flight runs **twice**: a relaxed variant at Stage 3 (everything except pool!=0; pause must be true), and the **full PR #181 variant at Stage 6** before unpausing.

---

## 2. Mainnet dependencies — verification

`DeployLuminaV5Mainnet.s.sol` (the wrapper) **already hardcodes the right Base mainnet addresses** for the four external deps. Verified against the script:

| Dep | Mainnet address | Set by |
|-----|-----------------|--------|
| USDC (Circle) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | wrapper L31 ✅ |
| Uniswap V3 SwapRouter02 | `0x2626664c2603336E57B271c5C0b26F421741e481` | wrapper L36 ✅ |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` | wrapper L35 ✅ |
| Chainlink BTC/USD | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` | wrapper L32 ✅ |
| Chainlink ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` | wrapper L33 ✅ |
| Chainlink USDC/USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | wrapper L34 ✅ |

### Things to change BEFORE running the deploy

These are not in the wrapper — operator MUST set them in env:

| Env var | Required value | Source / why |
|---------|----------------|--------------|
| `MULTISIG` | `0xa9aE612fD97f5e33B5829d16B6408ebD8422C783` | the Gnosis Safe (founder-supplied) |
| `DEPLOYER_PRIVATE_KEY` (or `PRIVATE_KEY` or `FOUNDER_PRIVATE_KEY` — **see ⚠ below**) | private key of `0x130377…9040` (NEW hardware wallet) | NEVER use 0xe585…fDa8 (burned Sepolia EOA per OP-SEC-7) |
| `LBP_DEPOSIT` | NEW Base-mainnet address (will receive 5M LUMINA pre-LBP) | should be a hardware wallet or the LBP launcher contract |
| `OPS_WALLET` | NEW Base-mainnet address (receives 3M Treasury) | hardware wallet |
| `FOUNDER_RECIPIENT` | NEW Base-mainnet address (will receive 8M `FounderVesting` releases) | hardware wallet; **MUST NOT** be the burned EOA |
| `ORACLE_KEY` | NEW Base-mainnet EOA address (the EIP-712 signer used by LuminaOracleV2) | matching private key lives in Railway env on lumina-api |
| `SEQUENCER_UPTIME_FEED` | `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` (Base mainnet Chainlink L2 sequencer feed) | **CRITICAL — missing = sequencer-blind oracle (OP-DEPLOY-4)** |
| `AERODROME_ROUTER` | mainnet Aerodrome router | look up on basescan / aerodrome docs |
| `AERODROME_FACTORY` | mainnet Aerodrome factory | look up on basescan |
| `UNISWAP_V3_ROUTER` | `0x2626664c2603336E57B271c5C0b26F421741e481` (SwapRouter02) | **note ⚠ below** |
| `UNISWAP_V3_QUOTER` | `0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a` (QuoterV2) | not set by wrapper |

⚠ **Env-var name drift to fix in the deploy** *(operational bug, not a code bug):*
- The wrapper does `vm.setEnv("SWAP_ROUTER", …)` but the Complete script reads `vm.envAddress("UNISWAP_V3_ROUTER")`. **Different keys — the wrapper's setEnv is dead.** Operator must set `UNISWAP_V3_ROUTER` manually OR the wrapper must be patched. Same for `UNISWAP_V3_QUOTER`, `AERODROME_ROUTER`, `AERODROME_FACTORY` (the wrapper sets none of them). Surface OP-DEPLOY-3 had already flagged the lack of dep-probing; this is the more concrete sub-issue.
- The deployer-key env var is one of THREE names depending on which script runs (`PRIVATE_KEY` / `DEPLOYER_PRIVATE_KEY` / `FOUNDER_PRIVATE_KEY` — OP-SEC-3). The Mainnet script uses `DEPLOYER_PK` per its docblock; the Complete script's broadcast uses whichever Foundry picks up. Safer: export all three to the same key for the deploy session.

---

## 3. Keys — what's needed at deploy vs runtime

| Key | Where it lives | Used at deploy? | Used at runtime? | Status |
|-----|----------------|-----------------|------------------|--------|
| **Deployer EOA** `0x130377…9040` | hardware wallet (founder) | YES (signs every tx of Stage 1) | NO (handed off in Stage 2) | NEW ✓ (replaces burned 0xe585) |
| **Safe multisig** `0xa9aE612f…C783` | Gnosis Safe on Base mainnet | NO directly (admin handoff after) | YES (admin of every contract) | NEW ✓ |
| **Relayer EOA** | hardware wallet (founder) + Railway env on lumina-api | NO (only its address passed to `setRelayer`) | YES (signs `submitTrigger`, `purchasePolicyFor`) | **NOT GENERATED YET — must create** |
| **Oracle EOA** (EIP-712 signer) | hardware wallet (founder) + Railway env on lumina-api | YES (address passed to `LuminaOracleV2.initialize` via `ORACLE_KEY` env) | YES (signs EIP-712 price proofs) | **NOT GENERATED YET — must create** |
| **`RELAYER_PRIVATE_KEY`** on Railway lumina-api | Railway env | NO | YES | **Today = Sepolia EOA 0x168dC7… — MUST rotate to mainnet EOA** |
| **`ORACLE_PRIVATE_KEY`** on Railway lumina-api | Railway env | NO | YES | **Today = Sepolia signer — MUST rotate to mainnet EOA** |
| **`ADMIN_TOKEN`** on Railway lumina-api | Railway env | NO | YES (gates /api/v1/keys/generate) | regenerate ≥32-char random pre-mainnet |

**Action before deploy:** generate 2 fresh hardware-wallet EOAs (relayer + oracle), copy their addresses to env vars for the deploy, and copy their private keys to Railway env. None of them ever touched a hot machine. Confirm none of them == the burned `0xe585…fDa8`.

---

## 4. Contract deploy order (30 contracts) and dependencies

From `DeployLuminaV5Complete.s.sol` (lines ~150-410). Each row is a single `new ERC1967Proxy(impl, abi.encodeCall(initialize, …))` (atomic init — FN-H2 mitigated deploy-side). Dependencies = constructor/initialize args that need another contract already deployed.

| # | Contract | Deps (must exist first) |
|---|----------|-------------------------|
| 1 | `MaintenanceReserve` | usdc, multisig |
| 2 | `ClaimBond` | (none — wired later via `setBondVault`) |
| 3 | `CapacityOracle` | usdc, **pool = `address(0)` for bootstrap**, emergencyPrice |
| 4 | `BondVault` | claimBond, capacityOracle, multisig |
| 5 | `CEXLiquidityReserve` | bondVault, multisig |
| 6 | `TreasuryVesting` | (lumina deployed next, wired after) |
| 7 | `LuminaTokenV2` | (mints 100M to 5 buckets via initialize) |
| 8 | `SolvencyOracle` | bondVault, capacityOracle |
| 9 | `AdaptiveFeeDistributor` | solvencyOracle |
| 10 | `TWAPBurner` | lumina, usdc, capacityOracle, adaptiveFeeDistributor |
| 11 | `PolicyManagerV2` | bondVault |
| 12 | `ShieldKeeper` | policyManager |
| 13 | `CoverRouterV2` | policyManager, twapBurner, capacityOracle, usdc |
| 14 | `LuminaBondMarketplace` | claimBond, usdc, twapBurner |
| 15 | `BuybackEngine` | bondVault, claimBond, marketplace, capacityOracle, solvencyOracle, multisig |
| 16-21 | **6 shields** (FlashBTC/ETH 1h/24h/48h) + adapters — **NOT in the current Complete script** (TODO Phase C at L454-457, L463-466). **Must be deployed by `DeployShieldsAndAdapters.s.sol` separately**, or merged into Complete before mainnet — **deploy gate**. |
| 22 | `LuminaOracleV2` (non-UUPS) | oracleKey, sequencerUptimeFeed |
| 23 | `FounderVestingV2` (non-UUPS) | lumina, founderRecipient, capacityOracle/oracleV2, aavePool |
| 24-25 | DEX adapters (`AerodromeAdapter`, `UniswapV3Adapter`) | aerodrome/uniswap routers |

**Wiring (after creation, same broadcast)**: `grantRole(BURNER_ROLE, twapBurner)`, `setAuthorizedSender(coverRouter)`, `setBondVault(claimBond)`, `setAuthorizedCaller(buybackEngine)`, `setAuthorizedOperator(marketplace, buybackEngine)`, register products (TODO), set relayer on adapters, set keeper on adapters.

**Total**: 30 contracts including shields/adapters when fully wired. **Today, deploying the current Complete script alone produces a NON-FUNCTIONAL protocol** (no shields → no products → no purchases possible). This is OP-DEPLOY-5 and is a HARD GATE before mainnet.

---

## 5. STAGED PLAN

> Legend: 🔒 = reversible (no user funds at risk yet) · ⚠ = irreversible the moment it's done (real money, public price discovery).

### ETAPA 0 — Pre-deploy preparation (T-7 → T-0) 🔒
- **Generate** the 2 missing hardware EOAs (relayer + oracle); record addresses.
- **Set all env vars** per §2, especially the ones missing from the wrapper.
- **Patch the wrapper bug**: either fix `UNISWAP_V3_ROUTER` setEnv key (preferred) or commit to setting all 4 missing env vars manually. Same for the env-var-name standardization (OP-SEC-3).
- **Phase C**: implement shield + product registration in the deploy flow (or commit to running `DeployShieldsAndAdapters.s.sol` as Stage 1b).
- **Branch protection + CI** on lumina-api / landing (OP-CICD-1/2) — wire UptimeRobot pings (OP-MON-1). These are also Phase-6-hardening but are best done now while planning.
- **Dry-run on a fork** (`test/audit/v5.1-uups/integration/mainnet-fork/MainnetForkDeploy.t.sol` exists per wrapper L19-21) — must pass before broadcast.
- **Multisig signers ready** + key-rotation done (Alchemy, RAILWAY_TOKEN, founder PK — see OP-SEC plan).

### ETAPA 1 — Deploy contracts (T+0, H0-H1) 🔒
- Run `forge script script/deploy/DeployLuminaV5Mainnet.s.sol --rpc-url $BASE_MAINNET_RPC --broadcast --verify --slow -vvv` from the new deployer hardware wallet.
- The script deploys all 22 proxies, wires authorizations, and (when Phase C is merged) registers products.
- **State at end of Stage 1**: contracts exist on chain; `CapacityOracle.pool() == address(0)`; `emergencyPrice` set to an initial bootstrap value (e.g. $0.01 ≈ LBP starting price); `CoverRouter.paused()` — *currently `false` by default*; ownership/admin still on the deployer EOA. **Risk: deployer EOA holds admin and CoverRouter is unpaused with manipulable price.** → immediate Stage 2.

### ETAPA 1b — Pause + Stage 1 hand-off (T+0, H1) 🔒
**Within the same operator session as Stage 1, before anything else:**
- `coverRouter.setPaused(true)` from the deployer EOA. ← *single most important safety call.*
- (optional) `bondVault.pause()` if a global pause exists; otherwise the redeem path is bounded by `MIN_REDEEM_PRICE` and no bonds yet.
- Confirm `coverRouter.paused() == true` on basescan.

### ETAPA 2 — Wiring + transfer of ownership (T+0, H1-H2) 🔒
- Run `WireLuminaV5PostDeploy.s.sol` if any wiring deferred from Stage 1.
- For every `Ownable` contract: `transferOwnership(MULTISIG)` (or `Ownable2Step` accept on the Safe side).
- For every `AccessControl` contract (LuminaTokenV2 + BondVault + BuybackEngine + …):
  `grantRole(DEFAULT_ADMIN_ROLE, MULTISIG)` → Safe accepts → then **DECISION (per ADR-012 vs RM-C1)**: revoke `DEFAULT_ADMIN_ROLE` from deployer EOA on Token and Vault?
  - **RM-C1 says YES** (Safe-only).
  - **ADR-012 keeps deployer as backstop** to prevent SET-B-style brick.
  - **Recommended (post-audit):** revoke from EOA so the Safe is the sole admin; the brick-bug is now post-morteed in the code and the deploy script asserts the deployer still holds it at end of broadcast (DeployLuminaV5Complete.s.sol:514-525), so for THIS handover step do the revoke from a SEPARATE post-deploy script, not in the same broadcast.
- **State at end of Stage 2**: contracts deployed, all admin handed to Safe, CoverRouter paused, pool = 0.

### ETAPA 3 — Pre-flight (RELAXED variant) — pre-LBP gate 🔒
- Run a relaxed version of the pre-flight that asserts everything EXCEPT pool!=0, PLUS asserts `coverRouter.paused() == true`. This is a small additional script (`PreFlightCheckBootstrap.s.sol`) that calls `verify(..., requirePool=false)` — *recommend adding this to the PR #181 module as a sibling entrypoint*.
- Concretely: FN-H1 (USDC), RM-C1 (admin = Safe + EOA revoked), chainId==8453, deployer != burned, **paused==true**. NO pool check.
- All must pass. Stage 3 is the gate before authorizing the LBP launch.

### ETAPA 4 — LBP (Phase 7.3, external) ⚠
- Founder-driven, off this runbook. Likely Fjord Foundry / Balancer LBP on Base. Uses the `LBP_DEPOSIT` wallet's 5M LUMINA + an amount of USDC seed.
- LBP ends → there is a Uniswap V3 LUMINA/USDC pool (or the LBP token gets transferred to a fresh Uniswap V3 pool).
- **IRREVERSIBLE** moment: price discovery happens publicly; LUMINA market cap is now a real number.
- Wait ≥2h after the pool has actual swap activity, so `CapacityOracle`'s 7200s long-window TWAP is populated.

### ETAPA 5 — Wire pool 🔒 (Safe-controlled, mostly reversible)
- Safe calls `capacityOracle.setPool(<realPoolAddress>)`.
- Now `getLuminaPrice()` reads the live TWAP with the F-02/MR-H01 staleness + deviation guards.
- (Optional, recommended) Safe calls `capacityOracle.proposeEmergencyPrice(<latestPoolPrice>)` and after 24h `applyEmergencyPrice()` to align the fallback floor with current market.
- **Caveat (RM-H1):** `setPool` itself is NOT timelocked. Use a Safe transaction with at least 24h between proposal and execution (off-chain coordination), or queue it via a TimelockController if one exists.

### ETAPA 6 — Pre-flight FULL (PR #181) — pre-unpause gate 🔒
- `forge script script/PreFlightCheck.s.sol --rpc-url $BASE_MAINNET_RPC`.
- ALL must pass: FN-C1 (pool!=0 ✓), FN-H1 (Circle USDC ✓), RM-C1 (Safe admin + EOA revoked ✓), BONUS (chainId, deployer hygiene ✓).
- Operator must see `ALL PRE-FLIGHT CHECKS PASSED - safe to deploy` on stdout before continuing.

### ETAPA 7 — Activate protocol ⚠ (purchases now real money)
- Safe calls `coverRouter.setPaused(false)`.
- (If applicable) Safe calls any other unpause needed (BondVault.policiesPaused if set).
- The protocol is **live**. First purchase will reach `_purchase`, pull USDC, send to TWAPBurner, mint policy.
- **Watch:** UptimeRobot on /health + /indexer/health (OP-MON-1 must be wired by now); supervisor logs visible; relayer/oracle ETH balances > thresholds.

### ETAPA 8 — Stabilization (T+1 → T+7) 🔒
- Existing daily checks per `DEPLOY-MAINNET-RUNBOOK.md`.
- First webhook delivery proven; first redeem proven (when bonds mint after first triggers); marketplace listing+buy proven on small amount.
- Game-day rehearsal of oracle-key compromise + bank-run runbooks within 30d (OP-IR-6).

---

## 6. Reversibility summary

| Stage | Reversibility |
|-------|---------------|
| 0 Prep | fully reversible |
| 1 Deploy | reversible-ish: contracts on chain forever, but no user funds; could redeploy v2 if needed (cost: gas + naming) |
| 1b Pause | trivially reversible |
| 2 Wire + ownership | reversible if deployer EOA still has admin (per ADR-012) OR via Safe |
| 3 Pre-flight (relaxed) | read-only |
| **4 LBP** | **IRREVERSIBLE — price discovery public, liquidity in pool** |
| 5 setPool | reversible (Safe can setPool again) but consequential |
| 6 Pre-flight (full) | read-only |
| **7 Unpause** | reversible (Safe re-pauses), but ONCE A PURCHASE HAPPENS user funds are in the protocol |
| 8 Stabilization | ops; no irreversible single action |

The two truly irreversible moments are **Stage 4 (LBP)** and **Stage 7 (first purchase)**. Everything before stage 4 can be aborted with minimal damage; once 4 is done, downside is reputational/financial but the contracts are still in a safe paused state until stage 7.

---

## 7. Open items before this plan can execute

1. **Patch the env-var name drift** in `DeployLuminaV5Mainnet.s.sol` (wrapper sets `SWAP_ROUTER`, Complete reads `UNISWAP_V3_ROUTER`; same for missing AERODROME + QUOTER) — OR commit operator to set them by hand. (This file change is small; recommend the wrapper fix.)
2. **Implement Phase C** (shield + product registration) in the deploy flow — OR document the manual `DeployShieldsAndAdapters.s.sol` step as Stage 1c.
3. **Add the "relaxed" pre-flight variant** (`PreFlightCheckBootstrap`) — small addition to the PR #181 module (~30 LoC, same test pattern).
4. **Standardize the deployer env-var name** (OP-SEC-3) — pick one of the three.
5. **Phase 6 (Pre-Mainnet Hardening) consolidated checklist** from the operational audit (LP#179) — multisig live, CI live, alerting live, key rotations done, OP-CICD-1/2 closed.
6. **Mainnet fork dry-run** (`MainnetForkDeploy.t.sol`) MUST pass cleanly with the new wrapper config before going live.

---

*No transactions broadcast. No code modified. Pure analysis. Inputs: deploy scripts on `main` + audited findings + the two operator-supplied addresses.*
