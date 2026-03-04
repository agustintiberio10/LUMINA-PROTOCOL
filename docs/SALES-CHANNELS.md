# Lumina Protocol — Sales Channels

> How agents discover and purchase Lumina insurance across all distribution paths.

---

## Overview

Lumina has **5 sales channels**. Humans don't buy policies — agents do. Each channel represents a different way an agent discovers and interacts with Lumina.

```
CHANNEL 1: REST API Direct       → Agent calls endpoints autonomously
CHANNEL 2: Web Dashboard          → Human registers agent, sets limits via website
CHANNEL 3: Natural Language        → Human tells agent to buy coverage
CHANNEL 4: ACP Marketplace        → Agent discovers Lumina via Virtuals Protocol
CHANNEL 5: Framework Plugins       → Agent has Lumina as a built-in capability
```

---

## Channel 1: REST API Direct (M2M Pure)

**Who uses this:** Autonomous agents with no human involvement in the purchase decision.

**Flow:**
```
Agent discovers Lumina in a service registry or config
→ GET /api/v1/products
→ Agent evaluates which products match its risk profile
→ POST /api/v1/quote
→ Agent decides if premium is worth the coverage
→ USDC approve on-chain
→ createPool() on MutualLumina on-chain
→ POST /api/v1/purchase
→ Policy active. AutoResolver monitors.
```

**Badge:** "Zero human interaction"

**Requirements:**
- Agent must have pre-registered API key
- Agent must have USDC + ETH on Base L2
- Agent must have EVM transaction capability

**Best for:** Trading bots, DeFi agents, arbitrage agents, MEV agents.

**Integration time:** ~30 minutes

---

## Channel 2: Web Dashboard (Human Configures)

**Who uses this:** Humans who own agents and want to set up permissions.

**Flow:**
```
Human visits lumina-org.com
→ Connects wallet (RainbowKit)
→ Registers agent wallet address
→ Sets permissions: allowed products, max coverage, max monthly spend
→ Receives API key
→ Gives API key to the agent
→ Agent operates autonomously within the limits
→ Human monitors via dashboard
```

**Badge:** "Full control"

**What the human does:**
- Register agent (one-time)
- Set spending limits
- Monitor active policies
- Review premium spend

**What the human does NOT do:**
- Buy policies (the agent does this)
- File claims (automatic)
- Vote on disputes (none exist)

**Best for:** Agent creators who want to control risk exposure.

---

## Channel 3: Natural Language Command

**Who uses this:** Humans who instruct their LLM-powered agent verbally.

**Flow:**
```
Human says: "Buy depeg insurance for USDC, $5K coverage, 30 days"
→ Agent parses intent
→ Agent maps to: productId=DEPEG-USDC-001, coverageAmount=5000, durationDays=30
→ Agent calls Lumina API (same as Channel 1)
→ Agent confirms to human: "Purchased USDC depeg cover for $65 premium"
```

**Badge:** "Works with any LLM-powered agent"

**Example commands a human might give:**
```
"Get me liquidation protection for my ETH position"
"Buy insurance against USDC depeg, cheapest option"
"What's the premium for $10K of bridge failure cover?"
"Check the status of my active policies"
"How much have I spent on insurance this month?"
"Cancel the gas spike shield" (policy can't be cancelled, but agent explains)
```

**Requirements:**
- Agent must have Lumina skill/plugin installed
- Agent must understand insurance terminology OR have the skill description in context
- Agent must have API key and wallet access

**Best for:** Users of ChatGPT-based agents, Claude-based agents, or any conversational AI managing a wallet.

---

## Channel 4: ACP Marketplace (Virtuals Protocol)

**Who uses this:** Agents operating within the Virtuals Protocol ecosystem.

**Flow:**
```
Agent queries ACP service registry for "insurance" providers
→ Discovers Lumina Protocol as a service
→ Reads service offerings (8 products)
→ Sends ACP service_request message
→ Lumina ACP Handler translates to REST API call
→ Returns quote via ACP response
→ Agent confirms purchase via ACP
→ On-chain transactions executed
→ Policy active
```

**Badge:** "ACP Compatible"

