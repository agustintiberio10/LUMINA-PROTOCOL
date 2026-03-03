/**
 * Standalone heartbeat runner — starts a single agent cycle.
 * Can be scheduled with cron or run manually for testing.
 *
 * Usage: node scripts/heartbeat.js
 */
require("dotenv").config();
const { runHeartbeat } = require("../agent/index");

(async () => {
  try {
    console.log(`[${new Date().toISOString()}] Running heartbeat...`);
    await runHeartbeat();
    console.log(`[${new Date().toISOString()}] Heartbeat complete.`);
    process.exit(0);
  } catch (err) {
    console.error("Heartbeat failed:", err);
    process.exit(1);
  }
})();
