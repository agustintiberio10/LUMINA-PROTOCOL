/**
 * LUMINA PROTOCOL — API Routes
 * All v1 insurance endpoints
 */

import type { FastifyInstance } from "fastify";
import { cotizarHandler, emitirHandler, estadoHandler } from "../controllers/insurance.controller";

export async function insuranceRoutes(app: FastifyInstance): Promise<void> {
  // POST /api/v1/cotizar — Get a coverage quote
  app.post("/api/v1/cotizar", cotizarHandler);

  // POST /api/v1/emitir — Issue a policy from a confirmed quote
  app.post("/api/v1/emitir", emitirHandler);

  // GET /api/v1/estado/:id — Check policy status
  app.get("/api/v1/estado/:id", estadoHandler);
}
