/**
 * LUMINA PROTOCOL — Type Definitions
 * Strict typing for M2M parametric insurance API
 */

// Coverage categories (matches on-chain EVENT_CATEGORIES)
export const COVERAGE_TYPES = [
  "smart_contract_exploit",
  "depeg",
  "gas_spike",
  "oracle_failure",
  "liquidation",
  "bridge_exploit",
  "governance_attack",
  "flash_loan",
  "rug_pull",
  "impermanent_loss",
] as const;

export type CoverageType = (typeof COVERAGE_TYPES)[number];

export const SUPPORTED_PROTOCOLS = [
  "aave", "compound", "uniswap", "curve", "maker",
  "lido", "yearn", "balancer", "sushiswap", "morpho",
  "generic",
] as const;

export type SupportedProtocol = (typeof SUPPORTED_PROTOCOLS)[number];

export type PolicyStatus = "quoted" | "active" | "expired" | "claimed" | "rejected";

// POST /cotizar - request
export interface QuoteRequest {
  coverageType: CoverageType;
  protocol: string;
  coverageAmount: number;      // USDC (min 10)
  durationDays: number;        // 1-365
  description?: string;
  callerAddress?: string;
}

// POST /cotizar - response
export interface QuoteResponse {
  quoteId: string;
  coverageType: CoverageType;
  protocol: string;
  coverageAmount: number;
  durationDays: number;
  premium: number;
  premiumRate: number;          // Basis points
  riskLevel: "low" | "medium" | "high" | "very_high";
  deadline: string;             // ISO - coverage end
  quoteExpiresAt: string;       // ISO - quote valid 1 hour
  warnings: string[];
  metadata: {
    chain: string;
    token: string;
    contract: string;
    disputeResolver: string;
    feeModel: string;
  };
}

// POST /emitir - request
export interface IssueRequest {
  quoteId: string;
  txHash: string;               // Payment tx on Base L2
  payerAddress: string;
}

// POST /emitir - response
export interface IssueResponse {
  policyId: string;
  quoteId: string;
  status: PolicyStatus;
  coverageType: CoverageType;
  protocol: string;
  coverageAmount: number;
  premium: number;
  premiumRate: number;
  activatedAt: string;
  expiresAt: string;
  payerAddress: string;
  txHash: string;
  onChain: {
    poolId: number | null;
    contract: string;
    explorerUrl: string | null;
  };
  verification: {
    oracle: string;
    tee: string;
    disputeResolver: string;
    disputeWindow: string;
  };
}

// GET /estado/:id - response
export interface StatusResponse {
  policyId: string;
  status: PolicyStatus;
  coverageType: CoverageType;
  protocol: string;
  coverageAmount: number;
  premium: number;
  activatedAt: string;
  expiresAt: string;
  remainingDays: number;
  resolution: {
    resolved: boolean;
    claimApproved: boolean | null;
    resolvedAt: string | null;
    disputeWindow: {
      active: boolean;
      expiresAt: string | null;
    };
  };
  onChain: {
    poolId: number | null;
    txHash: string;
    contract: string;
    explorerUrl: string | null;
  };
}

// Internal storage (replace with DB in production)
export interface StoredQuote {
  quoteId: string;
  coverageType: CoverageType;
  protocol: string;
  coverageAmount: number;
  durationDays: number;
  premium: number;
  premiumRate: number;
  riskLevel: "low" | "medium" | "high" | "very_high";
  warnings: string[];
  createdAt: Date;
  expiresAt: Date;
  used: boolean;
}

export interface StoredPolicy {
  policyId: string;
  quoteId: string;
  status: PolicyStatus;
  coverageType: CoverageType;
  protocol: string;
  coverageAmount: number;
  premium: number;
  premiumRate: number;
  durationDays: number;
  activatedAt: Date;
  expiresAt: Date;
  payerAddress: string;
  txHash: string;
  onChainPoolId: number | null;
  claimApproved: boolean | null;
  resolvedAt: Date | null;
}

export interface ApiError {
  error: string;
  code: string;
  details?: Record<string, string[]>;
  timestamp: string;
}
