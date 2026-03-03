/**
 * GET  /api/v1/policy/:policyId — Detalle de póliza con precio actual
 * GET  /api/v1/policies — Listar pólizas del agente
 * POST /api/v1/cancel/:policyId — Cancelar póliza en cooling-off
 */
const express = require("express");
const { ethers } = require("ethers");
const { getPolicyById, getPoliciesByAgentId, updatePolicyStatus } = require("../db/database");
const { PRODUCTS, CHAINLINK_FEEDS } = require("../config/products");
const AggregatorV3ABI = require("../abis/AggregatorV3.json");

const router = express.Router();

// ── Leer precio de Chainlink ──
async function readChainlinkPrice(feedAddress) {
  try {
    const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL || "https://mainnet.base.org");
    const feed = new ethers.Contract(feedAddress, AggregatorV3ABI, provider);
    const [, answer, , updatedAt] = await feed.latestRoundData();
    const decimals = await feed.decimals();
    const price = Number(answer) / 10 ** Number(decimals);
    return { price, updatedAt: Number(updatedAt) };
  } catch (err) {
    console.error("[Chainlink] Error leyendo feed:", err.message);
    return null;
  }
}

// ── Calcular distancia al trigger ──
function triggerDistance(policy, currentPrice) {
  if (!currentPrice) return null;

  const product = PRODUCTS[policy.productId];
  if (!product) return null;

  switch (product.triggerType) {
    case "PRICE_DROP_PCT": {
      // threshold está en bps (ej: 2000 = 20%)
      const triggerPct = policy.threshold / 100;
      return {
        currentPrice: currentPrice.price,
        triggerType: "PRICE_DROP_PCT",
        triggerThreshold: `${triggerPct}% drop`,
        note: `Trigger at ${triggerPct}% price drop from reference`,
      };
    }
    case "PRICE_BELOW": {
      // threshold en price_4decimals (ej: 9500 = $0.95)
      const triggerPrice = policy.threshold / 10000;
      return {
        currentPrice: currentPrice.price,
        triggerPrice,
        triggerType: "PRICE_BELOW",
        distanceToTrigger: `$${(currentPrice.price - triggerPrice).toFixed(4)}`,
        note: `Current: $${currentPrice.price.toFixed(4)} — trigger at $${triggerPrice.toFixed(4)}`,
      };
    }
    case "PRICE_DIVERGENCE": {
      return {
        triggerType: "PRICE_DIVERGENCE",
        triggerThreshold: `${policy.threshold / 100}% divergence`,
      };
    }
    default:
      return null;
  }
}

// GET /api/v1/policy/:policyId
router.get("/:policyId", async (req, res) => {
  try {
    const policy = getPolicyById(req.params.policyId);
    if (!policy) {
      return res.status(404).json({ error: "Policy not found" });
    }
    if (policy.agentId !== req.agent.id) {
      return res.status(403).json({ error: "Policy does not belong to this agent" });
    }

    // Leer precio actual si hay feed
    let priceData = null;
    let trigger = null;
    if (policy.chainlinkFeed) {
      priceData = await readChainlinkPrice(policy.chainlinkFeed);
      trigger = triggerDistance(policy, priceData);
    }

    // Tiempo restante
    const now = new Date();
    const expires = new Date(policy.expiresAt);
    const remainingMs = Math.max(0, expires - now);
    const remainingDays = Math.ceil(remainingMs / (24 * 60 * 60 * 1000));

    const product = PRODUCTS[policy.productId];

    res.json({
      policyId: policy.id,
      productId: policy.productId,
      productName: product?.name,
      status: policy.status,
      coverageAmount: policy.coverageAmount,
      premium: policy.premium,
      maxPayout: policy.maxPayout,
      deductibleBps: policy.deductibleBps,
      triggerType: policy.triggerType,
      threshold: policy.threshold,
      asset: policy.asset,
      activatedAt: policy.activatedAt,
      waitingEndsAt: policy.waitingEndsAt,
      expiresAt: policy.expiresAt,
      remainingDays,
      currentPrice: priceData,
      triggerAnalysis: trigger,
      onChain: {
        poolId: policy.poolId,
        paymentTxHash: policy.paymentTxHash,
      },
      resolution: {
        resolved: !!policy.resolvedAt,
        result: policy.resolutionResult,
        resolvedAt: policy.resolvedAt,
      },
    });
  } catch (err) {
    console.error("[Policy] Error:", err.message);
    res.status(500).json({ error: "Internal server error" });
  }
});

// GET /api/v1/policies
router.get("/", (req, res) => {
  const filters = {};
  if (req.query.status) filters.status = req.query.status;
  if (req.query.productId) filters.productId = req.query.productId;

  const policies = getPoliciesByAgentId(req.agent.id, filters);
  res.json({ count: policies.length, policies });
});

// POST /api/v1/cancel/:policyId
router.post("/cancel/:policyId", (req, res) => {
  const policy = getPolicyById(req.params.policyId);
  if (!policy) {
    return res.status(404).json({ error: "Policy not found" });
  }
  if (policy.agentId !== req.agent.id) {
    return res.status(403).json({ error: "Policy does not belong to this agent" });
  }
  if (policy.status !== "active") {
    return res.status(400).json({ error: `Cannot cancel policy with status: ${policy.status}` });
  }

  // Verificar cooling-off period
  const product = PRODUCTS[policy.productId];
  const activatedAt = new Date(policy.activatedAt);
  const coolEnd = new Date(activatedAt.getTime() + (product?.coolingOffPeriod || 0) * 1000);
  const now = new Date();

  if (now > coolEnd) {
    return res.status(400).json({
      error: "Cooling-off period expired",
      coolingOffEnded: coolEnd.toISOString(),
    });
  }

  // Cancelar
  updatePolicyStatus(policy.id, "cancelled", {
    resolvedAt: now.toISOString(),
    resolutionResult: "cancelled",
  });

  // Monto de reembolso = premium completo durante cooling-off
  res.json({
    policyId: policy.id,
    status: "cancelled",
    refundAmount: policy.premium,
    cancelledAt: now.toISOString(),
  });
});

module.exports = router;
