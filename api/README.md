# Lumina Protocol — M2M Insurance REST API

Public REST API for autonomous agents to quote, purchase, and track parametric insurance coverage on Base L2.

## Architecture

```
lumina-api/
├── src/
│   ├── index.ts                    # Server entry point (Fastify + plugins)
│   ├── controllers/
│   │   └── insurance.controller.ts # Request handling + validation
│   ├── services/
│   │   ├── insurance.service.ts    # Business logic (quote, issue, status)
│   │   └── risk.service.ts         # Premium calculation engine
│   ├── routes/
│   │   └── insurance.routes.ts     # Endpoint registration
│   ├── types/
│   │   ├── insurance.ts            # TypeScript interfaces
│   │   └── schemas.ts              # Zod validation schemas
│   ├── middleware/                  # TODO: Auth, logging, API keys
│   └── utils/
│       └── config.ts               # Environment + constants
├── package.json
├── tsconfig.json
├── .env.example
└── README.md
```

## Quick Start

```bash
# Install
npm install

# Development (hot reload)
npm run dev

# Production build
npm run build
npm start
```

## Endpoints

### `GET /health`
Health check + contract addresses.

### `GET /api/v1`
API info, supported operations, and contract metadata.

### `POST /api/v1/cotizar`
Get a coverage quote.

```bash
curl -X POST http://localhost:3100/api/v1/cotizar \
  -H "Content-Type: application/json" \
  -d '{
    "coverageType": "depeg",
    "protocol": "aave",
    "coverageAmount": 10000,
    "durationDays": 14
  }'
```

Response:
```json
{
  "quoteId": "QT-a1b2c3d4e5f6",
  "coverageType": "depeg",
  "protocol": "aave",
  "coverageAmount": 10000,
  "durationDays": 14,
  "premium": 459.08,
  "premiumRate": 459,
  "riskLevel": "medium",
  "deadline": "2026-03-16T...",
  "quoteExpiresAt": "2026-03-02T...",
  "warnings": [],
  "metadata": {
    "chain": "Base L2 (8453)",
    "token": "USDC",
    "contract": "0x1c5E...bd7",
    "disputeResolver": "0x2e4D...09cA",
    "feeModel": "3% protocol fee on resolution"
  }
}
```

### `POST /api/v1/emitir`
Issue a policy from a confirmed quote.

```bash
curl -X POST http://localhost:3100/api/v1/emitir \
  -H "Content-Type: application/json" \
  -d '{
    "quoteId": "QT-a1b2c3d4e5f6",
    "txHash": "0x1234...abcd",
    "payerAddress": "0xYourWallet..."
  }'
```

### `GET /api/v1/estado/:id`
Check policy status.

```bash
curl http://localhost:3100/api/v1/estado/POL-x1y2z3w4v5u6
```

## Stack

| Layer | Choice | Reason |
|-------|--------|--------|
| Runtime | Node.js + TypeScript (strict) | Type safety for M2M |
| Framework | Fastify | 2-3x faster than Express |
| Validation | Zod | Runtime + compile-time safety |
| Security | helmet + rate-limit + CORS | DDoS + abuse prevention |

## On-Chain Integration

| Contract | Address | Role |
|----------|---------|------|
| MutualLumina | `0x1c5E5c90aC46e960aACbfCeAE9dEC2F79ce06bd7` | Insurance pools |
| DisputeResolver | `0x2e4D0112A65C2e2DCE73e7F85bF5C2889c7709cA` | 24h dispute window |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | Payment token |

## TODO (Production Roadmap)

- [ ] PostgreSQL + Prisma ORM (replace in-memory Maps)
- [ ] Redis cache for hot quote lookups
- [ ] JWT / API-key authentication
- [ ] On-chain tx verification (ethers.js)
- [ ] Automatic pool creation via createAndFund()
- [ ] Webhook system for policy lifecycle events
- [ ] OpenAPI/Swagger documentation
- [ ] Blockchain event listener for status sync
- [ ] Cloudflare deployment for DDoS protection

## Risk Engine

Premium formula matches on-chain oracle:
```
premiumRateBps = (baseRate + frequency × riskMultiplier) × protocolAdj × durationAdj × amountAdj
```

Adjustments:
- **Protocol**: Known protocols (Aave, Compound) get lower rates. Unknown = 1.2x
- **Duration**: 1-7d = 0.85x, 8-14d = 0.92x, 15-30d = 1.0x, 31-90d = 1.15x
- **Amount**: >$100K = 0.90x (volume discount), <$100 = 1.20x

## License

MIT
