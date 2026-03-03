/**
 * GET /api/v1/products — Catálogo público de productos (sin auth)
 */
const express = require("express");
const { PRODUCTS, CHAINLINK_FEEDS } = require("../config/products");

const router = express.Router();

router.get("/", (req, res) => {
  // Transformar productos para respuesta pública
  const catalog = Object.values(PRODUCTS).map((p) => ({
    id: p.id,
    name: p.name,
    description: p.description,
    triggerType: p.triggerType,
    availableAssets: p.availableAssets,
    thresholdOptions: p.thresholdOptions,
    thresholdUnit: p.thresholdUnit,
    durationRange: { min: p.minDurationDays, max: p.maxDurationDays },
    coverageRange: { min: p.minCoverageUSDC, max: p.maxCoverageUSDC },
    minPremiumUSDC: p.minPremiumUSDC,
    deductibleBps: p.deductibleBps,
    waitingPeriod: p.waitingPeriod,
    sustainedPeriod: p.sustainedPeriod,
    coolingOffPeriod: p.coolingOffPeriod,
    supportsAutoRenew: p.supportsAutoRenew || false,
    supportedBridges: p.supportedBridges || null,
    exclusions: p.exclusions || [],
  }));

  res.json({
    products: catalog,
    chainlinkFeeds: CHAINLINK_FEEDS,
    termsVersion: "1.1.0",
    chain: "Base L2 (8453)",
  });
});

module.exports = router;
