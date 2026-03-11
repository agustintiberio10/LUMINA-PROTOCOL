# SKILL: Lumina Protocol — Insurance & Yield for AI Agents

## Version: 2.0 (March 2026)
## Chain: Base L2 (8453) | Settlement: USDY (Ondo Finance)
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
Depeg USDC: $40,000 / (0.90 × 0.97) = $45,830 coverage
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
| Waiting Period | None — coverage starts immediately |
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

**What it covers:** Stablecoin losing its peg — falling below $0.95. Covers USDC, DAI, and USDT.

**When you need it:** You hold large stablecoin positions and want protection against a SVB-type event (USDC went to $0.87 in March 2023) or a Tether FUD event. The longer your hold period, the more sense it makes.

| Parameter | Value |
|-----------|-------|
| Product ID | `DEPEG-STABLE-001` |
| Trigger | Stablecoin TWAP 30 min < $0.95 |
| Payout | Depends on stablecoin (see below) |
| Duration | 14 to 365 days |
| Waiting Period | 24 hours (protection starts after 24h) |
| Base Rate | 24% annualized |
| Protocol Fee (USDC) | 3% on premium + 3% on payout. Net payout USDC = 87.3% of coverage |
| Protocol Fee (DAI) | 3% on premium + 3% on payout. Net payout DAI = 85.36% of coverage |
| Protocol Fee (USDT) | 3% on premium + 3% on payout. Net payout USDT = 82.45% of coverage |

**Why 24h waiting?** Stablecoin depegs develop slowly: rumors → news → panic → depeg. The 24h window prevents agents from buying insurance after seeing the first signs of trouble. This is what makes the product actuarially viable — without it, premiums would be 3x higher.

**Payout by stablecoin:**

| Stablecoin | Deductible | Max Payout | Risk Multiplier | Why different? |
|------------|-----------|------------|-----------------|----------------|
| USDC | 10% | 90% | 1.0x | Reserves audited by Deloitte. Lowest risk. |
| DAI | 12% | 88% | 1.2x | Crypto-collateralized via MakerDAO. Cascade liquidation risk. |
| USDT | 15% | 85% | 1.4x | Historically opaque reserves. Highest perceived risk. |

**Duration discount (longer = cheaper per day):**

| Duration | Discount | Effect |
|----------|----------|--------|
| 14-90 days | 1.0x | Standard price |
| 91-180 days | 0.90x | 10% cheaper per day |
| 181-365 days | 0.80x | 20% cheaper per day |

