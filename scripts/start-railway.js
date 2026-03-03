/**
 * Railway Production Runner — Lumina Oracle + MoltBook + MoltX in one service.
 * v3.0 — Express health check + Oracle V3 lifecycle + Ephemeral-safe state
 *
 * Features:
 * - Express HTTP health check (Railway uses PORT env var)
 * - Oracle bot with blockchain state reconstruction on startup
 * - Sequential heartbeats to avoid state.json race conditions
 * - Graceful shutdown on SIGTERM/SIGINT
 * - Auto-restart on uncaught errors (logs and continues)
 *
 * Usage:
 *   npm start                (all: oracle + moltbook + moltx)
 *   npm run railway          (same)
 *   BOT_MODE=oracle          (oracle V3 lifecycle only)
 *   BOT_MODE=moltbook        (MoltBook only)
 *   BOT_MODE=moltx           (MoltX only)
 *   BOT_MODE=social          (MoltBook + MoltX, no oracle)
 */
require("dotenv").config();
const express = require("express");

// ── Bot imports (lazy — only loaded if their mode is active) ──
let runHeartbeat, runMoltxHeartbeat;
let initOracleBot, runOracleHeartbeat, getOracleStatus;

// ── Config ──────────────────────────────────────────────────
const PORT = process.env.PORT || 3000;
const HEARTBEAT_INTERVAL_MS = 10 * 60 * 1000; // 10 minutes
const BOT_MODE = process.env.BOT_MODE || "all"; // "all" | "oracle" | "moltbook" | "moltx" | "social" | "both"

const shouldRunOracle = ["all", "oracle"].includes(BOT_MODE);
const shouldRunMoltbook = ["all", "both", "social", "moltbook"].includes(BOT_MODE);
const shouldRunMoltx = ["all", "both", "social", "moltx"].includes(BOT_MODE);

let heartbeatTimer = null;
let isShuttingDown = false;
let lastHeartbeat = null;
let heartbeatCount = 0;
let lastError = null;
let startedAt = Date.now();

// ── Express Health Check Server ──────────────────────────────
const app = express();

app.get("/", (req, res) => {
  res.json({ status: "Lumina Oracle Alive" });
});

app.get("/health", (req, res) => {
  const uptime = process.uptime();
  const oracleStatus = getOracleStatus ? getOracleStatus() : { initialized: false };

  res.json({
    status: "ok",
    service: "Lumina Oracle",
    mode: BOT_MODE,
    uptime: `${Math.floor(uptime / 3600)}h ${Math.floor((uptime % 3600) / 60)}m`,
    heartbeats: heartbeatCount,
    lastHeartbeat,
    lastError,
    memory: `${Math.round(process.memoryUsage().rss / 1024 / 1024)}MB`,
    oracle: oracleStatus,
    bots: {
      oracle: shouldRunOracle,
      moltbook: shouldRunMoltbook,
      moltx: shouldRunMoltx,
    },
  });
});

// ── Heartbeat Cycle ─────────────────────────────────────────
async function runCycle() {
  if (isShuttingDown) return;

  const start = Date.now();
  console.log(`\n${"═".repeat(60)}`);
  console.log(`[Railway] Heartbeat #${heartbeatCount + 1} starting — ${new Date().toISOString()}`);
  console.log(`${"═".repeat(60)}`);

  try {
    // ── Oracle V3 Lifecycle ──
    if (shouldRunOracle && runOracleHeartbeat) {
      console.log("\n[Railway] ▸ Running Oracle V3 heartbeat...");
      await runOracleHeartbeat();
      console.log("[Railway] ✓ Oracle V3 heartbeat complete");
    }

    // ── MoltBook bot (isolated — errors don't kill MoltX) ──
    if (shouldRunMoltbook && runHeartbeat) {
      try {
        console.log("\n[Railway] ▸ Running MoltBook heartbeat...");
        await runHeartbeat();
        console.log("[Railway] ✓ MoltBook heartbeat complete");
      } catch (mbErr) {
        console.error("[Railway] ✗ MoltBook heartbeat failed (isolated):", mbErr.message);
      }
    }

    // ── MoltX bot (isolated — errors don't kill MoltBook) ──
    if (shouldRunMoltx && runMoltxHeartbeat) {
      try {
        console.log("\n[Railway] ▸ Running MoltX heartbeat...");
        await runMoltxHeartbeat();
        console.log("[Railway] ✓ MoltX heartbeat complete");
      } catch (mxErr) {
        console.error("[Railway] ✗ MoltX heartbeat failed (isolated):", mxErr.message);
      }
    }

    heartbeatCount++;
    lastHeartbeat = new Date().toISOString();
    lastError = null;

    const elapsed = ((Date.now() - start) / 1000).toFixed(1);
    console.log(`\n[Railway] Cycle #${heartbeatCount} done in ${elapsed}s. Next in ${HEARTBEAT_INTERVAL_MS / 60000} min.`);
  } catch (err) {
    lastError = `${err.message} (${new Date().toISOString()})`;
    console.error(`[Railway] Heartbeat error:`, err.message);
    // Don't crash — just log and continue to next cycle
  }
}

