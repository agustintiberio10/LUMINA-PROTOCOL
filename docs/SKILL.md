# LUMINA PROTOCOL — SKILL V4.2 (SINGLE SOURCE OF TRUTH)
## Parametric risk speculation for humans and AI agents
### Base Sepolia testnet (Chain 84532) | Token: $LUMINA | Last update: 2026-05-06

---

## Lifecycle Overview (the 6 steps)

1. **Buy policy** — pay USDC premium → receive active policy.
2. **Event triggers** — parametric, on-chain, automatic. No manual claims.
3. **ClaimBond minted** — ERC-1155, $1 face value/unit, units = USDC coverage, maturity = 730 days.
4. **Decision**: hold to maturity (option A) or sell early (option B).
   - **Option A**: At day 730, call `redeemBond()` → receive `$LUMINA` (= units × $1 ÷ LUMINA_price_at_redeem).
   - **Option B**: List on `LuminaBondMarketplace` for USDC. Fees 1.5% maker + 1.5% taker.
5. **If sold**: new holder has same choice.
6. **Maturity (day 730)**: contract burns the bond and mints `$LUMINA` to the holder.

**Premium = USDC. Marketplace trade = USDC. Bond redeem at maturity = $LUMINA.**

Worked example: $3 USDC premium for $800 coverage → trigger fires → 800-unit bond minted → wait 730d → at $0.50 LUMINA → receive 1,600 LUMINA (= $800 / $0.50).

