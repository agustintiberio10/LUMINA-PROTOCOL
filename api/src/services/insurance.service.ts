/**
 * LUMINA PROTOCOL — Insurance Service
 *
 * Core business logic: quoting, issuing, and tracking policies.
 *
 * Storage: In-memory Map for now.
 * TODO: Replace with PostgreSQL + Prisma for production:
 *   - quotes table (TTL index for auto-cleanup)
 *   - policies table (indexed by policyId, payerAddress, status)
 *   - Add Redis cache layer for hot quote lookups
 *
 * Blockchain: Simulated for now.
 * TODO: Connect to real blockchain client:
 *   - Verify txHash on Base L2 via ethers.js
 *   - Call MutualLumina.createAndFund() to create on-chain pool
 *   - Monitor pool lifecycle via event listeners
 */

import { nanoid } from "nanoid";
import { assessRisk } from "./risk.service";
import { CONFIG } from "../utils/config";
import type {
  QuoteRequest,
  QuoteResponse,
  IssueRequest,
  IssueResponse,
  StatusResponse,
  StoredQuote,
  StoredPolicy,
} from "../types/insurance";

// ── In-Memory Storage ──
// TODO: Replace with database
const quotes = new Map<string, StoredQuote>();
const policies = new Map<string, StoredPolicy>();

// ── Periodic cleanup of expired quotes ──
setInterval(() => {
  const now = new Date();
  for (const [id, quote] of quotes) {
    if (quote.expiresAt < now && !quote.used) {
      quotes.delete(id);
    }
  }
}, 5 * 60 * 1000); // Every 5 minutes

// ══════════════════════════════════════════════════════════════
// COTIZAR — Generate a quote
// ══════════════════════════════════════════════════════════════

export function createQuote(req: QuoteRequest): QuoteResponse {
  const quoteId = `QT-${nanoid(12)}`;

  // Run risk assessment
  const risk = assessRisk(
    req.coverageType,
    req.protocol,
    req.coverageAmount,
    req.durationDays
  );

  // Calculate deadline
  const now = new Date();
  const deadline = new Date(now.getTime() + req.durationDays * 24 * 60 * 60 * 1000);
  const quoteExpiry = new Date(now.getTime() + CONFIG.QUOTE_TTL_MINUTES * 60 * 1000);

  // Store quote
  const stored: StoredQuote = {
    quoteId,
    coverageType: req.coverageType,
    protocol: req.protocol,
    coverageAmount: req.coverageAmount,
    durationDays: req.durationDays,
    premium: risk.premium,
    premiumRate: risk.premiumRateBps,
    riskLevel: risk.riskLevel,
    warnings: risk.warnings,
    createdAt: now,
    expiresAt: quoteExpiry,
    used: false,
  };
  quotes.set(quoteId, stored);

  return {
    quoteId,
    coverageType: req.coverageType,
    protocol: req.protocol,
    coverageAmount: req.coverageAmount,
    durationDays: req.durationDays,
    premium: risk.premium,
    premiumRate: risk.premiumRateBps,
    riskLevel: risk.riskLevel,
    deadline: deadline.toISOString(),
    quoteExpiresAt: quoteExpiry.toISOString(),
    warnings: risk.warnings,
    metadata: {
      chain: CONFIG.CHAIN,
      token: "USDC",
      contract: CONFIG.LUMINA_CONTRACT,
      disputeResolver: CONFIG.DISPUTE_RESOLVER,
      feeModel: `${CONFIG.PROTOCOL_FEE_BPS / 100}% protocol fee on resolution`,
    },
  };
}

// ══════════════════════════════════════════════════════════════
// EMITIR — Issue a policy from a confirmed quote
// ══════════════════════════════════════════════════════════════

