/**
 * LUMINA PROTOCOL — Risk Engine Service
 *
 * Calculates premiums using the same formula as the on-chain oracle:
 *   premiumRateBps = baseRate + (frequency x riskMultiplier)
 *
 * TODO: Connect to real data sources:
 *   - CoinGecko API for price history
 *   - DeFi Llama for protocol TVL/hack data
 *   - On-chain event logs for historical claims
 */

import { CoverageType } from "../types/insurance";

// Base rates and historical frequencies per coverage type
const RISK_PARAMETERS: Record<
  CoverageType,
  { baseRateBps: number; historicalFrequency: number; riskMultiplier: number }
> = {
  smart_contract_exploit: { baseRateBps: 200, historicalFrequency: 0.065, riskMultiplier: 8000 },
  depeg:                  { baseRateBps: 200, historicalFrequency: 0.04,  riskMultiplier: 8000 },
  gas_spike:              { baseRateBps: 200, historicalFrequency: 0.175, riskMultiplier: 8000 },
  oracle_failure:         { baseRateBps: 200, historicalFrequency: 0.03,  riskMultiplier: 8000 },
  liquidation:            { baseRateBps: 200, historicalFrequency: 0.10,  riskMultiplier: 8000 },
  bridge_exploit:         { baseRateBps: 200, historicalFrequency: 0.055, riskMultiplier: 8000 },
  governance_attack:      { baseRateBps: 200, historicalFrequency: 0.02,  riskMultiplier: 8000 },
  flash_loan:             { baseRateBps: 200, historicalFrequency: 0.08,  riskMultiplier: 8000 },
  rug_pull:               { baseRateBps: 200, historicalFrequency: 0.12,  riskMultiplier: 8000 },
  impermanent_loss:       { baseRateBps: 200, historicalFrequency: 0.15,  riskMultiplier: 8000 },
};

// Protocol-specific risk adjustments (multiplier on base premium)
const PROTOCOL_ADJUSTMENTS: Record<string, number> = {
  aave:      0.85,  // Battle-tested, lower risk
  compound:  0.85,
  maker:     0.90,
  uniswap:   0.95,
  curve:     0.95,
  lido:      0.90,
  balancer:  1.00,
  yearn:     1.05,
  sushiswap: 1.10,
  morpho:    1.05,
  generic:   1.20,  // Unknown protocol = higher risk
};

// Duration adjustment: longer = more risk exposure
function durationMultiplier(days: number): number {
  if (days <= 7) return 0.85;
  if (days <= 14) return 0.92;
  if (days <= 30) return 1.00;
  if (days <= 90) return 1.15;
  if (days <= 180) return 1.30;
  return 1.50;
}

// Amount adjustment: larger coverage = slightly lower rate (economies of scale)
function amountMultiplier(usdcAmount: number): number {
  if (usdcAmount < 100) return 1.20;
  if (usdcAmount < 1_000) return 1.10;
  if (usdcAmount < 10_000) return 1.00;
  if (usdcAmount < 100_000) return 0.95;
  return 0.90;
}

export interface RiskAssessment {
  premiumRateBps: number;
  premium: number;
  riskLevel: "low" | "medium" | "high" | "very_high";
  warnings: string[];
}

export function assessRisk(
  coverageType: CoverageType,
  protocol: string,
  coverageAmount: number,
  durationDays: number
): RiskAssessment {
  const params = RISK_PARAMETERS[coverageType];
  const warnings: string[] = [];

  // Base premium rate: baseRate + (frequency x multiplier)
  const basePremiumBps = params.baseRateBps + (params.historicalFrequency * params.riskMultiplier);

  // Apply adjustments
  const protocolAdj = PROTOCOL_ADJUSTMENTS[protocol.toLowerCase()] ?? PROTOCOL_ADJUSTMENTS.generic;
  const durationAdj = durationMultiplier(durationDays);
  const amountAdj = amountMultiplier(coverageAmount);

  // Unknown protocol warning
  if (!(protocol.toLowerCase() in PROTOCOL_ADJUSTMENTS)) {
    warnings.push(`Unknown protocol "${protocol}" — generic risk multiplier applied (1.2x)`);
  }

  // Final rate
  const adjustedBps = Math.round(basePremiumBps * protocolAdj * durationAdj * amountAdj);

  // Clamp between 100 bps (1%) and 5000 bps (50%)
  const finalBps = Math.max(100, Math.min(5000, adjustedBps));

  // Premium in USDC
  const premium = parseFloat(((coverageAmount * finalBps) / 10_000).toFixed(2));

  // Risk level classification
  let riskLevel: RiskAssessment["riskLevel"];
  if (finalBps <= 400) riskLevel = "low";
  else if (finalBps <= 800) riskLevel = "medium";
  else if (finalBps <= 1500) riskLevel = "high";
  else riskLevel = "very_high";

  // High-risk warnings
  if (finalBps > 1500) {
    warnings.push("Very high risk — premium exceeds 15% of coverage amount");
  }
  if (durationDays > 90) {
    warnings.push("Long duration — consider splitting into shorter coverage periods");
  }
  if (coverageAmount > 500_000) {
    warnings.push("Large coverage — may require multiple pools for full collateralization");
  }

  return { premiumRateBps: finalBps, premium, riskLevel, warnings };
}