// ── Graceful Shutdown ───────────────────────────────────────
function shutdown(signal) {
  if (isShuttingDown) return;
  isShuttingDown = true;

  console.log(`\n[Railway] ${signal} received — shutting down gracefully...`);

  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }

  // Give in-flight requests 5s to complete
  const server = app._server;
  if (server) {
    server.close(() => {
      console.log("[Railway] HTTP server closed.");
      console.log(`[Railway] Total heartbeats completed: ${heartbeatCount}`);
      process.exit(0);
    });
  }

  // Force exit after 10s if server doesn't close
  setTimeout(() => {
    console.error("[Railway] Forced exit after timeout.");
    process.exit(1);
  }, 10000);
}

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// ── Start ───────────────────────────────────────────────────
async function start() {
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║       LUMINA ORACLE — RAILWAY 24/7 PRODUCTION          ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ Mode: ${BOT_MODE.padEnd(51)}║`);
  console.log(`║ Oracle V3: ${(shouldRunOracle ? "ENABLED" : "disabled").padEnd(46)}║`);
  console.log(`║ MoltBook:  ${(shouldRunMoltbook ? "ENABLED" : "disabled").padEnd(46)}║`);
  console.log(`║ MoltX:     ${(shouldRunMoltx ? "ENABLED" : "disabled").padEnd(46)}║`);
  console.log(`║ Health: http://0.0.0.0:${String(PORT).padEnd(35)}║`);
  console.log(`║ Heartbeat: Every ${HEARTBEAT_INTERVAL_MS / 60000} min${" ".repeat(36)}║`);
  console.log("╚══════════════════════════════════════════════════════════╝");
  console.log();

  // ── Step 1: Start Express health check immediately ──
  // Railway needs a port binding ASAP or it kills the container.
  app._server = app.listen(PORT, "0.0.0.0", () => {
    console.log(`[Railway] Express health check listening on port ${PORT}`);
  });

  // ── Step 2: Load bot modules based on mode ──
  if (shouldRunMoltbook) {
    try {
      ({ runHeartbeat } = require("../agent/index.js"));
      console.log("[Railway] MoltBook module loaded.");
    } catch (err) {
      console.error("[Railway] Failed to load MoltBook module:", err.message);
    }
  }

  if (shouldRunMoltx) {
    try {
      ({ runMoltxHeartbeat } = require("../agent/index-moltx.js"));
      console.log("[Railway] MoltX module loaded.");
    } catch (err) {
      console.error("[Railway] Failed to load MoltX module:", err.message);
    }
  }

  // ── Step 3: Initialize Oracle Bot (blockchain sync) ──
  // This is the critical step for ephemeral resilience:
  // syncFromChain() reads MutualPoolV3.nextPoolId() and reconstructs
  // pool state from on-chain data, so a fresh container starts correctly.
  if (shouldRunOracle) {
    try {
      const oracle = require("../agent/oracle-bot.js");
      initOracleBot = oracle.initOracleBot;
      runOracleHeartbeat = oracle.runOracleHeartbeat;
      getOracleStatus = oracle.getOracleStatus;

      console.log("\n[Railway] Initializing Oracle V3 + blockchain state sync...");
      await initOracleBot();
      console.log("[Railway] Oracle V3 initialized and synced from chain.");
    } catch (err) {
      console.error("[Railway] Oracle init failed:", err.message);
      console.error("[Railway] Oracle heartbeats will be skipped until restart.");
      // Don't crash — social bots can still run
    }
  }

  // ── Step 4: Run first cycle immediately ──
  await runCycle();

  // ── Step 5: Schedule recurring cycles ──
  heartbeatTimer = setInterval(() => {
    runCycle().catch((err) => {
      console.error("[Railway] Unhandled cycle error:", err);
    });
  }, HEARTBEAT_INTERVAL_MS);
}

start().catch((err) => {
  console.error("[Railway] Fatal startup error:", err);
  process.exit(1);
});