**Example:**
```
You buy: $100,000 USDC coverage for 90 days
Premium: $100,000 × 0.24 × 1.0 × 1.0 × 1.25 (util) × (90/365) = $3,699

If USDC depegs to $0.93 (TWAP 30 min confirms):
→ You receive $90,000 (90% of $100K)
→ Return: $90,000 / $3,699 = 24x
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
| Waiting Period | None (trigger is relative to purchase price) |
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

**What it covers:** Catastrophic hack or exploit of a specific DeFi protocol (Aave, Compound, Uniswap, MakerDAO, Curve, Morpho).

**When you need it:** You have funds deposited in a DeFi protocol and want protection against a smart contract exploit. This is the DeFi equivalent of bank robbery insurance.

| Parameter | Value |
|-----------|-------|
| Product ID | `EXPLOIT-001` |
| Trigger | DUAL: (1) Governance token -25% in 24h AND (2) Receipt token -30% for 4h or contract paused |
| Payout | 90% of coverage (10% deductible) |
| Duration | 90 to 365 days |
| Waiting Period | 14 days (longest — anti-insider) |
| Max Coverage | $50,000 per wallet |
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
| Aave v3 | 1 | 1.0x | $1,500 | 3.0% |
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

When you deposit USDY into a Lumina vault, you earn from TWO independent sources:

### Layer 1: USDY Base Yield (~3.55% APY)
USDY is Ondo Finance's yield-bearing stablecoin, backed by US Treasuries. It generates ~3.55% APY automatically, regardless of what happens in Lumina. This is your "risk-free" floor.

### Layer 2: Insurance Premiums (8-22% APY depending on vault)
Every time an agent buys an insurance policy, they pay a premium. That premium goes directly to the vault that backs the policy. The more policies sold, the more premiums flow to LPs.

### Combined Yield:

| Vault | Cooldown | USDY Base | Premiums | TOTAL APY |
|-------|----------|-----------|----------|-----------|
| VolatileShort | 30 days | 3.55% | 9-11% | **12.55-14.55%** |
| VolatileLong | 90 days | 3.55% | 12-14% | **15.55-17.55%** |
| StableShort | 90 days | 3.55% | 8-10% | **11.55-13.55%** |
| StableLong | 365 days | 3.55% | 15-22% | **18.55-25.55%** |

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
Kink multiplier at 85%: 1.88x
Next premium for same policy: $50K × 0.22 × 1.88 × (14/365) = $793

The premium increased 36% because utilization went up.
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
| Waiting periods | Prevents buying when you see the event coming | Depeg (24h), Exploit (14d) |
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
  "coverageAmount": 50000000000,    // $50,000 in 6 decimals (USDY)
  "durationSeconds": 1209600,       // 14 days
  "asset": "ETH",                   // For BSS and IL
  "stablecoin": "",                 // For Depeg: "USDC", "DAI", "USDT"
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

**⚠️ DEADLINE:** The `deadline` timestamp is typically 5 minutes from quote generation. You MUST execute the `purchasePolicy` transaction on-chain BEFORE this deadline expires. If you request a quote and then perform other tasks, the quote will expire and the transaction will revert with `QuoteExpired`. **Best practice:** Request quote → approve → purchase in a single sequential flow, no interruptions.

## Step 2: Approve USDY

```solidity
IERC20(USDY_ADDRESS).approve(COVER_ROUTER, premiumAmount);
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
// USDY arrives in your wallet in the same transaction
```

**⚠️ PROTOCOL FEE ON CLAIMS:** Your payout will be 97% of the calculated amount. The 3% protocol fee is deducted automatically by the CoverRouter. This is NOT a bug — it is the protocol's revenue model.

Example:
```
BSS triggers: Shield calculates $40,000 payout
CoverRouter deducts: $1,200 (3%) → protocol treasury
You receive: $38,800 (97%)

If you need exactly $40,000 net, buy coverage of $51,546 instead of $50,000.
```

## Step 6: Auto-Repurchase (recommended for continuous coverage)

Insurance policies EXPIRE. They do not renew automatically. If you want continuous coverage, your agent must buy a new policy before the current one expires.

**Timing rules to avoid coverage gaps:**

| Product | Waiting Period | When to repurchase | Gap if late? |
|---------|---------------|-------------------|-------------|
| BSS | 0 | Any time before expiry | No gap (immediate coverage) |
| IL Index | 0 | Any time before expiry | No gap |
| Depeg | 24h | At least 24h before expiry | YES — 24h without coverage |
| Exploit | 14 days | At least 14 days before expiry | YES — 14 days without coverage |

**Agent configuration:**
```json
{
  "autoRepurchase": true,
  "maxPremiumIncrease": 0.30,
  "preferredDuration": 14,
  "fallbackDuration": 7,
  "minCoverage": 25000
}
```

**Repurchase flow:**
```
1. Check: policy expires in < (waitingPeriod + 24h buffer)?
2. If yes: request new quote at CURRENT price
3. Compare: new premium vs last premium
4. If increase ≤ maxPremiumIncrease (30%): BUY immediately
5. If increase > 30%: try fallbackDuration (shorter = cheaper)
6. If still too expensive: NOTIFY human owner
   "BSS policy expiring in 22h. New premium is 45% higher ($7.25 vs $5.00).
    Utilization rose from 30% to 75%. Do you want me to buy anyway?"
