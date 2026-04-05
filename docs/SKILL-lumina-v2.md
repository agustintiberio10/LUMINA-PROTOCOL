# SKILL: Lumina Protocol — Insurance & Yield for AI Agents

## Version: 2.3 (March 2026)
## Last updated: 2026-03-24
## Chain: Base L2 (8453) | Settlement: USDC (Circle)
## Contact: hello@lumina-org.com
## Docs: https://lumina-org.com

---

# SECTION 1: WHAT IS LUMINA?

Lumina Protocol is parametric insurance built exclusively for AI agents. No humans buy policies or deposit funds — only agents do. Every operation is automated, on-chain, and instant.

**What does "parametric" mean?**
Traditional insurance requires a human to file a claim, a human to review it, and weeks to get paid. Parametric insurance uses mathematical triggers verified by oracles. If the condition is met (e.g., ETH drops 30%), the payout is instant and automatic. No claims. No disputes. No waiting for humans.

**Why should an agent care?**
If you manage DeFi positions, treasury funds, or LP positions, you face risks that can destroy your portfolio in minutes: market crashes, stablecoin depegs, impermanent loss, protocol hacks. Lumina lets you hedge these risks programmatically, just like a professional trading desk hedges its exposure.

**What does it cost?**
Typically 0.5% to 3% of the covered amount per month, depending on the product, duration, and current market conditions. Think of it as the cost of sleeping well at night.

**Protocol Fee:**
Lumina charges a 3% protocol fee on two events:
- **When you buy:** 3% of your premium goes to the protocol. The vault receives 97%.
- **When you claim:** 3% of your payout goes to the protocol. You receive 97%.

This means your NET payout = calculated payout × 0.97. If a BSS policy calculates $40,000 payout (80% of $50K coverage), you receive $38,800. Plan your coverage accordingly.

**Coverage planning with fee:**
If you need to receive EXACTLY $40,000 net after a claim:
```
Required coverage = target_net / (maxPayout% × 0.97)
BSS: $40,000 / (0.80 × 0.97) = $51,546 coverage
Depeg USDT: $40,000 / (0.85 × 0.97) = $48,530 coverage
Depeg DAI: $40,000 / (0.88 × 0.97) = $46,860 coverage
Exploit: $40,000 / (0.90 × 0.97) = $45,830 coverage
```

---

# SECTION 2: THE 4 INSURANCE PRODUCTS

## Product 1: Black Swan Shield (BSS)

**What it covers:** Catastrophic crash of ETH or BTC (>30% drop from your purchase price).

**When you need it:** You hold ETH/BTC exposure and want protection against sudden market collapse. Not for normal 10-15% swings — this is for "the world is ending" scenarios like COVID March 2020, LUNA collapse 2022, or FTX crash 2022.

| Parameter | Value |
|-----------|-------|
| Product ID | `BLACKSWAN-001` |
| Trigger | Price drops >30% from the exact price at the moment you buy the policy |
| Payout | 80% of coverage (20% deductible) |
| Duration | 7 to 30 days (you choose, priced by the second) |
| Waiting Period | 1 hour |
| Minimum Coverage | $100 |
| Base Rate | 22% annualized |
| Protocol Fee | 3% on premium + 3% on payout. Net payout = 77.6% of coverage |

**Example:**
```
You buy: $50,000 coverage on ETH for 14 days
ETH price at purchase: $2,000
Trigger price: $2,000 × 0.70 = $1,400

Premium: $50,000 × 0.22 × 1.25 (utilization multiplier) × (14/365) = $527

Scenario A: ETH stays above $1,400 → policy expires, you lose $527
Scenario B: ETH crashes to $1,350 → you receive $40,000 (80% of $50K)
Return on premium: $40,000 / $527 = 75x
```

**Pricing table ($50,000 coverage, utilization 40%):**

| Duration | Premium | % of Coverage |
|----------|---------|---------------|
| 7 days | $264 | 0.53% |
| 14 days | $527 | 1.05% |
| 21 days | $791 | 1.58% |
| 30 days | $1,130 | 2.26% |

---

## Product 2: Depeg Shield

**What it covers:** Stablecoin losing its peg — falling below $0.95. Covers USDT and DAI (USDC excluded).

**When you need it:** You hold large stablecoin positions and want protection against a SVB-type event (USDC went to $0.87 in March 2023) or a Tether FUD event. The longer your hold period, the more sense it makes.

| Parameter | Value |
|-----------|-------|
| Product ID | `DEPEG-STABLE-001` |
| Trigger | Stablecoin TWAP 30 min < $0.95 |
| Payout | Depends on stablecoin (see below) |
| Duration | 14 to 365 days |
| Waiting Period | 24 hours (protection starts after 24h) |
| Base Rate | 24% annualized |
| Protocol Fee (USDT) | 3% on premium + 3% on payout. Net payout USDT = 82.45% of coverage |
| Protocol Fee (DAI) | 3% on premium + 3% on payout. Net payout DAI = 85.36% of coverage |

**Why 24h waiting?** Stablecoin depegs develop slowly: rumors → news → panic → depeg. The 24h window prevents agents from buying insurance after seeing the first signs of trouble. This is what makes the product actuarially viable — without it, premiums would be 3x higher.

**Payout by stablecoin:**

| Stablecoin | Deductible | Max Payout | Risk Multiplier | Why different? |
|------------|-----------|------------|-----------------|----------------|
| USDT | 15% | 85% | 1.4x | Historically opaque reserves. Highest perceived risk. |
| DAI | 12% | 88% | 1.2x | Crypto-collateralized via MakerDAO. Cascade liquidation risk. |

Note: USDC is excluded — Lumina settles in USDC, so insuring it would be circular.

**Duration discount (longer = cheaper per day):**

| Duration | Discount | Effect |
|----------|----------|--------|
| 14-90 days | 1.0x | Standard price |
| 91-180 days | 0.90x | 10% cheaper per day |
| 181-365 days | 0.80x | 20% cheaper per day |

**Example:**
```
You buy: $100,000 USDT coverage for 90 days
Premium: $100,000 × 0.24 × 1.4 × 1.0 × 1.25 (util) × (90/365) = $5,178

If USDT depegs to $0.93 (TWAP 30 min confirms):
→ Gross Payout = $100,000 × 0.85 = $85,000 (15% deductible)
→ Protocol Fee = $85,000 × 0.03 = $2,550
→ Net Payout (you receive) = $82,450
→ Return: $82,450 / $5,178 = 15.9x
```

---

## Product 3: IL Index Cover

**What it covers:** Impermanent Loss exceeding 2% for liquidity providers in AMMs (Uniswap, Aerodrome, Curve).

**When you need it:** You provide liquidity in ETH/USDC pools and want protection against large price movements that create IL. This is NOT for concentrated liquidity (V3 ranges) — it covers the standard IL formula for 50/50 pools.

**KEY DIFFERENCE:** This is the only product with PROPORTIONAL payout. The others pay a fixed percentage (binary). IL Index pays based on the actual IL at expiry.

| Parameter | Value |
|-----------|-------|
| Product ID | `ILPROT-001` |
| Trigger | IL > 2% at policy expiry |
| Payout | Proportional: Coverage × max(0, IL% - 2%) × 90% |
| Cap | 11.7% of coverage |
| Resolution | European-style: ONLY within 48h window after expiry |
| Duration | 14 to 90 days |
| Waiting Period | 1 hour |
| Base Rate | 20% annualized |
| Asset | ETH/USD |
| Protocol Fee | 3% on premium + 3% on payout. Net payout = IL_net × 87.3% of coverage |

**CRITICAL — European-style resolution:**
Unlike other products where you can claim anytime during coverage, IL Index can ONLY be claimed within 48 hours after the policy expires. This prevents you from scanning the entire policy window and claiming at the point of maximum IL (which would be an "American option" and destroy LP economics).

**The 2% deductible is "restable" (subtracted, not multiplicative):**
```
IL formula: IL% = 1 - 2√r / (1+r), where r = currentPrice / purchasePrice

IL of 1.9% → payout = $0 (below deductible)
IL of 2.0% → payout = $0 (exactly at deductible)
IL of 3.0% → payout = coverage × (3.0% - 2.0%) × 90% = coverage × 0.9%
IL of 5.0% → payout = coverage × (5.0% - 2.0%) × 90% = coverage × 2.7%
```

**Payout table ($50,000 coverage):**

| ETH moves | IL% | IL net (−2%) | Payout |
|-----------|-----|-------------|--------|
| ±10% | 0.6% | 0% | $0 |
| ±20% | 2.0% | 0% | $0 |
| ±25% | 3.0% | 1.0% | $450 |
| ±30% | 4.4% | 2.4% | $1,080 |
| ±50% | 5.7% | 3.7% | $1,665 |
| ±75% | 10.6% | 8.6% | $3,870 |
| >±90% | >15% | cap | $5,850 |

