# V5.1 Boundary Thresholds Inventory

**Audit:** V5.1 #6 — Boundary Conditions Re-audit
**Branch:** `audit/v5.1-06-boundary-conditions`
**Date:** 2026-04-22

---

## 1. Thresholds Tested

Each threshold is exercised at the **exact boundary**, **1 wei/unit below**,
and **1 wei/unit above** wherever applicable.

### BondVault
| Threshold | Value | Test |
|-----------|-------|------|
| burn cap per tx | 5% of reserve | exact / below / above |
| SAFETY_FACTOR_BPS | 5000 (50%) | commit = 50% → avail = 0; −$1 → avail = $1 |
| MIN_REDEEM_PRICE | 1e15 (0.001 USD/LUMINA) | value assertion |
| BOND_MATURITY_SECONDS | 730 days | value assertion |

### SolvencyOracle
| Threshold | Value | Test |
|-----------|-------|------|
| SOLVENCY_ULTRA_BPS | 20000 | ratio = 20000 reachable, 20001 above |
| SOLVENCY_HEALTHY_BPS | 10000 | ratio = 10000 reachable |
| SOLVENCY_STRESSED_BPS | 7000 | ratio = 7000 reachable, 6999 below (crisis) |
| MOMENTUM_RALLY_BPS | 11000 | constant asserted (indirect via distribution) |
| MOMENTUM_STABLE_LOW_BPS | 9500 | constant asserted |
| MOMENTUM_DECLINE_BPS | 8500 | constant asserted |
| EVALUATION_INTERVAL | 1 day | value assertion |
| COOLDOWN_BETWEEN_QUADRANT_CHANGES | 7 days | value assertion |

### BuybackEngine
| Threshold | Value | Test |
|-----------|-------|------|
| maxPricePercent | 1..95 | exact 95 allows; 96 reverts; 94 allows; 0 reverts |
| duration hours | 1..72 | exact 72 allows; 73 reverts; 0 reverts |

### TWAPBurner
| Threshold | Value | Test |
|-----------|-------|------|
| maxSlippageBps | 50..1000 | 50 allows; 49 reverts; 1000 allows; 1001 reverts |
| burnCooldown | 60..86400 | 60 allows; 59 reverts; 86400 allows; 86401 reverts |
| minBurnAmount | ≥ 0.1 USDC (1e5) | 1e5 allows; 1e5−1 reverts |
| poolFee | {500,3000,10000} | valid values accepted; 400 reverts |

### CapacityOracle
| Threshold | Value | Test |
|-----------|-------|------|
| twapWindow | 300..7200 s | 300 allows; 299 reverts; 7200 allows; 7201 reverts |
| emergencyPrice | > 0 | 0 reverts; 1 allows |

### AdaptiveFeeDistributor
| Threshold | Value | Test |
|-----------|-------|------|
| distribution sum | 10000 | all 16 quadrants sum exactly 10000 |
| maintenance floor | 200 bps | all 16 quadrants ≥ 200 |
| solvency level | 0..3 | level 4 reverts |
| momentum level | 0..3 | level 4 reverts |

### LuminaBondMarketplace
| Threshold | Value | Test |
|-----------|-------|------|
| BUYER_FEE_BPS | 150 (1.5%) | exact calculation asserted |
| SELLER_FEE_BPS | 150 (1.5%) | constant asserted |
| BPS_DENOMINATOR | 10000 | constant asserted |

### Shields (9 products)
| Shield | TRIGGER_DROP_BPS | MIN/MAX_DURATION |
|--------|-----------------:|-----------------:|
| FlashBTCShield1h | 500 (5%) | 3600 s |
| FlashBTCShield4h | 800 (8%) | 14400 s |
| FlashBTCShield24h | 1000 (10%) | 86400 s |
| FlashBTCShield48h | 1500 (15%) | 172800 s |
| FlashETHShield1h | 700 (7%) | 3600 s |
| FlashETHShield24h | 1200 (12%) | 86400 s |
| FlashETHShield48h | 1800 (18%) | 172800 s |
| MicroDepegShield | `TRIGGER_PRICE` = 99_500_000 ($0.995, 8-dec) | 604800 s |
| RateShockShield | `TRIGGER_RATE` = 10e25 (10% APY, RAY) | 604800 s |
| all 7 BSS children | `DEDUCTIBLE_BPS` = 2000 (20%) | — |

### Epoch (BondVault._timestampToEpoch)
| Case | Result |
|------|--------|
| `block.timestamp` 1970, maturity 1972 (before BASE_TS) | revert "Before base" |
| `block.timestamp` BASE_TS − 1 (maturity well after BASE_TS) | succeed |
| `block.timestamp` = BASE_TS | succeed |

### Token distribution
| Bucket | Amount |
|--------|--------|
| BondVault | 70M |
| CEX | 14M |
| Founder | 8M |
| LBP | 5M |
| Treasury | 3M |
| **Sum** | **100M** ✓ (`totalSupply == 100_000_000e18`) |

### CoverRouterV2 circuit-breaker constants
| Constant | Value |
|----------|-------|
| `MIN_PRICE_FOR_NEW_POLICIES` | 5e15 ($0.005) |
| `RESET_PRICE_FOR_NEW_POLICIES` | 8e15 ($0.008) |

### CoverRouterV2 premium coverage
| Case | Result |
|------|--------|
| `quotePremium(pid, 100e6)` | succeeds, premium > 0 |
| `quotePremium(pid, 99e6)` | succeeds (enforcement is in buyPolicy only) |

See `REPORT.md` for test counts and raw forge output.
