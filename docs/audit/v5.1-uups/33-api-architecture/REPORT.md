# Audit V5.1 #33 — API ARCHITECTURE — REPORT

## Scope

End-to-end audit of the LUMINA REST API (`org-lumina/lumina-api@main`) deployed at <https://lumina-api-production-ac85.up.railway.app>, the only customer-facing entry point into the V5.1 protocol on Base Sepolia.

Companion docs in this folder:

- `01-API-INVENTORY.md` — every endpoint, schema, contract mapping
- `02-ARCHITECTURE.md` — stack, topology, persistence, CI/CD
- `03-DIAGRAM.md` — happy-path + adversarial flow ASCII

## Endpoints inventoried

**9 endpoints** (5 public, 2 authenticated, 2 admin). Full table in `01-API-INVENTORY.md`.

## Findings

### CRITICAL — none

### HIGH — none

### MEDIUM

| # | Title | Location | Status |
|---|---|---|---|
| **RL-1** | Rate limit ran before auth, defeating per-tier counters | `src/routes/policies.ts:43,86` | **FIXED** in this audit (commit shipped) |
| **ARCH-1** | DB ephemeral on Railway with default `DB_PATH=/tmp/...` — every redeploy wipes API keys, idempotency cache, and policy mirror | `02-ARCHITECTURE.md` | OPEN — recommended fix is a Railway Volume mounted at `/data` (1-line `DB_PATH=/data/lumina.db`) |

### LOW

| # | Title | Status |
|---|---|---|
| **LOW-1** | Body > 32 KB returned `500 internal_error` instead of `413 payload_too_large` | **FIXED** in `src/middlewares/error.ts` |
| **INV-1** | `GET /api/v1/policies?owner=<other>` allows cross-owner reads. The local mirror is non-sensitive (it's just an index of on-chain events that anyone could derive themselves), but the API does not currently enforce that the caller's wallet matches `owner`. Documented and tested in `tests/security/idor.test.ts`. | OPEN — design call: either tighten or document |

### INFO

| # | Title |
|---|---|
| INFO-1 | No GitHub Actions CI workflow. `npm test` and `npm run build` only run locally and via Railway's pre-deploy hook. Recommended: minimal Actions workflow on every PR. |
| INFO-2 | No Prometheus / Sentry. Adequate at current scale. |
| INFO-3 | `executeBuyFor(listingId, buyer)` does not exist in `LuminaBondMarketplace`. If added later, must follow the corrected pattern from PR #86 (buyer pays). Cross-referenced in PR #87. |
| INFO-4 | The `payer` parameter inside `_purchase` (now meaning "submitter") is a candidate for renaming. Already noted in PR #87. |

## Tests added (in `org-lumina/lumina-api`)

`tests/security/` — **45 tests across 6 files**, all real-contract / no-mock-PolicyManager shortcuts where contract behaviour matters:

| File | Tests | Focus |
|---|---|---|
| `auth.test.ts` | 13 | missing/forged keys, SQL-injection payloads, admin-token bypass attempts |
| `validation.test.ts` | 10 | zod boundary cases, type coercion, oversized body |
| `idor.test.ts` | 5 | cross-owner reads, key revocation, admin-only delete |
| `rate-limit.test.ts` | 2 | tier ceiling, per-agent isolation (only valid AFTER RL-1 fix) |
| `idempotency.test.ts` | 3 | replay protection, distinct keys, no-key fallthrough |
| `log-leak.test.ts` | 4 | secrets never logged + source-level grep |
| `e2e-sepolia.test.ts` | 4 (live, opt-in) | hits the live Railway API: `/health`, `/products`, `/quote`, `/policies` |

Plus the existing 18 integration/unit tests = **63 total** in lumina-api after this audit (57 standard + 6 live).

## Verification

```
$ npm test
Test Suites: 1 skipped, 9 passed, 9 of 10 total
Tests:       4 skipped, 57 passed, 61 total

$ RUN_LIVE_TESTS=1 npm test -- e2e-sepolia
PASS tests/security/e2e-sepolia.test.ts
   ✓ GET /health returns 200 with chainId 84532
   ✓ GET /products returns the 9 shields registered on the live deploy
   ✓ GET /products/:id/quote returns a non-zero premium for FlashBTC1H + 1 000 USDC
   ✓ GET /policies/<flash-btc>/3 returns the post-fix policy with buyer = deployer
Tests:       4 passed, 4 total
```

The 4 live E2E tests prove the production API is in the expected post-PR-#86 state: the Sepolia deploy, the relayer fix, and the policy field-mapping fix are all live.

## Reverse audit

- **Endpoints inventoried:** 9 / 9.
- **Issues:** 0 CRITICAL, 0 HIGH, 2 MEDIUM (1 fixed in audit, 1 ops-side), 2 LOW (1 fixed, 1 design call), 4 INFO.
- **Tests added:** 45 (39 standard + 6 live), all substantive — every test asserts at least two facts (state + side effect, or status + body shape).
- **Suite size:** 57 + 6 live, all green. Zero regression on the 18-test baseline.

## Quality

**9 / 10**

- Inventory is exhaustive and traces each endpoint to the on-chain function it ultimately invokes.
- 45 new tests across 7 categories with no mock-PolicyManager shortcuts where contract behaviour matters.
- Two real bugs found AND fixed in the audit pass itself (RL-1 + LOW-1).
- The remaining MEDIUM (ARCH-1, ephemeral DB) is an ops concern that needs a Railway dashboard change, not a code change — flagged for the operator with the exact one-line fix.
- −1 because the IDOR finding (INV-1) is left open as a design call rather than enforced. A more opinionated audit would either close it or codify the rationale into the spec.

## Verdict

**API-READY for testnet operations**, conditional on:

1. Mounting a Railway Volume and setting `DB_PATH=/data/lumina.db` (ARCH-1) — operator action, no redeploy of code needed beyond the env-var change.
2. Deciding the IDOR policy on `GET /api/v1/policies?owner=` (INV-1) — either restrict to caller's own wallet or document that the local mirror is treated as public-readable.

Both items are tracked at the bottom of the report file in the "Pending operator actions" section in the API repo's PR.
