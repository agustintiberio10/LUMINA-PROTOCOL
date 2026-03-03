/**
 * Deploy ONLY MutualPoolRouter (V3 already deployed)
 * Then link Router → V3 via setRouter()
 */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const ENV_PATH = path.join(__dirname, "..", ".env");
const STATE_PATH = path.join(__dirname, "..", "state.json");

const V3_ADDRESS = "0x3ee94c92eD66CfB6309A352136689626CDed3c40";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log("Balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(deployer.address)), "ETH");
  console.log("Using existing V3:", V3_ADDRESS);

  const usdcAddress = process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

  // 1. Deploy Router
  console.log("\n[1/2] Deploying MutualPoolRouter...");
  const Router = await hre.ethers.getContractFactory("MutualPoolRouter");
  const router = await Router.deploy(usdcAddress, V3_ADDRESS);
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  console.log("  MutualPoolRouter:", routerAddress);

  // 2. Link Router → V3
  console.log("\n[2/2] Setting Router on V3...");
  const V3 = await hre.ethers.getContractFactory("MutualPoolV3");
  const v3 = V3.attach(V3_ADDRESS);
  const setRouterTx = await v3.setRouter(routerAddress);
  await setRouterTx.wait();
  console.log("  V3.router =", routerAddress);

  // Save to .env
  let envContent = fs.readFileSync(ENV_PATH, "utf8");
  const envVars = {
    V3_CONTRACT_ADDRESS: V3_ADDRESS,
    ROUTER_ADDRESS: routerAddress,
  };
  for (const [key, value] of Object.entries(envVars)) {
    const regex = new RegExp(`^${key}=.*$`, "m");
    if (regex.test(envContent)) {
      envContent = envContent.replace(regex, `${key}=${value}`);
    } else {
      envContent += `\n${key}=${value}\n`;
    }
  }
  fs.writeFileSync(ENV_PATH, envContent);

  // Save to state.json
  const state = JSON.parse(fs.readFileSync(STATE_PATH, "utf8"));
  state.v3 = {
    contract: V3_ADDRESS,
    router: routerAddress,
    oracle: deployer.address,
    deployedAt: new Date().toISOString(),
    network: hre.network.name,
  };
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));

  console.log("\n✓ Router deployed and linked to V3");
  console.log("  V3:", V3_ADDRESS);
  console.log("  Router:", routerAddress);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
