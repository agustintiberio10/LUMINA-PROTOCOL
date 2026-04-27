# 01 — API endpoint inventory

Source: `org-lumina/lumina-api@main`, file-by-file from `src/routes/`.
Live deployment: <https://lumina-api-production-ac85.up.railway.app>.
9 endpoints total, grouped by auth tier.

## Convention

- Bytes32 hex literals are 0x + 64 hex chars (66 chars total).
- USDC amounts are integer **base units** (6 decimals). 1 USDC = 1 000 000.
- All write endpoints accept an optional `Idempotency-Key` header.

---

## Public — no auth

### 1. `GET /health`
| | |
|---|---|
| File | `src/routes/health.ts` |
| Auth | none |
| Rate limit | none |
| Request | — |
| Response 200 | `{ status, service, version, uptimeSeconds, chain: { chainId, block, rpcConnected }, relayer: { address, balanceWei }, contracts: {...} }` |
| Errors | 5xx if RPC unreachable (returned as `internal_error`) |
| Smart-contract calls | `provider.getBlockNumber()`, `provider.getBalance(relayer)`, `provider.getNetwork()` |

### 2. `GET /products`
| | |
|---|---|
| File | `src/routes/products.ts` |
| Auth | none |
| Rate limit | none |
| Request | — |
| Response 200 | `{ count, products: [{ productId, shield, payoutRatioBps, triggerProbBps, marginBps, durationSeconds, active }] }` |
| Errors | 5xx if RPC unreachable |
| Contract | `CoverRouterV2.getProductCount()`, `CoverRouterV2.productList(i)`, `CoverRouterV2.products(productId)`, `PolicyManagerV2.productShield(productId)` |

### 3. `GET /products/:productId`
| | |
|---|---|
| File | `src/routes/products.ts` |
| Auth | none |
| Rate limit | none |
| Path schema | `productId` is bytes32 hex |
| Response 200 | `ProductDto` (same as in /products array) |
| Errors | 400 invalid productId; 404 product_not_found; 5xx |
| Contract | `PolicyManagerV2.productActive(...)`, `PolicyManagerV2.productShield(...)`, `CoverRouterV2.products(...)` |

### 4. `GET /products/:productId/quote?coverageAmount=N`
| | |
|---|---|
| File | `src/routes/products.ts` |
| Auth | none |
| Rate limit | none |
| Path | `productId` bytes32 hex |
| Query | `coverageAmount` positive integer string (USDC base units) |
| Response 200 | `{ productId, coverageAmount, premium, payout }` |
| Errors | 400 validation_error |
| Contract | `CoverRouterV2.quotePremium(productId, coverageAmount)` |

### 5. `GET /policies/:productId/:policyId`
| | |
|---|---|
| File | `src/routes/policies.ts` (publicRouter) |
| Auth | none |
| Rate limit | none |
| Path | `productId` bytes32 hex; `policyId` positive integer string |
| Response 200 | `{ productId, policyId, shield, buyer, coverageAmount, payoutAmount, premiumPaid, createdAt, expiresAt, triggered, expired }` |
| Errors | 400 validation_error; 404 policy_not_found |
| Contract | `PolicyManagerV2.policies(productId, policyId)` (struct returned via tuple-position decoding documented in source) |

---

## Authenticated — `x-api-key: lk_<...>`

The header is required. The plaintext is hashed with SHA-256 and looked up in the SQLite `api_keys` table; revoked rows are excluded by index. The matching agent attaches at `req.agent = { id, wallet, tier, keyId }`.

Rate limits per `req.agent.tier`:
- `free` — 10 req/min
- `paid` — 100 req/min

Limiter window is keyed by `agent:<id>` (or `ip:<x>` if no agent). 429 returned when exceeded.