See [docs.lumina-org.com/concepts/lifecycle](https://docs.lumina-org.com/concepts/lifecycle) for the full diagram.

---

## 1. WHAT IS LUMINA

Lumina Protocol is a market where humans and AI agents bet against
market events. They pay cheap premiums. If the event occurs, they
receive ClaimBond tokens (ERC-1155) redeemable for $LUMINA in 24 months.
If the event doesn't occur, the premium already burned $LUMINA forever.

Two types of users:
  1. Speculators (humans via web + AI agents via API):
     buy cheap bets, collect bonds with 17x to 333x returns
  2. Yield Seekers (humans + funds + agents):
     buy discounted bonds, wait 24 months, earn yield

It's not just insurance. It's parametric speculation with built-in deflation.

---

## 2. TOKEN $LUMINA

Total supply:     100,000,000 (fixed, no mint function)
Burn:             ERC20Burnable + BURNER_ROLE
Chain:            Base Sepolia testnet (84532)
DEX:              Uniswap V3 (LUMINA/USDC)

DISTRIBUTION:
  82,000,000 (82%)  →  BondVault.sol        Bond Reserve
   5,000,000  (5%)  →  Fjord Foundry        LBP (generates liquidity with $0)
  10,000,000 (10%)  →  FounderVesting.sol   Founder (AltSeason conditions)
   3,000,000  (3%)  →  TreasuryVesting.sol  Treasury (6m lock, 250K/month after)

---

## 3. BURN SOURCES — 3 ENGINES OF DEFLATION

### Engine 1: PREMIUMS (primary, continuous)
100% of every premium paid by any user → buy & burn $LUMINA forever.
Happens at the moment of purchase, regardless of trigger outcome.
If there's no trigger: premium already burned, bet lost, nothing else happens.
If there's a trigger: premium already burned, bond is minted.

### Engine 2: MARKETPLACE FEES (secondary, activated post-launch)
When bond holders sell bonds P2P on the secondary marketplace:
  - 1.5% fee paid by seller (deducted from proceeds)
  - 1.5% fee paid by buyer (added to purchase price)
  - Total: 3% of trade value, all in USDC
These fees are sent to TWAPBurner, used to buy and burn $LUMINA. 100% burn.
No revenue sharing, no treasury portion. All fees burned.

### Engine 3: NONE
There are no other fees, no protocol taxes, no revenue streams.
Ops are funded out-of-pocket by the founder (~$183/month).

---

## 4. BONDVAULT — THE VAULT

Contains:         82,000,000 LUMINA
Type:             IMMUTABLE contract (no Ownable, no UUPS, no proxy)
Admin:            NOBODY
Withdraw:         DOES NOT EXIST
Emergency:        DOES NOT EXIST
Upgrade:          DOES NOT EXIST

Important clarification:
The 82M LUMINA are NOT locked or reserved. They sit passively in the vault.
The vault tracks bonds in USD terms (totalCommittedUSD).
Tokens only leave via redeemBond() when a bond matures.

ONLY EXIT: redeemBond(epochId, usdAmount)
  Requires: block.timestamp >= maturityDate[epochId]
  Reads current $LUMINA price from oracle at the moment of redemption
  Calculates: luminaAmount = usdAmount / currentPrice
  Transfers luminaAmount to caller
  Burns equivalent ERC-1155 bond tokens (they're the claimed ticket, now invalid)

Neither the founder, nor a multisig, nor governance can extract tokens.
Verifiable on BaseScan. The code is the law.

---

## 5. PRODUCTS — 9 SPECULATION PRODUCTS

### Pricing formula:
  Premium = Coverage × 0.80 × P(trigger) × 1.50
  Payout  = Coverage × 0.80 (as ClaimBond ERC-1155, 24 months)
  
  The user chooses coverage amount. Premium and payout scale proportionally.
  The multiplier is FIXED per product.
  Payout is FIXED IN USD. Settled in $LUMINA at market price at redemption.

### Product table:
  FLASHBTC1H-001   BTC drops 5%                     1 hour    0.20%   333x
  FLASHBTC4H-001   BTC drops 8%                     4 hours   0.35%   190x
  FLASHBTC24-001   BTC drops 10%                    24 hours  1.50%    44x
  FLASHBTC48-001   BTC drops 15%                    48 hours  0.80%    83x
  FLASHETH1H-001   ETH drops 7%                     1 hour    0.25%   266x
  FLASHETH24-001   ETH drops 12%                    24 hours  2.00%    33x
  FLASHETH48-001   ETH drops 18%                    48 hours  0.90%    74x
  MICRODEPEG-001   USDT trades below $0.995         7 days    3.50%    19x
  RATESHOCK-001    Aave USDC borrow rate above 10%  7 days    4.00%    17x

### Example at $1,000 coverage:
  Flash BTC 1h:  Premium $2.40 → Bond of $800 (333x)
  Flash BTC 24h: Premium $18   → Bond of $800 (44x)
  Micro Depeg:   Premium $42   → Bond of $800 (19x)

---

## 6. CLAIMBONDS — ERC-1155 BY EPOCH

Standard:       ERC-1155 (fungible by epoch, fractional)
Token ID:       maturity epoch (format: YYYYMM)
Unit:           1 token = $1 USD of claim, settled in $LUMINA at market price
Quantity:       payout in USD (e.g., $800 payout → 800 tokens)
Maturity:       100% at 24 months. No linear vesting. No monthly unlock.

### Lifecycle:

ISSUANCE (at trigger):
  Payout $800, regardless of $LUMINA price at this moment
  Mint 800 tokens of epoch "202804" to the user
  BondVault tracks: totalCommittedUSD += $800
  No LUMINA moves. Only USD accounting changes.

HOLDING (between trigger and maturity):
  User can hold all 800 tokens
  User can sell all or part on the secondary marketplace
  User can transfer to any wallet (ERC-1155 is transferable)

REDEMPTION (at maturity, 24 months later):
  User calls bondVault.redeemBond(202804, amount)
  Contract reads current $LUMINA price
  If $LUMINA = $0.50: 800 tokens → 1,600 LUMINA ($800 worth)
  If $LUMINA = $2.00: 800 tokens → 400 LUMINA ($800 worth)
  THE USD VALUE IS ALWAYS $800. Only token count changes.
  Bond tokens are destroyed (claimed ticket, invalid now)
  totalCommittedUSD decreases by $800
  Partial redemption allowed.

---

## 7. COMPLETE FLOW

1. USER BUYS POLICY
   Humans: web app. AI Agents: POST /api/v1/purchase
   Pays premium in USDC.

2. PREMIUM BURNS $LUMINA IMMEDIATELY
   100% of premium → TWAPBurner → buys LUMINA on Uniswap → burns
   This happens NOW, before we know if there's a trigger.
   Nothing goes to treasury. Nothing goes to the team.

3a. NO TRIGGER → bet lost
    Premium already burned. Supply decreased. Done.

3b. TRIGGER → bond minted
    ERC-1155 tokens issued to user, denominated in USD.
    No LUMINA moves. BondVault tracks USD commitment.

4. HOLDER CAN TRADE BONDS (optional, any time)
   Sell all or part on secondary marketplace for USDC.
   Marketplace charges 3% fee (1.5% buyer + 1.5% seller).
   All fees → TWAPBurner → additional burn.

5. BOND MATURES (month 25)
   Holder redeems for $LUMINA at current market price.
   USD value never changes. Token count adjusts.

---

## 8. DEFLATIONARY MATH

Per-policy identity:
  Premium = Coverage × 0.80 × P(trigger) × 1.50
  Expected payout = Coverage × 0.80 × P(trigger)
  Ratio = Premium / Expected_payout = 1.50

This means: for every $1 the BondVault will pay out (probabilistically),
$1.50 is burned from premiums up front.
Net: $0.50 deflationary per expected $1 of payout.
Margin: 50% above breakeven.

Plus marketplace fees (3% of P2P trade volume) add additional burn
on top of the base 1.50 ratio.

Total burn rate is higher than 1.50 whenever the marketplace has activity.

Capacity formula:
  max_policies/day = 11,233 × LUMINA_price
  At $0.036: 404 policies/day
  At $0.10:  1,123 policies/day
  At $1.00:  11,233 policies/day

Circuit breaker: if price < $0.005 → pause new issuance.
Reactivation: price > $0.008 (hysteresis).
Redemptions always available, never blocked.

---

## 9. FOUNDER — 10% ALTSEASON VESTING

10,000,000 LUMINA locked until AltSeason conditions:
  2-of-3 sustained 7 days: ETH/BTC > 0.050, ETH > $4,000, Aave > 7%
  Fallback: 1460 days (4 years)
  Release: 3 tranches every 31 days
  OTC sales only (never on Uniswap) to avoid price impact

---

## 10. TREASURY — 3% WITH TIMELOCK

3,000,000 LUMINA. Locked 6 months. Max 250,000/month after.
Gnosis Safe multisig. Never sold on open market.
Used only for: liquidity top-ups, market maker deals,
bug bounties, emergency bond reserve top-up.

---

## 11. TGE — LAUNCH WITH $0

LBP on Fjord Foundry: 5M LUMINA, 72 hours, 96/4 → 50/50 weight.
Estimated raise: $52K-$133K USDC.
Post-LBP: all proceeds → Uniswap V3 pool (Protocol-Owned Liquidity).
Circulating: ~5M LUMINA (5%). Price: ~$0.036. FDV: ~$3.6M.

---

## 12. CONTRACTS — FULL LIST

### New V2 (9):
  1. LuminaTokenV2.sol          ERC20 + Burnable, 100M fixed
  2. BondVault.sol               Immutable, no owner, 82M LUMINA
  3. ClaimBond.sol               ERC-1155, monthly epochs, USD-denominated
  4. CapacityOracle.sol          TWAP price + capacity formula + circuit breaker
  5. TWAPBurner.sol              Distributed buy & burn, BURNER_ROLE
  6. FounderVesting.sol          10M, AltSeason conditions, 3 tranches
  7. TreasuryVesting.sol         3M, 6m lock, 250K/month post-lock
  8. LuminaBondMarketplace.sol   Orderbook for ERC-1155 bonds, 3% fee, 100% burn
  9. PolicyManagerV2.sol         Upgrade of PolicyManager for V2 model

### Kept & modified (5):
  10. CoverRouter.sol            Modified: sends 100% of premium to TWAPBurner
  11. FlashBTCShield24h.sol      Trigger changed to -10% (was -18%)
  12. FlashBTCShield48h.sol      Trigger changed to -15% (was -22%)
  13. FlashETHShield24h.sol      Trigger changed to -12% (was -20%)
  14. FlashETHShield48h.sol      Trigger changed to -18% (was -28%)

### New shields (5):
  15. FlashBTCShield1h.sol       BTC -5%, 1 hour
  16. FlashBTCShield4h.sol       BTC -8%, 4 hours
  17. FlashETHShield1h.sol       ETH -7%, 1 hour
  18. MicroDepegShield.sol       USDT <$0.995, 7 days
  19. RateShockShield.sol        Aave USDC >10%, 7 days

### Archived (56 files in archive/v1-vault-model/)

---

## 13. API — ENDPOINTS

POST /api/v1/purchase          Buy policy (USDC)
GET  /api/v1/products          Product list with pricing
GET  /api/v1/capacity          Current protocol capacity
GET  /api/v1/stats             Total burned, rate, supply, price

GET  /api/v1/bonds/:address    Bonds by address (ERC-1155 balances by epoch)
GET  /api/v1/bonds/epoch/:id   Epoch detail (supply, maturity, holders)
POST /api/v1/bonds/redeem      Redeem mature bonds

GET  /api/v1/marketplace/listings      Bonds for sale
POST /api/v1/marketplace/list          List bonds for sale (seller pays 1.5% on sale)
POST /api/v1/marketplace/buy           Buy listed bonds (buyer pays 1.5% fee)
POST /api/v1/marketplace/cancel        Cancel listing
GET  /api/v1/marketplace/stats         Volume, avg discount, fees burned

POST /api/v1/keys/create       Create API key (requires wallet signature)
GET  /api/v1/keys/list         List API keys for wallet

---

## 14. IMMUTABLE RULES

1. BondVault has NO withdraw, NO owner, NO upgrade.
2. The protocol NEVER buys bonds itself (Golden Rule — Gemini).
3. $LUMINA has NO mint. Supply only goes down.
4. Bonds are ERC-1155 grouped by monthly maturity epoch.
5. Bond payouts are FIXED IN USD. Settled in $LUMINA at market price at redemption.
6. Bonds mature 100% at 24 months. No linear vesting.
7. 100% of premiums buy and burn $LUMINA. Always.
8. Marketplace fees: 1.5% buyer + 1.5% seller = 3% total. All burned.
9. The pricing margin is 1.50. Always.
10. The founder CANNOT access tokens until AltSeason or 4-year fallback.
11. Treasury releases after 6 months, max 250K/month.
12. Lumina Protocol is 100% DeFi. No connection to traditional insurance.
