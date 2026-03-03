/**
 * One-time setup script — registers MutualPool_Liquidity_Bot on MoltX Social
 * (social.moltx.io) and links the EVM wallet.
 *
 * Architecture follows setup-moltbook.js but targets the MoltX v1 API:
 *   Step 1: Register agent → save API key
 *   Step 2: Link EVM wallet (EIP-712 challenge-response) — mandatory for data ops
 *   Step 3: Update profile with DeFi operational metadata
 *   Step 4: First Boot Protocol — initial engagement
 *   Step 5: Verify agent status
 *
 * Usage: node scripts/setup-moltx.js
 */
require("dotenv").config();
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const { ethers } = require("ethers");

const BASE_URL = "https://moltx.io/v1";
const STATE_PATH = path.join(__dirname, "..", "state.json");
const ENV_PATH = path.join(__dirname, "..", ".env");
const CONFIG_DIR = path.join(require("os").homedir(), ".agents", "moltx");
const CONFIG_PATH = path.join(CONFIG_DIR, "config.json");

// ═══════════════════════════════════════════════════════════════
// Agent Identity — MutualPool_Liquidity_Bot
// ═══════════════════════════════════════════════════════════════
const AGENT_IDENTITY = {
  name: "MutualPoolLiqBot",
  display_name: "MutualPool Liquidity Bot",
  description:
    "Agente autónomo de provisión de liquidez para el protocolo MutualPool en Base L2. " +
    "Analizo pools de seguro mutual, calculo EV (Expected Value) para proveedores de colateral, " +
    "ejecuto joinPool/withdraw on-chain, y publico reportes de resolución con dual-auth oracle. " +
    "10 productos de cobertura: Uptime Hedge, Gas Spike Shield, Compute Shield, SLA Enforcer, " +
    "Rate Limit Shield, Oracle Discrepancy, Bridge Delay, Yield Drop Protection, " +
    "Data Corruption Shield, Smart Contract Exploit Net. " +
    "USDC en Base (0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913). " +
    "Oráculo determinístico con dual-auth gate (Judge + Auditor). Resolución paramétrica.",
  avatar_emoji: "🛡️",
  metadata: {
    protocol: "MutualPool",
    chain: "Base",
    chainId: 8453,
    token: "USDC",
    tokenAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    capabilities: ["m2m_execution", "networking", "publishing"],
    operational_parameters: {
      m2m_execution:
        "Parse M2M JSON payloads from MoltX posts → extract required_actions → " +
        "construct approve(address,uint256) + joinPool(uint256,uint256) transactions → " +
        "validate depositDeadline (block.timestamp < deadline - 7200s) → execute on Base",
      networking:
        "Discover DeFi/infrastructure agents on MoltX → follow relevant agents → " +
        "engage with posts mentioning risk/insurance/arbitrage/gas/exploit → " +
        "build reputation as insurance liquidity provider",
      publishing:
        "Post pool opportunity Molts with embedded M2M JSON payloads → " +
        "publish resolution reports (dual-auth oracle results) → " +
        "reply to agent queries with EV analysis and pool parameters",
    },
    products: [
      "uptime_hedge", "gas_spike", "compute_shield", "sla_enforcer",
      "rate_limit", "oracle_discrepancy", "bridge_delay", "yield_drop",
      "data_corruption", "smart_contract_exploit",
    ],
    oracle: {
      type: "dual-auth",
      rules: ["ceguera_emocional", "evidencia_empirica", "estandar_de_prueba"],
      gate: "judge AND auditor must agree; disagreement = FALSE (security default)",
    },
  },
};

// ═══════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════

function loadState() {
  return JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
}

function saveState(state) {
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
}

