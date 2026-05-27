#!/usr/bin/env python3
"""
LUMINA Protocol — Economic Stress Model (V5.3/V5.4)
Audit 7.5 — 2026-05-27. Pure-stdlib (no deps). Run: python economic-model-v53.py

Grounded in on-chain reality (Base Sepolia V5.4):
  LUMINA supply        = 100,000,000
  BondVault reserve    = 70,000,000 LUMINA   (the ONLY payout backing)
  LUMINA price         = $0.036              (CapacityOracle.getLuminaPrice)
  premium formula      = coverage * payoutRatio(0.80) * triggerProb * margin(2.0)
  payout (face)        = coverage * payoutRatio(0.80)        [ClaimBond, $1 = $1 face]
  ClaimBond redeem     = faceUSD / luminaPrice  LUMINA  (from the 70M reserve)
  premium routing      = 100% USDC -> TWAPBurner -> buy&burn LUMINA (deflationary)
  redeem throttle      = 1.08% of reserve value / 7-day epoch ; 10% per user
  circuit breaker      = block new policies if LUMINA price < $0.005 (reset $0.008)
"""
import sys
try: sys.stdout.reconfigure(encoding="utf-8")
except Exception: pass

SUPPLY        = 100_000_000
RESERVE_LUM   = 70_000_000          # BondVault LUMINA (payout backing)
LUM_PRICE0    = 0.036               # USD
PAYOUT_RATIO  = 0.80
MARGIN        = 2.0
THROTTLE_WK   = 0.0108              # 1.08% of reserve VALUE redeemable / week
USER_CAP      = 0.10                # 10% of epoch cap per user
CB_FLOOR      = 0.005               # circuit breaker (block NEW policies)
CB_RESET      = 0.008
SAFETY_FACTOR = 0.50                # BondVault SAFETY_FACTOR_BPS=5000: max commit
                                    # = 50% of reserve value (≈200% backing).
                                    # Payout CAPACITY is HALF the reserve value.

# 6 products: trigger probability (bps) priced into the premium
TRIGGER_PROB = {                    # annualless per-window modeled prob (bps/10000)
    "FlashBTC1h": 0.0018, "FlashBTC24h": 0.0329, "FlashBTC48h": 0.0929,
    "FlashETH1h": 0.0010, "FlashETH24h": 0.0286, "FlashETH48h": 0.0769,
}

def premium(coverage, tprob):  return coverage * PAYOUT_RATIO * tprob * MARGIN
def face(coverage):            return coverage * PAYOUT_RATIO
def lumina_per_face(price):    return 1.0 / price          # LUMINA per $1 face
def reserve_value(price, reserve=RESERVE_LUM): return reserve * price
def face_capacity(price, reserve=RESERVE_LUM):              # ENFORCED payout ceiling
    return reserve_value(price, reserve) * SAFETY_FACTOR    # 50% commit rule

def line(t): print("\n" + "="*70 + "\n" + t + "\n" + "="*70)

# ---------------------------------------------------------------- baseline
line("BASELINE (on-chain)")
print(f"Reserve value @ ${LUM_PRICE0}: ${reserve_value(LUM_PRICE0):,.0f}  (70M LUMINA)")
print(f"ENFORCED payout capacity (50% commit rule): ${face_capacity(LUM_PRICE0):,.0f}")
print(f"Each $1 ClaimBond redeems {lumina_per_face(LUM_PRICE0):.2f} LUMINA")
print(f"Weekly redeemable (throttle 1.08%): ${reserve_value(LUM_PRICE0)*THROTTLE_WK:,.0f}/wk  "
      f"= {RESERVE_LUM*THROTTLE_WK:,.0f} LUMINA/wk")
print(f"Time to redeem 100% of reserve at throttle: {1/THROTTLE_WK:.0f} weeks (~{1/THROTTLE_WK/52:.1f} yrs)")

# ---------------------------------------------------------------- 2.1 steady state
line("2.1 STEADY STATE  (100 policies/mo, 50% trigger, $100 avg, mixed products)")
N, TR, COV = 100, 0.50, 100
avg_tprob = sum(TRIGGER_PROB.values())/len(TRIGGER_PROB)
prem_in  = N * premium(COV, avg_tprob)            # USDC in (burned)
# NOTE: real trigger rate is driven by markets, NOT the *priced* prob. We model
# an OPERATOR-CHOSEN 50% scenario to stress the reserve (worst realistic case).
faces    = N * TR * face(COV)                      # $ face minted as ClaimBonds
lum_out  = faces * lumina_per_face(LUM_PRICE0)     # LUMINA drained from reserve
print(f"Premium USDC in (burned): ${prem_in:,.2f}/mo")
print(f"ClaimBond face minted:    ${faces:,.0f}/mo  ({N*TR:.0f} triggers x $80)")
print(f"LUMINA drained/mo:        {lum_out:,.0f} LUMINA  ({lum_out/RESERVE_LUM*100:.4f}% of reserve)")
print(f">> Reserve lasts {RESERVE_LUM/lum_out:,.0f} months at this rate "
      f"(~{RESERVE_LUM/lum_out/12:,.0f} yrs). Premium ($) << payout face ($) -> "
      f"USDC does NOT fund payouts; reserve does. Premiums only deflate LUMINA.")

