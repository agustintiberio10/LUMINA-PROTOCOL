# LUMINA Protocol — Economic Audit V5.3/V5.4

**Sprint 7.5 — Economic Sustainability, Incentives & Financial Risk**
**Date:** 2026-05-27 · **Scope:** deployed Base Sepolia V5.4 contracts · **Type:** economic (not code)
**Method:** line-by-line constant extraction from `src/` + on-chain state read + quantitative stress model (`economic-model-v53.py`)

> This is **not** a code-safety audit (that is Sprint 7.4 functional / 7.2 red-team / 7.3 manual review). It evaluates whether **the numbers close**: solvency, incentives, price mechanics, and the scenarios where the protocol becomes insolvent or the token collapses.

---

## 1. Resumen Ejecutivo

### Veredicto: 🟠 **PASS WITH FINDINGS**

The core economic engine is **structurally sound and fail-closed**: the payout reserve is pre-funded, redemptions are throttled so no bank run can drain it, the fee matrix can never distribute >100%, and every oracle path reverts rather than pays on bad data. In steady state the protocol has a **~50-year reserve runway** and is solvent from day one.

**However**, three economic properties **must be fixed before mainnet with real money**. They do not make the protocol insolvent today, but they create correlated failure modes precisely in the conditions where parametric crypto insurance is most likely to be claimed.

### Top 3 Riesgos Económicos Críticos 🚨

1. 🚨 **Payout capacity is finite, non-replenishing, and price-coupled.** The vault enforces a **50% commit ceiling** (`SAFETY_FACTOR_BPS=5000`), so usable payout capacity is **$1.26M at $0.036** — *half* the $2.52M reserve value, and it **shrinks linearly as LUMINA falls**. Premiums **burn** LUMINA; they never refill the vault. At 10,000 policies/mo & 50% trigger, capacity is exhausted in **~3.2 months**, after which `issueBond` reverts — triggered policyholders cannot get a bond (effective coverage denial). The thing backing insurance payouts is a volatile governance token whose price is *negatively correlated with the events being insured*.

2. 🚨 **No on-chain timelock anywhere — single owner/admin controls all economic levers + instant UUPS upgrades.** Every upgradeable contract gates `_authorizeUpgrade` on `onlyOwner`/`DEFAULT_ADMIN_ROLE` with **no delay, no two-step queue, no TimelockController** (the "TimelockController in prod" comments are aspirational only). The same key can repoint the reserve, change `marginBps`, authorize `burnFromReserves`, swap the USDC token, or upgrade logic instantly. This is acknowledged as a "founder decision," but for an insurance protocol holding user obligations it is the single largest economic-governance risk.

3. 🚨 **Bondholders are stranded below $0.005 (fail-closed redemption).** `MIN_REDEEM_PRICE = $0.005` makes `redeemBond` **revert** when LUMINA ≤ $0.005. In a death spiral this protects the reserve — but bondholders **cannot redeem at all**, so outstanding obligations go permanently unhonored at low prices. Combined with risk #1, a LUMINA crash *simultaneously* (a) blocks new policies (circuit breaker $0.005), (b) blocks redemptions ($0.005 floor), and (c) shrinks capacity — a **triple correlated failure** at the worst possible moment.

### Top 3 Fortalezas

1. ✅ **Pre-funded reserve + fail-closed oracles.** 70M LUMINA sits in the vault from genesis, so cold-start payouts work day 1 with $0 premiums collected. Every settlement price path (`_redeemPrice`, TWAPBurner `minOut`, BuybackEngine `refPrice`) reverts on stale/zero/below-floor data rather than paying a wrong amount.
2. ✅ **Bank-run-proof throttle + FIFO queue.** 1.08%/epoch global cap + 10%-of-cap per-user cap + immediate bond burn on over-cap (custody-by-debt) makes it mathematically impossible for a redemption rush to drain the reserve; worst case ≈12.96% drainable over 12 weeks.
3. ✅ **Fee matrix is overflow-safe and counter-cyclical.** All 16 quadrants of `AdaptiveFeeDistributor` sum to **exactly 10000 bps (100%)** — no momentum/solvency combination distributes >100% (scenario 2.11 is **negative**). Low solvency → burn-heavy (defends price); high solvency → buyback-heavy. The fallback (85/8/2/5) mirrors the healthy/neutral quadrant.

---

## 2. Diagrama de Flujos Económicos

