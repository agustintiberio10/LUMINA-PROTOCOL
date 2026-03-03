/**
 * Deploy Fee System — MPOOLStaking + FeeRouter
 *
 * Run AFTER launch-mpool.js has deployed the MPOOL token.
 * Requires MPOOL_TOKEN_ADDRESS in .env.
 *
 * Deploys:
 * 1. MPOOLStaking (stake MPOOL, earn USDC)
 * 2. FeeRouter (splits fees 70/20/10)
 * 3. Links FeeRouter as reward distributor in MPOOLStaking
 *
 * Usage:
 *   npx hardhat run scripts/deploy-fee-system.js --network baseMainnet
 *   npx hardhat run scripts/deploy-fee-system.js --network baseSepolia
 */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const ENV_PATH = path.join(__dirname, "..", ".env");
const STATE_PATH = path.join(__dirname, "..", "state.json");

// Normalize any hex address to proper EIP-55 checksum
function toChecksumAddress(addr) {
  return hre.ethers.getAddress(addr.toLowerCase());
}

async function main() {
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║        DEPLOY FEE SYSTEM — STAKING + ROUTER             ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");

  const mpoolTokenAddress = toChecksumAddress(process.env.MPOOL_TOKEN_ADDRESS || "");
  const usdcAddress = toChecksumAddress(process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913");
  const ownerAddress = toChecksumAddress(process.env.PROTOCOL_OWNER || "0x2b4D825417f568231e809E31B9332ED146760337");

  if (!process.env.MPOOL_TOKEN_ADDRESS) {
    console.error("ERROR: MPOOL_TOKEN_ADDRESS not set. Run launch-mpool.js first.");
    process.exit(1);
  }

  console.log(`MPOOL Token: ${mpoolTokenAddress}`);
  console.log(`USDC:        ${usdcAddress}`);
  console.log(`Owner:       ${ownerAddress}\n`);

  const [deployer] = await hre.ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log(`Balance:  ${hre.ethers.formatEther(balance)} ETH\n`);

  // ── 1. Deploy or reuse MPOOLStaking ──
  let stakingAddress = process.env.MPOOL_STAKING_ADDRESS
    ? toChecksumAddress(process.env.MPOOL_STAKING_ADDRESS)
    : null;
  let staking;

  if (stakingAddress) {
    console.log(`[1/3] Reusing existing MPOOLStaking: ${stakingAddress}`);
    const MPOOLStaking = await hre.ethers.getContractFactory("MPOOLStaking");
    staking = MPOOLStaking.attach(stakingAddress);
  } else {
    console.log("[1/3] Deploying MPOOLStaking...");
    const MPOOLStaking = await hre.ethers.getContractFactory("MPOOLStaking");
    staking = await MPOOLStaking.deploy(mpoolTokenAddress, usdcAddress);
    await staking.waitForDeployment();
    stakingAddress = await staking.getAddress();
    console.log(`  MPOOLStaking: ${stakingAddress}`);
  }

  // ── 2. Deploy or reuse FeeRouter ──
  const FeeRouter = await hre.ethers.getContractFactory("FeeRouter");
  let feeRouter;
  let feeRouterAddress;

  if (process.env.FEE_ROUTER_ADDRESS) {
    feeRouterAddress = toChecksumAddress(process.env.FEE_ROUTER_ADDRESS);
    console.log(`[2/3] Reusing existing FeeRouter: ${feeRouterAddress}`);
    feeRouter = FeeRouter.attach(feeRouterAddress);
  } else {
    console.log("[2/3] Deploying FeeRouter...");
    feeRouter = await FeeRouter.deploy(usdcAddress, stakingAddress, ownerAddress, ownerAddress);
    await feeRouter.waitForDeployment();
    feeRouterAddress = await feeRouter.getAddress();
    console.log(`  FeeRouter:    ${feeRouterAddress}`);
  }

  // ── 3. Set FeeRouter as reward distributor ──
  console.log("[3/3] Linking FeeRouter to MPOOLStaking...");
  const setRouterTx = await staking.setFeeRouter(feeRouterAddress);
  await setRouterTx.wait();
  console.log(`  FeeRouter set as reward distributor.`);

  // ── Save to .env ──
  let envContent = fs.readFileSync(ENV_PATH, "utf8");
  if (!envContent.includes("MPOOL_STAKING_ADDRESS")) {
    envContent += `MPOOL_STAKING_ADDRESS=${stakingAddress}\n`;
    envContent += `FEE_ROUTER_ADDRESS=${feeRouterAddress}\n`;
  } else {
    envContent = envContent.replace(/MPOOL_STAKING_ADDRESS=.*/, `MPOOL_STAKING_ADDRESS=${stakingAddress}`);
    envContent = envContent.replace(/FEE_ROUTER_ADDRESS=.*/, `FEE_ROUTER_ADDRESS=${feeRouterAddress}`);
  }
  fs.writeFileSync(ENV_PATH, envContent);
  console.log("\n.env updated.");

  // ── Save to state.json ──
  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  if (!state.mpoolToken) state.mpoolToken = {};
  state.mpoolToken.stakingContract = stakingAddress;
  state.mpoolToken.feeRouter = feeRouterAddress;
  state.mpoolToken.feeSystemDeployedAt = new Date().toISOString();
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));
  console.log("state.json updated.\n");

  // ── Summary ──
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║               FEE SYSTEM DEPLOYED!                       ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ MPOOLStaking: ${stakingAddress.padEnd(42)}║`);
  console.log(`║ FeeRouter:    ${feeRouterAddress.padEnd(42)}║`);
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log("║ Fee Split: 70% stakers / 20% treasury / 10% buyback     ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log("║ NEXT STEPS:                                              ║");
  console.log("║ 1. Transfer 2.5M MPOOL to staking as reward reserve      ║");
  console.log("║ 2. Approve USDC for FeeRouter from protocol wallet       ║");
  console.log("║ 3. Call feeRouter.routeFees(amount) to distribute        ║");
  console.log("╚══════════════════════════════════════════════════════════╝");
}

main().catch((err) => {
  console.error("Error:", err);
  process.exit(1);
});
