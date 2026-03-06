# Lumina Protocol — API Reference v2.0

> **Base URL:** `https://moltagentinsurance-production-6e3d.up.railway.app`  
> **Authentication:** Bearer token (`Authorization: Bearer lum_YOUR_API_KEY`)  
> **Format:** JSON  
> **Chain:** Base L2 (8453)  

---

## Endpoints

### `GET /health`
**Auth required:** No

Returns protocol status, version, and contract addresses.

**Response:**
```json
{
  "status": "ok",
  "version": "2.0.0",
  "chain": "Base L2 (8453)",
  "contracts": {
    "MutualLumina": "0x1c5Ec90aC46e960aACbfCeAE9d6C2F79ce806b07",
    "DisputeResolver": "0x2e4D0112A65C2e2DCE73e7F85bF5C2889c7709cA",
    "AutoResolver": "0x8D919F0BEf46736906e190da598570255FF02754"
  },
  "chainlinkFeeds": 5
}
```

---

### `GET /api/v1/products`
**Auth required:** No

Returns all 8 insurance products with pricing parameters and Chainlink feed addresses.

**Response:**
```json
{
  "products": [
    {
      "id": "LIQSHIELD-001",
      "triggerMode": "instant",
      "name": "Liquidation Shield",
      "triggerType": "PRICE_DROP_PCT",
      "thresholdOptions": [1500, 2000, 2500, 3000],
      "sustainedPeriod": 0,
      "waitingPeriod": 86400,
      "deductibleBps": 500,
      "variableDeductible": { "1500": 800, "2000": 600, "2500": 500, "3000": 500 },
      "premiumRange": { "min": 250, "max": 1200 },
      "durationRange": { "min": 7, "max": 90 },
      "chainlinkFeed": "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70",
      "assets": ["ETH", "BTC"],
      "autoRenewal": true
    },
    {
      "id": "DEPEG-USDC-001",
      "name": "USDC Depeg Cover",
      "triggerType": "PRICE_BELOW",
      "thresholdOptions": [9900, 9700, 9500, 9000],
      "sustainedPeriod": 14400,
      "waitingPeriod": 172800,
      "deductibleBps": 300,
      "premiumRange": { "min": 130, "max": 600 },
      "durationRange": { "min": 14, "max": 365 },
      "autoRenewal": true,
      "longDurationDiscount": 0.35,
      "chainlinkFeed": "0x7e860098F58bBFC8648a4311b374B1D669a2bc6B"
    },
    {
      "id": "DEPEG-USDT-001",
      "name": "USDT Depeg Cover",
      "triggerType": "PRICE_BELOW",
      "thresholdOptions": [9900, 9700, 9500, 9000],
      "sustainedPeriod": 14400,
      "waitingPeriod": 172800,
      "deductibleBps": 300,
      "riskMultiplier": 1.3,
      "chainlinkFeed": "0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9"
    },
    {
      "id": "DEPEG-DAI-001",
      "name": "DAI Depeg Cover",
      "triggerType": "PRICE_BELOW",
      "thresholdOptions": [9900, 9700, 9500, 9000],
      "sustainedPeriod": 14400,
      "waitingPeriod": 172800,
      "deductibleBps": 300,
      "riskMultiplier": 1.2,
      "chainlinkFeed": "0x591e79239a7d679378eC8c847e5038150364C78F"
    },
    {
      "id": "ILPROT-001",
      "name": "Impermanent Loss Protection",
      "triggerType": "PRICE_DIVERGENCE",
      "thresholdOptions": [1500, 2000, 3000, 5000],
      "sustainedPeriod": 7200,
      "deductibleBps": 800,
      "premiumRange": { "min": 350, "max": 1000 },
      "durationRange": { "min": 14, "max": 60 },
      "supportedPairs": ["ETH/USDC", "BTC/USDC", "ETH/BTC"]
    },
    {
      "id": "GASSPIKE-001",
      "name": "Gas Spike Shield",
      "triggerType": "GAS_ABOVE",
      "thresholdOptions": [50, 100, 200, 500],
      "sustainedPeriod": 900,
      "deductibleBps": 1000,
      "premiumRange": { "min": 170, "max": 550 },
      "durationRange": { "min": 7, "max": 30 },
      "chain": "Base L2 only"
    },
    {
      "id": "SLIPPAGE-001",
      "name": "Slippage Protection",
      "triggerType": "PRICE_DROP_PCT",
      "thresholdOptions": [200, 300, 500, 1000],
      "sustainedPeriod": 0,
      "coolingOff": 1800,
      "deductibleBps": 300,
      "premiumRange": { "min": 130, "max": 700 },
      "durationRange": { "min": 1, "max": 7 }
    },
    {
      "id": "BRIDGE-001",
      "name": "Bridge Failure Cover",
      "triggerType": "TRANSFER_ABSENCE",
      "bridgesCovered": ["Base Bridge", "Across", "Stargate", "Hop"],
      "deductibleBps": 500,
      "premiumBps": 300,
      "durationDays": 365,
      "subrogation": true
    }
  ],
  "chainlinkFeeds": {
    "ETH": "0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70",
    "BTC": "0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F",
    "USDC": "0x7e860098F58bBFC8648a4311b374B1D669a2bc6B",
    "USDT": "0xf19d560eB8d2ADf07BD6D13ed03e1D11215721F9",
    "DAI": "0x591e79239a7d679378eC8c847e5038150364C78F"
  },
  "termsVersion": "1.2.0",
  "chain": "Base L2 (8453)"
}
```

---

### `POST /api/v1/register`
**Auth required:** No (returns API key)

