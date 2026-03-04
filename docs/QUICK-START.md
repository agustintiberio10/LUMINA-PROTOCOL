# Lumina Protocol — Quick Start (5 Minutes)

Get your AI agent insured on Base L2 in 5 minutes.

---

## Prerequisites

- Agent wallet with USDC + ETH on **Base L2** (Chain ID 8453)
- Agent can make HTTP requests and sign EVM transactions

---

## Step 1: Register (Human Does This Once)

```bash
curl -X POST https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/register \
  -H "Content-Type: application/json" \
  -d '{
    "agentWallet": "0xYOUR_AGENT_WALLET",
    "ownerWallet": "0xYOUR_WALLET",
    "allowedProducts": ["LIQSHIELD-001", "DEPEG-USDC-001"],
    "maxCoveragePerPolicy": 10000,
    "maxMonthlySpend": 500
  }'
```

Save the `apiKey` from the response. You'll give it to your agent.

---

## Step 2: Discover Products

```bash
curl https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/products
```

---

## Step 3: Get a Quote

```bash
curl -X POST https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/quote \
  -H "Authorization: Bearer lum_YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "productId": "LIQSHIELD-001",
    "coverageAmount": 5000,
    "durationDays": 14,
    "threshold": 2000,
    "asset": "ETH"
  }'
```

---

## Step 4: Approve USDC + Purchase On-Chain

```javascript
// Using ethers.js / viem / web3.py
// 1. Approve USDC spend
await usdc.approve("0x1c5Ec90aC46e960aACbfCeAE9d6C2F79ce806b07", premiumAmount);
// 2. Create pool on MutualLumina
const tx = await mutualLumina.createPool(/* params from quote */);
```

---

## Step 5: Confirm

```bash
curl -X POST https://moltagentinsurance-production-6e3d.up.railway.app/api/v1/purchase \
  -H "Authorization: Bearer lum_YOUR_KEY" \
  -H "Content-Type: application/json" \
  -d '{ "quoteId": "QT-xxxx", "txHash": "0x..." }'
```

Done. AutoResolver monitors Chainlink. If the trigger activates, USDC goes to your agent's wallet automatically.

---

## Next Steps

- **Full skill documentation:** [SKILL-lumina-insurance.md](./SKILL-lumina-insurance.md)
- **Framework guides:** [INTEGRATION-GUIDES.md](./INTEGRATION-GUIDES.md) (Virtuals, ElizaOS, LangChain, generic HTTP)
- **API reference:** [API-REFERENCE.md](./API-REFERENCE.md)
- **Sales channels:** [SALES-CHANNELS.md](./SALES-CHANNELS.md)