```

**IMPORTANT:** The new policy is a COMPLETELY NEW purchase at the CURRENT market price. The old premium is irrelevant — it was already paid and consumed. You are buying fresh coverage at today's utilization rate.

24h before expiry, request a new quote. If premium is within maxPremiumIncrease, purchase. If not, try fallbackDuration. If still too expensive, notify your human owner.

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
- **USDY approval:** Standard ERC20 ABI (`approve(address,uint256)`)
- **CoverRouter:** Use the CoverRouter ABI from the Lumina GitHub repo (`src/core/CoverRouter.sol`)
- **Vaults:** Use the IVault ABI (`src/interfaces/IVault.sol`) for deposit/withdraw operations

ABIs are published at: `https://github.com/agustintiberio10/LUMINA-PROTOCOL/tree/main/src`

---

# SECTION 6: HOW TO OPERATE (FOR LP AGENTS)

## Understanding the Vaults (CRITICAL — read before depositing)

**All 4 vaults work identically.** Same smart contract, same mechanics. The ONLY differences are:

| What changes | VolatileShort | VolatileLong | StableShort | StableLong |
|-------------|---------------|--------------|-------------|------------|
| Cooldown (exit notice) | 30 days | 90 days | 90 days | 365 days |
| Products backed | BSS + IL short | IL long + BSS overflow | Depeg short | Depeg long + Exploit |
| Risk type | VOLATILE | VOLATILE | STABLE | STABLE |
| Claim frequency | Higher | Higher | Low | Very low |
| APY (USDY + premiums) | 12-15% | 15-18% | 11-14% | 18-26% |

**What is a cooldown? It is NOT a lock period. It is an EXIT NOTICE.**

```
WRONG understanding:  "I deposit for 30 days, then I get my money back"
RIGHT understanding:  "I deposit INDEFINITELY. When I want to leave, I give 30 days notice."

Think of it like renting an apartment:
  - You sign the lease (deposit USDY)
  - You live there as long as you want (earn yield indefinitely)
  - One day you decide to move out (requestWithdrawal)
  - You give 30 days notice (cooldown period)
  - After 30 days, you leave and get your deposit back (completeWithdrawal + yield)
```

**Why does the cooldown exist?**
Because your money is BACKING insurance policies. If you could withdraw instantly and a crash happens 5 minutes later, the policies you were backing would have no collateral. The cooldown ensures your capital stays until existing policies expire or are settled.

**Why does longer cooldown = higher APY?**
- 30-day cooldown: you can exit relatively quickly, so you earn less
- 365-day cooldown: you're committed for a year when you decide to exit, so you earn the highest yield
- Longer commitment = backs longer (more expensive) policies = more premium income

**Your money keeps earning DURING the cooldown:**
When you request withdrawal, your capital still backs existing policies and earns premiums from them. The only change is that the PolicyManager stops assigning NEW policies to your capital.

## Step 1: Choose a Vault

Evaluate each vault based on:
- **Current APY** (USDY base 3.55% + premium yield — check real-time)
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
Want moderate yield with 90-day exit notice?           → VolatileLong or StableShort (11-18%)
Want quick exit (30-day notice) and accept BSS risk?   → VolatileShort (12-15%)
Unsure? Start with VolatileShort (shortest commitment) → move to longer vaults later
```

## Step 2: Deposit USDY

```solidity
IERC20(USDY_ADDRESS).approve(VAULT_ADDRESS, depositAmount);
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
// From this moment: cooldown clock starts (30/90/90/365 days depending on vault)
// Your capital still earns yield during cooldown

// Step 4b: WAIT for cooldown to complete
// Nothing to do. Just wait.
// VolatileShort: 30 days, VolatileLong: 90 days
// StableShort: 90 days, StableLong: 365 days

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
1. requestWithdrawal() from VolatileShort → wait 30 days
2. completeWithdrawal() → USDY back in your wallet
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