Register an agent. Typically called by the human owner.

**Request:**
```json
{
  "agentWallet": "0xAGENT_WALLET_ADDRESS",
  "ownerWallet": "0xHUMAN_OWNER_WALLET",
  "allowedProducts": ["LIQSHIELD-001", "DEPEG-USDC-001"],
  "maxCoveragePerPolicy": 50000,
  "maxMonthlySpend": 2000
}
```

**Response:**
```json
{
  "agentId": "AGT-xxxx",
  "apiKey": "lum_xxxxxxxxxxxxxxxxxxxx",
  "status": "active",
  "permissions": {
    "allowedProducts": ["LIQSHIELD-001", "DEPEG-USDC-001"],
    "maxCoveragePerPolicy": 50000,
    "maxMonthlySpend": 2000
  }
}
```

**IMPORTANT:** The API key is only shown once. Store it securely.

---

### `POST /api/v1/quote`
**Auth required:** Yes

Get a premium quote for a specific product configuration.

**Request:**
```json
{
  "productId": "LIQSHIELD-001",
  "coverageAmount": 10000,
  "durationDays": 30,
  "threshold": 2000,
  "asset": "ETH"
}
```

| Field | Type | Description |
|---|---|---|
| `productId` | string | Product ID from /products |
| `coverageAmount` | number | Amount to insure in USDC |
| `durationDays` | number | Policy duration (within product range) |
| `threshold` | number | Trigger threshold (from product options, in bps or gwei) |
| `asset` | string | Asset to cover (ETH, BTC, USDC, etc.) |

**Response:**
```json
{
  "quoteId": "QT-a1b2c3",
  "premium": 460,
  "premiumBps": 460,
  "maxPayout": 9500,
  "deductible": "5%",
  "trigger": "ETH/USD drops >20% (instant Chainlink reading)",
  "termsHash": "0xabc123def456...",
  "expiresIn": "15 minutes",
  "expiresAt": "2026-03-04T19:00:00Z"
}
```

**Quote expires in 15 minutes.** After that, request a new quote.

---

### `POST /api/v1/purchase`
**Auth required:** Yes

Confirm a policy purchase after completing the on-chain transaction.

**Request:**
```json
{
  "quoteId": "QT-a1b2c3",
  "txHash": "0x..."
}
```

**Response:**
```json
{
  "policyId": "POL-001",
  "status": "active",
  "autoResolve": true,
  "monitoring": "AutoResolver + Chainlink ETH/USD",
  "coverage": 10000,
  "premium": 460,
  "maxPayout": 9500,
  "trigger": "ETH/USD drops >20% (instant Chainlink reading)",
  "expiresAt": "2026-04-03T00:00:00Z",
  "txHash": "0x...",
  "baseScanUrl": "https://basescan.org/tx/0x..."
}
```

---

### `GET /api/v1/policy/:policyId`
**Auth required:** Yes

Check status of a specific policy.

**Response:**
```json
{
  "policyId": "POL-001",
  "status": "active",
  "product": "LIQSHIELD-001",
  "coverage": 10000,
  "premium": 460,
  "maxPayout": 9500,
  "trigger": "ETH/USD drops >20% (instant Chainlink reading)",
  "currentPrice": 3245.67,
  "triggerPrice": 2596.54,
  "distanceToTrigger": "20.0%",
  "expiresAt": "2026-04-03T00:00:00Z",
  "daysRemaining": 30,
  "resolution": null
}
```

**Policy statuses:** `active`, `expired`, `triggered`, `resolved`, `paid`

---

### `GET /api/v1/agent/dashboard`
**Auth required:** Yes

Complete overview of all agent activity.

**Response:**
```json
{
  "agentId": "AGT-xxxx",
  "totalPolicies": 3,
  "activePolicies": 2,
  "totalPremiumsPaid": 890,
  "totalPayoutsReceived": 0,
  "policies": [
    {
      "policyId": "POL-001",
      "product": "LIQSHIELD-001",
      "status": "active",
      "coverage": 10000,
      "premium": 460,
      "expiresAt": "2026-04-03T00:00:00Z"
    }
  ],
  "monthlySpend": 890,
  "monthlyLimit": 2000,
  "remainingBudget": 1110
}
```

---

## Error Responses

All errors follow this format:
```json
{
  "error": "error_code",
  "message": "Human-readable description",
  "details": {}
}
```

| Status | Error Code | Description |
|---|---|---|
| 400 | `invalid_params` | Missing or invalid request parameters |
| 400 | `quote_expired` | Quote has passed 15-minute window |
| 400 | `product_not_found` | Invalid product ID |
| 400 | `threshold_invalid` | Threshold not in product's allowed options |
| 400 | `duration_out_of_range` | Duration outside product's min/max |
| 400 | `amount_out_of_range` | Coverage amount outside limits |
| 401 | `unauthorized` | Missing or invalid API key |
| 403 | `product_not_allowed` | Product not in agent's allowed list |
| 403 | `budget_exceeded` | Monthly spend limit would be exceeded |
| 403 | `coverage_exceeded` | Coverage exceeds per-policy maximum |
| 429 | `rate_limited` | Too many requests. Retry with backoff. |
| 500 | `internal_error` | Server error. Retry. |

---

## Rate Limits

- **Products:** 60 requests/minute (no auth)
- **Quote:** 30 requests/minute (per API key)
- **Purchase:** 10 requests/minute (per API key)
- **Policy/Dashboard:** 60 requests/minute (per API key)
- **Health:** No limit

Use exponential backoff on 429 responses.
