/**
 * Motor de cálculo de primas — Lumina Protocol
 * Cada producto tiene su propia lógica de pricing
 */
const { PRODUCTS } = require("../config/products");

// ── Tablas de riesgo por threshold ──

const LIQSHIELD_THRESHOLD_RISK = { 3000: 50, 2500: 100, 2000: 150, 1500: 300, 1000: 500 };
const DEPEG_THRESHOLD_RISK = { 9000: 30, 9500: 80, 9700: 200, 9900: 500 };
const ILPROT_THRESHOLD_RISK = { 5000: 50, 3000: 200, 2000: 400, 1500: 700 };
const GASSPIKE_THRESHOLD_RISK = { 500: 20, 200: 80, 100: 200, 50: 400 };
const SLIPPAGE_THRESHOLD_RISK = { 1000: 30, 500: 150, 300: 350, 200: 600 };
const BRIDGE_TIME_RISK = { 48: 30, 24: 100, 12: 250, 6: 500 };

// ── Ajustes de duración ──

function liqshieldDurationAdj(days) {
  if (days <= 14) return 1.0;
  if (days <= 30) return 1.3;
  if (days <= 60) return 1.6;
  return 2.0;
}

function depegDurationAdj(days) {
  if (days <= 30) return 1.0;
  if (days <= 60) return 1.3;
  if (days <= 90) return 1.6;
  if (days <= 180) return 1.8 * 0.9;   // 1.62
  if (days <= 270) return 2.0 * 0.8;   // 1.6
  return 2.2 * 0.65;                    // 1.43
}

function ilprotDurationAdj(days) {
  if (days <= 30) return 1.0;
  return 1.3;
}

function gasspikeDurationAdj(days) {
  if (days <= 14) return 1.0;
  return 1.3;
}

// ── Ajustes extra ──

function liqshieldAmountAdj(amount) {
  if (amount < 1000) return 1.0;
  if (amount <= 10000) return 1.1;
  if (amount <= 50000) return 1.2;
  return 1.4;
}

const ILPROT_PAIR_RISK = {
  "ETH/USDC": 1.0,
  "BTC/USDC": 1.0,
  "ETH/BTC": 0.8,
};

const BRIDGE_RISK = {
  "base-bridge": 0.8,
  "across": 1.0,
  "stargate": 1.0,
  "hop": 1.0,
};

// ── Función principal ──

function calculatePremium(productId, params) {
  const product = PRODUCTS[productId];
  if (!product) throw new Error(`Producto desconocido: ${productId}`);

  const { coverageAmount, durationDays, threshold, asset, bridge } = params;
  let premiumRateBps;

  switch (productId) {
    case "LIQSHIELD-001": {
      const tRisk = LIQSHIELD_THRESHOLD_RISK[threshold];
      if (tRisk === undefined) throw new Error(`Threshold inválido para LIQSHIELD: ${threshold}`);
      const dAdj = liqshieldDurationAdj(durationDays);
      const aAdj = liqshieldAmountAdj(coverageAmount);
      premiumRateBps = Math.round(200 + tRisk * dAdj * aAdj);
      break;
    }

    case "DEPEG-USDC-001":
    case "DEPEG-USDT-001":
    case "DEPEG-DAI-001": {
      const tRisk = DEPEG_THRESHOLD_RISK[threshold];
      if (tRisk === undefined) throw new Error(`Threshold inválido para DEPEG: ${threshold}`);
      const dAdj = depegDurationAdj(durationDays);
      const sRisk = product.stablecoinRiskMultiplier;
      premiumRateBps = Math.round(100 + tRisk * dAdj * sRisk);
      break;
    }

    case "ILPROT-001": {
      const tRisk = ILPROT_THRESHOLD_RISK[threshold];
      if (tRisk === undefined) throw new Error(`Threshold inválido para ILPROT: ${threshold}`);
      const dAdj = ilprotDurationAdj(durationDays);
      const pRisk = ILPROT_PAIR_RISK[asset] ?? 1.0;
      premiumRateBps = Math.round(300 + tRisk * dAdj * pRisk);
      break;
    }

    case "GASSPIKE-001": {
      const tRisk = GASSPIKE_THRESHOLD_RISK[threshold];
      if (tRisk === undefined) throw new Error(`Threshold inválido para GASSPIKE: ${threshold}`);
      const dAdj = gasspikeDurationAdj(durationDays);
      premiumRateBps = Math.round(150 + tRisk * dAdj);
      break;
    }

    case "SLIPPAGE-001": {
      const tRisk = SLIPPAGE_THRESHOLD_RISK[threshold];
      if (tRisk === undefined) throw new Error(`Threshold inválido para SLIPPAGE: ${threshold}`);
      const vAdj = 1.0; // ETH/BTC → 1.0
      premiumRateBps = Math.round(100 + tRisk * vAdj);
      break;
    }

    case "BRIDGE-001": {
      const tRisk = BRIDGE_TIME_RISK[threshold];
      if (tRisk === undefined) throw new Error(`Threshold inválido para BRIDGE: ${threshold}`);
      const bRisk = BRIDGE_RISK[bridge] ?? 1.0;
      premiumRateBps = Math.round(200 + tRisk * bRisk);
      break;
    }

    default:
      throw new Error(`Pricing no implementado para: ${productId}`);
  }

  // Calcular premium en USDC
  let premium = Math.round((coverageAmount * premiumRateBps) / 10000);

  // Mínimo 10 USDC
  if (premium < 10) premium = 10;

  // maxPayout = coverageAmount - deducible
  const maxPayout = Math.round(coverageAmount * (1 - product.deductibleBps / 10000));

  return { premium, premiumRateBps, maxPayout };
}

module.exports = { calculatePremium };
