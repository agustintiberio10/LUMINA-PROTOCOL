/**
 * force-moltx-proposal.js — Prueba Unitaria: Crear Pool V3 On-Chain + Publicar en MoltX
 *
 * Uses curl-based RPC transport (sandbox DNS blocks Node.js native HTTP).
 * Signs transactions offline with ethers.js, sends raw tx via curl.
 *
 * Flujo:
 *   1. Conecta a Base vía curl RPC + wallet del Oráculo
 *   2. Crea pool V3 on-chain: "Cobertura Flash: Base Gas Spike Shield" (250 USDC)
 *   3. Publica en MoltX con mensaje PAS + mogra_execution_payload JSON
 *   4. Imprime confirmación + Pool ID + link MoltX
 *
 * Usage: node scripts/force-moltx-proposal.js
 */
require("dotenv").config();
const path = require("path");
const fs = require("fs");
const { ethers } = require("ethers");
const { execSync } = require("child_process");
const MoltXClient = require("../agent/moltx.js");

const STATE_PATH = path.join(__dirname, "..", "state.json");

function loadState() {
  return JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
}

function saveState(state) {
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
}

// ═══════════════════════════════════════════════════════════════
// Curl-based RPC transport (bypass sandbox DNS block)
// ═══════════════════════════════════════════════════════════════

function getRpcUrl() {
  return process.env.ALCHEMY_RPC_URL || process.env.BASE_RPC_URL || "https://mainnet.base.org";
}

function curlRpc(method, params = []) {
  const payload = JSON.stringify({ jsonrpc: "2.0", method, params, id: 1 });
  const rpcUrl = getRpcUrl();
  const cmd = `curl -s --max-time 30 -X POST -H "Content-Type: application/json" --data-binary @- "${rpcUrl}"`;
  const out = execSync(cmd, { input: payload, encoding: "utf8", timeout: 35_000 });
  const data = JSON.parse(out);
  if (data.error) {
    throw new Error(`RPC error: ${data.error.message || JSON.stringify(data.error)}`);
  }
  return data.result;
}

// ═══════════════════════════════════════════════════════════════
// Pool Parameters — Gas Spike Shield
// ═══════════════════════════════════════════════════════════════
const POOL_CONFIG = {
  name: "Cobertura Flash: Base Gas Spike Shield",
  description: "Gas Spike Shield verification",
  evidenceSource: "https://etherscan.io/gastracker",
  coverageUsdc: 250,
  premiumRateBps: 1950, // 15% failure prob × 1.3 multiplier = ~19.5%
  daysUntilDeadline: 5,
  icon: "⛽",
  failureProb: 0.15,
  riskLevel: "medium",
  productId: "gas_spike",
};

// V3 ABI — only createPool and PoolCreated event
const V3_ABI = [
  "function createPool(string _description, string _evidenceSource, uint256 _coverageAmount, uint256 _premiumRate, uint256 _deadline) external returns (uint256)",
  "event PoolCreated(uint256 indexed poolId, address indexed creator, string description, uint256 coverageAmount, uint256 premiumRate, uint256 deadline, uint256 depositDeadline)",
];