```
                         ┌──────────────────────────────────────────────────────────┐
                         │                      POLICYHOLDER / AI AGENT                │
                         └───────┬───────────────────────────────────────┬───────────┘
            premium (USDC)       │                                        │ on trigger: receives
        = cov·0.80·tProb·margin  │ purchasePolicy(For)                    │ ERC-1155 ClaimBond ($1 face)
                                 ▼                                        ▲
                    ┌────────────────────────┐  recordPolicy   ┌──────────┴───────────┐
                    │     CoverRouterV2       │────────────────▶│   PolicyManagerV2     │
                    │  • $100–$10k coverage   │  reserveCapacity│  • payout = cov·80%   │
                    │  • CB: block new if     │◀────────────────│  • triggerPayout →    │
                    │    price<$0.005(rst .008)│  triggerPayout  │    issueBond(usdPayout)│
                    └───────────┬─────────────┘                 └──────────┬────────────┘
              100% premium USDC │                                          │ issueBond / reserve
                                ▼                                          ▼
                    ┌────────────────────────┐                 ┌───────────────────────────────┐
                    │      TWAPBurner         │  burn(LUMINA)   │          BondVault            │
                    │  receivePremium()accrue │────────────────▶│  • holds 70M LUMINA reserve  │
                    │  executeBurn()(perm.):  │   to 0xdead     │  • 50% COMMIT CEILING (200%) │
                    │   split via FeeDist /    │                 │  • redeem = usd·1e36/price   │
                    │   fallback 85/8/2/5:     │                 │  • throttle 1.08%/epoch,FIFO │
                    │   ├ burn  → buy&burn LUM │◀── quadrant ────│  • MIN_REDEEM_PRICE $0.005   │
                    │   ├ buyback→ buybackRsv  │  AdaptiveFee    │    (fail-closed revert)      │
                    │   ├ ops    → opsReserve  │  Distributor    │  • burnFromReserves ≤5%/tx   │
                    │   └ maint  → maintReserve│  (16-quad,=100%)│    (authorized only)         │
                    └───────────┬─────────────┘                 └──────┬─────────────┬──────────┘
                                │ buybackReserve (USDC)                 │ LUMINA      │ obligations
                                ▼                                       │ payout      │ sync
                    ┌────────────────────────┐  buy listings  ┌─────────┴──────┐      │
                    │     BuybackEngine       │◀───────────────│   ClaimBond     │◀─────┘
                    │  • executeOffer(op-only)│  burnByHolder  │   (ERC-1155)    │
                    │  • DoubleBurn if solv   │───────────────▶│  • 1 = $1 USD   │
                    │    ≥150%: +2% slip,2x cap│  (double burn) │  • id = YYYYMM  │
                    └────────────┬───────────┘                 │  • xfer only via│
                                 │ buy@discount                │    auth operator│
                                 ▼                             └────────┬────────┘
                    ┌────────────────────────┐  list/buy (3% fee)       │ secondary trades
                    │  LuminaBondMarketplace  │◀─────────────────────────┘
                    └────────────────────────┘

   ┌──────────────────────────────────────────────────────────────────────────────────────┐
   │ FounderVesting V2 (NON-upgradeable): 8M LUMINA, 3 tranches × 31d, unlock via            │
   │ PATH1 AltSeason(2-of-3) │ PATH2 ETH>$5000 │ PATH3 fallback 1095d (3y). 24 obs ×1h sust. │
   └──────────────────────────────────────────────────────────────────────────────────────┘

  VALUE-FLOW SUMMARY:
   • USDC: policyholder → TWAPBurner → (buy&burn LUMINA to 0xdead) + (buyback/ops/maint reserves).
           USDC NEVER funds payouts and NEVER refills BondVault. It only DEFLATES LUMINA.
   • LUMINA: pre-funded 70M in BondVault → out to bondholders on redeem (at market price), in
            (effectively) only via dormant CEX auto-injection or buyback-reserve recycling.
   • ClaimBonds: minted on trigger (PolicyManager→BondVault), redeemed for LUMINA (730d maturity
                mainnet), or traded on marketplace / bought-and-double-burned by BuybackEngine.
```

**The central economic asymmetry:** the two flows are **decoupled**. Premiums (USDC) deflate the token; payouts (LUMINA) drain a fixed pre-funded pile. Solvency is therefore **not** "premiums ≥ claims" (the usual insurance equation) but **`reserveLUMINA × price × 50% ≥ outstanding face`** — a quantity that depends on a volatile token price the protocol cannot control.

---

## 3. Resultado de los 12 Escenarios

