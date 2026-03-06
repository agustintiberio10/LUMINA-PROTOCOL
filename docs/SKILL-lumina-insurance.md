# Lumina Protocol — AI Agent Skill: Parametric Insurance

> **Version:** 1.0.0  
> **Last Updated:** 2026-03-04  
> **Skill ID:** `lumina-insurance`  
> **Protocol:** Lumina Protocol  
> **Chain:** Base L2 (Chain ID 8453)  
> **Settlement:** USDC  

---

## What Is This Skill?

This skill enables an AI agent to autonomously purchase parametric insurance coverage on Base L2 via Lumina Protocol. The agent can protect itself (or the portfolio it manages) against measurable DeFi risks — liquidations, stablecoin depeg events, impermanent loss, gas spikes, slippage, and bridge failures.

**Parametric** means: if a measurable condition is met (verified by Chainlink oracles), the payout is automatic. No claims to file, no human intervention, no disputes.

---

## Required Agent Capabilities

Your agent MUST be able to:

| Capability | Why |
|---|---|
| Make HTTP requests (GET, POST) | Interact with Lumina REST API |
| Parse JSON responses | Read quotes, products, policy data |
| Hold an EVM wallet with private key | Sign transactions on Base L2 |
| Send ERC-20 `approve()` transactions | Approve USDC for premium payment |
| Call smart contract functions | Create pools on MutualLumina contract |
| Store and use an API key | Authenticate with Lumina API |
| Make decisions based on data | Evaluate if a policy is worth the premium |

**Optional but recommended:**
- Read Chainlink price feeds directly (for pre-purchase risk assessment)
- Track policy expiration dates (to auto-renew if needed)
- Monitor portfolio exposure (to decide coverage amounts dynamically)

---

## Infrastructure (All Live on Base Mainnet)

### API
```
Base URL: https://moltagentinsurance-production-6e3d.up.railway.app
Auth: Bearer token (API key from registration)
Format: JSON
Rate limit: Standard REST limits
```

### Smart Contracts (Verified on BaseScan)
```
MutualLumina:    0x1c5Ec90aC46e960aACbfCeAE9d6C2F79ce806b07
DisputeResolver: 0x2e4D0112A65C2e2DCE73e7F85bF5C2889c7709cA
AutoResolver:    0x8D919F0BEf46736906e190da598570255FF02754
USDC (Base):     0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
```

### Chainlink Price Feeds (Base Mainnet)
```
ETH/USD:  0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
BTC/USD:  0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F
USDC/USD: 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B
USDT/USD: 0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9
DAI/USD:  0x591e79239a7d679378eC8c847e5038150364C78F
```

---

## Complete Agent Workflow

### Step 0: Registration (One-Time, Done by Human Owner)

The human owner registers the agent via the web dashboard or API:

```bash
curl -X POST https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{
    "agentWallet": "0xYOUR_AGENT_WALLET_ADDRESS",
    "ownerWallet": "0xHUMAN_OWNER_WALLET",
    "allowedProducts": ["LIQSHIELD-001", "DEPEG-USDC-001", "DEPEG-USDT-001", "DEPEG-DAI-001", "ILPROT-001", "GASSPIKE-001", "SLIPPAGE-001", "BRIDGE-001"],
    "maxCoveragePerPolicy": 50000,
    "maxMonthlySpend": 2000
  }'
```

**Response:**
```json
{
  "agentId": "AGT-xxxx",
  "apiKey": "lum_xxxxxxxxxxxxxxxxxxxx",
  "status": "active"
}
```

**IMPORTANT:** Save the API key securely. It won't be shown again. The agent uses this key for all subsequent API calls.

---

### Step 1: Discover Products

```bash
curl https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/products
```

**Response includes all 8 products with:**
- Product ID, name, trigger type
- Threshold options (in basis points or absolute values)
- Sustained period (how long the condition must hold)
- Deductible, premium range, duration range
- Chainlink feed addresses

**Decision logic the agent should implement:**
```
FOR each risk I face:
  FIND the matching Lumina product
  EVALUATE: is the premium < expected loss × probability?
  IF yes → proceed to quote
```

---

### Step 2: Get a Quote

```bash
curl -X POST https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/quote \
  -H "Authorization: Bearer lum_YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "productId": "LIQSHIELD-001",
    "coverageAmount": 10000,
    "durationDays": 30,
    "threshold": 2000,
    "asset": "ETH"
  }'
```

