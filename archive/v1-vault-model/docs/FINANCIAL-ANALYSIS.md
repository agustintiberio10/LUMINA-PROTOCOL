# LUMINA PROTOCOL — COMPREHENSIVE FINANCIAL ANALYSIS
**Date:** 2026-04-06 | **Analysts:** Yield Architect, Kink Surgeon, Risk Quant, Market Comparator, Institutional DD, Tokenomics

---

## FINANCIAL SUMMARY TABLE

| Vault | APY Optimist | APY Base | APY Pessimist | VaR 95% | VaR 99% | Max Drawdown | Recovery | Cooldown | Sharpe |
|-------|-------------|---------|--------------|---------|---------|-------------|----------|----------|--------|
| VolatileShort | 11.7% | 7.5% | 4.6% | -$3.2K | -$16.8K | -16.8% | 27 mo | 37d | 0.82 |
| VolatileLong | 12.5% | 8.0% | 4.8% | -$3.5K | -$17.0K | -17.0% | 29 mo | 97d | 0.75 |
| StableShort | 6.8% | 5.1% | 3.8% | -$1.5K | -$18.0K | -22.1% | 52 mo | 97d | 0.54 |
| StableLong | 7.3% | 5.3% | 3.9% | -$1.8K | -$18.0K | -27.0% | 60 mo | 372d | 0.46 |

*Per $100K deposit. VaR = 30-day horizon. Recovery = months to breakeven after max drawdown.*

---

## YIELD COMPARISON TABLE

| Protocol | APY | Risk (1-10) | Liquidity | Lock? | Audited? |
|----------|-----|-------------|-----------|-------|----------|
| US T-Bills | 4.5% | 1 | Instant | No | N/A |
| Aave V3 USDC | 3-5% | 2 | Instant | No | Yes (Tier 1) |
| Compound V3 | 3-4% | 2 | Instant | No | Yes (Tier 1) |
| MakerDAO DSR | 5-8% | 3 | Instant | No | Yes (Tier 1) |
| Ethena sUSDe | 15-25% | 6 | 7d cooldown | Soft | Yes |
| **Lumina VolatileShort** | **7-12%** | **5** | **37d cooldown** | **Yes** | **AI-only** |
| **Lumina StableLong** | **5-7%** | **3** | **372d cooldown** | **Yes** | **AI-only** |

---

## KINK MODEL M(U) CURVE

| U% | M(U) | Premium at BCS/EAS 6.5% | Zone |
|----|------|---------------------|------|
| 0% | 1.000 | 6.50% | Safe |
| 20% | 1.125 | 7.31% | Safe |
| 40% | 1.250 | 8.13% | Safe |
| 60% | 1.375 | 8.94% | Safe |
| 80% | 1.500 | 9.75% | Kink |
| 85% | 2.250 | 14.63% | Stress |
| 90% | 3.000 | 19.50% | Stress |
| 95% | 3.750 | 24.38% | Critical |
| >95% | REJECT | — | — |

**Sweet spot for LPs:** U=50-65% (max yield per unit risk)
**Kink effect:** 12x steeper slope above 80% — directly inspired by Aave V3

---

## STRESS TESTS

| Scenario | Trigger | Vault Loss | Recovery |
|----------|---------|-----------|----------|
| ETH -50% (Black Thursday) | All BCS/EAS | -16.8% TVL | 27 months |
| USDT depeg to $0.90 | Depeg Shield | -22.1% TVL | 52 months |
| Aave V3 exploit (-20%) | Direct capital loss | -20% TVL | N/A (unrecoverable) |
| ETH crash + USDT depeg | Correlated BCS/EAS+Depeg | -22% volatile + -22% stable | 40+ months |
| Bank run (all LPs withdraw) | Liquidity crunch | 0% (cooldown prevents) | N/A |

---

## TOP 10 INSTITUTIONAL QUESTIONS

| # | Question | Answer |
|---|---------|--------|
| 1 | Security audit? | AI-only (8 agents, 126 tests). No human Tier 1 audit. |
| 2 | Max loss? | 70% correlation cap × 80% payout = ~56% of allocated capital |
| 3 | Who controls multisig? | 2-of-3 signers, identities not publicly disclosed |
| 4 | Oracle decentralized? | No. 1-of-1 default (planned 2-of-3) |
| 5 | Aave exploit impact? | Direct capital loss. Try/catch queues payouts but doesn't prevent Aave losses |
| 6 | Early exit? | No. Irrevocable cooldowns 37-372 days |
| 7 | Track record? | V3 launched April 2026. No claim events documented |
| 8 | Legal recourse? | Unlikely. No legal entity, no ToS |
| 9 | Premium pricing? | Kink model — actuarially reasonable but not backtested |
| 10 | USDC depeg? | 100% USDC-denominated. Systemic risk, no internal hedge |

---

## TOP 5 STRENGTHS

1. **Real yield, not emissions** — premiums = genuine risk transfer economics
2. **1:1 collateral backing** — no fractional reserve, no leverage
3. **Kink pricing is self-balancing** — borrowed from Aave, proven mechanism
4. **Automated parametric payouts** — no claims disputes, no moral hazard
5. **Aave V3 base yield floor** — LPs earn even at 0% utilization

## TOP 5 WEAKNESSES

1. **No Tier 1 external audit** — biggest barrier to institutional adoption
2. **Oracle 1-of-1** — single key compromise drains non-Exploit vaults
3. **Extreme illiquidity** — 37-372d irrevocable cooldowns, soulbound shares
4. **Long recovery times** — 27-60 months post-catastrophe
5. **BCS/EAS actuarially negative at small scale** — needs product blending + Aave subsidy

---

## RECOMMENDATIONS

- **Kink Model parameters:** Current settings are well-calibrated. No changes needed.
- **Base rates:** BCS/EAS 6.5% and IL 8.5% are appropriate for the risk. DEPEG 2.5% is barely competitive vs Nexus Mutual (2.6%). EXPLOIT 4.0% is 54% more expensive but justified by automation speed.
- **Cooldowns:** VolatileShort 37d is acceptable. StableLong 372d is extremely long — consider reducing to 180d.
- **Reaseguro:** Not implemented. At scale ($10M+ TVL), consider buying coverage on Nexus Mutual for tail risk.
- **Key metrics to track:** loss ratio per product, utilization by vault, premium income vs claim payouts, time-to-recovery after events.

---

## VERDICT

**Would an institutional invest today?** No. Missing: Tier 1 audit, oracle upgrade, multisig expansion, legal wrapper, operational history.

**For DeFi-native capital?** Yes — one of the more interesting real-yield opportunities on Base. Position sizing: 5-15% of portfolio until audit completed.

**Is the model sustainable?** Yes at scale ($5M+ TVL). At small scale, BCS/EAS alone is actuarially negative — protocol viability depends on product diversification and Aave yield subsidy.

**Best vault for LPs:** VolatileShort (highest Sharpe 0.82, shortest cooldown 37d, manageable drawdown).
