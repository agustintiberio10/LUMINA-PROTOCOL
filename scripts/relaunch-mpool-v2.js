/**
 * MPOOL v2 — Full Relaunch
 *
 * Fixes the original launch where totalSupply was sent as raw number (10000000)
 * but the launchpad interpreted it as wei, resulting in ~0 real tokens.
 *
 * This script:
 * 1. Launches MPOOL v2 via Fluid Launchpad with correct wei amounts
 * 2. Deploys new MPOOLStaking linked to the new token
 * 3. Deploys new FeeRouter linked to the new staking
 * 4. Transfers 2.5M MPOOL to staking as reward reserve
 * 5. Updates .env and state.json
 *
 * Usage:
 *   npx hardhat run scripts/relaunch-mpool-v2.js --network baseMainnet
 */
const hre = require("hardhat");
const axios = require("axios");
const fs = require("fs");
const path = require("path");

const LAUNCHPAD_BASE = "https://launchpad.moltx.io";
const DEPOSIT_AMOUNT = "0.001"; // ETH (minimum required by launchpad)
const STATE_PATH = path.join(__dirname, "..", "state.json");
const ENV_PATH = path.join(__dirname, "..", ".env");

const OWNER_ADDRESS = process.env.PROTOCOL_OWNER || "0x2b4D825417f568231e809E31B9332ED146760337";
const USDC_ADDRESS = process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

