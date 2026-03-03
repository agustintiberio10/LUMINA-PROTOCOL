/**
 * POST /api/v1/register — Registro público de agentes (sin auth)
 * Verifica firma del owner, genera API key
 */
const express = require("express");
const { ethers } = require("ethers");
const { insertAgent } = require("../db/database");

const router = express.Router();

router.post("/", (req, res) => {
  try {
    const { agentWallet, ownerWallet, ownerSignature, config } = req.body;

    // Validar campos requeridos
    if (!agentWallet || !ownerWallet || !ownerSignature) {
      return res.status(400).json({ error: "Missing required fields: agentWallet, ownerWallet, ownerSignature" });
    }

    // Validar formato de addresses
    if (!ethers.isAddress(agentWallet)) {
      return res.status(400).json({ error: "Invalid agentWallet address" });
    }
    if (!ethers.isAddress(ownerWallet)) {
      return res.status(400).json({ error: "Invalid ownerWallet address" });
    }

    // Verificar firma del owner
    const message = `I authorize agent ${agentWallet} to use Lumina Protocol`;
    let recoveredAddress;
    try {
      recoveredAddress = ethers.verifyMessage(message, ownerSignature);
    } catch {
      return res.status(400).json({ error: "Invalid signature format" });
    }

    if (recoveredAddress.toLowerCase() !== ownerWallet.toLowerCase()) {
      return res.status(403).json({
        error: "Signature verification failed",
        expected: ownerWallet,
        recovered: recoveredAddress,
      });
    }

    // Crear agente en DB
    const result = insertAgent({
      agentWallet,
      ownerWallet,
      allowedProducts: config?.allowedProducts || null,
      maxCoveragePerPolicy: config?.maxCoveragePerPolicy,
      maxMonthlySpend: config?.maxMonthlySpend,
      autoRenewEnabled: config?.autoRenewEnabled,
    });

    res.status(201).json({
      agentId: result.id,
      apiKey: result.apiKey,
      status: result.status,
      config: {
        allowedProducts: config?.allowedProducts || "all",
        maxCoveragePerPolicy: config?.maxCoveragePerPolicy || 50000,
        maxMonthlySpend: config?.maxMonthlySpend || 5000,
        autoRenewEnabled: config?.autoRenewEnabled || false,
      },
    });
  } catch (err) {
    console.error("[Register] Error:", err.message);
    res.status(500).json({ error: "Internal server error" });
  }
});

module.exports = router;
