const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying MutualPool with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // USDC on Base Mainnet
  const usdcAddress = process.env.USDC_ADDRESS || "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

  console.log("USDC address:", usdcAddress);
  console.log("Oracle (deployer):", deployer.address);

  // Deploy MutualPool
  const MutualPool = await hre.ethers.getContractFactory("MutualPool");
  const pool = await MutualPool.deploy(usdcAddress, deployer.address);
  await pool.waitForDeployment();

  const contractAddress = await pool.getAddress();
  console.log("MutualPool deployed to:", contractAddress);

  // Update state.json with contract address
  const statePath = path.join(__dirname, "..", "state.json");
  const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
  state.contractAddress = contractAddress;
  fs.writeFileSync(statePath, JSON.stringify(state, null, 2));
  console.log("Updated state.json with contract address");

  // Verify contract on explorer (optional, may fail on testnet)
  if (process.env.BASESCAN_API_KEY) {
    console.log("Waiting for block confirmations before verification...");
    await pool.deploymentTransaction().wait(5);
    try {
      await hre.run("verify:verify", {
        address: contractAddress,
        constructorArguments: [usdcAddress, deployer.address],
      });
      console.log("Contract verified on BaseScan");
    } catch (err) {
      console.log("Verification failed (non-critical):", err.message);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
