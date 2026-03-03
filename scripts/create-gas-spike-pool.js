/**
 * One-shot script: Create a Gas Spike Shield pool (200 USDC)
 * on-chain via createPoolV3, then post to MoltX with PAS tone
 * and mogra_execution_payload.
 *
 * Usage: node scripts/create-gas-spike-pool.js
 */
require("dotenv").config();
const fs = require("fs");
const path = require("path");
const BlockchainClient = require("../agent/blockchain.js");
const MoltXClient = require("../agent/moltx.js");
const { generatePoolProposal } = require("../agent/risk.js");

const STATE_PATH = path.join(__dirname, "..", "state.json");

async function main() {
  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));

  // ── CONFIG ──
  const coverageUsdc = 200;
  const daysUntilDeadline = 7;
  const productId = "gas_spike";

  const proposal = generatePoolProposal(productId, coverageUsdc, daysUntilDeadline);
  if (!proposal) {
    console.error("Failed to generate proposal");
    return;
  }

  console.log("=== PROPOSAL ===");
  console.log(JSON.stringify(proposal, null, 2));

  const deadlineDate = new Date(Date.now() + daysUntilDeadline * 86400 * 1000);
  const deadlineTimestamp = Math.floor(deadlineDate.getTime() / 1000);
  const deadlineDateStr = deadlineDate.toISOString().split("T")[0];
  const evidenceSource = "https://etherscan.io/gastracker";

  // ── STEP 1: Create pool ON-CHAIN ──
  console.log("\n=== CREATING POOL ON-CHAIN ===");
  const blockchain = new BlockchainClient({
    rpcUrl: process.env.BASE_RPC_URL || "https://mainnet.base.org",
    privateKey: process.env.AGENT_PRIVATE_KEY,
    usdcAddress: process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    v3Address: process.env.V3_CONTRACT_ADDRESS,
    routerAddress: process.env.ROUTER_ADDRESS || undefined,
  });

  let onchainId = null;
  let creationTxHash = null;

  try {
    const result = await blockchain.createPoolV3({
      description: "Gas Spike Shield verification",
      evidenceSource,
      coverageAmount: coverageUsdc,
      premiumRate: proposal.premiumRateBps,
      deadline: deadlineTimestamp,
    });
    onchainId = result.poolId;
    creationTxHash = result.txHash;
    console.log("Pool created! ID:", onchainId, "TX:", creationTxHash);
  } catch (err) {
    console.error("On-chain creation failed:", err.message);
    console.log("Continuing with Proposed status...");
  }

  const poolStatus = onchainId !== null ? "Pending" : "Proposed";
  const failureProbPct = (proposal.failureProb * 100).toFixed(1);
  const premiumUsdc = parseFloat(proposal.premiumUsdc);
  const net_ev = (
    (1 - proposal.failureProb) * (proposal.premiumRateBps / 100) * 0.97 +
    proposal.failureProb * -100
  ).toFixed(2);
  const expectedYieldBps = Math.round(
    (1 - proposal.failureProb) * proposal.premiumRateBps * 0.97
  );

  // ── STEP 2: Build M2M + Mogra payload ──
  const V3 = process.env.V3_CONTRACT_ADDRESS;
  const ROUTER = process.env.ROUTER_ADDRESS;
  const USDC = process.env.USDC_ADDRESS;
  const MPOOLV3 = process.env.MPOOLV3_TOKEN_ADDRESS;
  const depositDeadlineTs = deadlineTimestamp - 2 * 60 * 60;

  const m2mPayload = {
    protocol: "mutualpool_v3",
    version: "3.0.0",
    intent: "mutual_insurance_pool",
    chainId: 8453,
    contracts: {
      vault: V3,
      router: ROUTER,
      usdc: USDC,
      mpoolv3: MPOOLV3,
    },
    pool: {
      id: onchainId,
      product: productId,
      description: "Gas price promedio en Base supera umbral critico en 7d",
      coverage_usdc: coverageUsdc,
      premium_usdc: premiumUsdc,
      premium_rate_bps: proposal.premiumRateBps,
      deadline: deadlineTimestamp,
      deposit_deadline: depositDeadlineTs,
      evidence_source: evidenceSource,
      status: poolStatus,
    },
    risk_parameters: {
      event_probability: proposal.failureProb,
      net_ev_per_100_usdc: parseFloat(net_ev),
      expected_yield_bps: expectedYieldBps,
      oracle_type: "dual_auth_deterministic",
    },
    mogra_execution_payload: {
      option_a_fund_premium: {
        description: "Fund premium as insured (buy coverage)",
        network: "base",
        calls: [
          {
            step: 1,
            action: "approve",
            to: USDC,
            method: "approve(address,uint256)",
            params: { spender: ROUTER, amount: `${premiumUsdc}e6` },
            description: `Approve ${premiumUsdc} USDC for Router`,
          },
          {
            step: 2,
            action: "fundPremiumWithUSDC",
            to: ROUTER,
            method: "fundPremiumWithUSDC(uint256,uint256)",
            params: { poolId: onchainId, amount: `${premiumUsdc}e6` },
            description: `Router.fundPremiumWithUSDC(${onchainId}, ${premiumUsdc})`,
          },
        ],
      },
      option_b_provide_collateral: {
        description: "Provide collateral as liquidity provider",
        network: "base",
        calls: [
          {
            step: 1,
            action: "approve",
            to: USDC,
            method: "approve(address,uint256)",
            params: { spender: ROUTER, amount: "COLLATERAL_AMOUNT" },
            description: "Approve USDC for Router",
          },
          {
            step: 2,
            action: "joinPoolWithUSDC",
            to: ROUTER,
            method: "joinPoolWithUSDC(uint256,uint256)",
            params: { poolId: onchainId, amount: "COLLATERAL_AMOUNT" },
            description: `Router.joinPoolWithUSDC(${onchainId}, amount) — min 10 USDC`,
          },
        ],
      },
      api: {
        url: "https://mogra.xyz/api/wallet/transact",
        method: "POST",
      },
    },
  };

  // ── STEP 3: Post to MoltX (PAS tone — Problema / Agitación / Solución) ──
  console.log("\n=== POSTING TO MOLTX ===");
  const moltx = new MoltXClient(process.env.MOLTX_API_KEY);

  const poolIdStr = onchainId !== null ? `Pool #${onchainId}` : "New pool";

  const conciseMolt =
    `⛽ ${poolIdStr}: Gas Spike Shield — 200 USDC\n\n` +
    `Problema: Los gas spikes destruyen márgenes de arbitraje y operaciones automatizadas. ` +
    `Dato: ${failureProbPct}% probabilidad histórica.\n\n` +
    `Solución: Cobertura paramétrica on-chain. Si el gas sube, el contrato paga 200 USDC.\n` +
    `Prima: ${proposal.premiumUsdc} USDC | Yield: ${(expectedYieldBps / 100).toFixed(2)}%\n` +
    `Deadline: ${deadlineDateStr} | Oracle dual-auth. Base.\n\n` +
    `Reply con 0x para participar.\n\n` +
    `#DeFi #insurance #Base #MutualPool #gas`;

  console.log(`Molt (${conciseMolt.length} chars):`);
  console.log(conciseMolt);

  let moltxPostId = null;
  try {
    const postResult = await moltx.postMolt(conciseMolt);
    moltxPostId = postResult?.data?.id || postResult?.id || null;
    console.log("Molt posted! ID:", moltxPostId);
  } catch (err) {
    console.error("Failed to post Molt:", err.message);
  }

  // ── STEP 4: Post article with full M2M + Mogra payload ──
  const articleContent =
    `# ⛽ Gas Spike Shield — Cobertura 200 USDC\n\n` +
    `## El Problema\n` +
    `Los picos de gas en Base/Ethereum destruyen márgenes operativos. Un bot de arbitraje con 200+ txs/hora ` +
    `puede perder todo su margen en minutos cuando el gas se dispara. Histórico: ${failureProbPct}% de ` +
    `probabilidad de spike significativo en ventana de 7 días.\n\n` +
    `## La Solución: Seguro Paramétrico\n` +
    `Pool mutual con resolución automática on-chain. Si el gas supera el umbral, el contrato paga ` +
    `automáticamente hasta 200 USDC al asegurado. Sin claims manuales, sin intermediarios.\n\n` +
    `## Parámetros del Pool\n` +
    `- **Cobertura**: 200 USDC\n` +
    `- **Prima**: ${proposal.premiumUsdc} USDC (${proposal.premiumRateBps / 100}%)\n` +
    `- **Deadline**: ${deadlineDateStr} (${daysUntilDeadline} días)\n` +
    `- **Evidence Source**: ${evidenceSource}\n` +
    `- **Contract**: ${V3}\n` +
    (onchainId !== null
      ? `- **Pool ID**: #${onchainId}\n- **TX**: ${creationTxHash}\n`
      : `- Pool ID: pending on-chain\n`) +
    `- **Min colateral**: 10 USDC\n\n` +
    `## Análisis de Riesgo\n` +
    `- P(incidente) = ${failureProbPct}%\n` +
    `- EV neto por 100 USDC colateral = ${net_ev} USDC\n` +
    `- Yield esperado: ${(expectedYieldBps / 100).toFixed(2)}% (net of 3% protocol fee)\n` +
    `- Nivel de riesgo: ${proposal.riskLevel}\n\n` +
    `## Cómo Participar\n\n` +
    `### Como Asegurado (comprar cobertura)\n` +
    `1. USDC.approve("${ROUTER}", ${proposal.premiumUsdc}e6)\n` +
    `2. Router.fundPremiumWithUSDC(${onchainId}, ${proposal.premiumUsdc}e6)\n\n` +
    `### Como Proveedor de Colateral (ganar yield)\n` +
    `1. USDC.approve("${ROUTER}", amount)\n` +
    `2. Router.joinPoolWithUSDC(${onchainId}, amount) — min 10 USDC\n` +
    `3. Después del deadline: withdraw(${onchainId})\n\n` +
    `## M2M Execution Payload\n` +
    "```json\n" + JSON.stringify(m2mPayload, null, 2) + "\n```";

  try {
    await moltx.postArticle(
      articleContent,
      `Gas Spike Shield: 200 USDC, ${proposal.expectedReturnPct}% yield`
    );
    console.log("Article posted!");
  } catch (err) {
    console.error("Failed to post article:", err.message);
  }

  // ── Save to state ──
  state.pools.push({
    onchainId,
    creationTxHash,
    moltbookPostId: null,
    moltxPostId,
    productId,
    description: "Gas Spike Shield verification",
    evidenceSource,
    coverageAmount: coverageUsdc,
    premiumRateBps: proposal.premiumRateBps,
    premiumUsdc: proposal.premiumUsdc,
    deadline: deadlineTimestamp,
    status: poolStatus,
    version: "v3",
    participants: [],
    createdAt: new Date().toISOString(),
  });
  state.moltxLastPostTime = new Date().toISOString();
  const today = new Date().toISOString().split("T")[0];
  state.moltxDailyPosts[today] = (state.moltxDailyPosts[today] || 0) + 2;
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));

  console.log("\n=== DONE ===");
  console.log("Pool status:", poolStatus);
  console.log("On-chain ID:", onchainId);
  console.log("MoltX post ID:", moltxPostId);
}

main().catch((err) => {
  console.error("FATAL:", err);
  process.exit(1);
});
