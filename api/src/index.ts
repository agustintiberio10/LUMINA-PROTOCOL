/**
 * ═══════════════════════════════════════════════════════════════
 * LUMINA PROTOCOL — M2M Parametric Insurance API
 * ═══════════════════════════════════════════════════════════════
 *
 * Public REST API for autonomous agents to quote, purchase, and
 * track parametric insurance coverage on Base L2.
 *
 * Stack: Fastify + TypeScript (strict) + Zod validation
 *
 * Why Fastify over Express:
 *   - 2-3x faster request throughput (critical for M2M high-frequency)
 *   - Built-in schema validation support
 *   - Better TypeScript integration
 *   - Native async/await (no callback legacy)
 *
 * TODO for production:
 *   - Add PostgreSQL via Prisma ORM (replace in-memory Maps)
 *   - Add Redis for quote caching and rate limit state
 *   - Add JWT/API-key auth middleware for premium endpoints
 *   - Add webhook system for policy lifecycle events
 *   - Add OpenAPI/Swagger auto-generated docs
 *   - Add blockchain event listener for on-chain sync
 *   - Deploy behind Cloudflare for DDoS protection
 */

import Fastify from "fastify";
import cors from "@fastify/cors";
import helmet from "@fastify/helmet";
import rateLimit from "@fastify/rate-limit";
import { CONFIG } from "./utils/config";
import { insuranceRoutes } from "./routes/insurance.routes";

async function main(): Promise<void> {
  const app = Fastify({
    logger: {
      level: CONFIG.NODE_ENV === "production" ? "info" : "debug",
      transport:
        CONFIG.NODE_ENV !== "production"
          ? { target: "pino-pretty", options: { colorize: true } }
          : undefined,
    },
    // Request ID for tracing M2M calls
    requestIdHeader: "x-request-id",
    genReqId: () => `req-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
  });

  // ── Security ──
  await app.register(helmet, {
    contentSecurityPolicy: false, // API-only, no HTML
  });

  // ── CORS ──
  // TODO: Restrict origins in production
  await app.register(cors, {
    origin: CONFIG.NODE_ENV === "production" ? false : true,
    methods: ["GET", "POST"],
  });

  // ── Rate Limiting ──
  // Prevents abuse from misconfigured agents
  await app.register(rateLimit, {
    max: CONFIG.RATE_LIMIT_MAX,
    timeWindow: CONFIG.RATE_LIMIT_WINDOW,
    keyGenerator: (request) => {
      // Rate limit by API key header, fallback to IP
      return (request.headers["x-api-key"] as string) || request.ip;
    },
    errorResponseBuilder: () => ({
      error: "Rate limit exceeded — slow down",
      code: "RATE_LIMITED",
      timestamp: new Date().toISOString(),
    }),
  });

  // ── Health Check ──
  app.get("/health", async () => ({
    status: "ok",
    service: "lumina-api",
    version: "1.0.0",
    chain: CONFIG.CHAIN,
    contracts: {
      mutualLumina: CONFIG.LUMINA_CONTRACT,
      disputeResolver: CONFIG.DISPUTE_RESOLVER,
    },
    uptime: process.uptime(),
    timestamp: new Date().toISOString(),
  }));

  // ── API Info ──
  app.get("/api/v1", async () => ({
    name: "Lumina Protocol — M2M Insurance API",
    version: "v1",
    description: "Parametric insurance for autonomous agents on Base L2",
    endpoints: {
      "POST /api/v1/cotizar": "Get a coverage quote",
      "POST /api/v1/emitir": "Issue a policy from a confirmed quote",
      "GET /api/v1/estado/:id": "Check policy status",
    },
    chain: CONFIG.CHAIN,
    token: "USDC (6 decimals)",
    contracts: {
      mutualLumina: CONFIG.LUMINA_CONTRACT,
      disputeResolver: CONFIG.DISPUTE_RESOLVER,
      usdc: CONFIG.USDC_ADDRESS,
    },
    security: {
      oracle: "Dual-Auth LLM (Judge + Auditor) in Phala TEE",
      disputeWindow: `${CONFIG.DISPUTE_WINDOW_HOURS}h on all resolutions`,
      fee: `${CONFIG.PROTOCOL_FEE_BPS / 100}% protocol fee`,
    },
    rateLimit: `${CONFIG.RATE_LIMIT_MAX} requests per ${CONFIG.RATE_LIMIT_WINDOW}`,
    docs: "https://docs.lumina.insurance/api",
  }));

  // ── Register Routes ──
  await app.register(insuranceRoutes);

  // ── Global Error Handler ──
  app.setErrorHandler((error, _request, reply) => {
    app.log.error(error);
    reply.status(error.statusCode ?? 500).send({
      error: error.message || "Internal server error",
      code: "INTERNAL_ERROR",
      timestamp: new Date().toISOString(),
    });
  });

  // ── Start Server ──
  try {
    await app.listen({ port: CONFIG.PORT, host: CONFIG.HOST });
    app.log.info(`Lumina API running on ${CONFIG.HOST}:${CONFIG.PORT}`);
    app.log.info(`Environment: ${CONFIG.NODE_ENV}`);
    app.log.info(`MutualLumina: ${CONFIG.LUMINA_CONTRACT}`);
    app.log.info(`DisputeResolver: ${CONFIG.DISPUTE_RESOLVER}`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

main();