### 6. `POST /api/v1/policies`
| | |
|---|---|
| File | `src/routes/policies.ts` (authRouter) |
| Auth | `x-api-key` |
| Rate limit | tier-based |
| Body schema (zod) | `{ productId: bytes32, coverageAmount: int-string, asset: bytes32, buyer: 0x address }` |
| Optional header | `Idempotency-Key` (free-form string; cached response returned 200 if same `(key, agent_id)` seen before) |
| Response 201 | `{ ok: true, txHash, blockNumber, policyId, buyer, productId, coverageAmount, premiumPaid }` |
| Response 200 | (only on idempotent replay) cached body |
| Errors | 400 validation_error / tx_submit_failed; 401 invalid_api_key; 502 tx_reverted; 503 relayer_unauthorized; 429 rate_limited |
| Contract | `coverRouterRelayer.purchasePolicyFor(productId, coverageAmount, asset, buyer)` — pre-flight check via `coverRouterRelayer.authorizedRelayers(relayer.address)` |
| DB writes | inserts into `policies` and (if idempotency) `idempotency` |

### 7. `GET /api/v1/policies?owner=0x...`
| | |
|---|---|
| File | `src/routes/policies.ts` (authRouter) |
| Auth | `x-api-key` |
| Rate limit | tier-based |
| Query | optional `owner` (0x address); defaults to caller's `req.agent.wallet` |
| Response 200 | `{ owner, count, policies: [...] }` (rows from local SQLite mirror, NOT live chain reads) |
| Errors | 400 validation_error; 401 invalid_api_key; 429 |
| Contract | none — purely a DB query against `policies` table |
| **IDOR caveat** | endpoint allows querying ANY `owner` address, including ones the caller does not own. See finding INV-1 in REPORT.md. |

---

## Admin — `x-admin-token`

Constant-time compared against `process.env.ADMIN_TOKEN`. 32+ char secret, set in Railway. IP-keyed rate limit at 20 req/min for the whole admin surface.

### 8. `POST /api/v1/keys/generate`
| | |
|---|---|
| File | `src/routes/keys.ts` |
| Auth | `x-admin-token` |
| Rate limit | 20 req/min by IP |
| Body schema (zod) | `{ wallet: 0x address, label?: string ≤64 }` |
| Response 201 | `{ ok, keyId, apiKey: "lk_<64hex>", wallet, tier, label, createdAt, warning: "Store the apiKey now. It will not be shown again." }` |
| Errors | 400 validation_error / invalid_wallet; 401 missing_admin_token / invalid_admin_token; 409 key_limit_reached (wallet already at max=3) |
| DB writes | `agents` (find-or-create) + `api_keys` (insert hash only; plaintext never persisted) |

### 9. `DELETE /api/v1/keys/:id`
| | |
|---|---|
| File | `src/routes/keys.ts` |
| Auth | `x-admin-token` |
| Rate limit | 20 req/min by IP |
| Path | `id` positive integer (key id) |
| Response | 204 no content on success |
| Errors | 400 invalid_id; 401 missing_admin_token / invalid_admin_token; 404 key_not_found |
| DB writes | sets `revoked_at` on `api_keys` row |

---

## Cross-cutting concerns

| Concern | Implementation |
|---|---|
| Body parser | `express.json({ limit: "32kb" })` — requests > 32 KB rejected at the parser |
| Security headers | `helmet()` on every route |
| Trust proxy | `app.set("trust proxy", 1)` so `req.ip` reflects client behind Railway |
| Logging | `pino` JSON-structured; level from `LOG_LEVEL`; pretty-print only in `NODE_ENV=development` |
| Error envelope | `{ error: "<code>", message?: "...", details?: [...] }` for every non-2xx |
| Validation | `zod` schemas at the route level; failures surface as `400 validation_error` with `details[]` |
| Idempotency | only on `POST /api/v1/policies`; key + `(agent_id, key)` unique; cached body bytes-for-bytes |
| Smart-contract state | read on demand for products/policies/health; written via relayer for purchases |
| Persistence | SQLite at `DB_PATH`. **Ephemeral on Railway with default `/tmp/...`** — wiped on every redeploy. See finding ARCH-1. |