**Response:**
```json
{
  "quoteId": "QT-a1b2c3",
  "premium": 460,
  "maxPayout": 9500,
  "deductible": "5%",
  "trigger": "ETH/USD drops >20% for 30+ min (Chainlink)",
  "termsHash": "0xabc123...",
  "expiresIn": "15 minutes"
}
```

**Agent decision point:** Is $460 premium worth $9,500 protection? The agent should evaluate based on current market conditions, its exposure, and risk tolerance.

**IMPORTANT:** Quotes expire in 15 minutes. The agent must complete the purchase within that window.

---

### Step 3: Approve USDC (On-Chain)

Before paying the premium, the agent must approve the MutualLumina contract to spend USDC:

```
Contract: USDC (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)
Function: approve(address spender, uint256 amount)
Args:
  spender: 0x1c5Ec90aC46e960aACbfCeAE9d6C2F79ce806b07 (MutualLumina)
  amount: premium in USDC (6 decimals) → 460 USDC = 460000000
```

**Optimization:** The agent can approve a larger amount once to avoid approving on every purchase.

---

### Step 4: Create Pool On-Chain

Call `createPool()` on MutualLumina to create the insurance pool and pay the premium:

```
Contract: MutualLumina (0x1c5Ec90aC46e960aACbfCeAE9d6C2F79ce806b07)
Function: createPool(...)
```

**NOTE:** Check the actual ABI at `LUMINA-PROTOCOL/api/abis/MutualLumina.json` for exact parameter names and types. The function creates a pool, locks the premium, and starts the policy.

---

### Step 5: Confirm Purchase via API

After the on-chain transaction confirms, notify the API:

```bash
curl -X POST https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/purchase \
  -H "Authorization: Bearer lum_YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "quoteId": "QT-a1b2c3",
    "txHash": "0x..."
  }'
```

**Response:**
```json
{
  "policyId": "POL-001",
  "status": "active",
  "autoResolve": true,
  "monitoring": "AutoResolver + Chainlink ETH/USD",
  "expiresAt": "2026-04-03T00:00:00Z"
}
```

---

### Step 6: Monitoring (Automatic — No Agent Action Required)

Once the policy is active, the AutoResolver contract monitors the relevant Chainlink feed continuously. The agent does NOT need to do anything.

**To check policy status:**
```bash
curl -H "Authorization: Bearer lum_YOUR_API_KEY" \
  https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/policy/POL-001
```

**Resolution flow (fully automatic):**
1. AutoResolver detects trigger condition met for the required sustained period
2. AutoResolver calls `proposeResolution(true)` on-chain
3. 24-hour security timelock passes (not a dispute — just a safety delay)
4. `executeResolution()` sends USDC directly to the agent's wallet
5. Agent receives payout without taking any action

**If trigger never activates:**
- Policy expires at `expiresAt`
- LP recovers collateral + premium
- Agent loses premium (cost of insurance)
- No action required from anyone

---

### Step 7: Dashboard (For Human Owner)

The human owner can monitor all agent activity:

```bash
curl -H "Authorization: Bearer lum_YOUR_API_KEY" \
  https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/agent/dashboard
```

Returns: all policies, status, coverage amounts, premiums paid, payouts received, distance to trigger.

---

## The 8 Products — Complete Reference

### 1. LIQUIDATION SHIELD (LIQSHIELD-001)
**Protects:** Against sudden ETH or BTC price crashes  
**Trigger:** `PRICE_DROP_PCT` — single Chainlink reading below threshold (instant, no sustained period)  
**Threshold options:** 15%, 20%, 25%, 30%  
**Sustained period:** None — instant trigger. Chainlink aggregates multiple exchanges; single-exchange wicks don't trigger.  
**Waiting period:** 24 hours  
**Deductible:** 5%–8% (8% for 15% threshold, 6% for 20%, 5% for 25-30%)  
**Premium range:** 2.5% – 12%  
**Duration:** 7–90 days  
**Auto-renewal:** Yes. New policy enters Pending state until pool is funded. No coverage during gap. Agent and human owner are notified. Can cancel and recover premium if pool doesn't fill.  
**Use case:** Agent has $50K in Aave. ETH drops 22%. Chainlink confirms instantly. Agent receives compensation automatically within 24h.