**Optimal coverage strategy:**
Don't insure 100% of your LP position — the premium eats the yield. The sweet spot is covering ~50-60% of your position, spending no more than 50% of your projected pool fees on the premium.

```
Example:
  LP position: $100,000 in ETH/USDC pool
  Pool APY: 3% monthly = $3,000/month in fees
  Max premium budget: $1,500 (50% of fees)
  Optimal coverage: $1,500 / (0.20 × 1.25 × 30/365) = ~$73,000
  You cover 73% of your position for $1,500/month
```

---

## Product 4: Exploit Shield

**What it covers:** Catastrophic hack or exploit of a specific DeFi protocol (Compound, Uniswap, MakerDAO, Curve, Morpho). Aave V3 is excluded — Lumina vaults deposit into Aave, so insuring it would be circular.

**When you need it:** You have funds deposited in a DeFi protocol and want protection against a smart contract exploit. This is the DeFi equivalent of bank robbery insurance.

| Parameter | Value |
|-----------|-------|
| Product ID | `EXPLOIT-001` |
| Trigger | DUAL: (1) Governance token -25% in 24h AND (2) Receipt token -30% for 4h or contract paused. Verified via Oracle+TEE |
| Payout | 90% of coverage (10% deductible) |
| Duration | 90 to 365 days |
| Waiting Period | 14 days (longest — anti-insider) |
| Max Coverage | $50,000 per wallet |
| Lifetime Cap | $150,000 per wallet |
| Base Rate | 3% annualized (Tier 1) |
| Protocol Fee | 3% on premium + 3% on payout. Net payout = 87.3% of coverage |

**Why dual trigger?**
A single trigger would create false positives:
- Bear market drops governance tokens 25% → but aUSDC still worth $1 → NOT an exploit
- Flash loan moves receipt token for 1 block → but governance token unchanged → NOT an exploit
Only a REAL exploit triggers BOTH conditions simultaneously.

**Why 14-day waiting?** A security researcher could discover a vulnerability, buy insurance, then exploit/report it. 14 days makes this impractical.

**Why $50K cap?** If a hacker finds a $100M zero-day, a $45K Lumina payout doesn't justify burning the exploit.

**Protocols and pricing ($50K coverage, 365 days, U=40%):**

| Protocol | Tier | Risk Mult | Premium/year | % |
|----------|------|-----------|-------------|---|
| Compound III | 1 | 1.0x | $1,500 | 3.0% |
| Uniswap v3 | 1 | 1.0x | $1,500 | 3.0% |
| MakerDAO | 1 | 1.1x | $1,650 | 3.3% |
| Curve | 2 | 1.5x | $2,250 | 4.5% |
| Morpho | 2 | 1.8x | $2,700 | 5.4% |

**Comparison with Nexus Mutual:**
| | Lumina | Nexus Mutual |
|---|---|---|
| Resolution | Automatic, 1 transaction, minutes | Claim + human vote, up to 35 days |
| Trigger | Parametric dual (trustless) | Subjective jury decision |
| Operator | AI agent (M2M) | Human |
| Annual cost (Tier 1) | ~3% | ~2.6% |
| Advantage | Speed, automation | Covers more scenarios |

---

# SECTION 3: YIELD — HOW LPs EARN MONEY

## The Two Layers of Yield

When you deposit USDC into a Lumina vault, you earn from TWO independent sources:

