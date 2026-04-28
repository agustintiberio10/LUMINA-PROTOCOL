# 01 — Auth & Rate-limit inventory

Scope: deep audit of `org-lumina/lumina-api@main` authentication and rate-limit machinery, beyond the surface checks in audit #33. Source files referenced are post-PR #1 + PR #2 (RL-1 + LOW-1 + INV-1 fixes already merged).

## API key flow

| Stage | Code path | Notes |
|---|---|---|
| **Generation** | `services/keys.ts:issueKey()` | ① validate wallet (`ethers.isAddress`) ② `findOrCreateAgent(wallet)` ③ enforce `countActiveKeys ≤ 3` ④ `randomBytes(32).toString('hex')` for entropy ⑤ `lk_<hex>` plaintext returned ONCE ⑥ SHA-256 hash stored in `api_keys.key_hash` |
| **Storage** | `db/database.ts` | SQLite via `better-sqlite3`. Index on `(key_hash) WHERE revoked_at IS NULL`. Prepared statements throughout — parameterised, no SQL injection surface. |
| **Validation** | `middlewares/auth.ts:authMiddleware()` | Reads `req.header("x-api-key")`, prefix-checks `lk_`, hashes with SHA-256, looks up in DB. On match: attaches `req.agent = { id, wallet, tier, keyId }`. On miss: `next(new HttpError(401))`. |
| **Revocation** | `services/keys.ts:revoke(id)` + `db/database.ts:revokeKey(id)` | Soft delete (sets `revoked_at`); index excludes revoked rows so subsequent lookups miss without an explicit WHERE clause |
| **Limit per wallet** | `services/keys.ts` | Hard-coded constant `MAX_KEYS_PER_WALLET = 3`. Enforced at issue-time only; existing keys are not pruned when limit changes. |

### Key entropy

`randomBytes(32)` produces 256 bits of cryptographically secure randomness. The plaintext space is 2^256, so brute-force is computationally infeasible (the entire universe's atom-time is ~2^200). SHA-256 is appropriate here: keys are HIGH-entropy opaque tokens (not low-entropy passwords), so bcrypt/argon2 work-factor adds nothing — see audit decision DEC-1 in REPORT.md.

## Admin token flow

| Stage | Code path | Notes |
|---|---|---|
| **Storage** | `process.env.ADMIN_TOKEN`, validated by zod (`min(32)`) | At-least 32-char string, set in Railway secrets |
| **Validation** | `middlewares/admin.ts:adminAuth()` | Reads `req.header("x-admin-token")`, ⚠️ **uses `crypto.timingSafeEqual` for comparison** — constant-time, immune to timing attacks. Buffer length-mismatch returns 401 before the equal call. |
| **Endpoints** | `POST /api/v1/keys/generate`, `DELETE /api/v1/keys/:id` | Both gated by `adminAuth + adminLimiter`. Admin is per-IP rate-limited at 20 req/min. |

## Rate-limit flow

Post-RL-1 fix (PR #1), middleware order on `/api/v1/policies` is:

```ts
policiesAuthRouter.post("/", authMiddleware, apiLimiter, ...)
policiesAuthRouter.get("/",  authMiddleware, apiLimiter, ...)
```

`apiLimiter` configuration (`middlewares/rateLimit.ts`):

| Property | Value |
|---|---|
| Store | `MemoryStore` (default — process-local Map; lost on restart) |
| Window | 60 000 ms (1 min) |
| `max` | dynamic per request: `paid → 100`, `free → 10` (defaults from env, overridable per request) |
| `keyGenerator` | `req.agent ? agent:${id} : ip:${ip}`. Since auth runs first, authenticated requests are keyed per agent. |
| `standardHeaders` | `draft-7` |
| `legacyHeaders` | false |

Admin-side limiter (`adminLimiter`):

| Property | Value |
|---|---|
| Window | 60 000 ms |
| `max` | 20 |
| Key | `ip:${ip}` (always, no agent on admin path) |

## Public-route exposure

| Path | Auth | Rate-limit |
|---|---|---|
| `GET /health` | none | **none** |
| `GET /products` | none | **none** |
| `GET /products/:id` | none | **none** |
| `GET /products/:id/quote` | none | **none** |
| `GET /policies/:productId/:policyId` | none | **none** |

⚠️ **No rate-limit at all on public reads.** A sustained flood costs the API process CPU + the upstream RPC budget. See finding **PUB-RL-1** in REPORT.md.

## Idempotency cache

| Aspect | Implementation |
|---|---|
| Scope | `POST /api/v1/policies` only |
| Key | `Idempotency-Key` header (free-form string, agent-scoped) |
| Storage | SQLite `idempotency` table — `(key TEXT PRIMARY KEY, agent_id INTEGER, response_json TEXT, created_at INTEGER)` |
| TTL | **none** — entries persist indefinitely |
| Replay rule | Same `(key, agent_id)` returns cached body bytes-for-bytes; different bodies under same key are silently ignored (cached body wins) |

⚠️ **No TTL** — long-running deploy accumulates rows forever; on a Railway Volume that's bounded but still ugly. See finding **IDEM-TTL** in REPORT.md.

## Failed-auth path is not rate-limited

When `authMiddleware` calls `next(error)` (any 401), Express skips ahead to the error handler. `apiLimiter` never runs for that request. So a flooder sending invalid API keys is bound only by the public-IP RPC limit (none here) and the SQLite hash-lookup cost.

This is **MEDIUM** — see finding **AUTH-FLOOD** in REPORT.md.

## What is locked down vs what is not

| Concern | Status |
|---|---|
| API key brute force (against `lk_<256-bit-random>` keyspace) | INFEASIBLE — 2^256 keyspace |
| Admin token timing attack | ✅ HARDENED — `timingSafeEqual` |
| API key timing attack | ✅ HARDENED — DB lookup is indexed; both miss/hit go through the same code path |
| SQL injection on x-api-key | ✅ HARDENED — `better-sqlite3` parameterised statements; the hash is computed from the input first, so the input never appears in the SQL |
| Per-tier rate limit | ✅ POST RL-1 (per-agent counters work) |
| Per-IP rate limit on public routes | ❌ NONE |
| Per-IP rate limit on failed auth | ❌ NONE |
| Idempotency TTL | ❌ NONE (rows accumulate) |
| Multiple `x-api-key` headers | ⚠️ Express joins with `, `; the joined value fails the `lk_` prefix check ⇒ 401. Safe in practice. |
| Cookies / `Authorization: Bearer` | ✅ IGNORED — only `x-api-key` is read |
| Path traversal | ✅ Express normalises before route match |
| CORS | ⚠️ no explicit CORS middleware. Browsers respect same-origin by default; `helmet()` adds defaults but not CORS. The API is consumed primarily by server-side AI agents, not browsers, so this is mostly fine. INFO finding. |

## Source code references

- `src/middlewares/auth.ts` — API key middleware (post-INV-1 + post-RL-1)
- `src/middlewares/admin.ts` — admin token middleware (uses `timingSafeEqual`)
- `src/middlewares/rateLimit.ts` — `apiLimiter` and `adminLimiter`
- `src/services/keys.ts` — `issueKey()`, `revoke()`, `MAX_KEYS_PER_WALLET = 3`
- `src/db/database.ts` — `findActiveKeyByHash`, `countActiveKeys`, `findIdempotency`, `saveIdempotency`
- `src/routes/policies.ts` — `policiesAuthRouter` middleware order
- `src/routes/keys.ts` — `keysRouter` admin-gated
- `src/routes/health.ts`, `src/routes/products.ts`, `src/routes/policies.ts` — public reads (no rate limit)