### 2. USDC DEPEG COVER (DEPEG-USDC-001)
**Protects:** Against USDC losing dollar peg  
**Trigger:** `PRICE_BELOW` via Chainlink USDC/USD  
**Threshold options:** $0.99, $0.97, $0.95, $0.90  
**Sustained period:** 4 hours continuous  
**Waiting period:** 48 hours  
**Deductible:** 3%  
**Premium range:** 1.3% – 6%  
**Duration:** 14–365 days  
**Discount:** Up to 35% for annual policies  
**Auto-renewal:** Available (approve once, renews automatically)  
**Reference:** USDC dropped to $0.87 in March 2023 (SVB collapse)

### 3. USDT DEPEG COVER (DEPEG-USDT-001)
**Same as USDC Depeg but with 1.3x risk multiplier** reflecting historical uncertainty around Tether's reserves. Slightly higher premiums.

### 4. DAI DEPEG COVER (DEPEG-DAI-001)
**Same as USDC Depeg but with 1.2x risk multiplier.** DAI briefly lost peg in March 2020 (Black Thursday). Risk tied to MakerDAO's collateral.

### 5. IMPERMANENT LOSS PROTECTION (ILPROT-001)
**Protects:** AMM LP positions against excessive IL  
**Trigger:** `PRICE_DIVERGENCE` between two Chainlink feeds  
**Threshold options:** 15%, 20%, 30%, 50%  
**Sustained period:** 2 hours  
**Deductible:** 8% (high because some IL is expected)  
**Premium range:** 3.5% – 10%  
**Duration:** 14–60 days  
**Supported pairs:** ETH/USDC, BTC/USDC, ETH/BTC

### 6. GAS SPIKE SHIELD (GASSPIKE-001)
**Protects:** Against unexpected gas cost spikes on Base L2  
**Trigger:** `GAS_ABOVE` reading `tx.gasprice` directly from blockchain  
**Threshold options:** 50, 100, 200, 500 gwei  
**Sustained period:** 15 minutes  
**Deductible:** 10%  
**Premium range:** 1.7% – 5.5%  
**Duration:** 7–30 days  
**Note:** Base L2 only (does not measure Ethereum L1 gas)

### 7. SLIPPAGE PROTECTION (SLIPPAGE-001)
**Protects:** Against excessive price movement during trade execution  
**Trigger:** `PRICE_DROP_PCT` or `PRICE_RISE_PCT` (immediate — 0 sustained period)  
**Threshold options:** 2%, 3%, 5%, 10%  
**Deductible:** 3%  
**Premium range:** 1.3% – 7%  
**Duration:** 1–7 days  
**Cooling-off:** 30 minutes (vs 2 hours for other products)

### 8. BRIDGE FAILURE COVER (BRIDGE-001)
**Protects:** Funds lost or stuck in cross-chain bridges  
**Bridges covered:** Base Bridge, Across, Stargate, Hop  
**Trigger:** AutoResolver checks for Transfer events on-chain. If USDC never arrives at destination wallet within 365 days → payout.  
**Deductible:** 5%  
**Premium:** 3% fixed  
**Duration:** 365 days fixed  
**Subrogation:** If funds arrive after payout, agent must return compensation (rare — if it didn't arrive in a year, it's lost)

---

## Premium Calculation Formulas

All premiums follow: `premium = coverageAmount × premiumRate / 10,000`

### LIQSHIELD
```
premiumRate = 250 + (thresholdRisk × durationAdj × amountAdj)

thresholdRisk:
  30% (3000 bps) → 80
  25% (2500 bps) → 160
  20% (2000 bps) → 300
  15% (1500 bps) → 550

durationAdj:
  7–14 days  → 1.0
  15–30 days → 1.3
  31–60 days → 1.6
  61–90 days → 2.0

amountAdj:
  < $1,000    → 1.0
  $1K–$10K    → 1.1
  $10K–$50K   → 1.2
  > $50K      → 1.4

deductible (variable by threshold):
  15% threshold → 8%
  20% threshold → 6%
  25-30% threshold → 5%
```

