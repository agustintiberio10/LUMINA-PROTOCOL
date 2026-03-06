/**
 * Lumina Protocol — API REST M2M para seguro paramétrico
 * Express + SQLite + ethers.js
 *
 * Endpoints públicos: GET /api/v1/products, POST /api/v1/register
 * Endpoints auth:     POST /api/v1/quote, POST /api/v1/purchase,
 *                     GET /api/v1/policy/:id, GET /api/v1/policies,
 *                     POST /api/v1/cancel/:id, GET /api/v1/agent/dashboard,
 *                     PUT /api/v1/agent/config, DELETE /api/v1/agent
 * Legacy:             GET /health
 */
require("dotenv").config();
const express = require("express");
const rateLimit = require("express-rate-limit");
const { initDatabase } = require("./db/database");
const { authMiddleware } = require("./middleware/auth");

// Rutas
const productsRouter = require("./routes/products");
const registerRouter = require("./routes/register");
const quoteRouter = require("./routes/quote");
const purchaseRouter = require("./routes/purchase");
const policyRouter = require("./routes/policy");
const agentRouter = require("./routes/agent");

const app = express();
app.set("trust proxy", 1);
const PORT = process.env.PORT || 3000;

// ── Middleware global ──
app.use(express.json());

// Rate limit: 10 req/min por IP
const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  standardHeaders: true,
  legacyHeaders: false,
  message: { error: "Rate limit exceeded. Max 10 requests per minute." },
});

// ── Health check (legacy, mantener compatibilidad) ──
app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    service: "lumina-api",
    version: "2.0.0",
    chain: "Base L2 (8453)",
    contracts: {
      mutualLumina: process.env.MUTUAL_LUMINA_ADDRESS || "0x1c5E5c90aC46e960aACbfCeAE9dEC2F79ce06bd7",
      disputeResolver: process.env.DISPUTE_RESOLVER_ADDRESS || "0x2e4D0112A65C2e2DCE73e7F85bF5C2889c7709cA",
      autoResolver: process.env.AUTO_RESOLVER_ADDRESS || "0x8D919F0BEf46736906e190da598570255FF02754",
    },
    uptime: process.uptime(),
    timestamp: new Date().toISOString(),
  });
});

app.get("/", (req, res) => {
  res.json({ status: "Lumina Protocol API v2.0.0" });
});

// ── Endpoints públicos (sin auth) ──
app.use("/api/v1/products", productsRouter);
app.use("/api/v1/register", registerRouter);

// ── Endpoints protegidos (con auth + rate limit) ──
app.use("/api/v1/quote", apiLimiter, authMiddleware, quoteRouter);
app.use("/api/v1/purchase", apiLimiter, authMiddleware, purchaseRouter);
app.use("/api/v1/policy", apiLimiter, authMiddleware, policyRouter);
app.use("/api/v1/policies", apiLimiter, authMiddleware, (req, res) => {
  // Redirigir a policy router GET /
  const policyRouter = require("./routes/policy");
  // Inline: listar pólizas
  const { getPoliciesByAgentId } = require("./db/database");
  const filters = {};
  if (req.query.status) filters.status = req.query.status;
  if (req.query.productId) filters.productId = req.query.productId;
  const policies = getPoliciesByAgentId(req.agent.id, filters);
  res.json({ count: policies.length, policies });
});
app.post("/api/v1/cancel/:policyId", apiLimiter, authMiddleware, (req, res) => {
  const handler = require("./routes/policy");
  // Redirigir al handler de cancelación
  req.url = `/cancel/${req.params.policyId}`;
  handler(req, res);
});
app.use("/api/v1/agent", apiLimiter, authMiddleware, agentRouter);

// ── Error handler global ──
app.use((err, req, res, _next) => {
  console.error("[Server] Unhandled error:", err.message);
  res.status(500).json({ error: "Internal server error" });
});

// ── Iniciar ──
function start() {
  // Inicializar DB
  initDatabase();

  app.listen(PORT, "0.0.0.0", () => {
    console.log("╔══════════════════════════════════════════════════╗");
    console.log("║       LUMINA PROTOCOL — API v2.0.0              ║");
    console.log("╠══════════════════════════════════════════════════╣");
    console.log(`║ Port: ${String(PORT).padEnd(43)}║`);
    console.log(`║ DB:   SQLite (lumina.db)${" ".repeat(25)}║`);
    console.log(`║ Chain: Base L2 (8453)${" ".repeat(28)}║`);
    console.log("╚══════════════════════════════════════════════════╝");
  });
}

start();