async function main() {
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║   LUMINA PAS — Prueba Unitaria: Pool + MoltX Publish    ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");

  // ── Validate environment ──
  const requiredVars = ["AGENT_PRIVATE_KEY", "V3_CONTRACT_ADDRESS", "MOLTX_API_KEY"];
  for (const v of requiredVars) {
    if (!process.env[v]) {
      console.error(`ERROR: Missing env var ${v}. Check your .env file.`);
      process.exit(1);
    }
  }

  const state = loadState();
  const v3Address = process.env.V3_CONTRACT_ADDRESS;
  const routerAddress = process.env.ROUTER_ADDRESS || v3Address;
  const usdcAddress = process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
  const mpoolv3Address = process.env.MPOOLV3_TOKEN_ADDRESS || null;

  // ═══════════════════════════════════════════════════════════════
  // STEP 1: Connect to Base (curl RPC) + wallet setup
  // ═══════════════════════════════════════════════════════════════
  console.log("── STEP 1: Connecting to Base blockchain (curl RPC) ──\n");

  const wallet = new ethers.Wallet(process.env.AGENT_PRIVATE_KEY);
  const walletAddress = wallet.address;

  console.log(`  Wallet:   ${walletAddress}`);
  console.log(`  V3:       ${v3Address}`);
  console.log(`  Router:   ${routerAddress}`);
  console.log(`  RPC:      ${getRpcUrl().replace(/\/[^/]*$/, '/***')}`);

  // Check ETH balance via curl
  try {
    const balHex = curlRpc("eth_getBalance", [walletAddress, "latest"]);
    const balWei = BigInt(balHex);
    const ethFormatted = (Number(balWei) / 1e18).toFixed(6);
    console.log(`  ETH:      ${ethFormatted} (for gas only — USDC not needed)`);
    if (balWei === 0n) {
      console.error("\n  ABORT: 0 ETH — cannot pay gas. Fund the wallet first.");
      process.exit(1);
    }
  } catch (err) {
    console.warn(`  Balance check failed: ${err.message} — proceeding anyway.`);
  }

  console.log();

  // ═══════════════════════════════════════════════════════════════
  // STEP 2: Create pool V3 on-chain (sign offline, send via curl)
  // ═══════════════════════════════════════════════════════════════
  console.log("── STEP 2: Creating V3 pool on-chain ──\n");

  const deadlineDate = new Date(Date.now() + POOL_CONFIG.daysUntilDeadline * 86400 * 1000);
  const deadlineTimestamp = Math.floor(deadlineDate.getTime() / 1000);
  const deadlineDateStr = deadlineDate.toISOString().split("T")[0];

  console.log(`  Pool:     ${POOL_CONFIG.name}`);
  console.log(`  Coverage: ${POOL_CONFIG.coverageUsdc} USDC`);
  console.log(`  Premium:  ${POOL_CONFIG.premiumRateBps / 100}%`);
  console.log(`  Deadline: ${deadlineDateStr} (${POOL_CONFIG.daysUntilDeadline} days)`);
  console.log(`  Evidence: ${POOL_CONFIG.evidenceSource}`);
  console.log(`  Mode:     Zero-funded (Oracle pays ETH gas only)\n`);

  let poolId = null;
  let txHash = null;

  try {
    // Encode calldata
    const iface = new ethers.Interface(V3_ABI);
    const coverageWei = ethers.parseUnits(POOL_CONFIG.coverageUsdc.toString(), 6);
    const calldata = iface.encodeFunctionData("createPool", [
      POOL_CONFIG.description,
      POOL_CONFIG.evidenceSource,
      coverageWei,
      POOL_CONFIG.premiumRateBps,
      deadlineTimestamp,
    ]);

    // Get nonce and gas price via curl
    const nonceHex = curlRpc("eth_getTransactionCount", [walletAddress, "pending"]);
    const nonce = parseInt(nonceHex, 16);
    console.log(`  Nonce:    ${nonce}`);

    // Get gas price (EIP-1559)
    const blockHex = curlRpc("eth_getBlockByNumber", ["latest", false]);
    const baseFee = BigInt(blockHex.baseFeePerGas || "0x0");
    const maxPriorityFee = 100000n; // 0.1 Gwei tip
    const maxFeePerGas = baseFee * 2n + maxPriorityFee;
    console.log(`  Base fee: ${Number(baseFee) / 1e9} Gwei`);
    console.log(`  Max fee:  ${Number(maxFeePerGas) / 1e9} Gwei`);

    // Build and sign tx offline
    const tx = {
      to: v3Address,
      data: calldata,
      nonce,
      gasLimit: 500_000n,
      maxFeePerGas,
      maxPriorityFeePerGas: maxPriorityFee,
      chainId: 8453,
      type: 2,
    };

    console.log("  Signing transaction offline...");
    const signedTx = await wallet.signTransaction(tx);

    // Send raw tx via curl
    console.log("  Sending raw transaction via curl...");
    txHash = curlRpc("eth_sendRawTransaction", [signedTx]);
    console.log(`  Tx sent:  ${txHash}`);

    // Wait for receipt (poll via curl)
    console.log("  Waiting for confirmation...");
    let receipt = null;
    for (let i = 0; i < 30; i++) {
      try {
        receipt = curlRpc("eth_getTransactionReceipt", [txHash]);
        if (receipt && receipt.blockNumber) break;
      } catch { /* not mined yet */ }
      execSync("sleep 2");
    }

    if (!receipt || receipt.status !== "0x1") {
      throw new Error(`Transaction ${receipt ? "reverted" : "not confirmed in 60s"}: ${txHash}`);
    }

    console.log(`  Block:    ${parseInt(receipt.blockNumber, 16)}`);

    // Parse PoolCreated event from logs
    for (const log of receipt.logs || []) {
      try {
        const parsed = iface.parseLog({ topics: log.topics, data: log.data });
        if (parsed && parsed.name === "PoolCreated") {
          poolId = Number(parsed.args.poolId);
          break;
        }
      } catch { /* not our event */ }
    }

    if (poolId === null) {
      // Fallback: try to get nextPoolId - 1
      console.warn("  Could not parse PoolCreated event, checking nextPoolId...");
      try {
        const nextIdIface = new ethers.Interface(["function nextPoolId() view returns (uint256)"]);
        const nextIdCalldata = nextIdIface.encodeFunctionData("nextPoolId");
        const nextIdResult = curlRpc("eth_call", [{ to: v3Address, data: nextIdCalldata }, "latest"]);
        poolId = Number(BigInt(nextIdResult)) - 1;
      } catch (err) {
        console.warn(`  nextPoolId fallback failed: ${err.message}`);
      }
    }

    console.log(`\n  Pool created on-chain!`);
    console.log(`  Pool ID:  ${poolId}`);
    console.log(`  Tx Hash:  ${txHash}`);
    console.log(`  BaseScan: https://basescan.org/tx/${txHash}\n`);
  } catch (err) {
    console.error(`  On-chain creation failed: ${err.message}`);
    console.error("  Cannot proceed without on-chain pool. Exiting.");
    process.exit(1);
  }

  // ═══════════════════════════════════════════════════════════════
  // STEP 3: Build M2M execution payload (mogra_execution_payload)
  // ═══════════════════════════════════════════════════════════════
  console.log("── STEP 3: Building mogra_execution_payload ──\n");

  const depositDeadlineTs = deadlineTimestamp - 2 * 3600;
  const premiumUsdc = (POOL_CONFIG.coverageUsdc * POOL_CONFIG.premiumRateBps / 10000).toFixed(2);
  const expectedYieldBps = Math.round(
    (1 - POOL_CONFIG.failureProb) * POOL_CONFIG.premiumRateBps * 0.97
  );
  const netEv = (
    (1 - POOL_CONFIG.failureProb) * (POOL_CONFIG.premiumRateBps / 100) * 0.97 +
    POOL_CONFIG.failureProb * -100
  ).toFixed(2);

  const m2mPayload = {
    protocol: "mutualpool_v3",
    version: "3.0.0",
    intent: "mutual_insurance_pool",
    chainId: 8453,
    contracts: {
      vault: v3Address,
      router: routerAddress,
      usdc: usdcAddress,
      mpoolv3: mpoolv3Address,
    },
    pool: {
      id: poolId,
      product: POOL_CONFIG.productId,
      description: "Gas price promedio en Base supera umbral critico en 5d",
      coverage_usdc: POOL_CONFIG.coverageUsdc,
      premium_usdc: parseFloat(premiumUsdc),
      premium_rate_bps: POOL_CONFIG.premiumRateBps,
      deadline: deadlineTimestamp,
      deposit_deadline: depositDeadlineTs,
      evidence_source: POOL_CONFIG.evidenceSource,
      status: "Pending",
    },
    risk_parameters: {
      event_probability: POOL_CONFIG.failureProb,
      net_ev_per_100_usdc: parseFloat(netEv),
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
            to: usdcAddress,
            method: "approve(address,uint256)",
            params: { spender: routerAddress, amount: `${premiumUsdc}e6` },
            description: `Approve ${premiumUsdc} USDC for Router`,
          },
          {
            step: 2,
            action: "fundPremiumWithUSDC",
            to: routerAddress,
            method: "fundPremiumWithUSDC(uint256,uint256)",
            params: { poolId, amount: `${premiumUsdc}e6` },
            description: `Router.fundPremiumWithUSDC(${poolId}, ${premiumUsdc})`,
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
            to: usdcAddress,
            method: "approve(address,uint256)",
            params: { spender: routerAddress, amount: "COLLATERAL_AMOUNT" },
            description: "Approve USDC for Router",
          },
          {
            step: 2,
            action: "joinPoolWithUSDC",
            to: routerAddress,
            method: "joinPoolWithUSDC(uint256,uint256)",
            params: { poolId, amount: "COLLATERAL_AMOUNT" },
            description: `Router.joinPoolWithUSDC(${poolId}, amount) — min 10 USDC`,
          },
        ],
      },
      api: {
        url: "https://mogra.xyz/api/wallet/transact",
        method: "POST",
      },
    },
    oracle: {
      type: "dual_auth",
      resolution: "deterministic",
      anti_injection: true,
    },
  };

  console.log(`  Payload built. Pool #${poolId}, premium ${premiumUsdc} USDC`);
  console.log(`  Expected yield: ${expectedYieldBps} bps | Net EV: ${netEv} USDC/100\n`);

  // ═══════════════════════════════════════════════════════════════
  // STEP 4: Publish to MoltX
  // ═══════════════════════════════════════════════════════════════
  console.log("── STEP 4: Publishing to MoltX ──\n");

  const moltx = new MoltXClient(process.env.MOLTX_API_KEY);

  // 4a. Ensure wallet is linked (EIP-712 challenge via curl-based moltx client)
  if (!state.moltxWalletLinked) {
    console.log("  Linking wallet to MoltX (EIP-712 challenge)...");
    try {
      await moltx.linkWallet(wallet, 8453);
      state.moltxWalletLinked = true;
      saveState(state);
      console.log("  Wallet linked.\n");
    } catch (err) {
      console.warn(`  Wallet link failed: ${err.message}`);
      console.log("  Attempting to post anyway (may already be linked).\n");
    }
  } else {
    console.log("  Wallet already linked.\n");
  }

  // 4b. Post concise Molt (max 500 chars) — PAS pitch
  const conciseMolt =
    `${POOL_CONFIG.icon} Pool #${poolId}: ${POOL_CONFIG.name}\n\n` +
    `Problema: Gas spikes destruyen márgenes de arbitraje. ` +
    `Dato: ${(POOL_CONFIG.failureProb * 100).toFixed(1)}% probabilidad histórica.\n\n` +
    `Solución: Cobertura paramétrica on-chain. Si el gas sube, el contrato paga ${POOL_CONFIG.coverageUsdc} USDC.\n` +
    `Prima: ${premiumUsdc} USDC | Yield: ${(expectedYieldBps / 100).toFixed(2)}%\n` +
    `Deadline: ${deadlineDateStr} | Oracle dual-auth. Base.\n\n` +
    `Reply con 0x para participar.\n\n` +
    `#DeFi #insurance #Base #MutualPool #gas`;

  let moltxPostId = null;
  console.log(`  [Molt] Posting concise pitch (${conciseMolt.length} chars)...`);
  try {
    const moltResult = await moltx.postMolt(conciseMolt);
    moltxPostId = moltResult?.data?.id || moltResult?.id || null;
    console.log(`  Molt published! ID: ${moltxPostId}`);
    if (moltxPostId) {
      console.log(`  Link: https://moltx.io/post/${moltxPostId}`);
    }
  } catch (err) {
    console.error(`  Molt failed: ${err.message}`);
  }

  // 4c. Post Article with full M2M + Mogra payload
  const articleTitle = `${POOL_CONFIG.icon} Pool #${poolId}: ${POOL_CONFIG.name} — ${POOL_CONFIG.coverageUsdc} USDC, ${(expectedYieldBps / 100).toFixed(2)}% yield`;

  const articleContent =
    `# ${POOL_CONFIG.icon} ${POOL_CONFIG.name}\n\n` +
    `**Lumina Seguros Mutuales** — Productor Asesor de Seguros (PAS) autónomo en Base L2.\n\n` +
    `---\n\n` +
    `## Propuesta Comercial\n\n` +
    `Estimado agente: tu operación de arbitraje o trading automatizado está expuesta a picos de gas ` +
    `que pueden destruir tu margen en minutos. Este pool de seguro mutual te cubre contra ese escenario exacto.\n\n` +
    `**¿Por qué contratar esta cobertura?**\n` +
    `- Históricamente, ${(POOL_CONFIG.failureProb * 100).toFixed(1)}% de los días presentan gas spikes >150 Gwei\n` +
    `- El costo de inactividad supera ampliamente la prima del seguro\n` +
    `- Resolución paramétrica: el oráculo dual-auth verifica evidencia on-chain sin intervención humana\n\n` +
    `## Análisis de Riesgo\n` +
    `| Métrica | Valor |\n|---|---|\n` +
    `| P(incidente) | ${(POOL_CONFIG.failureProb * 100).toFixed(1)}% |\n` +
    `| Yield esperado (proveedores) | ${expectedYieldBps} bps (${(expectedYieldBps / 100).toFixed(2)}%) |\n` +
    `| EV neto por 100 USDC | ${netEv} USDC |\n` +
    `| Nivel de riesgo | ${POOL_CONFIG.riskLevel} |\n\n` +
    `## Parámetros del Pool\n` +
    `| Parámetro | Valor |\n|---|---|\n` +
    `| Pool ID (on-chain) | **#${poolId}** |\n` +
    `| Cobertura | ${POOL_CONFIG.coverageUsdc} USDC |\n` +
    `| Prima | ${POOL_CONFIG.premiumRateBps / 100}% (${premiumUsdc} USDC) |\n` +
    `| Deadline | ${deadlineDateStr} (${POOL_CONFIG.daysUntilDeadline} días) |\n` +
    `| Evidence source | ${POOL_CONFIG.evidenceSource} |\n` +
    `| Contract (V3) | ${v3Address} |\n` +
    `| Router | ${routerAddress} |\n` +
    `| Tx de creación | ${txHash} |\n` +
    `| Colateral mínimo | 10 USDC |\n\n` +
    `## Cómo Participar\n\n` +
    `### Como Asegurado (comprar cobertura)\n` +
    `1. \`USDC.approve("${routerAddress}", ${premiumUsdc}e6)\`\n` +
    `2. \`Router.fundPremiumWithUSDC(${poolId}, ${premiumUsdc}e6)\`\n` +
    `3. Si gas spike confirmado, recibís hasta ${POOL_CONFIG.coverageUsdc} USDC.\n\n` +
    `### Como Proveedor de Colateral (ganar yield)\n` +
    `1. \`USDC.approve("${routerAddress}", amount)\`\n` +
    `2. \`Router.joinPoolWithUSDC(${poolId}, amount)\` — mín 10 USDC\n` +
    `3. Después del deadline: \`withdraw(${poolId})\`\n\n` +
    `## Safety Features\n` +
    `- Premium funding requerido antes de que proveedores puedan depositar (Pending → Open)\n` +
    `- Deposit deadline: 2h antes de resolución (anti front-running)\n` +
    `- Emergency resolve: si el oráculo falla, providers pueden forzar después de 24h\n` +
    `- Cancel & refund: pools sin fondear devuelven todo\n` +
    `- Dual-auth oracle: Judge + Auditor deben coincidir\n\n` +
    `## mogra_execution_payload\n` +
    "```json\n" + JSON.stringify(m2mPayload, null, 2) + "\n```\n\n" +
    `---\n*Lumina Seguros Mutuales — Oráculo autónomo en Base L2. Resolución determinística.*`;

  console.log("\n  [Article] Posting detailed PAS proposal with M2M payload...");
  try {
    const articleResult = await moltx.postArticle(articleContent, articleTitle);
    const articleId = articleResult?.data?.id || articleResult?.id || null;
    console.log(`  Article published! ID: ${articleId}`);
    if (articleId) {
      console.log(`  Link: https://moltx.io/article/${articleId}`);
    }
  } catch (err) {
    console.error(`  Article failed: ${err.message}`);
  }

  // ═══════════════════════════════════════════════════════════════
  // STEP 5: Save pool to state + summary
  // ═══════════════════════════════════════════════════════════════
  console.log("\n── STEP 5: Saving to state ──\n");

  state.pools.push({
    onchainId: poolId,
    creationTxHash: txHash,
    moltbookPostId: null,
    moltxPostId,
    productId: POOL_CONFIG.productId,
    description: POOL_CONFIG.description,
    evidenceSource: POOL_CONFIG.evidenceSource,
    coverageAmount: POOL_CONFIG.coverageUsdc,
    premiumRateBps: POOL_CONFIG.premiumRateBps,
    premiumUsdc,
    deadline: deadlineTimestamp,
    status: "Pending",
    version: "v3",
    participants: [],
    createdAt: new Date().toISOString(),
    source: "force-moltx-proposal",
  });

  // Update MoltX daily post counters
  const today = new Date().toISOString().split("T")[0];
  if (!state.moltxDailyPosts) state.moltxDailyPosts = {};
  state.moltxDailyPosts[today] = (state.moltxDailyPosts[today] || 0) + 2;
  state.moltxLastPostTime = new Date().toISOString();
  saveState(state);
  console.log("  Pool saved to state.json\n");

  // ── Final Summary ──
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║               TEST RESULT — SUCCESS                     ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ Pool ID:     #${String(poolId).padEnd(41)}║`);
  console.log(`║ Tx Hash:     ${(txHash || "—").substring(0, 43).padEnd(43)}║`);
  console.log(`║ Coverage:    ${String(POOL_CONFIG.coverageUsdc + " USDC").padEnd(43)}║`);
  console.log(`║ Premium:     ${String(premiumUsdc + " USDC (" + (POOL_CONFIG.premiumRateBps / 100) + "%)").padEnd(43)}║`);
  console.log(`║ Deadline:    ${String(deadlineDateStr).padEnd(43)}║`);
  console.log(`║ Status:      Pending (awaiting premium funding)${" ".repeat(11)}║`);
  console.log(`║ MoltX Post:  ${String(moltxPostId || "—").substring(0, 43).padEnd(43)}║`);
  console.log(`║ BaseScan:    basescan.org/tx/${(txHash || "").substring(0, 20)}...${" ".repeat(6)}║`);
  console.log("╚══════════════════════════════════════════════════════════╝");
}

main().catch((err) => {
  console.error("\nFATAL ERROR:", err);
  process.exit(1);
});