### DEPEG (USDC/USDT/DAI)
```
premiumRate = 100 + (thresholdRisk × durationAdj × stablecoinRisk)

thresholdRisk:
  $0.90 → 30
  $0.95 → 80
  $0.97 → 200
  $0.99 → 500

durationAdj:
  14–30 days  → 1.0
  31–60 days  → 1.3
  61–90 days  → 1.6
  91–180 days → 1.62
  181–270 days → 1.6
  271–365 days → 1.43

stablecoinRisk:
  USDC → 1.0
  USDT → 1.3
  DAI  → 1.2
```

### ILPROT
```
premiumRate = 300 + (thresholdRisk × durationAdj × pairRisk)

thresholdRisk:
  50% (5000 bps) → 50
  30% (3000 bps) → 200
  20% (2000 bps) → 400
  15% (1500 bps) → 700

pairRisk:
  ETH/USDC → 1.0
  BTC/USDC → 1.0
  ETH/BTC  → 0.8
```

### GASSPIKE
```
premiumRate = 150 + (thresholdRisk × durationAdj)

thresholdRisk:
  500 gwei → 20
  200 gwei → 80
  100 gwei → 200
  50 gwei  → 400
```

### SLIPPAGE
```
premiumRate = 100 + (thresholdRisk × volatilityAdj)

thresholdRisk:
  10% (1000 bps) → 30
  5%  (500 bps)  → 150
  3%  (300 bps)  → 350
  2%  (200 bps)  → 600
```

### BRIDGE
```
premiumRate = 300 × bridgeRisk

bridgeRisk:
  Base Bridge → 0.8
  Across/Stargate/Hop → 1.0
```

**Max payout formula:** `maxPayout = coverageAmount × (1 - deductibleBps / 10,000)`

---

## Error Handling

| Error | What to Do |
|---|---|
| `401 Unauthorized` | API key missing or invalid. Re-register if lost. |
| `400 Bad Request` | Check parameter types and ranges for the product. |
| `429 Too Many Requests` | Rate limited. Wait and retry with exponential backoff. |
| `Quote expired` | Quotes last 15 minutes. Re-quote before purchasing. |
| `Insufficient USDC balance` | Check balance before attempting approve + purchase. |
| `Wrong network` | Ensure wallet is on Base L2 (Chain ID 8453). |
| `Transaction reverted` | Check USDC approval amount, gas, and contract parameters. |

---

## Knowledge Base: Answering Human Questions

If a human asks the agent about Lumina, here are accurate answers:

**"What is Lumina?"**
→ Parametric insurance for AI agents on Base L2. If a measurable condition happens (verified by Chainlink oracles), the payout is automatic. No claims, no disputes.

**"How much does it cost?"**
→ Premiums range from 1.3% to 10% of coverage amount depending on the product, duration, and risk level. Call the quote endpoint for exact pricing.

**"What happens if the trigger activates?"**
→ AutoResolver detects it via Chainlink, proposes a resolution on-chain, a 24-hour security timelock passes, then USDC is sent automatically to your wallet. You don't need to do anything.

**"Is it safe?"**
→ Three verified contracts on Base L2 with 123 passing tests on AutoResolver. Each policy is in its own isolated pool. Circuit breaker activates if claims exceed 50% of TVL. Formal Tier 1 audit is on the roadmap.

**"Can I use it with my framework?"**
→ Yes. Lumina is a REST API. Any agent that can make HTTP requests works: Virtuals Protocol, ElizaOS, LangChain, NEAR AI, or any custom bot. Integration takes about 30 minutes.

**"What's the risk?"**
→ You pay the premium upfront. If the trigger never activates, you lose the premium (that's the cost of insurance). If it does activate, you receive up to 95-97% of your coverage amount (minus deductible).

---

## Links

- **API Health Check:** https://moltagentinsurance-production-6e3d.up.railway.app/health
- **GitHub:** https://github.com/agustintiberio10/LUMINA-PROTOCOL
- **MutualLumina on BaseScan:** https://basescan.org/address/0x1c5Ec90aC46e960aACbfCeAE9d6C2F79ce806b07
- **AutoResolver on BaseScan:** https://basescan.org/address/0x8D919F0BEf46736906e190da598570255FF02754
- **DisputeResolver on BaseScan:** https://basescan.org/address/0x2e4D0112A65C2e2DCE73e7F85bF5C2889c7709cA
- **Terms Version:** 1.2.0
