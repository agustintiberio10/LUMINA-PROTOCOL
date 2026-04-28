# Audit V5.1 #36 — AUTH & RATE-LIMIT (DEEP) — REPORT

## Scope

Beyond audit #33's surface checks (missing header, malformed prefix, basic SQLi). This deep audit targets adversarial techniques: brute force, timing, race, replay, key-leakage, bypass paths, rate-limit edges, and admin-token end-to-end. Real-contract tests in `org-lumina/lumina-api`.

Companion docs:
- `01-AUTH-INVENTORY.md` — auth surface mapped end-to-end

## Findings

### CRITICAL — none

### HIGH — none

### MEDIUM

| # | Title | Location | Recommendation |
|---|---|---|---|
| **PUB-RL-1** | Public read endpoints (`/health`, `/products`, `/products/:id`, `/products/:id/quote`, `/policies/:productId/:policyId`) have **no rate limit at all**. A sustained flood costs the API process CPU + the upstream RPC budget. Confirmed by test `tests/security/auth-deep.test.ts › rate-limit deep › public routes have NO rate limit`. | `src/app.ts`, public route mounts | Add an IP-based limiter (loose — e.g. 120 req/min) on public routes |
| **AUTH-FLOOD** | Failed-auth requests do not run through `apiLimiter` because `authMiddleware` calls `next(error)` and Express skips ahead. A flooder sending invalid `x-api-key`s is bound only by the SQLite hash-lookup cost. The DB stays healthy but the API process consumes CPU. Confirmed by test `failed-auth requests do not consume the agent's rate-limit budget`. | `src/middlewares/auth.ts`, route mounts | Add an IP-keyed limiter BEFORE `authMiddleware` on `/api/v1/*` routes; e.g. 60 req/min/IP for failed paths |

### LOW

| # | Title | Status |
|---|---|---|
| **IDEM-TTL** | Idempotency cache rows in SQLite have no TTL. Long-running deploy accumulates rows forever. With the Railway Volume now in place (post-ARCH-1 fix), disk bloat is bounded but ugly; without one, the in-process file would grow. | OPEN — recommend a sweep on boot or a CRON-style sweep (`DELETE FROM idempotency WHERE created_at < strftime('%s','now') * 1000 - 7*86400000`) |

### INFO

| # | Note |
|---|---|
| **DEC-1** | API keys hashed with SHA-256 (not bcrypt/argon2). This is **the correct choice for opaque tokens**: keys come from `randomBytes(32)` (256 bits of entropy), so brute-force needs 2^256 attempts regardless of work factor. Bcrypt's value is for low-entropy human passwords. Documented to defend the architectural choice. |
| **DEC-2** | Admin token compared with `crypto.timingSafeEqual` after a length check. Timing-attack resistant. ✓ |
| **DEC-3** | The DB lookup for API keys is an indexed SHA-256 equality probe via `better-sqlite3` prepared statement. Both miss and hit go through the same index path; timing attack on key prefix is not viable. Test `timing attack resistance` confirms median response times are within 50% of each other (Express + event-loop noise dominates). |
| **DEC-4** | Race conditions on key generation are not exploitable: Node + `better-sqlite3` are synchronous, so each request handler runs to completion before another starts. Test `5 concurrent generate calls — never exceeds 3 active` confirms the cap holds. |
| **DEC-5** | Route handler **does** ignore `Authorization: Bearer ...` and cookies; only `x-api-key` is read. Confirmed by tests. |
| **DEC-6** | Multi-valued `x-api-key` header is joined by Node into a comma-separated string, which fails the `lk_` prefix check ⇒ 401. Safe by accident, but documented so a future change cannot regress it silently. |
| **DEC-7** | No CORS middleware. The API is consumed by server-side AI agents, not browsers; same-origin is the default. If a browser-side dashboard ever hits these endpoints, an explicit `cors()` config will be needed. |

## Tests added (`tests/security/auth-deep.test.ts`)

**25 tests, 8 describe blocks, all passing.**

| Block | # | What it asserts |
|---|---|---|
| brute force protection | 2 | 50 random keys all 401 in <15s; partial-prefix probe returns same shape as fully-random |
| timing attack resistance | 1 | median response time of valid-prefix vs random keys is within 50% |
| race conditions | 2 | 5 concurrent generates never exceed 3 active; revoke-while-in-use is graceful |
| replay & idempotency edges | 1 | idempotency cache is partitioned per `(key, agent_id)` — no cross-agent replay |
| API key leakage prevention | 4 | error response, response headers, validation_error details, OPTIONS preflight all leak nothing |
| auth bypass attempts | 7 | multi-header, path-traversal, traversal/jndi/html payloads, Bearer, Cookie all rejected |
| rate-limit deep | 3 | free-tier ceiling = 10, public routes UNCAPPED (confirms PUB-RL-1), failed-auth doesn't consume budget (confirms AUTH-FLOOD) |
| admin token security | 5 | missing/wrong-length/wrong-content/lk_-as-token all 401; admin token never echoed in error/log paths |

## Verification

```
$ npx jest --forceExit
Test Suites: 1 skipped, 10 passed, 10 of 11 total
Tests:       4 skipped, 85 passed, 89 total
```

(60 baseline + 25 new = 85 standard tests passing. The 4 skipped are the live-Sepolia E2E suite from audit #33.)

## Quality

**9 / 10**

- Inventory exhaustive ✓ (every middleware in the auth path traced)
- Tests are real-contract — no mock-PolicyManager shortcuts where it matters
- Two real findings (PUB-RL-1, AUTH-FLOOD) flagged with concrete recommended fixes; both are MEDIUM (DoS amplification), no CRITICAL surface
- −1 because the recommended fixes were not applied in this audit pass (would expand scope past "audit"); follow-up PR should land them and re-run the suite

## Verdict

**SECURE for current operations.** No bypass, no key leakage, no exploitable race, no timing attack. The MEDIUM findings (PUB-RL-1, AUTH-FLOOD) are about denial-of-service amplification on public/failed-auth paths — they do not allow an attacker to gain access or steal funds. They should be addressed in a follow-up PR.

### Priority for the operator

1. **AUTH-FLOOD** — add an IP-keyed limiter before auth on `/api/v1/*` (e.g. 60/min/IP)
2. **PUB-RL-1** — add an IP-keyed limiter on public reads (e.g. 120/min/IP)
3. **IDEM-TTL** — sweep `idempotency` rows older than 7 days on boot
