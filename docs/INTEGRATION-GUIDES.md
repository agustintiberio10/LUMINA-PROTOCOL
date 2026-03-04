# Lumina Protocol — Integration Guides by Framework

> See [SKILL-lumina-insurance.md](./SKILL-lumina-insurance.md) for the complete skill definition, products, and formulas.

---

## 1. Virtuals Protocol (ACP Handler)

Virtuals Protocol uses the Agent Commerce Protocol (ACP) for agent-to-agent commerce. Lumina integrates as a **service provider** that agents can discover and purchase from.

### Setup

The Lumina ACP Handler wraps the REST API into ACP-compatible service offerings. Each Lumina product becomes a discoverable service on the Virtuals marketplace.

### Service Registration
```javascript
// Register Lumina as a service provider on ACP
const luminaService = {
  serviceId: "lumina-parametric-insurance",
  provider: "lumina-protocol",
  offerings: [
    {
      id: "LIQSHIELD-001",
      name: "Liquidation Shield",
      description: "Parametric insurance against ETH/BTC price crashes",
      priceRange: { min: "2.5%", max: "7%", currency: "USDC" },
      chain: "base",
    },
    // ... all 8 products
  ],
  endpoint: "https://moltagentinsurance-production-6e3d.up.railway.app",
};
```

### Agent Discovery → Purchase Flow
```javascript
// 1. Agent discovers Lumina via ACP service registry
const services = await acp.discoverServices({ category: "insurance" });
const lumina = services.find(s => s.provider === "lumina-protocol");

// 2. Agent selects product and gets quote
const quote = await fetch(`${lumina.endpoint}/api/v1/quote`, {
  method: "POST",
  headers: {
    "Authorization": `Bearer ${apiKey}`,
    "Content-Type": "application/json"
  },
  body: JSON.stringify({
    productId: "LIQSHIELD-001",
    coverageAmount: 10000,
    durationDays: 30,
    threshold: 2000,
    asset: "ETH"
  })
}).then(r => r.json());

// 3. Agent evaluates and purchases (standard Lumina flow)
// See Steps 3-5 in SKILL-lumina-insurance.md
```

### ACP Message Format
```json
{
  "type": "service_request",
  "from": "agent-0xABC...",
  "to": "lumina-protocol",
  "action": "purchase_insurance",
  "params": {
    "productId": "LIQSHIELD-001",
    "coverageAmount": 10000,
    "durationDays": 30,
    "threshold": 2000
  }
}
```

### Files
- ACP Handler source: `LUMINA-PROTOCOL/acp-handler/` (if available)
- The handler translates ACP messages into Lumina API calls

---

## 2. ElizaOS (Plugin)

ElizaOS agents use plugins to add capabilities. The Lumina plugin gives any Eliza agent the ability to purchase insurance.

### Plugin Structure
```
eliza-plugin-lumina/
├── src/
│   ├── index.ts          # Plugin registration
│   ├── actions/
│   │   ├── getProducts.ts    # List available products
│   │   ├── getQuote.ts       # Get premium quote
│   │   ├── purchase.ts       # Buy policy (API + on-chain)
│   │   ├── checkPolicy.ts    # Monitor active policies
│   │   └── evaluateRisk.ts   # Decision logic helper
│   ├── providers/
│   │   └── luminaProvider.ts # API client wrapper
│   └── types.ts
├── package.json
└── README.md
```

### Plugin Registration
```typescript
// src/index.ts
import { Plugin } from "@elizaos/core";
import { getProductsAction } from "./actions/getProducts";
import { getQuoteAction } from "./actions/getQuote";
import { purchaseAction } from "./actions/purchase";
import { checkPolicyAction } from "./actions/checkPolicy";
import { evaluateRiskAction } from "./actions/evaluateRisk";

export const luminaPlugin: Plugin = {
  name: "lumina-insurance",
  description: "Parametric insurance for DeFi agents via Lumina Protocol",
  actions: [
    getProductsAction,
    getQuoteAction,
    purchaseAction,
    checkPolicyAction,
    evaluateRiskAction,
  ],
};
```