### Layer 1: Aave V3 Lending Yield (variable, ~3-5% APY)
USDC is deposited into Aave V3 on Base, earning lending APY (~3-5%, variable). This is your baseline yield floor, independent of Lumina policy activity. Your USDC is supplied to Aave V3. The vault holds aUSDC (Aave's receipt token) which grows in value automatically as interest accrues.

### Layer 2: Insurance Premiums (8-22% APY depending on vault)
Additional yield from insurance premiums paid by AI agents. Every time an agent buys an insurance policy, they pay a premium. That premium goes directly to the vault that backs the policy. The more policies sold, the more premiums flow to LPs.

Total yield = Aave V3 yield + premium yield

### Combined Yield:

| Vault | Cooldown | Aave V3 Base | Premiums | TOTAL APY |
|-------|----------|-----------|----------|-----------|
| VolatileShort | 37 days | 3-5% | 9-11% | **12-16%** |
| VolatileLong | 97 days | 3-5% | 12-14% | **15-19%** |
| StableShort | 97 days | 3-5% | 8-10% | **11-15%** |
| StableLong | 372 days | 3-5% | 15-22% | **18-27%** |

Note: Premium APYs shown are AFTER the 3% protocol fee. The vault receives 97% of each premium. These APYs already reflect that.

### Why Different Vaults Pay Different Yields

The Kink Model (dynamic pricing) creates a self-balancing market:

**Scenario: VolatileShort vault has little liquidity**
```
Vault TVL: $200K, Allocated: $120K → Utilization: 60%
Kink multiplier at 60%: 1.38x
Premium for a $50K BSS policy (14d): $50K × 0.22 × 1.38 × (14/365) = $582

Now an agent buys another $50K policy:
New utilization: ($120K + $50K) / $200K = 85%
Kink multiplier at 85%: 2.25x
Next premium for same policy: $50K × 0.22 × 2.25 × (14/365) = $949

The premium increased 63% because utilization went up.
LPs in this vault are earning MORE per dollar deployed.
This higher yield attracts new LPs → they deposit → utilization drops → premiums normalize.
```

**Scenario: StableLong vault is mostly empty**
```
Vault TVL: $1M, Allocated: $100K → Utilization: 10%
Kink multiplier at 10%: 1.06x
Premiums are cheap → few LPs interested → some leave
Now TVL drops to $500K, same $100K allocated → Utilization: 20%
Multiplier: 1.13x → premiums slightly higher → yield goes up
Natural equilibrium: the market finds its balance.
```

### KEY INSIGHT FOR AGENTS:
**The APY you see is the APY RIGHT NOW based on CURRENT utilization. It is NOT a fixed rate.**

- If you deposit $100K and lower utilization from 60% to 40%, YOUR OWN DEPOSIT reduced the APY.
- If many agents buy policies after you deposit, utilization rises and your yield goes up.
- This is a dynamic market, not a savings account.

**Think of it like this:**
- Short vaults (30d) = checking account: low yield, quick access, high turnover
- Long vaults (365d) = certificate of deposit: high yield, locked for a year, stable income

### Claims Risk (What Can Go Wrong for LPs)

LPs earn premiums but also absorb claims. Here's the risk profile:

| Vault | Products | Claim Frequency | Max Loss per Event | Expected Monthly |
|-------|----------|----------------|-------------------|-----------------|
| VolatileShort | BSS + IL | BSS: rare but large. IL: frequent but small | 20% of vault (BSS) | Premiums >> claims |
| StableLong | Depeg + Exploit | Very rare (both) | 22% of vault (Depeg) | Very stable income |

**Worst case (once every 5-10 years):**
A black swan event triggers BSS AND Depeg simultaneously (e.g., market crash + bank failure like SVB). Combined loss: ~38% of vault TVL. Severe but not terminal. The protocol survives and rebuilds via ongoing premiums.

**Expected case (normal year):**
Premiums far exceed claims. The Kink Model ensures premiums are always priced above expected loss. LP is profitable in expectation.

---

# SECTION 4: ANTI-FRAUD MECHANISMS

Lumina uses multiple layers to prevent gaming:

| Mechanism | Purpose | Products |
|-----------|---------|----------|
| TWAP verification | Prevents flash crash exploitation | All |
| Waiting periods | Prevents buying when you see the event coming | BSS (1h), Depeg (24h), Exploit (14d) |
| Circuit breakers | Pauses or increases price during volatile moments | All |
| European-style resolution | Prevents scanning for optimal claim point | IL Index |
| $50K cap per wallet | Makes insider attacks unprofitable | Exploit |
| Dual trigger | Requires two independent signals | Exploit |
| L2 Sequencer check | Prevents stale-price attacks after network downtime | All (via Oracle) |
| 24h claim grace period | Allows claims near expiry even if network is congested | All |

**Circuit breaker rules:**

| Condition | BSS | Depeg | IL | Exploit |
|-----------|-----|-------|----|---------|
| Moderate volatility | Premium ×1.5 | Premium ×2.0 | Premium ×1.5 | Premium ×3.0 |
| Extreme volatility | HALT new policies | HALT new policies | HALT new policies | HALT new policies |

---

# SECTION 5: HOW TO OPERATE (FOR BUYING AGENTS)

## Step 1: Get a Quote

```
GET /api/v2/quote
{
  "productId": "BLACKSWAN-001",
  "coverageAmount": 50000000000,    // $50,000 in 6 decimals (USDC)
  "durationSeconds": 1209600,       // 14 days
  "asset": "ETH",                   // For BSS and IL
  "stablecoin": "",                 // For Depeg: "DAI", "USDT" (USDC excluded)
  "protocol": "",                   // For Exploit: protocol address
  "buyer": "0xYourAgentWallet"
}

Response:
{
  "premiumAmount": 527000000,       // $527 in 6 decimals
  "signedQuote": { ... },           // EIP-712 signed by oracle
  "signature": "0x...",
  "deadline": 1710200000,           // Quote valid for 5 minutes
  "nonce": 42
}
```

Premium varies based on vault utilization. This example assumes ~50% utilization.

**⚠️ DEADLINE:** The `deadline` timestamp is typically 5 minutes from quote generation. You MUST execute the `purchasePolicy` transaction on-chain BEFORE this deadline expires. If you request a quote and then perform other tasks, the quote will expire and the transaction will revert with `QuoteExpired`. **Best practice:** Request quote → approve → purchase in a single sequential flow, no interruptions.

## Step 2: Approve USDC

```solidity
IERC20(USDC_ADDRESS).approve(COVER_ROUTER, premiumAmount);
```

## Step 3: Purchase Policy

```solidity
CoverRouter.purchasePolicy(signedQuote, signature);
// Returns: PurchaseResult { policyId, vault, coverageAmount, premiumPaid, startsAt, expiresAt }
```

## Step 4: Monitor

```
GET /api/v2/policies?buyer=0xYourWallet
// Returns all active policies with status, coverage, expiry
```

## Step 5: Claim (if trigger met)

```solidity
// Backend detects trigger → computes TWAP → signs proof
// Agent receives proof and submits:
CoverRouter.triggerPayout(productId, policyId, oracleProof);
// USDC arrives in your wallet in the same transaction
```

**⚠️ PROTOCOL FEE ON CLAIMS:** Your payout will be 97% of the calculated amount. The 3% protocol fee is deducted automatically by the CoverRouter. This is NOT a bug — it is the protocol's revenue model.

Example:
```
Gross Payout = coverageAmount × (1 - deductibleBps/10000)
Protocol Fee = Gross Payout × 3%
Net Payout = Gross Payout - Protocol Fee

Example: $1000 BSS with 20% deductible:
  Gross Payout = $1000 × 0.80 = $800
  Protocol Fee = $800 × 0.03 = $24
  Net Payout (you receive) = $776

For larger amounts ($50,000 BSS coverage):
  Gross Payout = $50,000 × 0.80 = $40,000
  Protocol Fee = $40,000 × 0.03 = $1,200
  Net Payout (you receive) = $38,800

If you need exactly $40,000 net, buy coverage of $51,546 instead of $50,000.
```

PENDING PAYOUTS (if Aave has low liquidity):
If the vault cannot withdraw USDC from Aave at the time of your claim (rare, only during extreme Aave utilization), your payout is queued automatically. You will NOT lose your payout.

To claim a pending payout:
POST /api/v2/claim-pending
Headers: X-API-Key: YOUR_KEY
Body: {"policyId":"YOUR_POLICY_ID"}

Or on-chain: call claimPendingPayout() on the vault contract.

The payout will execute as soon as Aave has sufficient liquidity. Check periodically (every hour) until you receive it.

LARGE PAYOUT DELAY:
Payouts above the large payout threshold may be delayed by up to 6 hours as a security measure. This is automatic and the payout executes after the delay. The protocol owner can cancel suspicious payouts during this window.

## Step 6: Auto-Repurchase (recommended for continuous coverage)

AUTO-REPURCHASE STRATEGY:
To maintain continuous coverage without gaps:

┌─────────┬────────────────┬────────────────────────────────────────────────────┐
│ Product │ Waiting Period │ Repurchase Window                                  │
├─────────┼────────────────┼────────────────────────────────────────────────────┤
│ BSS     │ 3600s (1h)     │ Repurchase when expiresAt - now < 7200 (2 hours)   │
│ DEPEG   │ 86400s (24h)   │ Repurchase when expiresAt - now < 90000 (25 hours) │
│ IL      │ None           │ Repurchase when expiresAt - now < 3600 (1 hour)    │
│ EXPLOIT │ 1209600s (14d) │ Repurchase when expiresAt - now < 1296000 (15 days)│
└─────────┴────────────────┴────────────────────────────────────────────────────┘

Logic for your agent loop:
  currentTime = Math.floor(Date.now() / 1000)
  timeLeft = policy.expiresAt - currentTime
  if (timeLeft < repurchaseWindowSeconds) → GET /quote → POST /purchase

This ensures zero coverage gaps. The extra buffer (2h for BSS, 1h for IL, 25h for DEPEG, 15d for EXPLOIT) accounts for the waiting period of the new policy.

## Error Handling

On-chain transactions can revert. Here is how to handle each error:

| Revert Reason | Cause | What To Do |
|---------------|-------|------------|
| `QuoteExpired` | You took too long between getting the quote and submitting the TX | Request a new quote and execute immediately (< 5 min) |
| `SequencerDown` | Base L2 sequencer is offline | Wait 60 minutes, then retry |
| `SequencerGracePeriodNotOver` | Sequencer just restarted | Wait 60 minutes after restart, then retry |
| `StalePrice` | Chainlink feed hasn't updated recently | Wait 10 minutes, then retry (feed may be lagging) |
| `MaxAllocationExceeded` | Product hit its allocation cap in the vault | Reduce coverage amount or wait for policies to expire (frees capacity) |
| `NoVaultCapacity` | All vaults for this risk type are full (>95% utilization) | Wait 24 hours for utilization to drop, or reduce coverage amount |
| `CorrelationGroupCapExceeded` | Correlated products hit their combined cap | Same as above — wait or reduce |
| `NonceAlreadyUsed` | You resubmitted a quote that was already used | Request a fresh quote with a new nonce |
| `DurationOutOfRange` | Duration outside product limits | Check product's durationRange (e.g., BSS: 7-30 days) |
| `CoverageOutOfRange` | Coverage below $100 minimum | Increase coverage to at least $100 |
| `MaxCoveragePerWalletExceeded` | Exploit Shield: exceeded $50K per wallet | You already have $50K in Exploit coverage — cannot buy more from this wallet |
| `LifetimeCapExceeded` | Exploit Shield: exceeded $150K lifetime cap per wallet | Cumulative Exploit Shield payouts have reached $150K for this wallet |
| `TriggerNotMet` | Tried to claim but the trigger condition wasn't met | Verify the event actually occurred. Check oracle proof freshness. |
| `PolicyAlreadyResolved` | Policy was already paid out or cleaned up | No action needed — policy is settled |

**General retry strategy:**
```
MAX_RETRIES = 3
RETRY_DELAY = [60, 300, 3600]  // 1 min, 5 min, 1 hour

for attempt in range(MAX_RETRIES):
    try:
        execute_transaction()
        break
    except SequencerDown, SequencerGracePeriodNotOver:
        wait(3600)  // Always wait 1h for sequencer issues
    except QuoteExpired:
        get_new_quote()  // Get fresh quote, don't wait
    except StalePrice:
        wait(RETRY_DELAY[attempt])
    except MaxAllocationExceeded, NoVaultCapacity:
        notify_owner("Capacity full, waiting 24h")
        wait(86400)
```

## ABIs

To build transactions on-chain, use these ABIs:
- **USDC approval:** Standard ERC20 ABI (`approve(address,uint256)`)
- **CoverRouter:** Use the CoverRouter ABI from the Lumina GitHub repo (`src/core/CoverRouter.sol`)
- **Vaults:** Use the IVault ABI (`src/interfaces/IVault.sol`) for deposit/withdraw operations

ABIs are published at: `https://github.com/org-lumina/LUMINA-PROTOCOL/tree/main/src`

---

# SECTION 6: HOW TO OPERATE (FOR LP AGENTS)

## Understanding the Vaults (CRITICAL — read before depositing)

**All 4 vaults work identically.** Same smart contract, same mechanics. The ONLY differences are:

| What changes | VolatileShort | VolatileLong | StableShort | StableLong |
|-------------|---------------|--------------|-------------|------------|
| Cooldown (exit notice) | 37 days | 97 days | 97 days | 372 days |
| Products backed | BSS + IL short | IL long + BSS overflow | Depeg short | Depeg long + Exploit |
| Risk type | VOLATILE | VOLATILE | STABLE | STABLE |
| Claim frequency | Higher | Higher | Low | Very low |
| APY (Aave V3 + premiums) | 12-16% | 15-19% | 11-15% | 18-27% |

**What is a cooldown? It is NOT a lock period. It is an EXIT NOTICE.**

```
WRONG understanding:  "I deposit for 37 days, then I get my money back"
RIGHT understanding:  "I deposit INDEFINITELY. When I want to leave, I give 37 days notice."

Think of it like renting an apartment:
  - You sign the lease (deposit USDC)
  - You live there as long as you want (earn yield indefinitely)
  - One day you decide to move out (requestWithdrawal)
  - You give 37 days notice (cooldown period)
  - After 37 days, you leave and get your deposit back (completeWithdrawal + yield)
```

**Why does the cooldown exist?**
Because your money is BACKING insurance policies. If you could withdraw instantly and a crash happens 5 minutes later, the policies you were backing would have no collateral. The cooldown ensures your capital stays until existing policies expire or are settled.

**Why does longer cooldown = higher APY?**
- 37-day cooldown: you can exit relatively quickly, so you earn less
- 372-day cooldown: you're committed for a year when you decide to exit, so you earn the highest yield
- Longer commitment = backs longer (more expensive) policies = more premium income

**Your money keeps earning DURING the cooldown:**
When you request withdrawal, your capital still backs existing policies and earns premiums from them. The only change is that the PolicyManager stops assigning NEW policies to your capital.

## Step 1: Choose a Vault

Evaluate each vault based on:
- **Current APY** (Aave V3 base 3-5% + premium yield -- check real-time)
- **Current utilization** (higher util = higher yield BUT higher claim risk)
- **Cooldown** (how long is the exit notice when you want to leave)
- **Products backed** (what claim risks are you exposed to)

```
GET /api/v2/vaults
// Returns all 4 vaults with: TVL, utilization, APY, cooldown, products
```

**Decision guide:**
```
Want maximum yield and OK with 1-year exit notice?    → StableLong (18-26%)
Want moderate yield with 97-day exit notice?           → VolatileLong or StableShort (11-18%)
Want quick exit (37-day notice) and accept BSS risk?   → VolatileShort (12-15%)
Unsure? Start with VolatileShort (shortest commitment) → move to longer vaults later
```

## Step 2: Deposit USDC

```solidity
IERC20(USDC_ADDRESS).approve(VAULT_ADDRESS, depositAmount);
IVault(VAULT_ADDRESS).deposit(depositAmount, receiverAddress);
// Returns: shares (soulbound ERC-4626 — cannot be transferred or sold)
```

**After depositing:** Your capital is IN the vault generating yield. There is nothing else to do. No renewal, no management, no rebalancing. Just hold.

**Your shares are SOULBOUND.** You cannot transfer or sell them on a DEX. This prevents cooldown bypass via secondary markets.

## Step 3: Monitor Yield

```
GET /api/v2/vaults/{address}/position?holder=0xYourWallet
// Returns: shares, currentValue, depositedValue, yieldEarned, APY
```

The share price increases over time as premiums flow into the vault. Your yield = (currentValue - depositedValue). Check periodically but there is no action required.

**APY WILL FLUCTUATE.** The yield depends on:
- How many policies are sold (more policies = more premiums = higher APY)
- Current utilization (higher util = Kink Model charges more = higher APY)
- Claims (if a claim is paid, the vault shrinks temporarily = lower APY until premiums rebuild)

This is a DYNAMIC market, not a fixed-rate product.

## Step 4: Withdraw (when you decide to leave)

This is a 3-step process. You choose WHEN to start it — there is no automatic expiry.

```solidity
// Step 4a: REQUEST withdrawal (starts the cooldown timer)
IVault(VAULT_ADDRESS).requestWithdrawal(sharesToWithdraw);
// From this moment: cooldown clock starts (37/97/97/372 days depending on vault)
// Your capital still earns yield during cooldown

// Step 4b: WAIT for cooldown to complete
// Nothing to do. Just wait.
// VolatileShort: 37 days, VolatileLong: 97 days
// StableShort: 97 days, StableLong: 372 days

// Step 4c: COMPLETE withdrawal (after cooldown ends)
IVault(VAULT_ADDRESS).completeWithdrawal();
// Principal + ALL accumulated yield arrives in your wallet

// OPTIONAL: Cancel withdrawal (changed your mind?)
IVault(VAULT_ADDRESS).cancelWithdrawal();
// Cooldown resets, capital goes back to full availability
```

## Moving Between Vaults

If you want to switch from VolatileShort to StableLong (better APY):
```
1. requestWithdrawal() from VolatileShort → wait 37 days
2. completeWithdrawal() → USDC back in your wallet
3. deposit() into StableLong → done
```
There is no direct transfer between vaults. You must withdraw and re-deposit.

---

# SECTION 7: DECISION FRAMEWORK

## Should I buy insurance? (For buyer agents)

```
IF you hold ETH/BTC exposure > $10,000:
  → Consider BSS for crash protection

IF you hold stablecoins > $50,000 for > 14 days:
  → Consider Depeg Shield
  → Deductible varies by stablecoin: USDT = 15% (higher risk, opaque reserves), DAI = 12% (crypto-collateralized, cascade risk). This means for $10,000 USDT coverage, max payout is $8,500. For DAI, max payout is $8,800.

IF you provide liquidity in AMM pools:
  → Consider IL Index Cover (budget ≤ 50% of projected fees)

IF you have funds in Compound/Curve/other DeFi > $10,000:
  → Consider Exploit Shield (max $50K). Note: Aave V3 excluded.

IF the premium (including 3% protocol fee) exceeds 5% of your projected returns:
  → SKIP — the insurance costs more than the risk is worth
```

## Should I deposit as LP? (For LP agents)

```
IF you want maximum yield and can lock for 372 days:
  → StableLong (18-25% APY combined)

IF you want moderate yield with 97-day flexibility:
  → VolatileLong or StableShort (12-17% APY)

IF you want quick access (37 days) and tolerate BSS/IL claim risk:
  → VolatileShort (12-14% APY)

IF a vault's utilization is > 80%:
  → Caution: high yield but high claim probability

IF a vault's utilization is < 20%:
  → Yield will be low, but claims are also unlikely
  → Consider waiting for utilization to rise

ALWAYS CHECK: Current APY = Aave V3 base (variable, ~3-5%) + premium yield
The Aave V3 base yield is variable and depends on lending market conditions.
```

MARKET DATA SOURCES (for autonomous decision-making):

Your agent needs external data to make buy/sell decisions. Recommended free sources:

- ETH price: GET https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd
- ETH volatility: Fetch ETH price hourly, compute stddev over 24 points. If stddev > 5% of price → high volatility → consider BSS
- Stablecoin peg: GET https://api.coingecko.com/api/v3/simple/price?ids=tether,dai&vs_currencies=usd — if price < 0.98 → consider DEPEG
- Vault utilization: GET /api/v2/vaults → use utilizationPct. If > 80% → premiums expensive. If < 40% → premiums cheap
- DeFi exploits: Monitor https://rekt.news for hack reports
- USDC balance: Not available via API. If purchase fails with "Insufficient USDC balance", alert owner immediately

OWNER ALERT STRATEGY:
- ChatGPT/Claude: tell the user in the chat
- ElizaOS/custom: log to stderr or send webhook
- Via API: return error, owner monitors logs
There is no built-in notification endpoint in Lumina. Alerting is your responsibility.

---

# SECTION 8: KINK MODEL — PRICING ENGINE

The Kink Model determines insurance premiums dynamically based on vault utilization.

## Formula:
```
Premium = Coverage × P_base × [RiskMult] × [DurationDiscount] × M(U) × (Duration / 365 days)
```

## Utilization Multiplier M(U):
```
U = (allocated + requested) / total_vault_assets

If U ≤ 80%:  M(U) = 1 + (U / 0.80 × 0.5)     → gentle slope
If U > 80%:  M(U) = 1 + 0.5 + ((U - 0.80) / 0.20 × 3.0)  → aggressive slope
If U > 95%:  REJECTED — policy cannot be issued
```

## Multiplier Table:

| Utilization | M(U) | What it means |
|-------------|------|---------------|
| 0% | 1.00x | Cheapest possible premium |
| 20% | 1.13x | Slightly above minimum |
| 40% | 1.25x | Normal operating range |
| 60% | 1.38x | Getting busy |
| 80% | 1.50x | Kink point — premiums start rising fast |
| 85% | 2.25x | Stress zone |
| 90% | 3.00x | Very expensive |
| 95% | 3.75x | Maximum before rejection |
| >95% | REJECTED | No more policies sold |

## Why This Matters For You:

**As a buyer:** Buy when utilization is low (premiums are cheap). If utilization is >80%, consider waiting or reducing coverage.

**As an LP:** Deposit when utilization is high (your yield will be great). But be aware: high utilization means many active policies = higher claim risk.

**Note on protocol fee:**
The premium calculated by the Kink Model is the COMMERCIAL premium (what you pay). Of this amount:
- 97% goes to the vault (risk premium that backs your policy)
- 3% goes to the protocol (fee)

The Kink Model's utilization calculation uses the TOTAL premium you pay, not the net vault amount. This means the utilization-based pricing already accounts for the fee split.

---

# SECTION 8.1: DYNAMIC PRICING — HOW TO THINK ABOUT LUMINA

## CRITICAL: Prices and yields are NOT fixed

Every number in this SKILL — premiums, APYs, costs — changes in real time based on vault utilization (U). The Kink model means:

- When U is LOW (0-30%): premiums are cheap, LP yields are low
- When U is MEDIUM (30-60%): premiums are moderate, LP yields are decent
- When U is HIGH (60-80%): premiums increase, LP yields become very attractive
- When U is KINK ZONE (80-95%): premiums SURGE (2x-3.6x base), LP yields are exceptional
- When U > 95%: NO new policies accepted (vault full)

## Correct M(U) Multiplier Table (from PremiumMath.sol)

These are the EXACT values computed by the on-chain Kink model:

```
U%   │ M(U)   │ Zone        │ Premium vs baseline
─────┼────────┼─────────────┼────────────────────
 0%  │ 1.000  │ Minimum     │ 1.00x (cheapest)
 5%  │ 1.031  │ Low         │ 1.03x
10%  │ 1.063  │ Low         │ 1.06x
15%  │ 1.094  │ Low         │ 1.09x
20%  │ 1.125  │ Normal      │ 1.13x
25%  │ 1.156  │ Normal      │ 1.16x
30%  │ 1.188  │ Normal      │ 1.19x
35%  │ 1.219  │ Normal      │ 1.22x
40%  │ 1.250  │ Normal      │ 1.25x
45%  │ 1.281  │ Moderate    │ 1.28x
50%  │ 1.313  │ Moderate    │ 1.31x
55%  │ 1.344  │ Moderate    │ 1.34x
60%  │ 1.375  │ Busy        │ 1.38x
65%  │ 1.406  │ Busy        │ 1.41x
70%  │ 1.438  │ Busy        │ 1.44x
75%  │ 1.469  │ Busy        │ 1.47x
80%  │ 1.500  │ ★ KINK ★    │ 1.50x — inflection point
82%  │ 1.800  │ Post-kink   │ 1.80x — steep jump begins
84%  │ 2.100  │ Post-kink   │ 2.10x
86%  │ 2.400  │ Post-kink   │ 2.40x
88%  │ 2.700  │ Stress      │ 2.70x
90%  │ 3.000  │ Stress      │ 3.00x — triple baseline
92%  │ 3.300  │ Critical    │ 3.30x
94%  │ 3.600  │ Critical    │ 3.60x — near maximum
>95% │ REJECT │ Full        │ Policy rejected
```

Formula (from `src/libraries/PremiumMath.sol`):
```
U ≤ 80%:  M(U) = 1.0 + (U / 0.80) × 0.5
U > 80%:  M(U) = 1.0 + 0.5 + ((U − 0.80) / 0.20) × 3.0
U > 95%:  REVERTED — no policy issued
```

## AS A POLICY BUYER — Real-Time Premium Tables

Current on-chain parameters (verified against live API):
```
Product     │ pBase (annual) │ riskMult │ Used by vaults
────────────┼────────────────┼──────────┼──────────────────────
BSS         │ 6.50%  (650bp) │ 1.0x     │ VolatileShort, VolatileLong
IL Index    │ 8.50%  (850bp) │ 1.0x     │ VolatileShort, VolatileLong
Depeg       │ 2.50%  (250bp) │ 1.0x     │ StableShort, StableLong
Exploit     │ 4.00%  (400bp) │ 1.0x     │ StableShort, StableLong
```

### TABLE 1 — BSS Premium ($10,000 coverage, 14 days)

Formula: Premium = $10,000 × 0.065 × M(U) × (14/365)

```
U%   │ M(U)  │ Premium  │ % of coverage │ Verdict
─────┼───────┼──────────┼───────────────┼─────────────────────────
 0%  │ 1.000 │   $24.93 │ 0.25%         │ ✦ VERY CHEAP — buy aggressively
10%  │ 1.063 │   $26.49 │ 0.26%         │ ✦ VERY CHEAP
20%  │ 1.125 │   $28.05 │ 0.28%         │ ✦ CHEAP
30%  │ 1.188 │   $29.60 │ 0.30%         │ ● FAIR — good value
40%  │ 1.250 │   $31.16 │ 0.31%         │ ● FAIR
50%  │ 1.313 │   $32.72 │ 0.33%         │ ● FAIR
60%  │ 1.375 │   $34.28 │ 0.34%         │ ▲ MODERATE
70%  │ 1.438 │   $35.84 │ 0.36%         │ ▲ MODERATE
80%  │ 1.500 │   $37.39 │ 0.37%         │ ▲ KINK — still reasonable
82%  │ 1.800 │   $44.87 │ 0.45%         │ ▼ EXPENSIVE — buy only if needed
84%  │ 2.100 │   $52.35 │ 0.52%         │ ▼ EXPENSIVE
86%  │ 2.400 │   $59.83 │ 0.60%         │ ▼ VERY EXPENSIVE
88%  │ 2.700 │   $67.31 │ 0.67%         │ ▼ VERY EXPENSIVE
90%  │ 3.000 │   $74.78 │ 0.75%         │ ✗ PROHIBITIVE — market pricing in danger
92%  │ 3.300 │   $82.26 │ 0.82%         │ ✗ PROHIBITIVE
94%  │ 3.600 │   $89.74 │ 0.90%         │ ✗ PROHIBITIVE
```

Scaling: For $50K coverage multiply by 5, for $100K by 10.
Duration scaling: For 7 days divide by 2, for 30 days multiply by 2.14.

### TABLE 2 — Depeg Shield Premium ($10,000 coverage, 14 days, USDT)

Formula: Premium = $10,000 × 0.025 × M(U) × (14/365)

```
U%   │ M(U)  │ Premium │ % of coverage │ Verdict
─────┼───────┼─────────┼───────────────┼────────────────────
 0%  │ 1.000 │   $9.59 │ 0.10%         │ ✦ EXTREMELY CHEAP
20%  │ 1.125 │  $10.79 │ 0.11%         │ ✦ VERY CHEAP
40%  │ 1.250 │  $11.99 │ 0.12%         │ ✦ CHEAP
60%  │ 1.375 │  $13.19 │ 0.13%         │ ● FAIR
80%  │ 1.500 │  $14.38 │ 0.14%         │ ● FAIR — still very affordable
86%  │ 2.400 │  $23.01 │ 0.23%         │ ▲ MODERATE
90%  │ 3.000 │  $28.77 │ 0.29%         │ ▼ EXPENSIVE
94%  │ 3.600 │  $34.52 │ 0.35%         │ ▼ EXPENSIVE
```

Depeg Shield is the cheapest product. Even at U=94%, the premium is only 0.35% for 14 days.
For 90-day coverage: multiply by 6.43. For 365-day coverage: multiply by 26.07.

### TABLE 3 — IL Index Premium ($10,000 coverage, 30 days)

Formula: Premium = $10,000 × 0.085 × M(U) × (30/365)

```
U%   │ M(U)  │ Premium  │ % of coverage │ Verdict
─────┼───────┼──────────┼───────────────┼────────────────────
 0%  │ 1.000 │   $69.86 │ 0.70%         │ ● FAIR
20%  │ 1.125 │   $78.60 │ 0.79%         │ ● FAIR
40%  │ 1.250 │   $87.33 │ 0.87%         │ ▲ MODERATE
60%  │ 1.375 │   $96.06 │ 0.96%         │ ▲ MODERATE
80%  │ 1.500 │  $104.79 │ 1.05%         │ ▼ GETTING EXPENSIVE
86%  │ 2.400 │  $167.67 │ 1.68%         │ ▼ EXPENSIVE
90%  │ 3.000 │  $209.59 │ 2.10%         │ ✗ PROHIBITIVE
94%  │ 3.600 │  $251.51 │ 2.52%         │ ✗ PROHIBITIVE
```

IL Index is the most expensive product per day. Budget ≤50% of projected pool fees.

### TABLE 4 — Exploit Shield Premium ($10,000 coverage, 90 days)

Formula: Premium = $10,000 × 0.040 × M(U) × (90/365)

```
U%   │ M(U)  │ Premium  │ % of coverage │ Verdict
─────┼───────┼──────────┼───────────────┼────────────────────
 0%  │ 1.000 │   $98.63 │ 0.99%         │ ● FAIR
20%  │ 1.125 │  $110.96 │ 1.11%         │ ● FAIR
40%  │ 1.250 │  $123.29 │ 1.23%         │ ● FAIR
60%  │ 1.375 │  $135.62 │ 1.36%         │ ▲ MODERATE
80%  │ 1.500 │  $147.95 │ 1.48%         │ ▲ MODERATE
86%  │ 2.400 │  $236.71 │ 2.37%         │ ▼ EXPENSIVE
90%  │ 3.000 │  $295.89 │ 2.96%         │ ▼ EXPENSIVE
94%  │ 3.600 │  $355.07 │ 3.55%         │ ✗ PROHIBITIVE
```

For 365-day coverage: multiply by 4.06.

### BUYER DECISION MATRIX

```
STEP 1: GET /api/v2/vaults → check utilizationBps for the relevant vault

STEP 2: Use this matrix:

  U < 30%    → CHEAP ZONE
               All products are near minimum price.
               BUY AGGRESSIVELY if you need protection.
               This is the best time — few agents are buying, market feels safe.
               
  U = 30-60% → FAIR ZONE
               Prices are 1.2-1.4x baseline. Normal operating range.
               BUY if you need protection — prices are reasonable.
               
  U = 60-80% → BUSY ZONE
               Prices are 1.4-1.5x baseline. The market is active.
               BUY if you have high conviction you need the coverage.
               Consider shorter duration to reduce cost.
               
  U = 80-90% → KINK ZONE
               Prices are 1.5-3.0x baseline. SURGE pricing.
               BUY ONLY if you believe a crash is imminent.
               The market is already pricing in elevated risk.
               
  U = 90-95% → STRESS ZONE
               Prices are 3.0-3.6x baseline. Emergency pricing.
               Most agents should WAIT for utilization to drop.
               Only buy for critical, irreplaceable coverage.
               
  U > 95%    → FULL
               No new policies. Wait for existing policies to expire.
```

KEY INSIGHT: When premiums are cheap (low U), few agents are buying protection. This is often BEFORE a crash, when protection is most valuable. When premiums are expensive (high U), many agents are already protected — the market is pricing in danger.

STRATEGY: The smartest time to buy BSS is when U is LOW and the market feels safe. That's when protection is cheapest and most likely to pay off.

## AS A VAULT DEPOSITOR (LP) — Real-Time Yield Tables

LP yield = Aave V3 base yield + Premium yield from insurance policies

Premium yield = U × blended_pBase × M(U) × 0.97 (after 3% protocol fee)

### TABLE 5 — VolatileShort LP Yield (BSS + IL blend, pBase_avg ≈ 7.3%)

Assuming Aave V3 base yield = 3.5% (variable — check current rate)

```
U%   │ M(U)  │ Premium yield │ + Aave 3.5% │ TOTAL APY │ Beats?
─────┼───────┼───────────────┼─────────────┼───────────┼──────────────────
 0%  │ 1.000 │     0.00%     │    3.50%    │   3.50%   │ Aave only
10%  │ 1.063 │     0.75%     │    3.50%    │   4.25%   │ > Aave
20%  │ 1.125 │     1.59%     │    3.50%    │   5.09%   │ > most staking
30%  │ 1.188 │     2.52%     │    3.50%    │   6.02%   │
40%  │ 1.250 │     3.54%     │    3.50%    │   7.04%   │
50%  │ 1.313 │     4.65%     │    3.50%    │   8.15%   │ ≈ Pendle (8%)
60%  │ 1.375 │     5.84%     │    3.50%    │   9.34%   │ > Pendle
70%  │ 1.438 │     7.12%     │    3.50%    │  10.62%   │
80%  │ 1.500 │     8.50%     │    3.50%    │  12.00%   │
85%  │ 2.250 │    13.54%     │    3.50%    │  17.04%   │ > Ethena (15%)
90%  │ 3.000 │    19.11%     │    3.50%    │  22.61%   │ > most DeFi
94%  │ 3.600 │    23.96%     │    3.50%    │  27.46%   │ exceptional
```

### TABLE 6 — VolatileLong LP Yield (BSS overflow + IL, pBase_avg ≈ 8.0%)

```
U%   │ Premium yield │ + Aave 3.5% │ TOTAL APY
─────┼───────────────┼─────────────┼───────────
10%  │     0.78%     │    3.50%    │   4.28%
20%  │     1.74%     │    3.50%    │   5.24%
30%  │     2.77%     │    3.50%    │   6.27%
40%  │     3.88%     │    3.50%    │   7.38%
50%  │     5.09%     │    3.50%    │   8.59%
60%  │     6.40%     │    3.50%    │   9.90%
70%  │     7.81%     │    3.50%    │  11.31%
80%  │     9.31%     │    3.50%    │  12.81%
85%  │    14.85%     │    3.50%    │  18.35%
90%  │    20.95%     │    3.50%    │  24.45%
94%  │    26.26%     │    3.50%    │  29.76%
```

### TABLE 7 — StableShort LP Yield (Depeg only, pBase = 2.5%)

```
U%   │ Premium yield │ + Aave 3.5% │ TOTAL APY
─────┼───────────────┼─────────────┼───────────
10%  │     0.26%     │    3.50%    │   3.76%
20%  │     0.55%     │    3.50%    │   4.05%
30%  │     0.87%     │    3.50%    │   4.37%
40%  │     1.21%     │    3.50%    │   4.71%
50%  │     1.59%     │    3.50%    │   5.09%
60%  │     2.00%     │    3.50%    │   5.50%
70%  │     2.44%     │    3.50%    │   5.94%
80%  │     2.91%     │    3.50%    │   6.41%
85%  │     4.64%     │    3.50%    │   8.14%
90%  │     6.55%     │    3.50%    │  10.05%
94%  │     8.21%     │    3.50%    │  11.71%
```

### TABLE 8 — StableLong LP Yield (Depeg + Exploit blend, pBase_avg ≈ 3.0%)

```
U%   │ Premium yield │ + Aave 3.5% │ TOTAL APY
─────┼───────────────┼─────────────┼───────────
10%  │     0.31%     │    3.50%    │   3.81%
20%  │     0.66%     │    3.50%    │   4.16%
30%  │     1.04%     │    3.50%    │   4.54%
40%  │     1.46%     │    3.50%    │   4.96%
50%  │     1.91%     │    3.50%    │   5.41%
60%  │     2.40%     │    3.50%    │   5.90%
70%  │     2.93%     │    3.50%    │   6.43%
80%  │     3.49%     │    3.50%    │   6.99%
85%  │     5.57%     │    3.50%    │   9.07%
90%  │     7.86%     │    3.50%    │  11.36%
94%  │     9.85%     │    3.50%    │  13.35%
```

Note: Aave yield is ESTIMATED at 3.5%. Check current Aave V3 USDC rate on Base for real-time base yield.

### TABLE 9 — Competitive Breakpoints (at what U% does each vault beat alternatives?)

```
                       │ VolShort │ VolLong │ StbShort │ StbLong
                       │ (7.3%pb) │ (8.0%pb)│ (2.5%pb) │ (3.0%pb)
───────────────────────┼──────────┼─────────┼──────────┼─────────
Beats Aave only (3.5%) │   U>0%   │  U>0%   │   U>0%   │  U>0%
Beats 5% staking       │   U≈13%  │  U≈12%  │  U≈40%   │  U≈35%
Beats Pendle (8%)      │   U≈49%  │  U≈45%  │  U≈85%   │  U≈80%
Beats Ethena (15%)     │   U≈84%  │  U≈82%  │  never   │  U≈92%
Beats 20%              │   U≈88%  │  U≈86%  │  never   │  never
Beats 25%              │   U≈92%  │  U≈90%  │  never   │  never
```

KEY TAKEAWAY: Volatile vaults beat Ethena/Pendle in the Kink zone (U>82-85%). Stable vaults need extreme utilization to compete with high-yield protocols but offer much lower claim risk.

### LP DECISION MATRIX

```
STEP 1: GET /api/v2/vaults → check utilizationBps and estimatedAPY

STEP 2: Use this matrix:

  U < 15%    → LOW YIELD ZONE
               Yield barely above Aave. Vault has excess capital.
               WAIT for utilization to rise, or choose a different vault.
               Exception: deposit if you expect demand surge (bear market coming).
               
  U = 15-40% → GROWING ZONE
               Yield 5-7% (Volatile) or 4-5% (Stable).
               DEPOSIT if you believe demand will grow.
               Your deposit will temporarily lower U and your own APY.
               
  U = 40-70% → SWEET SPOT
               Yield 7-11% (Volatile) or 5-6% (Stable).
               DEPOSIT — this is the optimal entry point.
               Good yield without excessive claim risk.
               
  U = 70-85% → HIGH YIELD ZONE
               Yield 11-17% (Volatile) or 6-8% (Stable).
               DEPOSIT for high yield, but be aware of elevated claim risk.
               Kink zone premiums attract rapid LP deposits → U may drop.
               
  U > 85%    → EXCEPTIONAL BUT RISKY
               Yield 17-28% (Volatile) or 8-13% (Stable).
               HIGH claim risk — the market expects trouble.
               DEPOSIT only with capital you can afford to lose 18-26% of.
```

## THE KINK CYCLE — How the market self-balances

The Kink model creates a natural 4-phase cycle:

### PHASE 1 — LOW UTILIZATION (U < 30%)
```
Premiums: Cheap (1.0-1.2x baseline)
LP yield: Low (3.5-6%)
What happens:
  → Agents buy lots of cheap insurance
  → U increases → premiums increase → yields increase
  → Some LPs withdraw (yield too low) → U increases faster
Duration: Weeks to months (bull market can extend this phase)
```

### PHASE 2 — GROWING DEMAND (U = 30-60%)
```
Premiums: Moderate (1.2-1.4x baseline)
LP yield: Decent (6-9% Volatile, 4-6% Stable)
What happens:
  → More LPs attracted by rising yields → deposit
  → More capital → U decreases slightly → equilibrium
  → Steady state: new deposits ≈ new policies
Duration: This is the normal equilibrium zone
```

### PHASE 3 — HIGH DEMAND (U = 60-80%)
```
Premiums: Getting expensive (1.4-1.5x baseline)
LP yield: Strong (9-12% Volatile, 6-6.5% Stable)
What happens:
  → Some agents stop buying (too expensive)
  → New LPs rush in for the high yield
  → U stabilizes near kink point
  → Maximum capital efficiency
Duration: Days to weeks (market stress can push into Phase 4)
```

### PHASE 4 — KINK ZONE (U = 80-95%)
```
Premiums: SURGE (1.5-3.6x baseline)
LP yield: Exceptional (12-28% Volatile, 6.5-13% Stable)
What happens:
  → Only agents with high conviction buy
  → LPs earn massive yields
  → Eventually U drops as policies expire
  → Cycle restarts at Phase 1
Duration: Rare and brief — strong LP response compresses this phase
```

THIS IS NOT A BUG — IT IS THE CORE FEATURE. The protocol naturally oscillates between these phases. Smart agents and LPs position themselves accordingly.

## BEAR MARKET DYNAMICS

In a bear market (ETH declining):
```
→ Every agent wants BSS protection (crash insurance)
→ Demand explodes → U skyrockets toward 80-95%
→ Premiums become very expensive (2-3.6x baseline)
→ LP yields become EXCEPTIONAL (15-28% for Volatile vaults)
→ Lumina is one of the ONLY protocols paying high yield in a bear market
→ More LPs deposit, attracted by the yield
→ More capacity for agents to buy protection
→ The protocol THRIVES when everything else suffers
```

This is counter-cyclical by design. When traditional DeFi yields collapse to 0-2% in bear markets, Lumina vault yields surge because demand for protection explodes.

## BULL MARKET DYNAMICS

In a bull market (ETH rising):
```
→ Few agents need BSS protection
→ U drops toward 10-20%
→ Premiums are cheap
→ LP yields are low (4-5%, mostly Aave)
→ Smart agents buy cheap protection for the inevitable correction
→ LPs with low yield tolerance withdraw
→ The protocol scales down naturally — this is healthy
```

## HOW TO CHECK CURRENT STATE

Before any operation, ALWAYS check:

```
1. GET /api/v2/vaults
   → Look at utilizationBps for each vault
   → Calculate U% = utilizationBps / 100
   → This tells you what phase the market is in

2. GET /api/v2/quote with your desired parameters
   → The returned premiumAmount reflects current utilization
   → Compare with Tables 1-4 above to know if it's cheap or expensive
   → If utilizationAtQuote is returned, use it to verify your M(U) calculation

3. Look at estimatedAPY in the vault response
   → This is the CURRENT yield including Aave + premiums
   → Compare with Tables 5-8 to confirm and with Table 9 for context
```

NEVER make decisions based on fixed numbers alone. ALWAYS query the API for current state first. The tables in this section tell you HOW TO INTERPRET the current state.

## OPPORTUNITY DETECTION

As an autonomous agent, monitor for these opportunities:

### BUYING OPPORTUNITIES (for policy buyers):
```
Signal: Vault utilization drops below 20%
Action: Buy protection — it's at its cheapest
Why: Low U = M(U) ≈ 1.13 = premiums near minimum
Example: BSS $10K/14d costs only $28 at U=20% vs $75 at U=90%

Signal: ETH volatility rising BUT utilization still low
Action: Buy BSS immediately — cheap protection before the crowd arrives
Why: Demand will push U up → your renewal will be more expensive
```

### LP DEPOSIT OPPORTUNITIES (for vault depositors):
```
Signal: Vault utilization rises above 70%
Action: Deposit USDC — yields are surging
Why: High U = high premiums flowing to LPs
Example: VolatileShort pays 10.6% at U=70% vs 5.1% at U=20%

Signal: Bear market begins, utilization climbing rapidly
Action: Deposit into Volatile vaults — yields will keep rising
Why: Counter-cyclical: fear drives demand for protection → LP yield surges
```

### EXIT SIGNALS (for LPs):
```
Signal: Utilization drops below 15% for more than 2 weeks
Action: Consider requesting withdrawal
Why: Yield barely above Aave (4.2%), capital better used elsewhere

Signal: Bull market euphoria, no agents buying protection
Action: Request withdrawal — yield won't improve until sentiment shifts
Why: Low demand = low utilization = low premium yield
```

### RENEWAL OPTIMIZATION (for policy buyers):
```
Signal: Your policy expires soon AND utilization dropped since purchase
Action: Renew immediately — you'll get a cheaper premium
Why: Lower U = lower M(U) = cheaper renewal

Signal: Your policy expires soon AND utilization rose significantly
Action: Renew for SHORTER duration to reduce cost, then reassess
Why: Higher U = higher premium per day — minimize exposure to peak pricing
```

## VERIFICATION

You can verify any table value using the on-chain formula:

```
Premium = Coverage × (pBase / 10000) × (riskMult / 10000) × M(U) × (duration_seconds / 31536000)

Then apply ceiling division: premium = (raw_premium + 9999) / 10000

LP yield (annualized) = U × (pBase / 10000) × M(U) × 0.97 + Aave_rate
```

Cross-check with `GET /api/v2/quote` — the API premium should match within rounding.

---

# SECTION 9: CONTRACT ADDRESSES

## Base L2 (Chain 8453)

NOTE: These addresses correspond to the current deployment. They will be updated when new contracts are deployed. Always verify addresses at https://www.lumina-org.com or via the API.

Deployed on Base Mainnet (chain 8453). Verified on BaseScan.

Settlement token: USDC (Circle) on Base.

| Contract | Address | Notes |
|----------|---------|-------|
| USDC Token | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Circle USDC on Base (6 decimals) |
| CoverRouter | `0x8407afBa100812bFb5f9f188b44379E4268eff94` | Main entry point for all operations |
| PolicyManager | `0x615e9c32c70350192fCa9BAC06Ba8ebA9dC4fEF4` | Vault selection + allocation |
| LuminaOracle | `0x2f9d3DA66FCB84f47851636d9e0921373ede2176` | Chainlink price feeds + signature verification |
| LuminaPhalaVerifier | `0xa2d461f4A7eC7089A7e414986d9d9b43514a82EC` | Phala TEE attestation (Exploit Shield only) |
| VolatileShortVault | `0x2D7D735f71638730cbe9A143227A00Fa64E94E88` | 37-day cooldown |
| VolatileLongVault | `0xDf30548d46e77015A4dDA82D3c263e81a60B075c` | 97-day cooldown |
| StableShortVault | `0x8F6e6a4Ee6aeD70757c16382eA7156AD4b33c078` | 97-day cooldown |
| StableLongVault | `0x3e8dF8746c42Aa4B0CDb089174aBbBaf2C3aD46c` | 372-day cooldown |
| BlackSwanShield | `0xC01ED8eF52506B29545f08BBf9aAe5Fe59b15CF7` | BSS product |
| DepegShield | `0xCdA417909d43F252f63034346db9121441BfE70F` | Depeg product |
| ILIndexCover | `0x73fB5CB9Aa0BeBAf74a3a4b6Cfb09d3Fd66C9FB6` | IL product |
| ExploitShield | `0x05170F9Ca56026001064F5242c6F9F7f181c6baA` | Exploit product |

**Chainlink Price Feeds (Base L2):**

| Asset | Feed Address |
|-------|-------------|
| ETH/USD | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| BTC/USD | `0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F` |
| USDC/USD | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` |
| USDT/USD | `0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9` |
| DAI/USD | `0x591e79239a7d679378eC8c847e5038150364C78F` |

---

# SECTION 10: FAQ

**Q: Can a human buy a policy from the website?**
A: No. The website is informational only. All operations (buying, depositing, claiming) are done by AI agents via API or on-chain calls.

**Q: What happens if I don't claim within the grace period?**
A: The policy expires and funds are returned to the vault. For BSS/Depeg/Exploit, you have until cleanupAt (expiresAt + 24h). For IL Index, you have a 48h settlement window after expiry.

**Q: Can I cancel a policy mid-term?**
A: No. Policies are non-cancellable. The premium is paid upfront and non-refundable.

**Q: What if the L2 sequencer goes down during a crash?**
A: The oracle blocks stale prices until 1 hour after sequencer recovery. You have 24h grace period to submit your claim after policy expiry. Even with sequencer downtime, you're protected.

**Q: Is the base yield guaranteed?**
A: The Aave V3 lending yield (variable, ~3-5% APY) is not guaranteed by Lumina — it depends on Aave V3 lending market conditions on Base. The premium yield on top depends on Lumina policy volume.

**Q: What's the maximum I can lose as an LP?**
A: In the absolute worst case (simultaneous BSS crash + stablecoin depeg), a vault could lose ~38% of TVL. This is extremely rare (~2-3% annual probability). In normal years, premiums far exceed claims.

**Q: Why are shares soulbound?**
A: To prevent cooldown bypass. If you could sell your shares on a DEX, someone could buy "mature" shares that are about to finish cooldown, defeating the purpose of locking capital.

**Q: Why does Lumina charge 3% on claims? Isn't that unfair?**
A: Lumina charges 3% on BOTH premiums and payouts. This is the protocol's revenue model (adapted from MutualLumina V1). On claims, the 3% is negligible compared to your return: you pay $527 in premium and receive $38,800 — that's a 73x return even after the fee. If you need exact payout amounts, increase your coverage by 3.1% to compensate.

**Q: Does the fee affect LP yields?**
A: Minimally. LPs receive 97% of premiums instead of 100%. The difference is ~0.3% APY. A vault showing 14% total APY without fee would show 13.7% with fee. The fee on claims does NOT affect LPs -- it comes from the agent's payout, not the vault.

**Q: How do I contact Lumina for help?**
A: Email hello@lumina-org.com. A human will respond, explain the products, and provide the SKILL document for your agent.

════════════════════════════════════════════════════════════
13. API RESPONSE SCHEMAS
════════════════════════════════════════════════════════════

Every endpoint's exact response format. Parse these to make decisions.

GET /api/v2/health
{"status":"ok","chain":"base","chainId":8453}

GET /api/v2/products
[{"id":"BSS","name":"Black Swan Shield","pBaseBps":650,"deductibleBps":2000,"minDurationSeconds":604800,"maxDurationSeconds":2592000,"waitingPeriodSeconds":3600,"riskType":"VOLATILE","excludedAssets":[]},{"id":"DEPEG","name":"Depeg Shield","pBaseBps":250,"deductibleBps":{"USDT":1500,"DAI":1200},"minDurationSeconds":1209600,"maxDurationSeconds":31536000,"waitingPeriodSeconds":86400,"riskType":"STABLE","excludedAssets":["USDC"]},{"id":"IL","name":"IL Index Cover","pBaseBps":850,"deductibleBps":200,"minDurationSeconds":1209600,"maxDurationSeconds":7776000,"waitingPeriodSeconds":0,"riskType":"VOLATILE"},{"id":"EXPLOIT","name":"Exploit Shield","pBaseBps":400,"deductibleBps":1000,"minDurationSeconds":7776000,"maxDurationSeconds":31536000,"waitingPeriodSeconds":1209600,"riskType":"STABLE","excludedProtocols":["Aave V3"]}]

GET /api/v2/vaults
[{"id":"volatile_short","name":"Volatile Short","totalValueLockedUSD":24208.19,"currentUtilizationPct":20.61,"estimatedAPY":5.7,"cooldownDays":37,"products":["BSS","IL"],"riskProfile":"higher"}]

Key fields for decision-making:
- currentUtilizationPct: if > 80 → post-kink, premiums expensive
- estimatedAPY: total yield for LPs (Aave + premiums)
- allocatedAssets: how much is locked for active policies

GET /api/v2/quote?productId=BSS&coverageAmount=1000000000&durationSeconds=604800
{"premium":1635000,"premiumUSD":1.64,"product":"BSS","coverage":1000000000,"utilizationPct":20.6}

POST /api/v2/purchase (requires X-API-Key header)
Success: {"success":true,"policyId":"1","premium":1635000,"txHash":"0x..."}
Error: {"error":"Insufficient USDC balance","required":"1635000","balance":"0"}

GET /api/v2/policies?buyer=0x...
[{"policyId":1,"product":"BSS","coverageAmount":1000000000,"coverageUSD":1000.00,"premiumPaid":1635000,"premiumUSD":1.64,"maxPayout":800000000,"maxPayoutUSD":800.00,"deductibleBps":2000,"status":"active","startedAt":1774027483,"expiresAt":1775237483,"waitingEndsAt":1774027483,"triggerMet":false,"claimable":false,"vault":"volatile_short"}]

Key fields for your agent loop:
- status: "active" | "expired" | "claimed" | "claimable"
- triggerMet: true = the insured event happened (e.g. ETH dropped 30%)
- claimable: true = you MUST call POST /claim immediately (highest priority)
- expiresAt: Unix timestamp — use with getRepurchaseWindow() for auto-renewal
- waitingEndsAt: coverage only active AFTER this timestamp (relevant for DEPEG and EXPLOIT)

POST /api/v2/claim (requires X-API-Key header)
Success: {"success":true,"payout":776000000,"txHash":"0x..."}
Error: {"error":"Policy not claimable"}

════════════════════════════════════════════════════════════
14. AUTONOMOUS AGENT BLUEPRINT
════════════════════════════════════════════════════════════

Complete pseudocode for a fully autonomous Lumina agent:

INITIALIZATION:
  API_KEY = "lum_your_key"
  BASE_URL = "https://lumina-protocol-production.up.railway.app"
  WALLET = "0xYOUR_WALLET"
  HEADERS = {"Content-Type": "application/json", "X-API-Key": API_KEY}

MAIN LOOP (runs every 3600 seconds / 1 hour):

  1. HEALTH CHECK
     response = GET {BASE_URL}/api/v2/health
     if response.status != "ok" → log error, sleep 300, retry

  2. CHECK CLAIMABLE POLICIES (highest priority)
     policies = GET {BASE_URL}/api/v2/policies?buyer={WALLET}
     for each policy where claimable == true:
       result = POST {BASE_URL}/api/v2/claim with {"policyId": policy.policyId}
       log "CLAIMED: policy {policyId}, net payout {netPayoutUSD}"

  3. CHECK EXPIRING POLICIES (auto-repurchase)
     currentTime = now()
     for each policy where status == "active":
       timeLeft = policy.expiresAt - currentTime
       window = getRepurchaseWindow(policy.product)
       if timeLeft < window:
         quote = GET {BASE_URL}/api/v2/quote (same product/coverage/duration)
         if quote.premiumUSD is acceptable (kinkMultiplier < 2.0):
           POST {BASE_URL}/api/v2/purchase
           log "RENEWED: {product} for ${premiumUSD}"

  4. ASSESS MARKET CONDITIONS (decide new purchases)
     ethPrice = GET https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd
     stablePrices = GET https://api.coingecko.com/api/v3/simple/price?ids=tether,dai&vs_currencies=usd
     vaults = GET {BASE_URL}/api/v2/vaults

     Decision rules:
     - ETH stddev(24h) > 5% of price → consider buying BSS
     - USDT or DAI price < 0.98 → consider buying DEPEG
     - Providing liquidity in volatile AMM → consider buying IL
     - Funds in unaudited protocol → consider buying EXPLOIT

     For each consideration:
       quote = GET /api/v2/quote
       if quote.kinkMultiplier < 2.0 → POST /api/v2/purchase

  5. LOG VAULT STATUS (optional: inform owner)
     for each vault in vaults:
       log "{vault.name}: APY {estimatedAPY}%, util {currentUtilizationPct}%"

  6. SLEEP 3600 seconds → go to step 1

ERROR HANDLING:
  "Insufficient USDC balance" → alert owner, skip, continue loop
  "Rate limit exceeded" → sleep 60, retry once
  "Invalid API Key" → alert owner, STOP loop entirely
  "Policy expired" → log warning, do not retry
  Network error → sleep 10, retry up to 3 times
  Any other error → log, continue loop (never crash)

getRepurchaseWindow(product):
  BSS     → 3600     (1 hour before expiry)
  DEPEG   → 90000    (25 hours before expiry)
  IL      → 3600     (1 hour before expiry)
  EXPLOIT → 1296000  (15 days before expiry)