# ---------------------------------------------------------------- 2.2 black swan
line("2.2 BLACK SWAN  (BTC -30%: all FlashBTC policies trigger same day)")
cap = face_capacity(LUM_PRICE0)
for active, cov in [(1_000, 100), (10_000, 100), (1_000, 1_000)]:
    f = active * face(cov); lum = f * lumina_per_face(LUM_PRICE0)
    print(f"{active:,} active FlashBTC @ ${cov}: face=${f:,.0f}  needs {lum:,.0f} LUMINA "
          f"({lum/RESERVE_LUM*100:.1f}% of reserve) | ENFORCED capacity ${cap:,.0f} "
          f"-> {'OK' if f<cap else '🚨 EXCEEDS CAPACITY (new bonds blocked at 50% commit)'}")
print(">> 🚨 The 50% commit ceiling = $1.26M (NOT $2.52M) is the hard cap. "
      "issueBond REVERTS once committed face hits 50% of reserve value. "
      "10k policies @ $100 ($800k face) already uses 63% of the $1.26M ceiling.")

# ---------------------------------------------------------------- 2.3 bank run
line("2.3 BANK RUN  (all ClaimBond holders redeem at once)")
for outstanding in [100_000, 1_000_000, 2_520_000]:
    wk_cap = reserve_value(LUM_PRICE0)*THROTTLE_WK
    weeks = outstanding/wk_cap
    print(f"${outstanding:,.0f} face outstanding: throttle ${wk_cap:,.0f}/wk -> "
          f"{weeks:,.1f} weeks (~{weeks/52:.1f} yrs) to clear; "
          f"week-1 redeemable = {THROTTLE_WK*100:.2f}% = ${wk_cap:,.0f}")
print(">> Throttle PREVENTS a bank run from draining the reserve, but holders wait "
      "years. ClaimBonds are illiquid by design -> secondary marketplace is the exit.")

# ---------------------------------------------------------------- 2.4 death spiral
line("2.4 DEATH SPIRAL  (LUMINA price crash -> bonds drain more LUMINA)")
for p in [0.036, 0.018, 0.0072, 0.005, 0.0036]:
    lpf = lumina_per_face(p); cap = face_capacity(p, RESERVE_LUM)
    note = ""
    if p < CB_FLOOR: note = "<< new policies blocked"
    if p <= 0.005:   note += " | 🚨 redeem floor $0.005 -> redemptions REVERT (fail-closed)"
    print(f"LUMINA ${p:.4f}: $1 bond -> {lpf:,.1f} LUMINA | enforced capacity "
          f"${cap:,.0f} {note}")
print(">> 🚨 Two-edged: as price falls each $1 bond drains MORE LUMINA AND the 50% "
      "capacity shrinks. BUT MIN_REDEEM_PRICE $0.005 makes BondVault FAIL-CLOSED: at/below "
      "$0.005 redemptions REVERT entirely (holders cannot redeem at all). The breaker "
      "protects the reserve from infinite drain, but STRANDS bondholders. Defense exists; "
      "burden falls on holders, not the token.")

# ---------------------------------------------------------------- 2.5 marketplace arb
line("2.5 MARKETPLACE ARBITRAGE  (buy discounted bonds, redeem at maturity)")
for disc in [0.30, 0.50, 0.70]:
    buy = 100*(1-disc); redeem_val = 100  # $100 face -> $100 of LUMINA (at maturity price)
    print(f"Buy $100 face at {disc*100:.0f}% discount (${buy:.0f}) -> redeem $100 face: "
          f"gross profit ${redeem_val-buy:.0f} IF LUMINA price stable + bond matured + throttle allows")
print(">> Arb is bounded by: 730d maturity wait, throttle/queue at redeem, and LUMINA "
      "price risk over the hold. Marketplace fee 3%. Profitable only if discount > price "
      "decay + time-value -> self-correcting (discount reflects illiquidity).")

# ---------------------------------------------------------------- FASE 4 breaking points
line("FASE 4 — BREAKING POINTS (12-month projection)")
cap = face_capacity(LUM_PRICE0)
print(f"ENFORCED capacity @ $0.036 = ${cap:,.0f} (50% of $2.52M). Months until cumulative "
      "TRIGGERED face exhausts capacity:")
print(f"{'pol/mo':>8}{'trig%':>7}{'cov$':>7}{'face/mo$':>12}{'months to cap':>16}")
for N in [100, 1000, 5000, 10000]:
    for TR in [0.10, 0.50]:
        f = N*TR*face(100); months = cap/f if f else 9e9
        print(f"{N:>8}{TR*100:>6.0f}%{100:>7}{f:>12,.0f}{months:>16,.1f}")
print(">> 🚨 BREAKING POINT: at 10,000 pol/mo & 50% trigger -> $400k face/mo -> the $1.26M "
      "ENFORCED capacity is hit in ~3.2 months, after which issueBond REVERTS (new triggers "
      "cannot mint bonds). The reserve is finite, NOT refilled by premiums (premiums burn "
      "LUMINA; only buyback-reserve recycling/CEX-injection—dormant—could refill).")

# ---------------------------------------------------------------- 2.12 cold start
line("2.12 COLD START  (T+0: 70M LUMINA reserve, $0 USDC, first trigger)")
print("First trigger mints a ClaimBond (face $80) -> redeemable in LUMINA from the 70M "
      "reserve. NO USDC needed to pay (payout is LUMINA, not USDC). So cold-start payout "
      "WORKS from day 1 (reserve pre-funded). The $0 USDC only means $0 burned yet.")
print(">> Cold start is SOLVENT for payouts; the risk is LUMINA price discovery (thin "
      "liquidity -> volatile redeem value).")

line("KEY TAKEAWExtended in the .md report")
print("Premiums (USDC) burn LUMINA; payouts (LUMINA) come from the fixed 70M reserve.")
print("=> Solvency = reserve_LUMINA * price vs outstanding face. Finite & price-linked.")