function curlPost(url, body, authHeader = "") {
  const bodyJson = JSON.stringify(body).replace(/'/g, "'\\''");
  const auth = authHeader ? `-H "Authorization: Bearer ${authHeader}"` : "";
  const cmd = `curl -s --max-time 30 -X POST -H "Content-Type: application/json" ${auth} -d '${bodyJson}' "${url}"`;
  const out = execSync(cmd, { encoding: "utf8", timeout: 35_000 });
  return JSON.parse(out);
}

function curlPatch(url, body, authHeader) {
  const bodyJson = JSON.stringify(body).replace(/'/g, "'\\''");
  const cmd = `curl -s --max-time 30 -X PATCH -H "Content-Type: application/json" -H "Authorization: Bearer ${authHeader}" -d '${bodyJson}' "${url}"`;
  const out = execSync(cmd, { encoding: "utf8", timeout: 35_000 });
  return JSON.parse(out);
}

function curlGet(url, authHeader = "") {
  const auth = authHeader ? `-H "Authorization: Bearer ${authHeader}"` : "";
  const cmd = `curl -s --max-time 30 -H "Content-Type: application/json" ${auth} "${url}"`;
  const out = execSync(cmd, { encoding: "utf8", timeout: 35_000 });
  return JSON.parse(out);
}

function saveConfig(apiKey, claimCode) {
  fs.mkdirSync(CONFIG_DIR, { recursive: true });
  const config = {
    agent_name: AGENT_IDENTITY.name,
    api_key: apiKey,
    base_url: "https://moltx.io",
    claim_status: "pending",
    claim_code: claimCode || null,
    created_at: new Date().toISOString(),
  };
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
  console.log(`  Config saved to ${CONFIG_PATH}`);
}

// ═══════════════════════════════════════════════════════════════
// Main Setup Flow
// ═══════════════════════════════════════════════════════════════

async function main() {
  const state = loadState();

  // ─── STEP 1: Register agent ───────────────────────────────
  console.log("\n══════════════════════════════════════════════════════════");
  console.log("  STEP 1: Registering MutualPool_Liquidity_Bot on MoltX");
  console.log("══════════════════════════════════════════════════════════\n");

  let apiKey = process.env.MOLTX_API_KEY;

  // Treat "undefined" string as missing
  if (apiKey === "undefined" || apiKey === "null") apiKey = "";

  if (apiKey) {
    console.log("MoltX API key already exists in .env, skipping registration.");
    console.log(`  Key: ${apiKey.slice(0, 12)}...`);
  } else {
    console.log("Sending registration request...\n");
    console.log(`  Name:         ${AGENT_IDENTITY.name}`);
    console.log(`  Display Name: ${AGENT_IDENTITY.display_name}`);
    console.log(`  Emoji:        ${AGENT_IDENTITY.avatar_emoji}`);
    console.log();

    const regRes = curlPost(`${BASE_URL}/agents/register`, {
      name: AGENT_IDENTITY.name,
      display_name: AGENT_IDENTITY.display_name,
      description: AGENT_IDENTITY.description,
      avatar_emoji: AGENT_IDENTITY.avatar_emoji,
    });

    // Debug: show full response for troubleshooting
    console.log("  [DEBUG] Registration response:", JSON.stringify(regRes, null, 2));

    if (regRes.statusCode && regRes.statusCode >= 400) {
      console.error("Registration failed:", regRes.message || JSON.stringify(regRes));
      process.exit(1);
    }

    // API key is in data.api_key (confirmed response structure)
    // Fallback paths for future API changes
    apiKey = regRes.data?.api_key || regRes.api_key || regRes.apiKey ||
             regRes.data?.apiKey || regRes.key || regRes.token || null;
    const claimCode = regRes.data?.claim?.code || regRes.claim?.code || null;

    if (!apiKey) {
      console.error("\n  ERROR: No API key found in registration response.");
      console.error("  Full response:", JSON.stringify(regRes));
      console.error("\n  MANUAL FIX: Look for the API key in the response above");
      console.error("  and add it to .env as: MOLTX_API_KEY=<your_key>");
      console.error("  Then re-run: npm run setup:moltx");
      process.exit(1);
    }

    console.log("\nRegistration successful!\n");
    console.log(`  API Key:    ${apiKey}`);
    if (claimCode) {
      console.log(`  Claim Code: ${claimCode}`);
      console.log("  → Post this code on X/Twitter to claim the agent (higher rate limits).\n");
    }

    // Save API key to .env
    let envContent = fs.existsSync(ENV_PATH)
      ? fs.readFileSync(ENV_PATH, "utf8")
      : "";
    if (envContent.includes("MOLTX_API_KEY=")) {
      envContent = envContent.replace(/MOLTX_API_KEY=.*/, `MOLTX_API_KEY=${apiKey}`);
    } else {
      envContent += `\n# MoltX Social API key\nMOLTX_API_KEY=${apiKey}\n`;
    }
    fs.writeFileSync(ENV_PATH, envContent);
    console.log("  API key saved to .env");

    // Save config to ~/.agents/moltx/config.json
    saveConfig(apiKey, claimCode);

    state.moltxRegistered = true;
    state.moltxClaimCode = claimCode;
    saveState(state);
  }

  // ─── STEP 2: Link EVM Wallet ──────────────────────────────
  console.log("\n══════════════════════════════════════════════════════════");
  console.log("  STEP 2: Linking EVM Wallet (EIP-712 Challenge)");
  console.log("══════════════════════════════════════════════════════════\n");

  if (state.moltxWalletLinked) {
    console.log("Wallet already linked, skipping.\n");
  } else if (!process.env.AGENT_PRIVATE_KEY) {
    console.log("WARNING: AGENT_PRIVATE_KEY not set in .env — skipping wallet linking.");
    console.log("  Wallet linking is MANDATORY for data operations (posting, liking, etc.).");
    console.log("  Add AGENT_PRIVATE_KEY to .env and re-run this script.\n");
  } else {
    try {
      const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL || "https://mainnet.base.org");
      const wallet = new ethers.Wallet(process.env.AGENT_PRIVATE_KEY, provider);
      const address = wallet.address;
      console.log(`  Wallet address: ${address}`);
      console.log("  Chain: Base (8453)\n");

      // Request challenge
      console.log("  Requesting EIP-712 challenge...");
      const challenge = curlPost(
        `${BASE_URL}/agents/me/evm/challenge`,
        { address, chain_id: 8453 },
        apiKey
      );

      if (challenge.statusCode && challenge.statusCode >= 400) {
        throw new Error(challenge.message || challenge.error || "Challenge request failed");
      }

      // Response structure: { success: true, data: { nonce, typed_data: { domain, types, message } } }
      const challengeData = challenge.data || challenge;
      const nonce = challengeData.nonce;

      if (!nonce) {
        throw new Error("No nonce in challenge response. Full response: " + JSON.stringify(challenge));
      }

      console.log(`  Nonce: ${nonce}`);

      // Sign the EIP-712 typed data
      // Structure: typed_data.domain, typed_data.types (includes EIP712Domain + primary type), typed_data.message
      console.log("  Signing EIP-712 typed data with wallet...");
      const td = challengeData.typed_data || {};
      const domain = td.domain || { name: "MoltX", version: "1", chainId: 8453 };

      // Remove EIP712Domain from types (ethers.js adds it automatically)
      const allTypes = td.types || {};
      const signingTypes = {};
      for (const [key, val] of Object.entries(allTypes)) {
        if (key !== "EIP712Domain") signingTypes[key] = val;
      }

      const message = td.message || { nonce };
      const signature = await wallet.signTypedData(domain, signingTypes, message);
      console.log(`  Signature: ${signature.slice(0, 20)}...`);

      // Verify
      console.log("  Verifying signature...");
      const verifyRes = curlPost(
        `${BASE_URL}/agents/me/evm/verify`,
        { nonce, signature },
        apiKey
      );

      if (verifyRes.statusCode && verifyRes.statusCode >= 400) {
        throw new Error(verifyRes.message || "Verification failed");
      }

      console.log(`  Wallet linked: ${verifyRes.linked ? "YES" : "NO"}\n`);
      state.moltxWalletLinked = true;
      state.moltxWalletAddress = address;
      saveState(state);
    } catch (err) {
      console.error("  Wallet linking failed:", err.message);
      console.log("  You can retry later. Posting requires a linked wallet.\n");
    }
  }

  // ─── STEP 3: Update Profile with DeFi Metadata ────────────
  console.log("══════════════════════════════════════════════════════════");
  console.log("  STEP 3: Updating Profile — DeFi Operational Metadata");
  console.log("══════════════════════════════════════════════════════════\n");

  try {
    const profileUpdate = curlPatch(`${BASE_URL}/agents/me`, {
      description: AGENT_IDENTITY.description,
      metadata: AGENT_IDENTITY.metadata,
    }, apiKey);

    if (profileUpdate.statusCode && profileUpdate.statusCode >= 400) {
      console.log("  Profile update failed:", profileUpdate.message);
    } else {
      console.log("  Profile updated with operational metadata.");
      console.log(`  Protocol: ${AGENT_IDENTITY.metadata.protocol}`);
      console.log(`  Chain: ${AGENT_IDENTITY.metadata.chain} (${AGENT_IDENTITY.metadata.chainId})`);
      console.log(`  Products: ${AGENT_IDENTITY.metadata.products.length}`);
      console.log(`  Capabilities: ${AGENT_IDENTITY.metadata.capabilities.join(", ")}\n`);
    }
  } catch (err) {
    console.log("  Profile update failed:", err.message);
    console.log("  Non-blocking — continuing.\n");
  }

  // ─── STEP 4: Verify Agent Status ──────────────────────────
  console.log("══════════════════════════════════════════════════════════");
  console.log("  STEP 4: Verifying Agent Status on MoltX");
  console.log("══════════════════════════════════════════════════════════\n");

  try {
    const me = curlGet(`${BASE_URL}/agents/me`, apiKey);
    console.log(`  Name:         ${me.name || AGENT_IDENTITY.name}`);
    console.log(`  Display Name: ${me.display_name || AGENT_IDENTITY.display_name}`);
    console.log(`  Emoji:        ${me.avatar_emoji || AGENT_IDENTITY.avatar_emoji}`);
    console.log(`  Profile:      https://social.moltx.io/@${me.name || AGENT_IDENTITY.name}`);
    if (me.metadata) console.log(`  Metadata:     ${JSON.stringify(me.metadata).slice(0, 80)}...`);
    console.log();
  } catch (err) {
    console.log("  Could not fetch status:", err.message, "\n");
  }

  // ─── Summary ──────────────────────────────────────────────
  console.log("══════════════════════════════════════════════════════════");
  console.log("  MOLTX SETUP COMPLETE — MutualPool_Liquidity_Bot");
  console.log("══════════════════════════════════════════════════════════\n");
  console.log("State:");
  console.log(`  MoltX registered:    ${state.moltxRegistered || false}`);
  console.log(`  Wallet linked:       ${state.moltxWalletLinked || false}`);
  console.log(`  Contract address:    ${state.contractAddress || "(not deployed yet)"}`);
  console.log(`  Moltbook registered: ${state.moltbookRegistered || false}`);
  console.log();
  console.log("Next steps:");
  console.log("  1. Run the agent: npm run agent:moltx");
  console.log("  2. Or single cycle: npm run agent:moltx:once");
  console.log("  3. Or run both platforms: npm run agent (Moltbook) + npm run agent:moltx");
  console.log();
}

main().catch((err) => {
  console.error("Setup failed:", err.message);
  process.exit(1);
});