// MPOOL token SVG logo
const TOKEN_IMAGE = `data:image/svg+xml;base64,${Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><rect width="256" height="256" rx="48" fill="#6C3FA0"/><text x="128" y="170" font-family="Arial" font-size="120" font-weight="bold" fill="white" text-anchor="middle">M</text></svg>`).toString("base64")}`;

function toChecksumAddress(addr) {
  return hre.ethers.getAddress(addr.toLowerCase());
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║          MPOOL v2 — FULL RELAUNCH                       ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");
  console.log(`Deployer: ${deployer.address}`);

  const ethBalance = await hre.ethers.provider.getBalance(deployer.address);
  console.log(`Balance:  ${hre.ethers.formatEther(ethBalance)} ETH\n`);

  // Need ~0.001 deposit + ~0.0008 gas for contracts
  const minRequired = hre.ethers.parseEther("0.0018");
  if (ethBalance < minRequired) {
    console.error(`ERROR: Need at least 0.0018 ETH. Have ${hre.ethers.formatEther(ethBalance)}`);
    process.exit(1);
  }

  // ═══════════════════════════════════════════════════════════
  // PHASE 1: Launch MPOOL v2 via Fluid Launchpad
  // ═══════════════════════════════════════════════════════════

  // FIX: Use proper wei amounts — original bug was sending 10000000 as raw number
  // which the launchpad treated as 10000000 wei (= 0.00000000001 tokens)
  const totalSupplyWei = hre.ethers.parseUnits("10000000", 18).toString();
  const airdropAmountWei = hre.ethers.parseUnits("6000000", 18).toString();

  console.log("══ PHASE 1: Launch MPOOL v2 Token ══");
  console.log(`Total Supply: 10,000,000 MPOOL (${totalSupplyWei} wei)`);
  console.log(`LP: 40% (4M) | Owner airdrop: 60% (6M)\n`);

  // Step 1: Get deposit address
  console.log("[1/9] Creating deposit address...");
  let depositAddress;
  try {
    const res = await axios.post(`${LAUNCHPAD_BASE}/deposit`);
    if (!res.data.ok) throw new Error(JSON.stringify(res.data));
    depositAddress = res.data.depositAddress;
    console.log(`  Deposit address: ${depositAddress}`);
  } catch (err) {
    console.error("  FAILED:", err.response?.data || err.message);
    process.exit(1);
  }

  // Step 2: Send ETH to deposit
  console.log(`\n[2/9] Sending ${DEPOSIT_AMOUNT} ETH to deposit...`);
  try {
    const tx = await deployer.sendTransaction({
      to: depositAddress,
      value: hre.ethers.parseEther(DEPOSIT_AMOUNT),
    });
    console.log(`  Tx: ${tx.hash}`);
    await tx.wait();
    console.log("  Confirmed.");
  } catch (err) {
    console.error("  FAILED:", err.message);
    process.exit(1);
  }

  // Step 3: Wait for propagation
  console.log("\n[3/9] Waiting 15s for deposit to propagate...");
  await new Promise((r) => setTimeout(r, 15000));

  // Step 4: Deploy token
  console.log("\n[4/9] Deploying MPOOL v2 token...");
  const deployPayload = {
    depositAddress,
    name: "MutualPool Token",
    symbol: "MPOOL",
    image: TOKEN_IMAGE,
    tokenOwner: OWNER_ADDRESS,
    totalSupply: totalSupplyWei,
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
          amount: airdropAmountWei,
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

  let tokenAddress, poolAddress, deployTxHash;
  try {
    const res = await axios.post(`${LAUNCHPAD_BASE}/deploy`, deployPayload);
    if (!res.data.ok) throw new Error(JSON.stringify(res.data));
    tokenAddress = res.data.token;
    poolAddress = res.data.pool;
    deployTxHash = res.data.txHash;
    console.log(`  Token: ${tokenAddress}`);
    console.log(`  Pool:  ${poolAddress}`);
    console.log(`  Tx:    ${deployTxHash}`);
  } catch (err) {
    console.error("  FAILED:", err.response?.data || err.message);
    process.exit(1);
  }

  // Step 5: Initial buy (for aggregator registration)
  console.log("\n[5/9] Executing initial buy...");
  try {
    const res = await axios.post(`${LAUNCHPAD_BASE}/deploy/${tokenAddress}/buy`, {
      pool: poolAddress,
      tokenIsToken0: true,
      buyAmountETH: "0.0001",
    });
    if (!res.data.ok) throw new Error(JSON.stringify(res.data));
    console.log(`  Tx: ${res.data.txHash}`);
  } catch (err) {
    console.log("  Initial buy failed (non-blocking):", err.response?.data || err.message);
  }

  // Verify on-chain supply
  console.log("\n  Verifying on-chain supply...");
  const tokenAbi = ["function totalSupply() view returns (uint256)", "function balanceOf(address) view returns (uint256)"];
  const mpoolV2 = new hre.ethers.Contract(tokenAddress, tokenAbi, deployer);
  const supply = await mpoolV2.totalSupply();
  const ownerBal = await mpoolV2.balanceOf(deployer.address);
  console.log(`  Total Supply: ${hre.ethers.formatUnits(supply, 18)} MPOOL`);
  console.log(`  Owner balance: ${hre.ethers.formatUnits(ownerBal, 18)} MPOOL`);

  if (supply < hre.ethers.parseUnits("1000000", 18)) {
    console.error("\n  ERROR: Supply still too low. Launchpad may need different format.");
    console.error("  Stopping here to prevent deploying staking with wrong token.");
    // Still save what we have
    saveConfig(tokenAddress, poolAddress, deployTxHash, null, null);
    process.exit(1);
  }

  console.log("  ✓ Supply looks correct!");

  // ═══════════════════════════════════════════════════════════
  // PHASE 2: Deploy MPOOLStaking
  // ═══════════════════════════════════════════════════════════
  console.log("\n══ PHASE 2: Deploy MPOOLStaking ══");
  console.log("[6/9] Deploying MPOOLStaking...");

  const checkedToken = toChecksumAddress(tokenAddress);
  const checkedUsdc = toChecksumAddress(USDC_ADDRESS);

  const MPOOLStaking = await hre.ethers.getContractFactory("MPOOLStaking");
  const staking = await MPOOLStaking.deploy(checkedToken, checkedUsdc);
  await staking.waitForDeployment();
  const stakingAddress = await staking.getAddress();
  console.log(`  MPOOLStaking: ${stakingAddress}`);

  // ═══════════════════════════════════════════════════════════
  // PHASE 3: Deploy FeeRouter
  // ═══════════════════════════════════════════════════════════
  console.log("\n══ PHASE 3: Deploy FeeRouter ══");
  console.log("[7/9] Deploying FeeRouter...");

  const checkedOwner = toChecksumAddress(OWNER_ADDRESS);
  const FeeRouter = await hre.ethers.getContractFactory("FeeRouter");
  const feeRouter = await FeeRouter.deploy(checkedUsdc, stakingAddress, checkedOwner, checkedOwner);
  await feeRouter.waitForDeployment();
  const feeRouterAddress = await feeRouter.getAddress();
  console.log(`  FeeRouter: ${feeRouterAddress}`);

  // Link FeeRouter to staking
  console.log("\n[8/9] Linking FeeRouter to MPOOLStaking...");
  const linkTx = await staking.setFeeRouter(feeRouterAddress);
  await linkTx.wait();
  console.log("  ✓ FeeRouter set as reward distributor.");

  // ═══════════════════════════════════════════════════════════
  // PHASE 4: Transfer 2.5M MPOOL to staking
  // ═══════════════════════════════════════════════════════════
  console.log("\n══ PHASE 4: Fund Staking Rewards ══");
  console.log("[9/9] Transferring 2.5M MPOOL to staking...");

  const transferAbi = ["function transfer(address to, uint256 amount) returns (bool)"];
  const mpoolForTransfer = new hre.ethers.Contract(tokenAddress, transferAbi, deployer);
  const transferAmount = hre.ethers.parseUnits("2500000", 18);

  const currentBal = await mpoolV2.balanceOf(deployer.address);
  if (currentBal >= transferAmount) {
    const transferTx = await mpoolForTransfer.transfer(stakingAddress, transferAmount);
    await transferTx.wait();
    console.log("  ✓ 2.5M MPOOL transferred to staking contract.");
  } else {
    console.log(`  ⚠ Insufficient MPOOL balance (${hre.ethers.formatUnits(currentBal, 18)}). Transfer skipped.`);
  }

  // ═══════════════════════════════════════════════════════════
  // PHASE 5: Save config
  // ═══════════════════════════════════════════════════════════
  console.log("\n══ PHASE 5: Save Configuration ══");
  saveConfig(tokenAddress, poolAddress, deployTxHash, stakingAddress, feeRouterAddress);

  // Final summary
  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║            MPOOL v2 RELAUNCH COMPLETE!                   ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ MPOOL Token:  ${tokenAddress.padEnd(42)}║`);
  console.log(`║ LP Pool:      ${poolAddress.padEnd(42)}║`);
  console.log(`║ MPOOLStaking: ${stakingAddress.padEnd(42)}║`);
  console.log(`║ FeeRouter:    ${feeRouterAddress.padEnd(42)}║`);
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log("║ Fee Split: 70% stakers / 20% treasury / 10% buyback     ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log("║ UPDATE RAILWAY ENV VARS:                                 ║");
  console.log(`║   MPOOL_TOKEN_ADDRESS=${tokenAddress}   ║`);
  console.log(`║   MPOOL_STAKING_ADDRESS=${stakingAddress}║`);
  console.log("╚══════════════════════════════════════════════════════════╝");
}