export function issuePolicy(req: IssueRequest): IssueResponse {
  // Validate quote exists and is valid
  const quote = quotes.get(req.quoteId);
  if (!quote) {
    throw new PolicyError("Quote not found", "QUOTE_NOT_FOUND");
  }
  if (quote.used) {
    throw new PolicyError("Quote already used", "QUOTE_ALREADY_USED");
  }
  if (quote.expiresAt < new Date()) {
    throw new PolicyError("Quote expired — request a new one", "QUOTE_EXPIRED");
  }

  // TODO: Verify txHash on-chain
  // - Use ethers.js to check that the tx exists on Base L2
  // - Verify the tx transferred the correct premium amount in USDC
  // - Verify the tx was sent from payerAddress
  // Example:
  //   const receipt = await provider.getTransactionReceipt(req.txHash);
  //   if (!receipt || receipt.status !== 1) throw new PolicyError(...)

  // Mark quote as used
  quote.used = true;

  // Create policy
  const policyId = `POL-${nanoid(12)}`;
  const now = new Date();
  const expiresAt = new Date(now.getTime() + quote.durationDays * 24 * 60 * 60 * 1000);

  const policy: StoredPolicy = {
    policyId,
    quoteId: req.quoteId,
    status: "active",
    coverageType: quote.coverageType,
    protocol: quote.protocol,
    coverageAmount: quote.coverageAmount,
    premium: quote.premium,
    premiumRate: quote.premiumRate,
    durationDays: quote.durationDays,
    activatedAt: now,
    expiresAt,
    payerAddress: req.payerAddress,
    txHash: req.txHash,
    onChainPoolId: null, // TODO: Set after createAndFund() on-chain
    claimApproved: null,
    resolvedAt: null,
  };
  policies.set(policyId, policy);

  // TODO: Create on-chain pool
  // - Call blockchain.createAndFundLumina() with pool parameters
  // - Store the returned poolId in policy.onChainPoolId
  // Example:
  //   const poolId = await blockchain.createAndFundLumina({
  //     description: `${quote.coverageType} coverage for ${quote.protocol}`,
  //     evidenceSource: `lumina-api:${policyId}`,
  //     coverageAmount: quote.coverageAmount * 1e6, // USDC decimals
  //     premiumRate: quote.premiumRate,
  //     deadline: Math.floor(expiresAt.getTime() / 1000),
  //   });
  //   policy.onChainPoolId = poolId;

  return {
    policyId,
    quoteId: req.quoteId,
    status: "active",
    coverageType: quote.coverageType,
    protocol: quote.protocol,
    coverageAmount: quote.coverageAmount,
    premium: quote.premium,
    premiumRate: quote.premiumRate,
    activatedAt: now.toISOString(),
    expiresAt: expiresAt.toISOString(),
    payerAddress: req.payerAddress,
    txHash: req.txHash,
    onChain: {
      poolId: policy.onChainPoolId,
      contract: CONFIG.LUMINA_CONTRACT,
      explorerUrl: policy.onChainPoolId
        ? `${CONFIG.EXPLORER_BASE}/address/${CONFIG.LUMINA_CONTRACT}`
        : null,
    },
    verification: {
      oracle: "Dual-Auth (Judge + Auditor LLM consensus)",
      tee: "Phala Network (Intel TDX) — hardware-attested execution",
      disputeResolver: CONFIG.DISPUTE_RESOLVER,
      disputeWindow: `${CONFIG.DISPUTE_WINDOW_HOURS}h — all resolutions pass through DisputeResolver`,
    },
  };
}

// ══════════════════════════════════════════════════════════════
// ESTADO — Get policy status
// ══════════════════════════════════════════════════════════════

export function getPolicyStatus(policyId: string): StatusResponse {
  const policy = policies.get(policyId);
  if (!policy) {
    throw new PolicyError("Policy not found", "POLICY_NOT_FOUND");
  }

  // Auto-update status if expired
  const now = new Date();
  if (policy.status === "active" && policy.expiresAt < now) {
    policy.status = "expired";
  }

  // Calculate remaining days
  const remainingMs = Math.max(0, policy.expiresAt.getTime() - now.getTime());
  const remainingDays = Math.ceil(remainingMs / (24 * 60 * 60 * 1000));

  // TODO: Check on-chain status
  // - Query MutualLumina.getPool(poolId) for real status
  // - Check DisputeResolver.getProposal(poolId) for dispute info
  // - Sync claimApproved and resolvedAt from on-chain events

  return {
    policyId: policy.policyId,
    status: policy.status,
    coverageType: policy.coverageType,
    protocol: policy.protocol,
    coverageAmount: policy.coverageAmount,
    premium: policy.premium,
    activatedAt: policy.activatedAt.toISOString(),
    expiresAt: policy.expiresAt.toISOString(),
    remainingDays,
    resolution: {
      resolved: policy.resolvedAt !== null,
      claimApproved: policy.claimApproved,
      resolvedAt: policy.resolvedAt?.toISOString() ?? null,
      disputeWindow: {
        active: false, // TODO: Check DisputeResolver on-chain
        expiresAt: null,
      },
    },
    onChain: {
      poolId: policy.onChainPoolId,
      txHash: policy.txHash,
      contract: CONFIG.LUMINA_CONTRACT,
      explorerUrl: policy.onChainPoolId
        ? `${CONFIG.EXPLORER_BASE}/address/${CONFIG.LUMINA_CONTRACT}`
        : null,
    },
  };
}

// ── Custom Error Class ──

export class PolicyError extends Error {
  constructor(
    message: string,
    public readonly code: string
  ) {
    super(message);
    this.name = "PolicyError";
  }
}
