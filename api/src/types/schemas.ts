/**
 * LUMINA PROTOCOL — Input Validation Schemas
 * Zod ensures machines send us correct data
 */

import { z } from "zod";
import { COVERAGE_TYPES } from "./insurance";

export const QuoteRequestSchema = z.object({
  coverageType: z.enum(COVERAGE_TYPES, {
    errorMap: () => ({
      message: `Must be one of: ${COVERAGE_TYPES.join(", ")}`,
    }),
  }),
  protocol: z
    .string()
    .min(1, "Protocol name required")
    .max(50)
    .toLowerCase()
    .default("generic"),
  coverageAmount: z
    .number()
    .min(10, "Minimum coverage: 10 USDC")
    .max(10_000_000, "Maximum coverage: 10M USDC"),
  durationDays: z
    .number()
    .int("Must be whole number")
    .min(1, "Minimum: 1 day")
    .max(365, "Maximum: 365 days"),
  description: z.string().max(500).optional(),
  callerAddress: z
    .string()
    .regex(/^0x[a-fA-F0-9]{40}$/, "Invalid Ethereum address")
    .optional(),
});

export const IssueRequestSchema = z.object({
  quoteId: z.string().min(1, "Quote ID required"),
  txHash: z
    .string()
    .regex(/^0x[a-fA-F0-9]{64}$/, "Invalid transaction hash"),
  payerAddress: z
    .string()
    .regex(/^0x[a-fA-F0-9]{40}$/, "Invalid Ethereum address"),
});

export const PolicyIdSchema = z.object({
  id: z.string().min(1, "Policy ID required"),
});
