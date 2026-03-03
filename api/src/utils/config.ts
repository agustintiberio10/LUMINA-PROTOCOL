/**
 * LUMINA PROTOCOL — Configuration
 */

import dotenv from "dotenv";
dotenv.config();

export const CONFIG = {
  // Server
  PORT: parseInt(process.env.PORT || "3100", 10),
  HOST: process.env.HOST || "0.0.0.0",
  NODE_ENV: process.env.NODE_ENV || "development",

  // Rate limiting
  RATE_LIMIT_MAX: parseInt(process.env.RATE_LIMIT_MAX || "100", 10),
  RATE_LIMIT_WINDOW: process.env.RATE_LIMIT_WINDOW || "1 minute",

  // Quote validity
  QUOTE_TTL_MINUTES: 60,

  // On-chain addresses (Base Mainnet)
  LUMINA_CONTRACT: "0x1c5E5c90aC46e960aACbfCeAE9dEC2F79ce06bd7",
  DISPUTE_RESOLVER: "0x2e4D0112A65C2e2DCE73e7F85bF5C2889c7709cA",
  FEE_ROUTER: "0x205b14015e5f807DC12E31D188F05b17FcA304f4",
  USDC_ADDRESS: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",

  // Chain
  CHAIN: "Base L2 (8453)",
  EXPLORER_BASE: "https://basescan.org",

  // Protocol fee
  PROTOCOL_FEE_BPS: 300, // 3%
  BPS_DENOMINATOR: 10_000,

  // Dispute window
  DISPUTE_WINDOW_HOURS: 24,
} as const;
