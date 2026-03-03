/**
 * MPOOLV3 Token Launch via Fluid Launchpad
 *
 * Launches the MutualPool V3 Token (MPOOLV3) on Base via the Fluid DEX launchpad.
 * Cost: 0.001 ETH on Base (~$2.70)
 *
 * Steps:
 * 1. POST /deposit → get temporary deposit address
 * 2. Send 0.002 ETH from agent wallet to deposit address
 * 3. Poll deposit status until funded
 * 4. POST /deploy → deploy token + create pool + seed liquidity
 * 5. POST /deploy/{token}/buy → initial buy for aggregator registration
 * 6. Save all addresses to .env and state.json
 * 7. Set MPOOLV3 on MutualPoolRouter
 *
 * Token: MPOOLV3
 * Supply: 10,000,000 (fixed, no mint)
 * LP: 40% (4M tokens) on Fluid DEX
 * Airdrop to owner: 60% (6M tokens) — for staking, treasury, airdrops
 */
require("dotenv").config();
const axios = require("axios");
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

const LAUNCHPAD_BASE = "https://launchpad.moltx.io";
const DEPOSIT_AMOUNT = "0.002";
const STATE_PATH = path.join(__dirname, "..", "state.json");
const ENV_PATH = path.join(__dirname, "..", ".env");

const OWNER_ADDRESS = process.env.PROTOCOL_OWNER || "0x2b4D825417f568231e809E31B9332ED146760337";

