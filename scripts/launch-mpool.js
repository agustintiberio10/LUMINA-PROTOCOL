/**
 * MPOOL Token Launch via Fluid Launchpad
 *
 * Launches the MutualPool Token (MPOOL) on Base via the Fluid DEX launchpad.
 * Cost: 0.001 ETH on Base (~$2.70)
 *
 * Steps:
 * 1. POST /deposit → get temporary deposit address
 * 2. Send 0.001 ETH from agent wallet to deposit address
 * 3. Poll deposit status until funded
 * 4. POST /deploy → deploy token + create pool + seed liquidity
 * 5. POST /deploy/{token}/buy → initial buy for aggregator registration
 * 6. Save all addresses to .env and state.json
 *
 * Token: MPOOL
 * Supply: 10,000,000 (fixed, no mint)
 * LP: 40% (4M tokens)
 * Airdrop to owner: 60% (6M tokens) — for staking rewards, treasury, team, future airdrops
 */
require("dotenv").config();
const axios = require("axios");
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const LAUNCHPAD_BASE = "https://launchpad.moltx.io";
const DEPOSIT_AMOUNT = "0.002"; // ETH (0.001 min + gas headroom for deploy)
const STATE_PATH = path.join(__dirname, "..", "state.json");
const ENV_PATH = path.join(__dirname, "..", ".env");

const OWNER_ADDRESS = process.env.PROTOCOL_OWNER || "0x2b4D825417f568231e809E31B9332ED146760337";

