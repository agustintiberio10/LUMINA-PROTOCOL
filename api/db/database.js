/**
 * Módulo de base de datos — SQLite con better-sqlite3
 * Tablas: agents, quotes, policies
 */
const Database = require("better-sqlite3");
const path = require("path");
const crypto = require("crypto");

const DB_PATH = path.join(__dirname, "..", "lumina.db");
let db;

function getDb() {
  if (!db) {
    db = new Database(DB_PATH);
    db.pragma("journal_mode = WAL");
    db.pragma("foreign_keys = ON");
  }
  return db;
}

// ── Inicialización ──

function initDatabase() {
  const db = getDb();

  db.exec(`
    CREATE TABLE IF NOT EXISTS agents (
      id TEXT PRIMARY KEY,
      agentWallet TEXT NOT NULL,
      ownerWallet TEXT NOT NULL,
      apiKey TEXT UNIQUE NOT NULL,
      allowedProducts TEXT,
      maxCoveragePerPolicy INTEGER DEFAULT 50000,
      maxMonthlySpend INTEGER DEFAULT 5000,
      monthlySpent INTEGER DEFAULT 0,
      monthlyResetDate TEXT,
      autoRenewEnabled INTEGER DEFAULT 0,
      status TEXT DEFAULT 'active',
      createdAt TEXT,
      updatedAt TEXT
    );

    CREATE TABLE IF NOT EXISTS quotes (
      id TEXT PRIMARY KEY,
      agentId TEXT REFERENCES agents(id),
      productId TEXT NOT NULL,
      coverageAmount INTEGER NOT NULL,
      premium INTEGER NOT NULL,
      premiumRateBps INTEGER NOT NULL,
      durationDays INTEGER NOT NULL,
      threshold INTEGER NOT NULL,
      asset TEXT,
      chainlinkFeed TEXT,
      triggerType TEXT NOT NULL,
      sustainedPeriod INTEGER,
      waitingPeriod INTEGER,
      deductibleBps INTEGER,
      maxPayout INTEGER,
      termsHash TEXT,
      expiresAt TEXT NOT NULL,
      used INTEGER DEFAULT 0,
      createdAt TEXT
    );

    CREATE TABLE IF NOT EXISTS policies (
      id TEXT PRIMARY KEY,
      poolId INTEGER,
      quoteId TEXT REFERENCES quotes(id),
      agentId TEXT REFERENCES agents(id),
      productId TEXT NOT NULL,
      coverageAmount INTEGER NOT NULL,
      premium INTEGER NOT NULL,
      deductibleBps INTEGER NOT NULL,
      maxPayout INTEGER NOT NULL,
      triggerType TEXT NOT NULL,
      threshold INTEGER NOT NULL,
      asset TEXT,
      chainlinkFeed TEXT,
      sustainedPeriod INTEGER,
      waitingPeriod INTEGER,
      durationDays INTEGER NOT NULL,
      status TEXT DEFAULT 'active',
      signatureTxHash TEXT,
      paymentTxHash TEXT,
      activatedAt TEXT,
      waitingEndsAt TEXT,
      expiresAt TEXT,
      resolvedAt TEXT,
      resolutionResult TEXT,
      createdAt TEXT
    );
  `);

  console.log("[DB] Tablas inicializadas");
}

// ── Helpers: Agents ──

function _nextAgentId() {
  const db = getDb();
  const row = db.prepare("SELECT id FROM agents ORDER BY ROWID DESC LIMIT 1").get();
  if (!row) return "AGT-001";
  const num = parseInt(row.id.replace("AGT-", ""), 10) + 1;
  return `AGT-${String(num).padStart(3, "0")}`;
}

function insertAgent({ agentWallet, ownerWallet, allowedProducts, maxCoveragePerPolicy, maxMonthlySpend, autoRenewEnabled }) {
  const db = getDb();
  const id = _nextAgentId();
  const apiKey = `lum_${crypto.randomUUID()}`;
  const now = new Date().toISOString();
  const monthlyResetDate = _nextMonthReset();

  db.prepare(`
    INSERT INTO agents (id, agentWallet, ownerWallet, apiKey, allowedProducts, maxCoveragePerPolicy, maxMonthlySpend, monthlySpent, monthlyResetDate, autoRenewEnabled, status, createdAt, updatedAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 'active', ?, ?)
  `).run(
    id, agentWallet, ownerWallet, apiKey,
    allowedProducts ? JSON.stringify(allowedProducts) : null,
    maxCoveragePerPolicy || 50000,
    maxMonthlySpend || 5000,
    monthlyResetDate,
    autoRenewEnabled ? 1 : 0,
    now, now
  );

  return { id, apiKey, status: "active" };
}

function getAgentByApiKey(apiKey) {
  const db = getDb();
  const agent = db.prepare("SELECT * FROM agents WHERE apiKey = ?").get(apiKey);
  if (agent && agent.allowedProducts) {
    agent.allowedProducts = JSON.parse(agent.allowedProducts);
  }
  // Resetear gasto mensual si corresponde
  if (agent && agent.monthlyResetDate && new Date() >= new Date(agent.monthlyResetDate)) {
    _resetMonthlySpend(agent.id);
    agent.monthlySpent = 0;
    agent.monthlyResetDate = _nextMonthReset();
  }
  return agent;
}