function saveConfig(tokenAddress, poolAddress, deployTxHash, stakingAddress, feeRouterAddress) {
  // Update .env
  let env = fs.readFileSync(ENV_PATH, "utf8");

  function setEnv(key, value) {
    if (!value) return;
    const regex = new RegExp(`${key}=.*`);
    if (env.match(regex)) {
      env = env.replace(regex, `${key}=${value}`);
    } else {
      env += `${key}=${value}\n`;
    }
  }

  setEnv("MPOOL_TOKEN_ADDRESS", tokenAddress);
  setEnv("MPOOL_POOL_ADDRESS", poolAddress);
  setEnv("MPOOL_DEPLOY_TX", deployTxHash);
  if (stakingAddress) setEnv("MPOOL_STAKING_ADDRESS", stakingAddress);
  if (feeRouterAddress) setEnv("FEE_ROUTER_ADDRESS", feeRouterAddress);

  fs.writeFileSync(ENV_PATH, env);
  console.log("  .env updated.");

  // Update state.json
  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  state.mpoolToken = {
    address: tokenAddress,
    pool: poolAddress,
    deployTx: deployTxHash,
    name: "MutualPool Token",
    symbol: "MPOOL",
    totalSupply: "10000000",
    lpAllocation: "4000000",
    ownerAllocation: "6000000",
    launchedAt: new Date().toISOString(),
    distribution: {
      stakingRewards: { amount: "2500000", status: stakingAddress ? "transferred" : "pending_transfer" },
      treasury: { amount: "2000000", status: "held_by_owner" },
      airdropReserve: { amount: "1000000", status: "held_by_owner" },
      teamVesting: { amount: "500000", vestingMonths: 12, status: "held_by_owner" },
    },
    stakingContract: stakingAddress,
    feeRouter: feeRouterAddress,
    feeSystemDeployedAt: new Date().toISOString(),
    v2: true,
    v1Address: "0xb8550B07b94149b1B362E4042CE0d02cE037174A",
  };
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
  console.log("  state.json updated.");
}

main().catch((err) => {
  console.error("\nFATAL ERROR:", err);
  process.exit(1);
});