IF you provide liquidity in AMM pools:
  → Consider IL Index Cover (budget ≤ 50% of projected fees)

IF you have funds in Aave/Compound/Curve > $10,000:
  → Consider Exploit Shield (max $50K)

IF the premium (including 3% protocol fee) exceeds 5% of your projected returns:
  → SKIP — the insurance costs more than the risk is worth
```

## Should I deposit as LP? (For LP agents)

```
IF you want maximum yield and can lock for 365 days:
  → StableLong (18-25% APY combined)

IF you want moderate yield with 90-day flexibility:
  → VolatileLong or StableShort (12-17% APY)

IF you want quick access (30 days) and tolerate BSS/IL claim risk:
  → VolatileShort (12-14% APY)

IF a vault's utilization is > 80%:
  → Caution: high yield but high claim probability

IF a vault's utilization is < 20%:
  → Yield will be low, but claims are also unlikely
  → Consider waiting for utilization to rise

ALWAYS CHECK: Current APY = USDY base (3.55%) + premium yield
The 3.55% USDY yield is guaranteed regardless of utilization.
```

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
| 85% | 1.88x | Stress zone |
| 90% | 2.25x | Very expensive |
| 95% | 2.63x | Maximum before rejection |
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

# SECTION 9: CONTRACT ADDRESSES

## Base L2 (Chain 8453)

| Contract | Address | Notes |
|----------|---------|-------|
| USDY Token | TBD (deploy pending) | Ondo Finance yield-bearing stablecoin |
| CoverRouter | TBD | Main entry point for all operations |
| PolicyManager | TBD | Vault selection + allocation |
| LuminaOracle | TBD | Chainlink price feeds + signature verification |
| LuminaPhalaVerifier | TBD | Phala TEE attestation (Exploit Shield only) |
| VolatileShortVault | TBD | 30-day cooldown |
| VolatileLongVault | TBD | 90-day cooldown |
| StableShortVault | TBD | 90-day cooldown |
| StableLongVault | TBD | 365-day cooldown |
| BlackSwanShield | TBD | BSS product |
| DepegShield | TBD | Depeg product |
| ILIndexCover | TBD | IL product |
| ExploitShield | TBD | Exploit product |

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

**Q: Is the USDY yield guaranteed?**
A: The ~3.55% USDY base yield comes from Ondo Finance (US Treasuries). It's not guaranteed by Lumina — it's a property of the USDY asset itself. The premium yield on top depends on Lumina policy volume.

**Q: What's the maximum I can lose as an LP?**
A: In the absolute worst case (simultaneous BSS crash + stablecoin depeg), a vault could lose ~38% of TVL. This is extremely rare (~2-3% annual probability). In normal years, premiums far exceed claims.

**Q: Why are shares soulbound?**
A: To prevent cooldown bypass. If you could sell your shares on a DEX, someone could buy "mature" shares that are about to finish cooldown, defeating the purpose of locking capital.

**Q: Why does Lumina charge 3% on claims? Isn't that unfair?**
A: Lumina charges 3% on BOTH premiums and payouts. This is the protocol's revenue model (adapted from MutualLumina V1). On claims, the 3% is negligible compared to your return: you pay $527 in premium and receive $38,800 — that's a 73x return even after the fee. If you need exact payout amounts, increase your coverage by 3.1% to compensate.

**Q: Does the fee affect LP yields?**
A: Minimally. LPs receive 97% of premiums instead of 100%. The difference is ~0.3% APY. A vault showing 13.55% total APY without fee would show 13.25% with fee. The fee on claims does NOT affect LPs — it comes from the agent's payout, not the vault.

**Q: How do I contact Lumina for help?**
A: Email hello@lumina-org.com. A human will respond, explain the products, and provide the SKILL document for your agent.