function getAgentById(id) {
  const db = getDb();
  const agent = db.prepare("SELECT * FROM agents WHERE id = ?").get(id);
  if (agent && agent.allowedProducts) {
    agent.allowedProducts = JSON.parse(agent.allowedProducts);
  }
  return agent;
}

function updateAgent(id, fields) {
  const db = getDb();
  const sets = [];
  const values = [];
  for (const [key, val] of Object.entries(fields)) {
    sets.push(`${key} = ?`);
    values.push(key === "allowedProducts" ? JSON.stringify(val) : val);
  }
  sets.push("updatedAt = ?");
  values.push(new Date().toISOString());
  values.push(id);
  db.prepare(`UPDATE agents SET ${sets.join(", ")} WHERE id = ?`).run(...values);
}

function _resetMonthlySpend(agentId) {
  const db = getDb();
  db.prepare("UPDATE agents SET monthlySpent = 0, monthlyResetDate = ? WHERE id = ?")
    .run(_nextMonthReset(), agentId);
}

function _nextMonthReset() {
  const d = new Date();
  d.setMonth(d.getMonth() + 1, 1);
  d.setHours(0, 0, 0, 0);
  return d.toISOString();
}

// ── Helpers: Quotes ──

function insertQuote(quote) {
  const db = getDb();
  const now = new Date().toISOString();
  db.prepare(`
    INSERT INTO quotes (id, agentId, productId, coverageAmount, premium, premiumRateBps, durationDays, threshold, asset, chainlinkFeed, triggerType, sustainedPeriod, waitingPeriod, deductibleBps, maxPayout, termsHash, expiresAt, used, createdAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
  `).run(
    quote.id, quote.agentId, quote.productId, quote.coverageAmount,
    quote.premium, quote.premiumRateBps, quote.durationDays, quote.threshold,
    quote.asset || null, quote.chainlinkFeed || null, quote.triggerType,
    quote.sustainedPeriod ?? null, quote.waitingPeriod ?? null,
    quote.deductibleBps ?? null, quote.maxPayout ?? null,
    quote.termsHash || null, quote.expiresAt, now
  );
}

function getQuoteById(id) {
  return getDb().prepare("SELECT * FROM quotes WHERE id = ?").get(id);
}

function markQuoteUsed(id) {
  getDb().prepare("UPDATE quotes SET used = 1 WHERE id = ?").run(id);
}

// ── Helpers: Policies ──

function _nextPolicyId() {
  const db = getDb();
  const row = db.prepare("SELECT id FROM policies ORDER BY ROWID DESC LIMIT 1").get();
  if (!row) return "POL-001";
  const num = parseInt(row.id.replace("POL-", ""), 10) + 1;
  return `POL-${String(num).padStart(3, "0")}`;
}

function insertPolicy(policy) {
  const db = getDb();
  const id = _nextPolicyId();
  const now = new Date().toISOString();
  db.prepare(`
    INSERT INTO policies (id, poolId, quoteId, agentId, productId, coverageAmount, premium, deductibleBps, maxPayout, triggerType, threshold, asset, chainlinkFeed, sustainedPeriod, waitingPeriod, durationDays, status, signatureTxHash, paymentTxHash, activatedAt, waitingEndsAt, expiresAt, createdAt)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?, ?, ?)
  `).run(
    id, policy.poolId ?? null, policy.quoteId, policy.agentId, policy.productId,
    policy.coverageAmount, policy.premium, policy.deductibleBps, policy.maxPayout,
    policy.triggerType, policy.threshold, policy.asset || null,
    policy.chainlinkFeed || null, policy.sustainedPeriod ?? null,
    policy.waitingPeriod ?? null, policy.durationDays,
    policy.signatureTxHash || null, policy.paymentTxHash || null,
    policy.activatedAt, policy.waitingEndsAt || null, policy.expiresAt, now
  );
  return id;
}

function getPolicyById(id) {
  return getDb().prepare("SELECT * FROM policies WHERE id = ?").get(id);
}

function getPoliciesByAgentId(agentId, filters = {}) {
  const db = getDb();
  let sql = "SELECT * FROM policies WHERE agentId = ?";
  const params = [agentId];
  if (filters.status) {
    sql += " AND status = ?";
    params.push(filters.status);
  }
  if (filters.productId) {
    sql += " AND productId = ?";
    params.push(filters.productId);
  }
  sql += " ORDER BY createdAt DESC";
  return db.prepare(sql).all(...params);
}

function updatePolicyStatus(id, status, extra = {}) {
  const db = getDb();
  const sets = ["status = ?"];
  const values = [status];
  for (const [key, val] of Object.entries(extra)) {
    sets.push(`${key} = ?`);
    values.push(val);
  }
  values.push(id);
  db.prepare(`UPDATE policies SET ${sets.join(", ")} WHERE id = ?`).run(...values);
}

module.exports = {
  getDb,
  initDatabase,
  insertAgent,
  getAgentByApiKey,
  getAgentById,
  updateAgent,
  insertQuote,
  getQuoteById,
  markQuoteUsed,
  insertPolicy,
  getPolicyById,
  getPoliciesByAgentId,
  updatePolicyStatus,
};
