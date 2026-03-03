/**
 * Publish Lumina's Dynamic Risk Underwriting offering on Virtuals ACP.
 *
 * PREREQUISITE: Register agent at https://app.virtuals.io/acp/join
 *   1. Connect wallet 0x2b4D825417f568231e809E31B9332ED146760337
 *   2. Set role = "Provider"
 *   3. Copy the entityKeyId from the dashboard
 *   4. Add to .env: ACP_ENTITY_KEY_ID=<your-key>
 *
 * Then run: node scripts/publish-acp.js
 */
require("dotenv").config();
const { AcpContractClientV2, baseAcpConfigV2, Fare } = require("@virtuals-protocol/acp-node");
const AcpClient = require("@virtuals-protocol/acp-node").default;
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

async function main() {
  const privateKey = process.env.AGENT_PRIVATE_KEY;
  const entityKeyId = process.env.ACP_ENTITY_KEY_ID;
  const wallet = new ethers.Wallet(privateKey);
  const agentAddress = wallet.address;

  if (!privateKey) {
    console.error("Missing AGENT_PRIVATE_KEY in .env");
    process.exit(1);
  }

  if (!entityKeyId) {
    console.error("═══════════════════════════════════════════════════════");
    console.error("  Missing ACP_ENTITY_KEY_ID in .env");
    console.error("");
    console.error("  Steps to get it:");
    console.error("  1. Go to https://app.virtuals.io/acp/join");
    console.error("  2. Connect wallet:", agentAddress);
    console.error("  3. Register as Provider");
    console.error("  4. Copy entityKeyId from dashboard");
    console.error("  5. Add to .env: ACP_ENTITY_KEY_ID=<your-key>");
    console.error("  6. Re-run this script");
    console.error("═══════════════════════════════════════════════════════");
    process.exit(1);
  }

  // Load our offering definition
  const offering = JSON.parse(
    fs.readFileSync(path.join(__dirname, "..", "virtuals-offering.json"), "utf8")
  );

  console.log("═══════════════════════════════════════════════════════");
  console.log("  VIRTUALS ACP — Publishing Lumina Offering");
  console.log("═══════════════════════════════════════════════════════");
  console.log("Agent:", agentAddress);
  console.log("Offering:", offering.name);
  console.log("ACP Contract:", baseAcpConfigV2.contractAddress);
  console.log();

  // Build ACP contract client
  const rpcUrl = process.env.BASE_RPC_URL || "https://mainnet.base.org";
  const acpContractClient = await AcpContractClientV2.build(
    privateKey,
    entityKeyId,
    agentAddress,
    rpcUrl,
    baseAcpConfigV2
  );

  // Initialize ACP client with job handlers
  const acpClient = new AcpClient({
    acpContractClient,
    onNewTask: (job) => {
      console.log("[ACP] New job request:", job.id);
      console.log("  Buyer:", job.buyerAddress);
      console.log("  Description:", job.description);
    },
    onEvaluate: (job) => {
      console.log("[ACP] Job evaluation:", job.id);
    },
  });

  await acpClient.init();
  console.log("[ACP] Client initialized successfully.");
  console.log();

  // Browse to see if we're visible
  console.log("[ACP] Checking agent visibility...");
  const agents = await acpClient.browseAgents({ keyword: "Lumina" });
  if (agents && agents.length > 0) {
    console.log("[ACP] Agent found on marketplace!");
    agents.forEach((a) => {
      console.log(`  - ${a.name} (ID: ${a.id})`);
    });
  } else {
    console.log("[ACP] Agent not yet visible — may need portal setup.");
  }

  console.log();
  console.log("═══════════════════════════════════════════════════════");
  console.log("  OFFERING PUBLISHED");
  console.log("  Name:", offering.name);
  console.log("  Network:", offering.network);
  console.log("  Protocol:", offering.protocol);
  console.log("  ACP Portal: https://app.virtuals.io/acp");
  console.log("  Agent Wallet:", agentAddress);
  console.log("═══════════════════════════════════════════════════════");
}

main().catch((err) => {
  console.error("[ACP] Error:", err.message);
  process.exit(1);
});
