# Lumina Protocol Documentation

> **Parametric insurance for autonomous AI agents on Base L2.**  
> Chainlink-verified triggers. Automatic payouts. No claims. No disputes.

---

## For AI Agents

Your agent needs to understand Lumina to operate with it. Start here:

| Document | What It Covers |
|---|---|
| **[QUICK-START.md](./QUICK-START.md)** | Get insured in 5 minutes. Registration → Quote → Purchase. |
| **[SKILL-lumina-insurance.md](./SKILL-lumina-insurance.md)** | Complete skill definition. Products, formulas, workflows, FAQ. **Give this to your agent.** |
| **[API-REFERENCE.md](./API-REFERENCE.md)** | Every endpoint, request/response format, error codes, rate limits. |

## For Developers

Building an agent that uses Lumina? Pick your framework:

| Document | What It Covers |
|---|---|
| **[INTEGRATION-GUIDES.md](./INTEGRATION-GUIDES.md)** | Step-by-step for Virtuals (ACP), ElizaOS (plugin), LangChain (tools), and generic HTTP agents. |

## For Business

Understanding Lumina's distribution and go-to-market:

| Document | What It Covers |
|---|---|
| **[SALES-CHANNELS.md](./SALES-CHANNELS.md)** | All 5 channels: API Direct, Web Dashboard, Natural Language, ACP Marketplace, Framework Plugins. |

---

## Architecture

```
Human Owner                    AI Agent                     Lumina Protocol
─────────────                  ────────                     ───────────────
Register agent ──────────────→ Receives API key
Set limits     ──────────────→ Operates within limits
                               GET /products ──────────────→ Returns 8 products
                               POST /quote ────────────────→ Returns premium
                               approve USDC (on-chain) ───→ USDC contract
                               createPool (on-chain) ─────→ MutualLumina
                               POST /purchase ─────────────→ Policy active
                               
                               ... time passes ...
                               
Monitor dashboard              AutoResolver reads Chainlink continuously
                               Trigger detected? ──────────→ proposeResolution()
                               24h timelock ────────────────→ executeResolution()
                               USDC arrives in wallet ←────  Automatic payout
```

**Key principle:** Humans configure and monitor. Agents buy and claim. Resolution is fully automatic.

---

## Live Infrastructure

| Component | Address / URL |
|---|---|
| API | `https://moltagentinsurance-production-6e3d.up.railway.app` |
| MutualLumina | [`0x1c5Ec90aC46e960aACbfCeAE9d6C2F79ce806b07`](https://basescan.org/address/0x1c5Ec90aC46e960aACbfCeAE9d6C2F79ce806b07) |
| AutoResolver | [`0x8D919F0BEf46736906e190da598570255FF02754`](https://basescan.org/address/0x8D919F0BEf46736906e190da598570255FF02754) |
| DisputeResolver | [`0x2e4D0112A65C2e2DCE73e7F85bF5C2889c7709cA`](https://basescan.org/address/0x2e4D0112A65C2e2DCE73e7F85bF5C2889c7709cA) |
| Chain | Base L2 (8453) |
| Settlement | USDC |
| Terms Version | 1.2.0 |

---

## 8 Products

| ID | Name | Trigger | Premium | Duration |
|---|---|---|---|---|
| LIQSHIELD-001 | Liquidation Shield | Price drop % (instant) | 2.5-12% | 7-90d |
| DEPEG-USDC-001 | USDC Depeg Cover | Price below $ | 1.3-6% | 14-365d |
| DEPEG-USDT-001 | USDT Depeg Cover | Price below $ | 1.7-7.8% | 14-365d |
| DEPEG-DAI-001 | DAI Depeg Cover | Price below $ | 1.6-7.2% | 14-365d |
| ILPROT-001 | IL Protection | Price divergence | 3.5-10% | 14-60d |
| GASSPIKE-001 | Gas Spike Shield | Gas above gwei | 1.7-5.5% | 7-30d |
| SLIPPAGE-001 | Slippage Protection | Price move % | 1.3-7% | 1-7d |
| BRIDGE-001 | Bridge Failure Cover | No transfer | 3% fixed | 365d |

---

## License

Lumina Protocol © 2026. All rights reserved.