**ACP Service Listing:**
```json
{
  "serviceId": "lumina-parametric-insurance",
  "provider": "lumina-protocol",
  "category": "insurance",
  "chain": "base",
  "description": "Parametric insurance for DeFi agents. 8 products covering liquidation, depeg, IL, gas, slippage, and bridge risks. Chainlink oracle-verified. Automatic payouts.",
  "pricing": "1.3% - 10% of coverage amount",
  "settlement": "USDC",
  "integration": "REST API via ACP Handler"
}
```

**Best for:** Agents built on Virtuals Protocol that discover services dynamically.

---

## Channel 5: Framework Plugins (Pre-Installed)

**Who uses this:** Agents built on frameworks that have Lumina as a built-in plugin.

**Supported frameworks:**

| Framework | Integration Type | Status |
|---|---|---|
| ElizaOS | Plugin (`eliza-plugin-lumina`) | Available |
| LangChain | Tool definitions | Available |
| LangGraph | Stateful workflow nodes | Available |
| Virtuals Protocol | ACP Handler | Available |
| NEAR AI | REST integration | Compatible |
| MyShell | Skill package | Compatible |
| Farcaster Frames | Frame action | Planned |
| Custom HTTP | Direct REST calls | Available |

**Flow (ElizaOS example):**
```
Developer installs eliza-plugin-lumina
→ Plugin registers 5 actions: getProducts, getQuote, purchase, checkPolicy, evaluateRisk
→ Agent can now respond to insurance-related queries
→ User says "protect my ETH position"
→ Agent calls LUMINA_GET_PRODUCTS → LUMINA_GET_QUOTE → evaluates → purchases
→ Reports back: "Purchased Liquidation Shield, $460 premium, 30 days"
```

**Best for:** Developers who want insurance as a native capability of their agent.

---

## Channel Comparison

| Aspect | API Direct | Web Dashboard | Natural Language | ACP | Plugin |
|---|---|---|---|---|---|
| Human involvement | None | Registration only | Command per action | None | None |
| Discovery | Pre-configured | Manual | Agent interprets | Marketplace | Built-in |
| Speed | Fastest | Medium | Depends on LLM | Medium | Fast |
| Best for | Bots | Agent owners | End users | Virtuals agents | Developers |
| Setup time | 30 min | 10 min (human) | Varies | 1 hour | 30 min |

---

## Sales Funnel by Audience

### For Agent Developers / Builders
```
Discover → GitHub / Docs / Dev community
Learn    → SKILL-lumina-insurance.md + API-REFERENCE.md
Build    → Integration guide for their framework
Test     → Use testnet or small amounts on Base mainnet
Deploy   → Agent operates autonomously
```

### For Agent Owners / Non-Technical Users
```
Discover → lumina-org.com landing page
Learn    → "I Have an AI Agent" tab, FAQ
Register → Connect wallet, register agent, get API key
Configure → Set limits, choose products
Monitor  → Dashboard shows agent activity
```

### For Liquidity Providers
```
Discover → lumina-org.com landing page, "I Want to Earn Yield" tab
Learn    → Yield calculator, risk levels, pool mechanics
Deposit  → Connect wallet, approve USDC, deposit into pool
Earn     → Premiums accumulate, withdraw after policy expiry
Monitor  → Pool status, utilization, claim exposure
```

### For AI Agent Ecosystems (B2B)
```
Discover → Direct outreach, partnerships
Evaluate → API docs, smart contract verification
Integrate → ACP Handler, plugin, or custom wrapper
Launch   → Agents in the ecosystem can use Lumina natively
```

---

## Go-To-Market Priority

1. **API Direct + GitHub docs** — Foundation. If the docs are good, developers come.
2. **ElizaOS plugin** — Largest open-source agent framework. Plugin gets distribution.
3. **Virtuals ACP** — Growing marketplace. Agents discover Lumina organically.
4. **Web Dashboard** — For non-technical agent owners. Lower priority but important for perception.
5. **LangChain tools** — Python/AI community. Easy to publish as a package.
6. **Farcaster Frames** — Future. Social distribution for LP deposits.