// MPOOL token SVG logo (purple square with M)
const TOKEN_IMAGE = `data:image/svg+xml;base64,${Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect width="256" height="256" rx="48" fill="#6C3FA0"/><text x="128" y="170" font-family="Arial" font-size="120" font-weight="bold" fill="white" text-anchor="middle">M</text></svg>`).toString("base64")}`;

async function main() {
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║           MPOOL TOKEN LAUNCH — FLUID LAUNCHPAD          ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ Token: MutualPool Token (MPOOL)${" ".repeat(25)}║`);
  console.log(`║ Supply: 10,000,000 (fixed)${" ".repeat(30)}║`);
  console.log(`║ LP: 40% (4M) on Fluid DEX${" ".repeat(30)}║`);
  console.log(`║ Owner airdrop: 60% (6M)${" ".repeat(32)}║`);
  console.log(`║ Cost: 0.001 ETH on Base${" ".repeat(33)}║`);
  console.log("╚══════════════════════════════════════════════════════════╝\n");

  // Check private key
  if (!process.env.AGENT_PRIVATE_KEY) {
    console.error("ERROR: AGENT_PRIVATE_KEY not set in .env");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL || "https://mainnet.base.org");
  const wallet = new ethers.Wallet(process.env.AGENT_PRIVATE_KEY, provider);
  console.log(`[Wallet] ${wallet.address}`);

  // Check ETH balance
  const ethBalance = await provider.getBalance(wallet.address);
  const ethBalanceFormatted = ethers.formatEther(ethBalance);
  console.log(`[Balance] ${ethBalanceFormatted} ETH`);

  const requiredWei = ethers.parseEther("0.0025"); // 0.002 deposit + gas
  if (ethBalance < requiredWei) {
    console.error(`\nERROR: Insufficient ETH. Need at least 0.0025 ETH (0.002 deposit + gas).`);
    console.error(`Current balance: ${ethBalanceFormatted} ETH`);
    console.error(`Send ETH to ${wallet.address} on Base and retry.`);
    process.exit(1);
  }

  // ── STEP 1: Create deposit (or reuse existing) ──
  let depositAddress = process.env.MPOOL_DEPOSIT_ADDRESS || null;

  if (depositAddress) {
    console.log(`\n[Step 1] Reusing existing deposit address: ${depositAddress}`);
    console.log("[Step 2] Skipping ETH send (already funded).");
    console.log("[Step 3] Skipping verification (already confirmed on-chain).");
  } else {
    console.log("\n[Step 1] Creating deposit address...");
    try {
      const depositRes = await axios.post(`${LAUNCHPAD_BASE}/deposit`);
      if (!depositRes.data.ok) throw new Error(JSON.stringify(depositRes.data));
      depositAddress = depositRes.data.depositAddress;
      console.log(`[Step 1] Deposit address: ${depositAddress}`);
      console.log(`[Step 1] Required: ${depositRes.data.requiredAmount} ETH`);
    } catch (err) {
      console.error("[Step 1] Failed to create deposit:", err.response?.data || err.message);
      process.exit(1);
    }

    // ── STEP 2: Send ETH to deposit address ──
    console.log(`\n[Step 2] Sending ${DEPOSIT_AMOUNT} ETH to deposit address...`);
    try {
      const tx = await wallet.sendTransaction({
        to: depositAddress,
        value: ethers.parseEther(DEPOSIT_AMOUNT),
      });
      console.log(`[Step 2] Tx sent: ${tx.hash}`);
      console.log("[Step 2] Waiting for confirmation...");
      const receipt = await tx.wait();
      console.log(`[Step 2] Confirmed in block ${receipt.blockNumber}`);
    } catch (err) {
      console.error("[Step 2] Failed to send ETH:", err.message);
      process.exit(1);
    }

    // ── STEP 3: Wait for deposit to propagate ──
    console.log("\n[Step 3] Waiting 15s for deposit to propagate...");
    await new Promise((r) => setTimeout(r, 15000));
    console.log("[Step 3] Done. Proceeding to deploy.");
  }

  // ── STEP 4: Deploy token ──
  console.log("\n[Step 4] Deploying MPOOL token...");

  const deployPayload = {
    depositAddress: depositAddress,
    name: "MutualPool Token",
    symbol: "MPOOL",
    image: TOKEN_IMAGE,
    tokenOwner: OWNER_ADDRESS,
    totalSupply: 10000000,  // 10M tokens
    lpBps: 4000,            // 40% to LP
    feeRecipients: [
      {
        address: OWNER_ADDRESS,
        bps: 10000,           // 100% of trading fees to owner (protocol controls distribution)
        admin: OWNER_ADDRESS,
      },
    ],
    airdrop: {
      enabled: true,
      recipients: [
        {
          address: OWNER_ADDRESS,
          amount: "6000000", // 6M tokens (60% of 10M) — raw units, not wei
        },
      ],
    },
    metadata: JSON.stringify({
      description: "Protocol fee capture token for MutualPool — decentralized insurance for AI agents on Base L2",
      website: "https://moltx.io/MutualPoolLiqBot",
      category: "DeFi",
      tags: ["insurance", "mutual", "defi", "base", "ai-agents"],
    }),
  };

  let tokenAddress, poolAddress, deployTxHash, tokenIsToken0;
  try {
    console.log("[Step 4] Payload:", JSON.stringify(deployPayload, null, 2).substring(0, 500) + "...");
    const deployRes = await axios.post(`${LAUNCHPAD_BASE}/deploy`, deployPayload);
    if (!deployRes.data.ok) throw new Error(JSON.stringify(deployRes.data));

    tokenAddress = deployRes.data.token;
    poolAddress = deployRes.data.pool;
    deployTxHash = deployRes.data.txHash;
    tokenIsToken0 = deployRes.data.tokenIsToken0;

    console.log(`[Step 4] Token deployed!`);
    console.log(`  Token: ${tokenAddress}`);
    console.log(`  Pool:  ${poolAddress}`);
    console.log(`  Tx:    ${deployTxHash}`);
    console.log(`  Basescan: ${deployRes.data.basescan}`);
  } catch (err) {
    console.error("[Step 4] Deploy failed:", err.response?.data || err.message);
    process.exit(1);
  }

  // ── STEP 5: Initial buy (registers on DEX aggregators) ──
  console.log("\n[Step 5] Executing initial buy...");
  try {
    const buyRes = await axios.post(`${LAUNCHPAD_BASE}/deploy/${tokenAddress}/buy`, {
      pool: poolAddress,
      tokenIsToken0: tokenIsToken0,
      buyAmountETH: "0.0001",
    });

    if (!buyRes.data.ok) throw new Error(JSON.stringify(buyRes.data));

    console.log(`[Step 5] Initial buy successful!`);
    console.log(`  Tx: ${buyRes.data.txHash}`);
    if (buyRes.data.links) {
      console.log(`  DexScreener: ${buyRes.data.links.dexscreener}`);
      console.log(`  GeckoTerminal: ${buyRes.data.links.geckoterminal}`);
      console.log(`  Basescan: ${buyRes.data.links.basescan}`);
    }
  } catch (err) {
    console.error("[Step 5] Initial buy failed (non-blocking):", err.response?.data || err.message);
    console.log("Token is still deployed. You can manually do the initial buy later.");
  }

  // ── STEP 6: Save to .env and state.json ──
  console.log("\n[Step 6] Saving configuration...");

  // Update .env
  let envContent = fs.readFileSync(ENV_PATH, "utf8");
  if (!envContent.includes("MPOOL_TOKEN_ADDRESS")) {
    envContent += `\n# MPOOL Token (launched via Fluid Launchpad)\n`;
    envContent += `MPOOL_TOKEN_ADDRESS=${tokenAddress}\n`;
    envContent += `MPOOL_POOL_ADDRESS=${poolAddress}\n`;
    envContent += `MPOOL_DEPLOY_TX=${deployTxHash}\n`;
  } else {
    envContent = envContent.replace(/MPOOL_TOKEN_ADDRESS=.*/, `MPOOL_TOKEN_ADDRESS=${tokenAddress}`);
    envContent = envContent.replace(/MPOOL_POOL_ADDRESS=.*/, `MPOOL_POOL_ADDRESS=${poolAddress}`);
    envContent = envContent.replace(/MPOOL_DEPLOY_TX=.*/, `MPOOL_DEPLOY_TX=${deployTxHash}`);
  }
  fs.writeFileSync(ENV_PATH, envContent);
  console.log("[Step 6] .env updated with MPOOL addresses.");

  // Update state.json
  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  state.mpoolToken = {
    address: tokenAddress,
    pool: poolAddress,
    deployTx: deployTxHash,
    name: "MutualPool Token",
    symbol: "MPOOL",
    totalSupply: "10000000",
    lpAllocation: "4000000",     // 40%
    ownerAllocation: "6000000",  // 60% (staking + treasury + airdrop + team)
    launchedAt: new Date().toISOString(),
    distribution: {
      stakingRewards: { amount: "2500000", status: "pending_transfer" },
      treasury: { amount: "2000000", status: "held_by_owner" },
      airdropReserve: { amount: "1000000", status: "held_by_owner" },
      teamVesting: { amount: "500000", vestingMonths: 12, status: "held_by_owner" },
    },
  };
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
  console.log("[Step 6] state.json updated.");

  // ── DONE ──
  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║                 MPOOL LAUNCH COMPLETE!                   ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ Token: ${tokenAddress.padEnd(49)}║`);
  console.log(`║ Pool:  ${poolAddress.padEnd(49)}║`);
  console.log(`║ Tx:    ${deployTxHash.substring(0, 42).padEnd(49)}║`);
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log("║ NEXT STEPS:                                              ║");
  console.log("║ 1. Deploy staking + fee router:                          ║");
  console.log("║    npx hardhat run scripts/deploy-fee-system.js          ║");
  console.log("║ 2. Transfer 2.5M MPOOL to staking contract               ║");
  console.log("║ 3. Start routing fees via FeeRouter                       ║");
  console.log("╚══════════════════════════════════════════════════════════╝");
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
