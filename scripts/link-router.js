/**
 * Link Router to V3 via setRouter() + save to .env and state.json
 */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const ENV_PATH = path.join(__dirname, "..", ".env");
const STATE_PATH = path.join(__dirname, "..", "state.json");

const V3_ADDRESS = "0x3ee94c92eD66CfB6309A352136689626CDed3c40";
const ROUTER_ADDRESS = "0xdb9ca7ADb3739f3df1ED1B674F79AEDAdFB43F7f";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // Link Router → V3
  console.log("Setting Router on V3...");
  const V3 = await hre.ethers.getContractFactory("MutualPoolV3");
  const v3 = V3.attach(V3_ADDRESS);
  const tx = await v3.setRouter(ROUTER_ADDRESS);
  await tx.wait();
  console.log("  V3.router =", ROUTER_ADDRESS);

  // Save to .env
  let envContent = fs.readFileSync(ENV_PATH, "utf8");
  const envVars = {
    V3_CONTRACT_ADDRESS: V3_ADDRESS,
    ROUTER_ADDRESS: ROUTER_ADDRESS,
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
    router: ROUTER_ADDRESS,
    oracle: deployer.address,
    deployedAt: new Date().toISOString(),
    network: hre.network.name,
  };
  fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2));

  console.log("\n✓ Done. V3 + Router linked and saved.");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
