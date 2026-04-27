# 03 — Architecture diagram

ASCII flow for a typical end-to-end purchase. Read top-to-bottom; arrows = call direction; labels = data carried.

## Happy path: agent buys a 1 000 USDC FlashBTC1H policy

```
 ┌──────────────────┐
 │  AI agent / CLI  │
 │  wallet 0xBEEF…  │   1) once per agent: cast send USDC.approve(coverRouter, MAX)
 └────────┬─────────┘   2) per purchase: HTTPS POST /api/v1/policies + x-api-key + Idempotency-Key
          │
          │ HTTPS  TLS 1.3
          ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  Railway edge proxy (TLS termination, X-Forwarded-For)           │
 └────────┬─────────────────────────────────────────────────────────┘
          │ HTTP
          ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  Express app (single Node 20 process)                            │
 │                                                                  │
 │   helmet + JSON parser (32 KB cap)                              │
 │     │                                                            │
 │     ▼                                                            │
 │   rate-limit (per-tier, keyed by agent.id)                       │
 │     │                                                            │
 │     ▼                                                            │
 │   authMiddleware                                                 │
 │     │   sha256(plaintext) ──┐                                    │
 │     │                        ▼                                   │
 │     │   ┌─────────────────────────────┐                          │
 │     │   │  better-sqlite3             │                          │
 │     │   │   api_keys / agents         │  read                    │
 │     │   │   policies / idempotency    │                          │
 │     │   └─────────────────────────────┘                          │
 │     ▼                                                            │
 │   route handler  POST /api/v1/policies                           │
 │     │                                                            │
 │     │  zod validate body (productId, coverage, asset, buyer)     │
 │     │  idempotency lookup (return cached if hit)                 │
 │     │                                                            │
 │     ▼                                                            │
 │   service: purchaseViaRelayer(input)                             │
 │     │                                                            │
 │     │  pre-flight  ─→  CoverRouterV2.authorizedRelayers(relayer) │
 │     │  if false  → 503 relayer_unauthorized                      │
 │     │                                                            │
 │     │  ethers.Wallet(relayerKey, provider)                       │
 │     │    .CoverRouterV2.purchasePolicyFor(productId, coverage,   │
 │     │                                      asset, buyer)         │
 │     │                                                            │
 │     ▼                                                            │
 └─────┼──────────────────────────────────────────────────────────┘
       │
       │ JSON-RPC (eth_estimateGas, eth_sendRawTransaction, …)
       ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  Alchemy Base Sepolia (chainId 84532)                            │
 │                                                                  │
 │       CoverRouterV2 (proxy 0x60447F88…)                          │
 │         │                                                        │
 │         │  authorizedRelayers[msg.sender] check                  │
 │         │  USDC.safeTransferFrom(buyer, this, premium)  ← FIX #86│
 │         │  USDC.forceApprove(twapBurner, premium)                │
 │         │  TWAPBurner.receivePremium(premium)                    │
 │         │  PolicyManagerV2.recordPolicy(productId, buyer, …)     │
 │         │     ├─→ IShield.createPolicy({buyer, …})               │
 │         │     └─→ pr.buyer = buyer                               │
 │         └─→ emit PolicyPurchased(productId, policyId, buyer,     │
 │                                  coverage, premium, payout,      │
 │                                  payer=msg.sender)               │
 │                                                                  │
 └────────┬─────────────────────────────────────────────────────────┘
          │ tx receipt
          ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │  Express app (continuation)                                      │
 │     │                                                            │
 │     │  decode PolicyCreated event from receipt                   │
 │     │  → policyId, premiumPaid                                   │
 │     │                                                            │
 │     │  recordPolicy() → INSERT into policies (local mirror)      │
 │     │  saveIdempotency(key, agent_id, response) if key supplied  │
 │     │                                                            │
 │     │  pino.info({ productId, buyer, txHash }, "purchase ok")    │
 │     │                                                            │
 │     ▼                                                            │
 │  201 { ok, txHash, blockNumber, policyId, buyer, productId,      │
 │        coverageAmount, premiumPaid }                             │
 └──────────────────────────────────────────────────────────────────┘
```

## What a malicious caller sees

```
┌──────────────────────┐
│  Attacker            │
│  no API key          │
└──────────┬───────────┘
           │ POST /api/v1/policies (no header)
           ▼
   authMiddleware → 401 missing_api_key
   (request never touches RPC)

┌──────────────────────┐
│  Attacker            │
│  forged "lk_<…>" key │
└──────────┬───────────┘
           │ POST /api/v1/policies + x-api-key: lk_<random>
           ▼
   sha256(plaintext) → not in api_keys WHERE revoked_at IS NULL
   → 401 invalid_api_key

┌──────────────────────────┐
│  Authorized agent A      │
│  trying to buy for B     │
└──────────┬───────────────┘
           │ POST /api/v1/policies + x-api-key: <A's key>
           │ body: { …, buyer: 0xBOB }
           ▼
   passes auth + rate-limit + zod
   → CoverRouterV2.purchasePolicyFor(…, buyer=0xBOB)
   → safeTransferFrom(0xBOB, …) 
   → reverts ERC-20 InsufficientAllowance because BOB never approved.
   → 400 tx_submit_failed (no funds touched)
```

## Failure modes mapped to status codes

| Failure | Where caught | HTTP |
|---|---|---|
| missing API key | `auth.ts` | 401 missing_api_key |
| malformed API key (bad prefix / too short) | `auth.ts` | 401 invalid_api_key |
| revoked API key | DB lookup excludes by index | 401 invalid_api_key |
| body too large (> 32 KB) | `express.json` limit | 413 |
| unknown JSON shape | zod | 400 validation_error + details |
| `buyer` not a 0x address | zod refinement | 400 validation_error |
| rate limit exceeded | express-rate-limit | 429 rate_limited |
| relayer not yet authorised on-chain | `policies.service.ts` pre-flight | 503 relayer_unauthorized |
| revert at estimateGas | ethers throws → `policies.service.ts` catch | 400 tx_submit_failed (with on-chain reason) |
| tx mined with status=0 | `policies.service.ts` after `tx.wait()` | 502 tx_reverted |
| RPC unreachable | ethers throws → error middleware | 500 internal_error |
| missing admin token | `admin.ts` | 401 missing_admin_token |
| wrong admin token | `admin.ts` (timing-safe equal) | 401 invalid_admin_token |
| wallet has 3 keys, asks for 4th | `services/keys.ts` | 409 key_limit_reached |