### Action Example: Get Quote
```typescript
// src/actions/getQuote.ts
import { Action, ActionExample } from "@elizaos/core";
import { LuminaProvider } from "../providers/luminaProvider";

export const getQuoteAction: Action = {
  name: "LUMINA_GET_QUOTE",
  description: "Get an insurance premium quote from Lumina Protocol",
  similes: [
    "get insurance quote",
    "how much for coverage",
    "price for liquidation protection",
    "quote depeg insurance",
  ],
  
  validate: async (runtime, message) => {
    // Check that API key is configured
    return !!runtime.getSetting("LUMINA_API_KEY");
  },

  handler: async (runtime, message, state) => {
    const provider = new LuminaProvider(runtime.getSetting("LUMINA_API_KEY"));
    
    // Extract params from message context
    const params = extractInsuranceParams(message, state);
    
    const quote = await provider.getQuote({
      productId: params.productId,
      coverageAmount: params.coverageAmount,
      durationDays: params.durationDays,
      threshold: params.threshold,
      asset: params.asset,
    });

    return {
      text: `Quote for ${params.productId}: Premium $${quote.premium} USDC for $${quote.maxPayout} max payout. Trigger: ${quote.trigger}. Valid for 15 minutes.`,
      data: quote,
    };
  },

  examples: [
    [
      { user: "user", content: { text: "Get me a quote for liquidation protection on $10K for 30 days" }},
      { user: "agent", content: { text: "Quote for LIQSHIELD-001: Premium $460 USDC for $9,500 max payout." }},
    ],
  ],
};
```

### Provider (API Client)
```typescript
// src/providers/luminaProvider.ts
const BASE_URL = "https://moltagentinsurance-production-6e3d.up.railway.app";

export class LuminaProvider {
  constructor(private apiKey: string) {}

  async getProducts() {
    const res = await fetch(`${BASE_URL}/api/v1/products`);
    return res.json();
  }

  async getQuote(params: QuoteParams) {
    const res = await fetch(`${BASE_URL}/api/v1/quote`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(params),
    });
    return res.json();
  }

  async purchase(quoteId: string, txHash: string) {
    const res = await fetch(`${BASE_URL}/api/v1/purchase`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${this.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ quoteId, txHash }),
    });
    return res.json();
  }

  async getPolicyStatus(policyId: string) {
    const res = await fetch(`${BASE_URL}/api/v1/policy/${policyId}`, {
      headers: { "Authorization": `Bearer ${this.apiKey}` },
    });
    return res.json();
  }

  async getDashboard() {
    const res = await fetch(`${BASE_URL}/api/v1/agent/dashboard`, {
      headers: { "Authorization": `Bearer ${this.apiKey}` },
    });
    return res.json();
  }
}
```

### .env Configuration
```env
LUMINA_API_KEY=lum_xxxxxxxxxxxxxxxxxxxx
LUMINA_AGENT_WALLET=0xYOUR_AGENT_WALLET
LUMINA_MAX_COVERAGE=50000
LUMINA_MAX_MONTHLY_SPEND=2000
```

---

## 3. LangChain / LangGraph (Tools)

LangChain agents use Tools (function calling). Each Lumina action becomes a tool the LLM can invoke.

### Tool Definitions
```python
from langchain.tools import tool
import requests

BASE_URL = "https://moltagentinsurance-production-6e3d.up.railway.app"
API_KEY = "lum_xxxxxxxxxxxxxxxxxxxx"

HEADERS = {
    "Authorization": f"Bearer {API_KEY}",
    "Content-Type": "application/json"
}

@tool
def lumina_get_products() -> str:
    """List all available parametric insurance products from Lumina Protocol.
    Returns product IDs, triggers, thresholds, premiums, and durations.
    Use this to discover what coverage options are available."""
    
    response = requests.get(f"{BASE_URL}/api/v1/products")
    return response.json()

@tool
def lumina_get_quote(
    product_id: str,
    coverage_amount: int,
    duration_days: int,
    threshold: int,
    asset: str = "ETH"
) -> str:
    """Get an insurance premium quote from Lumina Protocol.
    
    Args:
        product_id: Product ID (e.g., LIQSHIELD-001, DEPEG-USDC-001)
        coverage_amount: Amount to insure in USDC (100-100000)
        duration_days: Policy duration in days
        threshold: Trigger threshold in basis points or absolute
        asset: Asset to cover (ETH, BTC, USDC, USDT, DAI)
    
    Returns: Quote with premium, max payout, trigger condition, and 15-min expiry.
    """
    
    response = requests.post(
        f"{BASE_URL}/api/v1/quote",
        headers=HEADERS,
        json={
            "productId": product_id,
            "coverageAmount": coverage_amount,
            "durationDays": duration_days,
            "threshold": threshold,
            "asset": asset,
        }
    )
    return response.json()

@tool
def lumina_check_policy(policy_id: str) -> str:
    """Check the status of an active Lumina insurance policy.
    
    Args:
        policy_id: Policy ID (e.g., POL-001)
    
    Returns: Policy status, coverage, trigger condition, distance to trigger, expiry.
    """
    
    response = requests.get(
        f"{BASE_URL}/api/v1/policy/{policy_id}",
        headers=HEADERS,
    )
    return response.json()

@tool 
def lumina_dashboard() -> str:
    """Get a complete overview of all agent insurance activity.
    Returns all policies, premiums paid, payouts received, and current coverage."""
    
    response = requests.get(
        f"{BASE_URL}/api/v1/agent/dashboard",
        headers=HEADERS,
    )
    return response.json()
```

