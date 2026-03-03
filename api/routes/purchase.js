/**
 * POST /api/v1/purchase — Comprar póliza con quote (requiere auth)
 * Verifica quote, verifica pago on-chain, crea póliza
 */
const express = require("express");
const { ethers } = require("ethers");
const { getQuoteById, markQuoteUsed, insertPolicy, updateAgent } = require("../db/database");
const { PRODUCTS } = require("../config/products");

const router = express.Router();

router.post("/", async (req, res) => {
  try {
    const agent = req.agent;
    const { quoteId, signatureTxHash, paymentTxHash } = req.body;

    if (!quoteId || !paymentTxHash) {
      return res.status(400).json({ error: "Missing required fields: quoteId, paymentTxHash" });
    }

    // Verificar quote
    const quote = getQuoteById(quoteId);
    if (!quote) {
      return res.status(404).json({ error: "Quote not found" });
    }
    if (quote.agentId !== agent.id) {
      return res.status(403).json({ error: "Quote does not belong to this agent" });
    }
    if (quote.used) {
      return res.status(410).json({ error: "Quote already used" });
    }
    if (new Date() > new Date(quote.expiresAt)) {
      return res.status(410).json({ error: "Quote expired" });
    }

    // Verificar pago on-chain (transfer de USDC)
    const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL || "https://mainnet.base.org");
    let receipt;
    try {
      receipt = await provider.getTransactionReceipt(paymentTxHash);
    } catch {
      return res.status(400).json({ error: "Could not fetch transaction receipt" });
    }

    if (!receipt || receipt.status !== 1) {
      return res.status(400).json({ error: "Transaction not confirmed or reverted" });
    }

    // Verificar que hay un Transfer de USDC en los logs
    const usdcAddress = (process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913").toLowerCase();
    const transferTopic = ethers.id("Transfer(address,address,uint256)");
    const hasUsdcTransfer = receipt.logs.some(
      (log) => log.address.toLowerCase() === usdcAddress && log.topics[0] === transferTopic
    );

    if (!hasUsdcTransfer) {
      return res.status(400).json({ error: "No USDC transfer found in transaction" });
    }

    // Marcar quote como usada
    markQuoteUsed(quoteId);

    // Crear póliza
    const product = PRODUCTS[quote.productId];
    const now = new Date();
    const waitingEndsAt = product.waitingPeriod
      ? new Date(now.getTime() + product.waitingPeriod * 1000).toISOString()
      : now.toISOString();
    const expiresAt = new Date(now.getTime() + quote.durationDays * 24 * 60 * 60 * 1000).toISOString();

    const policyId = insertPolicy({
      poolId: null, // Se asigna cuando se cree el pool on-chain
      quoteId,
      agentId: agent.id,
      productId: quote.productId,
      coverageAmount: quote.coverageAmount,
      premium: quote.premium,
      deductibleBps: quote.deductibleBps,
      maxPayout: quote.maxPayout,
      triggerType: quote.triggerType,
      threshold: quote.threshold,
      asset: quote.asset,
      chainlinkFeed: quote.chainlinkFeed,
      sustainedPeriod: quote.sustainedPeriod,
      waitingPeriod: quote.waitingPeriod,
      durationDays: quote.durationDays,
      signatureTxHash: signatureTxHash || null,
      paymentTxHash,
      activatedAt: now.toISOString(),
      waitingEndsAt,
      expiresAt,
    });

    // Actualizar gasto mensual
    updateAgent(agent.id, {
      monthlySpent: agent.monthlySpent + quote.premium,
    });

    res.status(201).json({
      policyId,
      quoteId,
      productId: quote.productId,
      productName: product.name,
      coverageAmount: quote.coverageAmount,
      premium: quote.premium,
      maxPayout: quote.maxPayout,
      status: "active",
      activatedAt: now.toISOString(),
      waitingEndsAt,
      expiresAt,
      onChain: {
        poolId: null,
        note: "Pool on-chain pendiente de creación",
      },
    });
  } catch (err) {
    console.error("[Purchase] Error:", err.message);
    res.status(500).json({ error: "Internal server error" });
  }
});

module.exports = router;
