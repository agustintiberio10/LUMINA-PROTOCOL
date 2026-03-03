/**
 * POST /api/v1/quote — Cotizar seguro (requiere auth)
 * GET  /api/v1/quote/:quoteId — Obtener quote existente
 */
const express = require("express");
const crypto = require("crypto");
const { ethers } = require("ethers");
const { PRODUCTS, CHAINLINK_FEEDS } = require("../config/products");
const { calculatePremium } = require("../services/pricing");
const { insertQuote, getQuoteById } = require("../db/database");

const router = express.Router();

const QUOTE_TTL_MS = 15 * 60 * 1000; // 15 minutos

router.post("/", (req, res) => {
  try {
    const agent = req.agent;
    const { productId, coverageAmount, durationDays, threshold, asset, bridge } = req.body;

    // Validar producto
    const product = PRODUCTS[productId];
    if (!product) {
      return res.status(400).json({ error: `Producto desconocido: ${productId}` });
    }

    // Validar que el agente tiene permitido este producto
    if (agent.allowedProducts && !agent.allowedProducts.includes(productId)) {
      return res.status(403).json({ error: `Producto ${productId} no permitido para este agente` });
    }

    // Validar parámetros contra el producto
    if (coverageAmount < product.minCoverageUSDC || coverageAmount > product.maxCoverageUSDC) {
      return res.status(400).json({
        error: `coverageAmount debe estar entre ${product.minCoverageUSDC} y ${product.maxCoverageUSDC} USDC`,
      });
    }
    if (durationDays < product.minDurationDays || durationDays > product.maxDurationDays) {
      return res.status(400).json({
        error: `durationDays debe estar entre ${product.minDurationDays} y ${product.maxDurationDays}`,
      });
    }
    if (!product.thresholdOptions.includes(threshold)) {
      return res.status(400).json({
        error: `threshold debe ser uno de: ${product.thresholdOptions.join(", ")}`,
      });
    }

    // Validar asset si el producto lo requiere
    if (product.availableAssets.length > 0) {
      if (!asset || !product.availableAssets.includes(asset)) {
        return res.status(400).json({
          error: `asset debe ser uno de: ${product.availableAssets.join(", ")}`,
        });
      }
    }

    // Calcular prima
    const pricing = calculatePremium(productId, {
      coverageAmount, durationDays, threshold, asset, bridge,
    });

    // Verificar gasto mensual
    const remaining = agent.maxMonthlySpend - agent.monthlySpent;
    if (pricing.premium > remaining) {
      return res.status(403).json({
        error: "Monthly spend limit exceeded",
        monthlySpent: agent.monthlySpent,
        monthlyLimit: agent.maxMonthlySpend,
        remaining,
        requiredPremium: pricing.premium,
      });
    }

    // Verificar cobertura máxima por póliza
    if (coverageAmount > agent.maxCoveragePerPolicy) {
      return res.status(403).json({
        error: `Coverage exceeds max per policy (${agent.maxCoveragePerPolicy} USDC)`,
      });
    }

    // Determinar Chainlink feed
    const feedAsset = asset ? asset.split("/")[0] : null;
    const chainlinkFeed = feedAsset ? CHAINLINK_FEEDS[feedAsset] || null : null;

    // Generar termsHash
    const termsData = JSON.stringify({
      productId, coverageAmount, durationDays, threshold, asset,
      premium: pricing.premium, premiumRateBps: pricing.premiumRateBps,
      deductibleBps: product.deductibleBps, maxPayout: pricing.maxPayout,
    });
    const termsHash = ethers.keccak256(ethers.toUtf8Bytes(termsData));

    // Generar quote
    const quoteId = `QT-${crypto.randomUUID().slice(0, 12)}`;
    const now = new Date();
    const expiresAt = new Date(now.getTime() + QUOTE_TTL_MS).toISOString();

    const quote = {
      id: quoteId,
      agentId: agent.id,
      productId,
      coverageAmount,
      premium: pricing.premium,
      premiumRateBps: pricing.premiumRateBps,
      durationDays,
      threshold,
      asset: asset || null,
      chainlinkFeed,
      triggerType: product.triggerType,
      sustainedPeriod: product.sustainedPeriod,
      waitingPeriod: product.waitingPeriod,
      deductibleBps: product.deductibleBps,
      maxPayout: pricing.maxPayout,
      termsHash,
      expiresAt,
    };

    insertQuote(quote);

    res.json({
      quoteId,
      productId,
      productName: product.name,
      coverageAmount,
      premium: pricing.premium,
      premiumRateBps: pricing.premiumRateBps,
      maxPayout: pricing.maxPayout,
      deductibleBps: product.deductibleBps,
      durationDays,
      threshold,
      thresholdUnit: product.thresholdUnit,
      asset: asset || null,
      triggerType: product.triggerType,
      chainlinkFeed,
      sustainedPeriod: product.sustainedPeriod,
      waitingPeriod: product.waitingPeriod,
      termsHash,
      expiresAt,
      exclusions: product.exclusions || [],
    });
  } catch (err) {
    console.error("[Quote] Error:", err.message);
    res.status(400).json({ error: err.message });
  }
});

router.get("/:quoteId", (req, res) => {
  const quote = getQuoteById(req.params.quoteId);
  if (!quote) {
    return res.status(404).json({ error: "Quote not found" });
  }
  // Verificar que pertenece al agente
  if (quote.agentId !== req.agent.id) {
    return res.status(403).json({ error: "Quote does not belong to this agent" });
  }
  // Verificar expiración
  if (new Date() > new Date(quote.expiresAt)) {
    return res.status(410).json({ error: "Quote expired", expiresAt: quote.expiresAt });
  }
  if (quote.used) {
    return res.status(410).json({ error: "Quote already used" });
  }
  res.json(quote);
});

module.exports = router;