### Agent Setup
```python
from langchain.agents import AgentExecutor, create_openai_tools_agent
from langchain_openai import ChatOpenAI

tools = [
    lumina_get_products,
    lumina_get_quote,
    lumina_check_policy,
    lumina_dashboard,
]

# System prompt for the agent
SYSTEM_PROMPT = """You are a DeFi agent that manages a portfolio on Base L2.
You have access to Lumina Protocol for parametric insurance.

When evaluating whether to purchase insurance:
1. Check your current exposure and positions
2. List available products with lumina_get_products
3. Get quotes for relevant products
4. Compare premium cost vs potential loss
5. Purchase if premium < expected_loss × probability

Always consider: coverage amount, duration, threshold, and deductible."""

llm = ChatOpenAI(model="gpt-4")
agent = create_openai_tools_agent(llm, tools, SYSTEM_PROMPT)
executor = AgentExecutor(agent=agent, tools=tools)
```

### LangGraph Integration
```python
from langgraph.graph import StateGraph

# Define state
class AgentState(TypedDict):
    portfolio: dict
    active_policies: list
    available_products: list
    pending_quotes: list

# Define nodes
def check_portfolio(state):
    """Evaluate current positions and risks."""
    # Your portfolio evaluation logic
    return state

def evaluate_coverage(state):
    """Check if current coverage is adequate."""
    products = lumina_get_products.invoke({})
    state["available_products"] = products
    return state

def get_quotes(state):
    """Get quotes for needed coverage."""
    # Based on portfolio gaps, get relevant quotes
    return state

def purchase_decision(state):
    """Decide whether to purchase based on quotes."""
    return state

# Build graph
workflow = StateGraph(AgentState)
workflow.add_node("check_portfolio", check_portfolio)
workflow.add_node("evaluate_coverage", evaluate_coverage)
workflow.add_node("get_quotes", get_quotes)
workflow.add_node("purchase_decision", purchase_decision)
```

---

## 4. Generic HTTP Agent (Any Framework)

Any agent that can make HTTP requests can integrate with Lumina. This is the simplest path.

### Minimal Integration (5 HTTP Calls)

```bash
# 1. Check what's available
GET /api/v1/products

# 2. Get a quote
POST /api/v1/quote
  Headers: Authorization: Bearer lum_YOUR_KEY
  Body: { productId, coverageAmount, durationDays, threshold, asset }

# 3. Approve USDC on-chain (EVM transaction, not HTTP)
# Call USDC.approve(MutualLumina, amount)

# 4. Create pool on-chain (EVM transaction, not HTTP)
# Call MutualLumina.createPool(...)

# 5. Confirm purchase
POST /api/v1/purchase
  Headers: Authorization: Bearer lum_YOUR_KEY
  Body: { quoteId, txHash }
```

### Health Check
```bash
GET /health
# Returns: { status: "ok", version: "2.0.0", chain: "base", contracts: {...} }
```

### Monitoring
```bash
# Check specific policy
GET /api/v1/policy/:policyId
  Headers: Authorization: Bearer lum_YOUR_KEY

# Full dashboard
GET /api/v1/agent/dashboard
  Headers: Authorization: Bearer lum_YOUR_KEY
```

### cURL Complete Example
```bash
# Step 1: Discover products (no auth needed)
curl -s https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/products | jq .

# Step 2: Get quote
curl -s -X POST https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/quote \
  -H "Authorization: Bearer lum_YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "productId": "LIQSHIELD-001",
    "coverageAmount": 10000,
    "durationDays": 30,
    "threshold": 2000,
    "asset": "ETH"
  }' | jq .

# Step 3-4: On-chain transactions (use ethers.js, web3.py, viem, or cast)
# See SKILL-lumina-insurance.md for contract details

# Step 5: Confirm
curl -s -X POST https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/purchase \
  -H "Authorization: Bearer lum_YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "quoteId": "QT-a1b2c3",
    "txHash": "0x..."
  }' | jq .
```

---

## Integration Checklist

Before going live, verify:

- [ ] API key obtained via registration
- [ ] Agent wallet funded with USDC on Base L2
- [ ] Agent wallet has ETH on Base L2 for gas
- [ ] USDC approval set for MutualLumina contract
- [ ] Products endpoint returns valid data
- [ ] Quote endpoint returns valid premium
- [ ] On-chain transaction succeeds on Base
- [ ] Purchase confirmation returns active policy
- [ ] Policy status check works
- [ ] Dashboard shows policy correctly

**Estimated integration time: 30 minutes** for an agent that already has HTTP and EVM capabilities.
