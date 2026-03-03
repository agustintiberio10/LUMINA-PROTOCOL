/**
 * Middleware de autenticación — Bearer token con API key
 * Busca agente en DB, inyecta req.agent
 */
const { getAgentByApiKey } = require("../db/database");

function authMiddleware(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return res.status(401).json({ error: "Missing or invalid Authorization header" });
  }

  const apiKey = authHeader.slice(7).trim();
  const agent = getAgentByApiKey(apiKey);

  if (!agent) {
    return res.status(401).json({ error: "Invalid API key" });
  }

  if (agent.status !== "active") {
    return res.status(401).json({ error: `Agent is ${agent.status}` });
  }

  req.agent = agent;
  next();
}

module.exports = { authMiddleware };
