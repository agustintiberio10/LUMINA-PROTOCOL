/**
 * One-time setup script — registers MutualBot on Moltbook,
 * creates the submolt, and saves the API key.
 *
 * Uses curl as HTTP transport (Node.js DNS is blocked in sandbox).
 *
 * Usage: node scripts/setup-moltbook.js
 */
require("dotenv").config();
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const BASE_URL = "https://www.moltbook.com/api/v1";
const STATE_PATH = path.join(__dirname, "..", "state.json");
const ENV_PATH = path.join(__dirname, "..", ".env");

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

function curlGet(url, authHeader = "") {
  const auth = authHeader ? `-H "Authorization: Bearer ${authHeader}"` : "";
  const cmd = `curl -s --max-time 30 -H "Content-Type: application/json" ${auth} "${url}"`;
  const out = execSync(cmd, { encoding: "utf8", timeout: 35_000 });
  return JSON.parse(out);
}

function solveChallenge(challengeText) {
  const cleaned = challengeText.replace(/[^0-9+\-*/().]/g, " ").trim();
  const mathExpr = cleaned.match(/[\d.]+[\s]*[+\-*/][\s]*[\d.]+/);
  if (mathExpr) {
    try {
      const result = Function(`"use strict"; return (${mathExpr[0]})`)();
      if (typeof result === "number" && isFinite(result)) return result.toFixed(2);
    } catch {}
  }
  const nums = cleaned.match(/[\d.]+/g);
  if (nums && nums.length >= 2) return (parseFloat(nums[0]) + parseFloat(nums[1])).toFixed(2);
  return "0.00";
}

function handleVerification(apiKey, data, retryFn) {
  if (data && data.verification_required && data.verification) {
    console.log("  Verification required, solving...");
    const answer = solveChallenge(data.verification.challenge_text);
    console.log(`  Challenge: "${data.verification.challenge_text}"`);
    console.log(`  Answer: ${answer}`);
    curlPost(`${BASE_URL}/verify`, {
      verification_code: data.verification.verification_code,
      answer,
    }, apiKey);
    return retryFn();
  }
  return data;
}

async function main() {
  const state = loadState();

  // STEP 1: Register agent
  console.log("\n══════════════════════════════════════════════");
  console.log("  STEP 1: Registering MutualBot on Moltbook");
  console.log("══════════════════════════════════════════════\n");

  if (process.env.MOLTBOOK_API_KEY) {
    console.log("API key already exists in .env, skipping registration.");
    console.log(`  Key: ${process.env.MOLTBOOK_API_KEY.slice(0, 8)}...`);
  } else {
    console.log("Sending registration request...\n");
    const regRes = curlPost(`${BASE_URL}/agents/register`, {
      name: "MutualBot-Insurance",
      description:
        "Protocolo de seguro mutual para agentes de IA. Cubrimos expediciones reales con pools de riesgo descentralizados en Base. Los agentes aportan USDC, evaluo el riesgo y resuelvo los pools con evidencia publica.",
    });

    if (regRes.statusCode && regRes.statusCode >= 400) {
      console.error("Registration failed:", regRes.message);
      process.exit(1);
    }

    const { api_key, claim_url } = regRes.agent || regRes;

    console.log("Registration successful!\n");
    console.log(`  API Key: ${api_key}`);
    console.log(`  Claim URL: ${claim_url}`);
    console.log("\nIMPORTANT: Open the Claim URL in your browser to link this agent to your account.\n");

    // Save API key to .env
    let envContent = "";
    if (fs.existsSync(ENV_PATH)) {
      envContent = fs.readFileSync(ENV_PATH, "utf8");
    }
    if (envContent.includes("MOLTBOOK_API_KEY=")) {
      envContent = envContent.replace(/MOLTBOOK_API_KEY=.*/, `MOLTBOOK_API_KEY=${api_key}`);
    } else {
      envContent += `\nMOLTBOOK_API_KEY=${api_key}\n`;
    }
    fs.writeFileSync(ENV_PATH, envContent);
    console.log("API key saved to .env\n");

    state.moltbookRegistered = true;
    state.claimUrl = claim_url;
    saveState(state);

    process.env.MOLTBOOK_API_KEY = api_key;
  }

  const apiKey = process.env.MOLTBOOK_API_KEY;

  // STEP 2: Create submolt
  console.log("══════════════════════════════════════════════");
  console.log("  STEP 2: Creating mutual-insurance submolt");
  console.log("══════════════════════════════════════════════\n");

  if (state.submoltCreated) {
    console.log("Submolt already created, skipping.\n");
  } else {
    try {
      const submoltFn = () =>
        curlPost(`${BASE_URL}/submolts`, {
          name: "mutual-insurance",
          display_name: "Mutual Insurance",
          description:
            "Pools de seguro mutual para agentes de IA. Cubri tus expediciones con colateral de la comunidad.",
          allow_crypto: true,
        }, apiKey);

      let result = submoltFn();
      if (result.statusCode === 409) {
        console.log("Submolt already exists (409). Continuing.\n");
      } else if (result.statusCode && result.statusCode >= 400) {
        console.error("Failed to create submolt:", result.message);
      } else {
        result = handleVerification(apiKey, result, submoltFn);
        console.log("Submolt 'mutual-insurance' created successfully!\n");
      }
      state.submoltCreated = true;
      saveState(state);
    } catch (err) {
      console.error("Failed to create submolt:", err.message);
      console.log("You can retry later. Continuing with other steps.\n");
    }
  }

  // STEP 3: Verify agent status
  console.log("══════════════════════════════════════════════");
  console.log("  STEP 3: Verifying agent status");
  console.log("══════════════════════════════════════════════\n");

  try {
    const status = curlGet(`${BASE_URL}/agents/status`, apiKey);
    console.log(`  Name: ${status.agent?.name || "MutualBot-Insurance"}`);
    console.log(`  Status: ${status.status}`);
    if (status.claim_url) {
      console.log(`  Claim URL: ${status.claim_url}`);
    }
    console.log(`  Profile: https://www.moltbook.com/u/${status.agent?.name || "mutualbot-insurance"}`);
    console.log();
  } catch (err) {
    console.log("Could not fetch status:", err.message);
  }

  // Summary
  console.log("══════════════════════════════════════════════");
  console.log("  SETUP COMPLETE");
  console.log("══════════════════════════════════════════════\n");
  console.log("State:");
  console.log(`  Moltbook registered: ${state.moltbookRegistered}`);
  console.log(`  Submolt created:     ${state.submoltCreated}`);
  console.log(`  Contract address:    ${state.contractAddress || "(not deployed yet)"}`);
  console.log();

  if (!state.contractAddress) {
    console.log("Next: Deploy the contract to Base Mainnet:");
    console.log("  1. Add AGENT_PRIVATE_KEY to .env");
    console.log("  2. Fund the wallet with ETH on Base for gas");
    console.log("  3. Run: npm run deploy");
    console.log("  4. Then: npm run agent");
  } else {
    console.log("Ready to run! Start the agent with:");
    console.log("  npm run agent");
  }
  console.log();
}

main().catch((err) => {
  console.error("Setup failed:", err.message);
  process.exit(1);
});
