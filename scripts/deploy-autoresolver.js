require("dotenv").config();
const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying AutoResolver with account:", deployer.address);

  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log("Account balance:", hre.ethers.formatEther(balance), "ETH");

  // Constructor parameters
  const DISPUTE_RESOLVER = "0x2e4D0112A65C2e2DCE73e7f85bf5C2889c7709cA";
  const MAX_STALENESS = 3600; // 1 hour

  console.log("\nConstructor parameters:");
  console.log("  _disputeResolver:", DISPUTE_RESOLVER);
  console.log("  _maxStaleness:   ", MAX_STALENESS, "(1 hour)");

  const AutoResolver = await hre.ethers.getContractFactory("AutoResolver");
  const autoResolver = await AutoResolver.deploy(DISPUTE_RESOLVER, MAX_STALENESS);

  await autoResolver.waitForDeployment();
  const address = await autoResolver.getAddress();
  const deployTx = autoResolver.deploymentTransaction();

  console.log("\n========================================");
  console.log("AutoResolver deployed to:", address);
  console.log("TX hash:", deployTx.hash);
  console.log("========================================");

  // Get gas used
  const receipt = await deployTx.wait();
  console.log("Gas used:", receipt.gasUsed.toString());

  console.log("\nNext steps:");
  console.log(`1. Verify:  npx hardhat verify --network baseMainnet ${address} "${DISPUTE_RESOLVER}" "${MAX_STALENESS}"`);
  console.log(`2. Set oracle on DisputeResolver: node scripts/set-oracle.js ${address}`);
  console.log("3. Register as Chainlink Automation upkeep");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
