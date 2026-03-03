/**
 * Deploy MutualPoolV3 + MutualPoolRouter
 *
 * 1. Deploy MutualPoolV3 (zero-funded vault, oracle = deployer)
 * 2. Deploy MutualPoolRouter (gateway between users and V3)
 * 3. Call V3.setRouter(router) to authorize the Router
 * 4. Save addresses to .env and state.json
 */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const ENV_PATH = path.join(__dirname, "..", ".env");
const STATE_PATH = path.join(__dirname, "..", "state.json");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║        MUTUALPOOL V3 + ROUTER — DEPLOYMENT              ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");
  console.log("Deployer:", deployer.address);
  console.log("Balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH");

  const usdcAddress = process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
  console.log("USDC:", usdcAddress);

  // ── 1. Deploy MutualPoolV3 ──
  console.log("\n[1/3] Deploying MutualPoolV3...");
  const V3 = await hre.ethers.getContractFactory("MutualPoolV3");
  const v3 = await V3.deploy(usdcAddress, deployer.address);
  await v3.waitForDeployment();
  const v3Address = await v3.getAddress();
  console.log("  MutualPoolV3:", v3Address);

  // ── 2. Deploy MutualPoolRouter ──
  console.log("\n[2/3] Deploying MutualPoolRouter...");
  const Router = await hre.ethers.getContractFactory("MutualPoolRouter");
  const router = await Router.deploy(usdcAddress, v3Address);
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("  MutualPoolRouter:", routerAddress);

  // ── 3. Link Router → V3 ──
  console.log("\n[3/3] Setting Router on V3...");
  const setRouterTx = await v3.setRouter(routerAddress);
  await setRouterTx.wait();
  console.log("  V3.router =", routerAddress);

  // ── Save to .env ──
  console.log("\nSaving to .env...");
  let envContent = fs.readFileSync(ENV_PATH, "utf8");

  const envVars = {
    V3_CONTRACT_ADDRESS: v3Address,
    ROUTER_ADDRESS: routerAddress,
  };

  for (const [key, value] of Object.entries(envVars)) {
    const regex = new RegExp(`^${key}=.*$`, "m");
    if (regex.test(envContent)) {
      envContent = envContent.replace(regex, `${key}=${value}`);
    } else {
      envContent += `\n# V3 Deployment\n${key}=${value}\n`;
    }
  }
  fs.writeFileSync(ENV_PATH, envContent);

  // ── Save to state.json ──
  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  state.v3 = {
    contract: v3Address,
    router: routerAddress,
    oracle: deployer.address,
    deployedAt: new Date().toISOString(),
    network: hre.network.name,
  };
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));

  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║                  DEPLOYMENT COMPLETE                      ║");
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log(`║ MutualPoolV3:     ${v3Address}  ║`);
  console.log(`║ MutualPoolRouter: ${routerAddress}  ║`);
  console.log(`║ Oracle:           ${deployer.address}  ║`);
  console.log("╠══════════════════════════════════════════════════════════╣");
  console.log("║ NEXT STEPS:                                              ║");
  console.log("║ 1. npm run launch:mpoolv3  (launch MPOOLV3 token)         ║");
  console.log("║ 2. router.setMpoolToken(tokenAddr)                        ║");
  console.log("║ 3. router.setSwapHandler(fluidHandler)                    ║");
  console.log("╚══════════════════════════════════════════════════════════╝");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
