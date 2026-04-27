# 02 — Architecture analysis

Companion to `01-API-INVENTORY.md`. Stack, deploy topology, and the trust boundaries the API depends on.

## Stack

| Layer | Choice | Notes |
|---|---|---|
| Runtime | Node.js 20 (`node:20-bookworm-slim`) | Pinned in Dockerfile multi-stage |
| HTTP | Express 4.21 | Synchronous middleware chain |
| Type system | TypeScript 5.6 strict | `noImplicitAny`, `strictNullChecks`, `noUnusedLocals/Parameters` |
| EVM client | ethers v6.13 | `JsonRpcProvider` + `Wallet` for the relayer |
| DB | SQLite via `better-sqlite3` 12 | Synchronous, in-process, file-backed |
| Validation | zod 3.23 | Per-route schemas; ZodError → 400 in error middleware |
| Logging | pino 9 + pino-pretty (dev only) | JSON in prod; one logger per process |
| Security headers | helmet 8 | default config |
| Rate limit | express-rate-limit 7.5 | `draft-7` standard headers; tier-based `max` per request |
| Tests | jest 29 + ts-jest + supertest 7 | runs in `:memory:` SQLite via `tests/setup-env.ts` |
| Build | `tsc` → `dist/` | committed lockfile is `package-lock.json` |
| Container | Docker multi-stage (deps → build → runtime) | non-root user `lumina` (uid 10001) |
| Deploy | Railway (`railway.toml`, `DOCKERFILE` builder) | health-check on `/health`, `restartPolicyType=ON_FAILURE` |

## Topology

```
        ┌────────────────────────────────────────────────┐
        │ AI agent / browser / external integration       │
        └─────────────┬──────────────────────────────────┘
                      │ HTTPS
                      │ x-api-key: lk_…  (or x-admin-token)
                      ▼
        ┌────────────────────────────────────────────────┐
        │ Railway edge proxy (TLS termination, IP fwd)   │
        └─────────────┬──────────────────────────────────┘
                      │ HTTP
                      ▼
        ┌────────────────────────────────────────────────┐
        │ Express app (single Node 20 process)           │
        │  ├── helmet()                                  │
        │  ├── express.json({ limit:32kb })              │
        │  ├── routers (health/products/policies/keys)   │
        │  │     └── per-route: rate-limit + auth        │
        │  ├── pino logger                               │
        │  ├── better-sqlite3 (api_keys, agents,         │
        │  │                   policies, idempotency)    │
        │  └── ethers v6 → JsonRpcProvider               │
        └────┬───────────────────────────┬───────────────┘
             │                           │
             │ ETH RPC (Alchemy)         │ Tx broadcast
             ▼                           ▼
        ┌──────────────┐          ┌──────────────────────┐
        │ Base Sepolia │          │ CoverRouterV2 + 5    │
        │ chainId 84532│  ──────► │ proxies + 9 shields  │
        └──────────────┘          └──────────────────────┘
```

## Trust boundaries

| Boundary | Trusted side | Untrusted side | Mitigation |
|---|---|---|---|
| Internet → Railway | API | Caller | TLS, helmet, body-size limit, rate limit |
| API → SQLite | API | — | In-process; no SQL injection surface (parameterised statements via better-sqlite3) |
| API → RPC | API | Alchemy | Static network pinning (`staticNetwork: true`), ABI-typed contract handles |
| Relayer key | API process memory | World | Held only in `process.env.RELAYER_PRIVATE_KEY`; never logged; only signs `purchasePolicyFor(...)` |
| Admin token | API process memory | World | Constant-time compare in `middlewares/admin.ts`; admin endpoints IP rate-limited |
| API key (plaintext) | Caller | API stores hash only | SHA-256 hash; plaintext returned once at issue, then unrecoverable |
| On-chain auth (relayer) | CoverRouterV2 owner | API relayer wallet | `authorizedRelayers[relayer] = true` via `setRelayer(...)` from owner; revocable |
| Buyer USDC | Buyer's wallet | API + relayer | Buyer must `approve(coverRouter, ...)` themselves; allowance is the cap (see PR #87 INV-1) |

## Configuration

All config sourced from environment variables, validated by zod at boot. Boot fails fast if any are missing or malformed.

Required:
- `PORT`, `NODE_ENV`, `LOG_LEVEL`
- `RPC_URL`, `CHAIN_ID` (default 84532)
- `RELAYER_PRIVATE_KEY`, `ADMIN_TOKEN`
- `LUMINA_TOKEN`, `CLAIM_BOND`, `BOND_VAULT`, `POLICY_MANAGER`, `COVER_ROUTER`, `MARKETPLACE`, `USDC`
- `DB_PATH`
- `RATE_LIMIT_FREE_RPM`, `RATE_LIMIT_PAID_RPM`

## Persistence model

`better-sqlite3` opens `DB_PATH` synchronously at process start; migrations live in `src/db/database.ts:migrate()`. Tables:

| Table | Purpose | Indexes |
|---|---|---|
| `agents` | one row per wallet seen (find-or-create) | unique on wallet |
| `api_keys` | SHA-256-hashed keys, `revoked_at` for soft-delete | unique on hash; partial index on `(agent_id) WHERE revoked_at IS NULL` |
| `policies` | local mirror of on-chain policies submitted by THIS API instance | unique on `(product_id, policy_id)`; index on `buyer`, `submitted_by` |
| `idempotency` | response cache for `POST /api/v1/policies` | PK on key |

**Persistence problem (ARCH-1).** With `DB_PATH=/tmp/lumina.db` (the current Railway value), the file lives in the container's ephemeral filesystem. On every redeploy or container restart **all rows in all four tables are lost**. Operationally:

- Issued API keys stop working — clients must regenerate.
- Idempotency replay protection is lost.
- The local mirror of past policies is lost (the on-chain state is intact, but `GET /api/v1/policies?owner=...` returns empty until policies are re-indexed).

Mitigation: mount a **Railway Volume** (e.g. `/data`) and set `DB_PATH=/data/lumina.db`. Alternatively migrate to a managed Postgres add-on.

This was hit live during PR #86's E2E retest: redeploying the policy-mapping fix wiped the API key issued earlier in the session, requiring re-generation. README documents the workaround in commit `2bda106`.

## Build & CI/CD

- Build: `npm run build` → `tsc` (strict).
- Local dev: `npm run dev` (ts-node-dev with --respawn).
- Test: `npm test` runs jest in band with `:memory:` SQLite.
- Smoke: `npm run smoke` runs `scripts/smoke.ts` against the live RPC, no broadcast.
- Deploy: Railway watches the GitHub repo; on push to `main`, Railway runs the Dockerfile and rolls a new container.

**No CI configured.** No GitHub Actions workflow file in the repo. `npm test` and `npm run build` run only locally and via Railway's pre-deploy hook. Recommended: add a minimal Actions workflow that runs `npm ci && npm run build && npm test` on every PR (see RECO-1).

## Observability

- Application logs are pino JSON; Railway captures stdout/stderr for browsing in their dashboard.
- `/health` exposes RPC connectivity, relayer balance, and contract wiring — suitable for an external uptime monitor (e.g. `curl /health` every minute).
- No metrics exporter (Prometheus) and no error reporter (Sentry). Adequate for the current usage scale; would be the first thing to add if traffic grew.
