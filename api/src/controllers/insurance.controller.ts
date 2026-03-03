/**
 * LUMINA PROTOCOL — Insurance Controller
 * Handles request parsing, validation, and response formatting.
 * Business logic lives in services — controllers are thin.
 */

import type { FastifyRequest, FastifyReply } from "fastify";
import { QuoteRequestSchema, IssueRequestSchema, PolicyIdSchema } from "../types/schemas";
import { createQuote, issuePolicy, getPolicyStatus, PolicyError } from "../services/insurance.service";

// ── POST /api/v1/cotizar ──

export async function cotizarHandler(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  // Validate input with Zod
  const parsed = QuoteRequestSchema.safeParse(request.body);
  if (!parsed.success) {
    reply.status(400).send({
      error: "Invalid request body",
      code: "VALIDATION_ERROR",
      details: parsed.error.flatten().fieldErrors,
      timestamp: new Date().toISOString(),
    });
    return;
  }

  try {
    const quote = createQuote(parsed.data);
    reply.status(200).send(quote);
  } catch (err) {
    handleError(err, reply);
  }
}

// ── POST /api/v1/emitir ──

export async function emitirHandler(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  const parsed = IssueRequestSchema.safeParse(request.body);
  if (!parsed.success) {
    reply.status(400).send({
      error: "Invalid request body",
      code: "VALIDATION_ERROR",
      details: parsed.error.flatten().fieldErrors,
      timestamp: new Date().toISOString(),
    });
    return;
  }

  try {
    const policy = issuePolicy(parsed.data);
    reply.status(201).send(policy);
  } catch (err) {
    handleError(err, reply);
  }
}

// ── GET /api/v1/estado/:id ──

export async function estadoHandler(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<void> {
  const parsed = PolicyIdSchema.safeParse(request.params);
  if (!parsed.success) {
    reply.status(400).send({
      error: "Invalid policy ID",
      code: "VALIDATION_ERROR",
      details: parsed.error.flatten().fieldErrors,
      timestamp: new Date().toISOString(),
    });
    return;
  }

  try {
    const status = getPolicyStatus(parsed.data.id);
    reply.status(200).send(status);
  } catch (err) {
    handleError(err, reply);
  }
}

// ── Error Handler ──

function handleError(err: unknown, reply: FastifyReply): void {
  if (err instanceof PolicyError) {
    const statusMap: Record<string, number> = {
      QUOTE_NOT_FOUND: 404,
      QUOTE_ALREADY_USED: 409,
      QUOTE_EXPIRED: 410,
      POLICY_NOT_FOUND: 404,
    };
    const status = statusMap[err.code] ?? 400;
    reply.status(status).send({
      error: err.message,
      code: err.code,
      timestamp: new Date().toISOString(),
    });
    return;
  }

  console.error("[Controller] Unexpected error:", err);
  reply.status(500).send({
    error: "Internal server error",
    code: "INTERNAL_ERROR",
    timestamp: new Date().toISOString(),
  });
}