| # | Escenario | Resultado (modelado) | Riesgo | Mitigación sugerida |
|---|-----------|----------------------|--------|---------------------|
| 2.1 | **Steady state** (100 pol/mo, 50% trig, $100) | $624 premium burned/mo; $4k face/mo; 111k LUMINA drained/mo = 0.16% reserve. ~50-yr runway. Solvent. | 🟢 Bajo | Monitor; none needed |
| 2.2 | **Black swan** (all FlashBTC trigger) | 1k pol @ $100 = $80k face → OK. 10k pol @ $100 = $800k face = **63% of the $1.26M ceiling**. 1k @ $1k same. Bonds mint until 50% commit, then `issueBond` reverts. | 🟠 Alto | Raise reserve or lower per-product cap; surface live capacity |
| 2.3 | **Bank run** (all redeem at once) | Throttle caps drain at $27.2k/wk. $1M outstanding = 37 wks; full $2.52M = 93 wks (~1.8 yr). Reserve never drained. Holders wait years. | 🟡 Medio | Document illiquidity; deepen marketplace liquidity |
| 2.4 | **Death spiral** (LUMINA −90%) | 🚨 At $0.0036 each $1 bond drains 278 LUMINA & capacity = $126k. At ≤$0.005 redemptions **revert** (fail-closed) AND new policies blocked. Reserve protected; **bondholders stranded**. | 🔴 **Crítico** | Decouple payout backing from LUMINA price (USDC tranche / hybrid reserve) |
| 2.5 | **Marketplace arbitrage** | Buy bond at X% discount, redeem $100 face. Profit only if discount > LUMINA price-decay + 730d time-value + 3% fee. Self-correcting; bounded by maturity + throttle. | 🟢 Bajo | None; discount correctly prices illiquidity |
| 2.6 | **Opportunistic trigger** | Premium = 2× expected loss (margin 2.0). Buy-just-before-trigger blocked by: 80% payout (20% deductible), barrier 2.5% (in shield), drop-from-purchase-price (not rolling), per-policy $10k cap. Margin makes EV-negative. | 🟡 Medio | Keep margin ≥2.0 for short-window products |
| 2.7 | **Oracle manipulation / sequencer fail** | Settlement uses Chainlink + (mainnet) sequencer-uptime grace 3600s; redeem/burn/refPrice all fail-closed on stale/zero. Manipulating Chainlink BTC/ETH is infeasible at protocol scale. | 🟢 Bajo | Enable sequencer feed on mainnet (Sepolia = address(0)) |
| 2.8 | **Founder vesting dysfunctional** | If AltSeason never fires, fallback releases 8M LUMINA (8% of supply) at **T+3y** (1095d, not 4y) in 3 tranches ×31d. Potential dump = 8% supply over ~62d. Non-upgradeable, permissionless release. | 🟡 Medio | Pre-announce schedule; consider streaming/longer taper |
| 2.9 | **Burner stuck** (thin pool) | TWAPBurner fail-closed: no oracle/oracle=0/can't meet oracle-derived `minOut` → `executeBurn` **reverts**, USDC accrues unburned (currently $735 on-chain, 0 burned). No timeout/soft-fallback. Premiums safe but deflation stalls. | 🟠 Alto | Add keeper alerting + multi-DEX liquidity before mainnet; consider partial-fill |
| 2.10 | **Migration attack** (malicious UUPS) | 🚨 No timelock → owner upgrades any contract **instantly**; can corrupt/repoint storage, drain via re-authorized `burnFromReserves`, repoint reserve. Only FounderVestingV2 is non-upgradeable. | 🔴 **Crítico** | Gnosis Safe + TimelockController **on-chain** pre-mainnet |
| 2.11 | **Fee extraction** (matrix >100%) | **Negative.** All 16 quadrants sum to exactly 10000 bps; `_executeAdaptive` requires sum ≤10000 and uses fallback otherwise. No combination yields >100%. | 🟢 Bajo | None |
| 2.12 | **Cold start** (70M LUMINA, $0 USDC) | First trigger mints a ClaimBond, redeemable in LUMINA from the pre-funded reserve — **no USDC needed to pay**. Solvent from day 1. Real risk is thin-liquidity price discovery making redeem value volatile. | 🟡 Medio | Seed DEX liquidity at launch; stage coverage caps low initially |

---

## 4. Análisis de Parámetros Calibrados

