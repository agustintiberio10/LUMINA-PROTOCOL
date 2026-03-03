/**
 * GET    /api/v1/agent/dashboard — Resumen del agente
 * PUT    /api/v1/agent/config — Actualizar configuración
 * DELETE /api/v1/agent — Eliminar agente
 */
const express = require("express");
const { ethers } = require("ethers");
const { getPoliciesByAgentId, updateAgent } = require("../db/database");
const { PRODUCTS } = require("../config/products");
const ERC20ABI = require("../abis/ERC20.json");

const router = express.Router();

// GET /api/v1/agent/dashboard
router.get("/dashboard", async (req, res) => {
  try {
    const agent = req.agent;

    // Leer balance USDC on-chain
    let usdcBalance = null;
    try {
      const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL || "https://mainnet.base.org");
      const usdc = new ethers.Contract(
        process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        ERC20ABI,
        provider
      );
      const balance = await usdc.balanceOf(agent.agentWallet);
      usdcBalance = Number(ethers.formatUnits(balance, 6));
    } catch (err) {
      console.error("[Dashboard] Error leyendo balance USDC:", err.message);
    }

    // Pólizas activas
    const activePolicies = getPoliciesByAgentId(agent.id, { status: "active" });
    const allPolicies = getPoliciesByAgentId(agent.id);

    // Historial reciente (últimas 10)
    const recentHistory = allPolicies.slice(0, 10).map((p) => ({
      policyId: p.id,
      productId: p.productId,
      productName: PRODUCTS[p.productId]?.name,
      status: p.status,
      coverageAmount: p.coverageAmount,
      premium: p.premium,
      createdAt: p.createdAt,
    }));

    res.json({
      agentId: agent.id,
      agentWallet: agent.agentWallet,
      ownerWallet: agent.ownerWallet,
      status: agent.status,
      usdcBalance,
      spending: {
        monthlySpent: agent.monthlySpent,
        monthlyLimit: agent.maxMonthlySpend,
        remaining: agent.maxMonthlySpend - agent.monthlySpent,
        resetDate: agent.monthlyResetDate,
      },
      policies: {
        active: activePolicies.length,
        total: allPolicies.length,
        activeList: activePolicies.map((p) => ({
          policyId: p.id,
          productId: p.productId,
          productName: PRODUCTS[p.productId]?.name,
          coverageAmount: p.coverageAmount,
          expiresAt: p.expiresAt,
          asset: p.asset,
          threshold: p.threshold,
        })),
      },
      recentHistory,
      config: {
        allowedProducts: agent.allowedProducts || "all",
        maxCoveragePerPolicy: agent.maxCoveragePerPolicy,
        autoRenewEnabled: !!agent.autoRenewEnabled,
      },
    });
  } catch (err) {
    console.error("[Dashboard] Error:", err.message);
    res.status(500).json({ error: "Internal server error" });
  }
});

// PUT /api/v1/agent/config
router.put("/config", (req, res) => {
  try {
    const agent = req.agent;
    const { ownerSignature, config } = req.body;

    if (!ownerSignature || !config) {
      return res.status(400).json({ error: "Missing ownerSignature or config" });
    }

    // Verificar firma del owner
    const message = `I authorize config update for agent ${agent.agentWallet} on Lumina Protocol`;
    let recoveredAddress;
    try {
      recoveredAddress = ethers.verifyMessage(message, ownerSignature);
    } catch {
      return res.status(400).json({ error: "Invalid signature" });
    }

    if (recoveredAddress.toLowerCase() !== agent.ownerWallet.toLowerCase()) {
      return res.status(403).json({ error: "Signature does not match owner wallet" });
    }

    // Actualizar config
    const updates = {};
    if (config.allowedProducts !== undefined) updates.allowedProducts = config.allowedProducts;
    if (config.maxCoveragePerPolicy !== undefined) updates.maxCoveragePerPolicy = config.maxCoveragePerPolicy;
    if (config.maxMonthlySpend !== undefined) updates.maxMonthlySpend = config.maxMonthlySpend;
    if (config.autoRenewEnabled !== undefined) updates.autoRenewEnabled = config.autoRenewEnabled ? 1 : 0;

    updateAgent(agent.id, updates);

    res.json({
      agentId: agent.id,
      message: "Config updated",
      config: { ...config },
    });
  } catch (err) {
    console.error("[Config] Error:", err.message);
    res.status(500).json({ error: "Internal server error" });
  }
});

// DELETE /api/v1/agent
router.delete("/", (req, res) => {
  try {
    const agent = req.agent;
    const { ownerSignature } = req.body;

    if (!ownerSignature) {
      return res.status(400).json({ error: "Missing ownerSignature" });
    }

    // Verificar firma
    const message = `I authorize deletion of agent ${agent.agentWallet} from Lumina Protocol`;
    let recoveredAddress;
    try {
      recoveredAddress = ethers.verifyMessage(message, ownerSignature);
    } catch {
      return res.status(400).json({ error: "Invalid signature" });
    }

    if (recoveredAddress.toLowerCase() !== agent.ownerWallet.toLowerCase()) {
      return res.status(403).json({ error: "Signature does not match owner wallet" });
    }

    // Marcar como deleted
    updateAgent(agent.id, { status: "deleted" });

    res.json({
      agentId: agent.id,
      status: "deleted",
      message: "Agent deleted. Active policies remain valid until expiry.",
    });
  } catch (err) {
    console.error("[Delete] Error:", err.message);
    res.status(500).json({ error: "Internal server error" });
  }
});

module.exports = router;