// MPOOLV3 token SVG logo (purple square with M3)
const TOKEN_IMAGE = `data:image/svg+xml;base64,${Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect width="256" height="256" rx="48" fill="#4A1D96"/><text x="128" y="155" font-family="Arial" font-size="80" font-weight="bold" fill="white" text-anchor="middle">M</text><text x="128" y="220" font-family="Arial" font-size="50" font-weight="bold" fill="#A78BFA" text-anchor="middle">V3</text></svg>`).toString("base64")}`;

async function main() {
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║         MPOOLV3 TOKEN LAUNCH — FLUID LAUNCHPAD          ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ Token: MutualPool V3 Token (MPOOLV3)${" ".repeat(20)}║`);
  console.log(`║ Supply: 10,000,000 (fixed, no mint)${" ".repeat(21)}║`);
  console.log(`║ LP: 40% (4M) on Fluid DEX${" ".repeat(30)}║`);
  console.log(`║ Owner airdrop: 60% (6M)${" ".repeat(32)}║`);
  console.log(`║ Cost: 0.001 ETH on Base${" ".repeat(33)}║`);
  console.log("╚══════════════════════════════════════════════════════════╝\n");

  if (!process.env.AGENT_PRIVATE_KEY) {
    console.error("ERROR: AGENT_PRIVATE_KEY not set in .env");
    process.exit(1);
  }

  const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL || "https://mainnet.base.org");
  const wallet = new ethers.Wallet(process.env.AGENT_PRIVATE_KEY, provider);
  console.log(`[Wallet] ${wallet.address}`);

  const ethBalance = await provider.getBalance(wallet.address);
  const ethBalanceFormatted = ethers.formatEther(ethBalance);
  console.log(`[Balance] ${ethBalanceFormatted} ETH`);

  const requiredWei = ethers.parseEther("0.0025");
  if (ethBalance < requiredWei) {
    console.error(`\nERROR: Insufficient ETH. Need at least 0.0025 ETH.`);
    console.error(`Current balance: ${ethBalanceFormatted} ETH`);
    console.error(`Send ETH to ${wallet.address} on Base and retry.`);
    process.exit(1);
  }

  // ── STEP 1: Create deposit ──
  let depositAddress = process.env.MPOOLV3_DEPOSIT_ADDRESS || null;

  if (depositAddress) {
    console.log(`\n[Step 1] Reusing existing deposit address: ${depositAddress}`);
  } else {
    console.log("\n[Step 1] Creating deposit address...");
    try {
      const depositRes = await axios.post(`${LAUNCHPAD_BASE}/deposit`);
      if (!depositRes.data.ok) throw new Error(JSON.stringify(depositRes.data));
      depositAddress = depositRes.data.depositAddress;
      console.log(`[Step 1] Deposit address: ${depositAddress}`);
      console.log(`[Step 1] Required: ${depositRes.data.requiredAmount} ETH`);
    } catch (err) {
      console.error("[Step 1] Failed:", err.response?.data || err.message);
      process.exit(1);
    }

    // ── STEP 2: Send ETH ──
    console.log(`\n[Step 2] Sending ${DEPOSIT_AMOUNT} ETH to deposit address...`);
    try {
      const tx = await wallet.sendTransaction({
        to: depositAddress,
        value: ethers.parseEther(DEPOSIT_AMOUNT),
      });
      console.log(`[Step 2] Tx sent: ${tx.hash}`);
      const receipt = await tx.wait();
      console.log(`[Step 2] Confirmed in block ${receipt.blockNumber}`);
    } catch (err) {
      console.error("[Step 2] Failed:", err.message);
      process.exit(1);
    }

    // ── STEP 3: Wait ──
    console.log("\n[Step 3] Waiting 15s for deposit to propagate...");
    await new Promise((r) => setTimeout(r, 15000));
  }

  // ── STEP 4: Deploy token ──
  console.log("\n[Step 4] Deploying MPOOLV3 token...");

  const deployPayload = {
    depositAddress,
    name: "MutualPool V3 Token",
    symbol: "MPOOLV3",
    image: TOKEN_IMAGE,
    tokenOwner: OWNER_ADDRESS,
    totalSupply: 10000000,
    lpBps: 4000,
    feeRecipients: [
      {
        address: OWNER_ADDRESS,
        bps: 10000,
        admin: OWNER_ADDRESS,
      },
    ],
    airdrop: {
      enabled: true,
      recipients: [
        {
          address: OWNER_ADDRESS,
          amount: "6000000",
        },
      ],
    },
    metadata: JSON.stringify({
      description: "Protocol token for MutualPool V3 — decentralized mutual insurance for AI agents on Base L2. Gateway token for pool participation via MutualPoolRouter.",
      website: "https://moltx.io/MutualPoolLiqBot",
      category: "DeFi",
      tags: ["insurance", "mutual", "defi", "base", "ai-agents", "v3"],
    }),
  };

  let tokenAddress, poolAddress, deployTxHash, tokenIsToken0;
  try {
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

  // ── STEP 5: Initial buy ──
  console.log("\n[Step 5] Executing initial buy...");
  try {
    const buyRes = await axios.post(`${LAUNCHPAD_BASE}/deploy/${tokenAddress}/buy`, {
      pool: poolAddress,
      tokenIsToken0,
      buyAmountETH: "0.0001",
    });

    if (!buyRes.data.ok) throw new Error(JSON.stringify(buyRes.data));
    console.log(`[Step 5] Initial buy successful! Tx: ${buyRes.data.txHash}`);
    if (buyRes.data.links) {
      console.log(`  DexScreener: ${buyRes.data.links.dexscreener}`);
      console.log(`  GeckoTerminal: ${buyRes.data.links.geckoterminal}`);
    }
  } catch (err) {
    console.error("[Step 5] Initial buy failed (non-blocking):", err.response?.data || err.message);
  }

  // ── STEP 6: Set MPOOLV3 on Router (if deployed) ──
  const routerAddress = process.env.ROUTER_ADDRESS;
  if (routerAddress) {
    console.log("\n[Step 6] Setting MPOOLV3 on MutualPoolRouter...");
    try {
      const routerAbi = ["function setMpoolToken(address) external"];
      const routerContract = new ethers.Contract(routerAddress, routerAbi, wallet);
      const tx = await routerContract.setMpoolToken(tokenAddress);
      await tx.wait();
      console.log(`[Step 6] Router.mpoolToken set to ${tokenAddress}`);
    } catch (err) {
      console.error("[Step 6] Failed (non-blocking):", err.message);
      console.log("  You can set it manually: router.setMpoolToken('" + tokenAddress + "')");
    }
  } else {
    console.log("\n[Step 6] ROUTER_ADDRESS not set — skip linking. Set manually after deploy-v3.");
  }

  // ── STEP 7: Save to .env and state.json ──
  console.log("\n[Step 7] Saving configuration...");

  let envContent = fs.readFileSync(ENV_PATH, "utf8");
  const envVars = {
    MPOOLV3_TOKEN_ADDRESS: tokenAddress,
    MPOOLV3_POOL_ADDRESS: poolAddress,
    MPOOLV3_DEPLOY_TX: deployTxHash,
  };

  for (const [key, value] of Object.entries(envVars)) {
    const regex = new RegExp(`^${key}=.*$`, "m");
    if (regex.test(envContent)) {
      envContent = envContent.replace(regex, `${key}=${value}`);
    } else {
      if (!envContent.includes("# MPOOLV3 Token")) {
        envContent += `\n# MPOOLV3 Token (launched via Fluid Launchpad)\n`;
      }
      envContent += `${key}=${value}\n`;
    }
  }
  fs.writeFileSync(ENV_PATH, envContent);

  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  state.mpoolV3Token = {
    address: tokenAddress,
    pool: poolAddress,
    deployTx: deployTxHash,
    name: "MutualPool V3 Token",
    symbol: "MPOOLV3",
    totalSupply: "10000000",
    lpAllocation: "4000000",
    ownerAllocation: "6000000",
    launchedAt: new Date().toISOString(),
    distribution: {
      stakingRewards: { amount: "2500000", status: "pending_transfer" },
      treasury: { amount: "2000000", status: "held_by_owner" },
      airdropReserve: { amount: "1000000", status: "held_by_owner" },
      teamVesting: { amount: "500000", vestingMonths: 12, status: "held_by_owner" },
    },
  };
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));

  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║               MPOOLV3 LAUNCH COMPLETE!                    ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ Token: ${tokenAddress.padEnd(49)}║`);
  console.log(`║ Pool:  ${poolAddress.padEnd(49)}║`);
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log("║ NEXT STEPS:                                              ║");
  console.log("║ 1. Deploy swap handler for Fluid DEX                     ║");
  console.log("║ 2. router.setSwapHandler(handlerAddr)                    ║");
  console.log("║ 3. Transfer MPOOLV3 to staking contract                  ║");
  console.log("╚══════════════════════════════════════════════════════════╝");
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