| Parámetro | Valor actual | Recomendado | Razón |
|-----------|--------------|-------------|-------|
| **Margin** | per-product `marginBps`; on-chain configured **2.00x** (code comment shows 1.5x default) | **Keep 2.00x** (short windows); 1.80x only for 48h products if competitiveness needed | Margin = premium/expected-loss. 2.0x makes opportunistic triggers (2.6) EV-negative and builds buffer. Lowering hurts the only buffer the reserve has. Premiums are tiny in absolute terms ($0.16–$14.86), so 2.0x is not a real adoption barrier. |
| **Throttle BondVault** | `MAX_REDEMPTION_PER_EPOCH_BPS = 108` (1.08%/7d) + 10%-of-cap/user | **Keep**, but make `currentEpoch` redeemable & queue depth **queryable on-chain** | 100% of reserve takes ~93 weeks (1.8 yr) — acceptable as a bank-run defense, but holders need transparency on wait time. The 10% per-user cap correctly prevents whale monopolization of an epoch. |
| **Safety factor** | `SAFETY_FACTOR_BPS = 5000` → **50% commit** of reserve **value** (≈200% backing) | **Keep 50%** as the floor, but **add an absolute USD reserve** decoupled from price | Clarification (Fase 3 prompt was ambiguous): it caps *committed face* at 50% of `reserveLUMINA × price`. It is the single most important solvency knob — and its weakness is that the denominator is a volatile price (risk #1). |
| **Circuit breaker** | block new policies if price `< $0.005`, reset `≥ $0.008` (sticky via `syncCircuitBreaker`) | **Keep**; **raise reset margin** awareness; add keeper to call `syncCircuitBreaker` | Only blocks *new* policies. Does NOT stop redemptions (those have their own $0.005 floor). Historically a $0.005 absolute floor only triggers if LUMINA loses ~86% from $0.036 — plausible in a token crash. Hysteresis correctly prevents flapping. |
| **Shield durations** | 1h / 24h / 48h | **Add 6h and/or 12h** | Gap between 1h and 24h is large; intraday agents (the target market) likely want 6–12h windows. No economic risk to adding; improves product-market fit. |
| **Barrier** | 2.5% / 250 bps (in flash-shield, not in the 8 audited files) | **Keep 2.5%** for now; revisit per-asset | High enough to filter noise (BTC/ETH routinely move <2.5% intraday), low enough to be useful. Per-asset calibration (BTC vs ETH vol) would be ideal post-launch. |
| **Bond maturity** | 730 days (mainnet); ~60s on Sepolia | **Reduce to 365d** or make tiered | 2 years is a long time to hold an illiquid, price-volatile claim. It *reduces* user confidence and widens marketplace discounts (2.5). Shorter maturity improves UX but increases near-term redemption pressure — trade-off to model. |
| **payoutRatio** | **locked 8000 (80%)**; 20% deductible | **Keep locked** | Hard-locked in `configureProduct` (reverts unless 8000). Removes operator foot-gun. The 20% deductible is the protocol's structural skin-saver. |

---

## 5. Stress Test Cuantitativo

Model: `audit-pack/audits/economic-model-v53.py` (pure-stdlib, runnable). On-chain anchors: 100M supply, 70M reserve, $0.036 price, margin 2.0, payout 0.80, throttle 1.08%, safety 50%.

### Key outputs

**Baseline.** Reserve value $2,520,000 → **enforced payout capacity $1,260,000** (50% rule). $1 bond = 27.78 LUMINA. Weekly redeemable $27,216. Full reserve redeem horizon ≈ 93 weeks.

**Months-to-capacity-exhaustion** (cumulative triggered face vs the $1.26M ceiling, price held at $0.036):

| pol/mo | trigger | face/mo | months to cap |
|-------:|--------:|--------:|--------------:|
| 100 | 10% | $800 | 1,575 |
| 100 | 50% | $4,000 | 315 |
| 1,000 | 10% | $8,000 | 158 |
| 1,000 | 50% | $40,000 | 31.5 |
| 5,000 | 50% | $200,000 | 6.3 |
| 10,000 | 10% | $80,000 | 15.8 |
| **10,000** | **50%** | **$400,000** | **🚨 3.1** |

**Death-spiral capacity (price-coupled):**

| LUMINA price | $1 bond → LUMINA | Enforced capacity | State |
|-------------:|-----------------:|------------------:|-------|
| $0.0360 | 27.8 | $1,260,000 | normal |
| $0.0180 | 55.6 | $630,000 | capacity halved |
| $0.0072 | 138.9 | $252,000 | capacity −80% |
| $0.0050 | 200.0 | $175,000 | 🚨 redeem floor — redemptions revert |
| $0.0036 | 277.8 | $126,000 | 🚨 new policies blocked + redeem stranded |

### Breaking points identificados

1. 🚨 **Volume breaking point:** at **~10,000 policies/mo with 50% trigger** ($400k face/mo), the $1.26M capacity is exhausted in **~3.2 months**; thereafter `issueBond` reverts — triggered policyholders cannot mint bonds. Scales linearly: 5,000 pol/mo @ 50% = 6.3 months.
2. 🚨 **Price breaking point (capacity):** capacity = `70M × price × 50%`. It halves with every halving of LUMINA. Below **$0.0072** capacity is already <$252k — a small-protocol number.
3. 🚨 **Price breaking point (redemption):** at **≤ $0.005**, `redeemBond` reverts entirely — existing bondholders are stranded while the breaker also blocks new policies.
4. ⚠️ **Burn stall:** if the DEX pool is too thin to meet the oracle-derived `minOut`, `executeBurn` reverts and USDC accrues unburned (observed: $735 on-chain, 0 burned) — deflation mechanism is non-functional until liquidity exists.

> **Note on "USDC in BondVault > contingent debt" (Fase 4.2):** this metric is **structurally N/A** for LUMINA — the BondVault holds **LUMINA, not USDC**, and USDC never enters it. The correct solvency ratio is **`reserveLUMINA × price × 0.50 / outstandingFaceUSD`**. The model reports this instead.

---

## 6. Comparación Competitiva

| Dimensión | LUMINA | Nexus Mutual | InsurAce | Sherlock |
|-----------|--------|--------------|----------|----------|
| **5.1 Premium pricing** | premium = 2× expected loss (margin 2.0); tiny absolute ($0.16–$14.86 for $100 cover, short windows) | Risk-assessor staking-driven, often 2–10% APR of cover | Pool-utilization curve, typ. 2–5% | Auction/markets, varies | LUMINA is *cheaper in absolute $* for short parametric windows, but charges a higher *load multiple* (2.0×). Justified by instant parametric payout (no claims assessment). |
| **5.2 Payout mechanics** | ClaimBond ERC-1155, **paid in LUMINA**, 730d maturity, throttled | USDC/ETH after member claims vote | USDC after assessment | USDC from staked pool, fast | 🔴 **LUMINA's biggest disadvantage.** Competitors pay stablecoin ~immediately; LUMINA pays a *volatile token* on a *2-year* clock. Mitigants: parametric (no dispute), marketplace exit, double-burn price support — but none make it USDC-equivalent. |
| **5.3 Target market** | **AI agents** (programmatic, API/SDK/MCP) | Humans/DAOs (smart-contract cover) | Humans (multi-chain cover) | Protocols (audit coverage) | LUMINA's niche is genuinely underserved — no direct competitor targets autonomous-agent parametric cover. Real differentiation, but unproven demand. |
| **5.4 Sustainability @ low volume** | ✅ Pre-funded 70M reserve → solvent from day 1 regardless of premium volume; ~50-yr runway at steady state | Needs capital pool to grow | Needs TVL | Needs staker capital | LUMINA *can* survive 6 months of low volume better than peers (no premium dependency to pay claims) — its cold-start story is a genuine strength. |

**Net:** LUMINA wins on cold-start sustainability and niche, loses on payout quality (volatile token + long maturity). The economic model is **viable for a low-volume agent-native launch** but the payout-asset risk caps how large/credible it can become without a stablecoin-backed tranche.

---

## 7. Findings Clasificados

### 🔴 Críticos (bloquean mainnet)
- **EC-C1 🚨 Price-coupled, finite, non-replenishing payout capacity.** Capacity = `70M × price × 50%`; exhausts in ~3 months at moderate scale and shrinks with price. Premiums burn LUMINA, never refill the vault. → *Introduce a USDC/stable-backed reserve tranche or hybrid backing decoupled from LUMINA price; add a replenishment path beyond dormant CEX-injection.*
- **EC-C2 🚨 No on-chain timelock; single owner controls all economic params + instant UUPS upgrades** (scenario 2.10). → *Deploy Gnosis Safe + on-chain TimelockController as owner/admin of every economic contract before mainnet. Make the "TimelockController in prod" comment real.*
- **EC-C3 🚨 Correlated triple-failure in a LUMINA crash** (2.4): at ≤$0.005, new policies blocked + redemptions revert + capacity collapsed — simultaneously, and correlated with the crypto crashes that drive claims. → *Decouple redemption floor from the capacity token, or back obligations in a non-correlated asset; model claim-vs-LUMINA-price correlation explicitly.*

### 🟠 Altos (recomendado fixear pre-launch)
- **EC-H1** Burn stall on thin liquidity (2.9): `executeBurn` reverts, deflation stalls, USDC idles (observed $735, 0 burned). → *Seed deep multi-DEX LUMINA liquidity + keeper alerting + consider partial-fill before mainnet.*
- **EC-H2** Black-swan capacity cliff (2.2): 10k policies @ $100 already consumes 63% of capacity. → *Stage coverage caps low at launch; expose live `availableCapacityUSD` to the purchase UI/SDK so quotes fail gracefully.*
- **EC-H3** USDC repointed to MockUSDC on Sepolia in CoverRouter + TWAPBurner (BL-USDC). → *Mainnet runbook MUST revert `setUsdc` to Circle USDC; add a deploy assertion.*

### 🟡 Medios (post-launch)
- **EC-M1** Founder vesting fallback dumps 8% supply at T+3y if AltSeason never fires (2.8). → *Pre-announce; consider streaming release.*
- **EC-M2** Bond maturity 730d widens marketplace discounts & hurts confidence. → *Evaluate 365d or tiered maturity.*
- **EC-M3** Throttle wait-time & queue depth not queryable on-chain. → *Add view functions for redeemable-this-epoch and queue position.*
- **EC-M4** Cold-start thin-liquidity price discovery makes early redeem values volatile (2.12). → *Seed DEX liquidity at launch.*

### 🟢 Bajos (nice-to-have)
- **EC-L1** Add 6h/12h shield durations (product-market fit).
- **EC-L2** Per-asset barrier calibration (BTC vs ETH vol).
- **EC-L3** Enable L2 sequencer-uptime feed on mainnet (Sepolia = address(0)).
- **EC-L4** Surface circuit-breaker state & `syncCircuitBreaker` keeper in ops dashboards.

---

## 8. Lista Priorizada de Acciones para Fase 6 (Pre-Mainnet Hardening)

| Prio | Acción | Finding | Tipo |
|------|--------|---------|------|
| 1 | Deploy Gnosis Safe + **on-chain TimelockController** as owner/admin of all economic contracts | EC-C2 | Governance |
| 2 | Design & add a **stable-backed reserve tranche** (decouple payout backing from LUMINA price) | EC-C1, EC-C3 | Economic architecture |
| 3 | Model **claim-rate × LUMINA-price correlation** explicitly; set conservative initial coverage caps | EC-C3, EC-H2 | Risk modeling |
| 4 | Seed **deep multi-DEX LUMINA liquidity** + keeper for `executeBurn`/`syncCircuitBreaker` + alerting | EC-H1, EC-L4 | Ops / liquidity |
| 5 | Mainnet deploy assertion: **USDC = Circle USDC** (revert MockUSDC); enable **sequencer feed** | EC-H3, EC-L3 | Deploy safety |
| 6 | Expose **live `availableCapacityUSD`** + throttle/queue views to SDK/UI so quotes degrade gracefully | EC-H2, EC-M3 | Transparency |
| 7 | Decide & document **bond maturity** (365d vs 730d) and **founder-vesting** comms plan | EC-M1, EC-M2 | Tokenomics |
| 8 | Activate **CEX auto-injection** (`cexReserve`) or an equivalent replenishment path | EC-C1 | Economic |

---

### Appendix — Methodology & Sources
- Constants extracted line-by-line from `src/core/{CoverRouterV2,PolicyManagerV2,AdaptiveFeeDistributor,TWAPBurner}.sol`, `src/bonds/{BondVault,ClaimBond}.sol`, `src/token/FounderVestingV2.sol`, `src/marketplace/BuybackEngine.sol`.
- On-chain state read from Base Sepolia V5.4: supply 100M, BondVault reserve 69,997,777.78 LUMINA, TWAPBurner USDC ≈$735.63, LUMINA price $0.036, 0xdead burned = 0.
- Quantitative model: `economic-model-v53.py` (this directory).
- **Corrections vs prior internal notes:** the audit-prompt "125% solvency floor" does **not** exist on-chain (BondVault = 50% commit/200% backing; BuybackEngine double-burn gate = 150%). Founder fallback = **3 years (1095d)**, not 4. Margin code-default comment is 1.5x but on-chain config is 2.0x. "Barrier 2.5%" lives in the flash-shield, not the 8 economic files.

*No code was modified. Read-and-analyze only, per sprint scope.*
