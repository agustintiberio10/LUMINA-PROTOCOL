/**
 * Set the oracle on DisputeResolver to point to AutoResolver.
 *
 * Usage:
 *   node scripts/set-oracle.js <AUTORESOLVER_ADDRESS>
 *
 * This calls DisputeResolver.setOracle(autoResolverAddress) so that
 * Chainlink Automation can call executeResolution() through AutoResolver.
 */
require("dotenv").config();
const { ethers } = require("ethers");

async function main() {
  const autoResolverAddress = process.argv[2];
  if (!autoResolverAddress || !autoResolverAddress.startsWith("0x")) {
    console.error("Usage: node scripts/set-oracle.js <AUTORESOLVER_ADDRESS>");
    process.exit(1);
  }

  const DISPUTE_RESOLVER = "0x2e4D0112A65C2e2DCE73e7f85bf5C2889c7709cA";

  const provider = new ethers.JsonRpcProvider(process.env.BASE_RPC_URL || "https://mainnet.base.org");
  const wallet = new ethers.Wallet(process.env.AGENT_PRIVATE_KEY, provider);

  const abi = [
    "function setOracle(address _newOracle) external",
    "function oracle() view returns (address)",
    "function owner() view returns (address)",
  ];

  const dr = new ethers.Contract(DISPUTE_RESOLVER, abi, wallet);

  // Safety checks
  const owner = await dr.owner();
  const currentOracle = await dr.oracle();
  console.log("DisputeResolver:", DISPUTE_RESOLVER);
  console.log("Current oracle: ", currentOracle);
  console.log("New oracle:     ", autoResolverAddress);
  console.log("Owner:          ", owner);
  console.log("Our wallet:     ", wallet.address);

  if (owner.toLowerCase() !== wallet.address.toLowerCase()) {
    console.error("\nERROR: We are not the owner of DisputeResolver. Cannot call setOracle().");
    process.exit(1);
  }

  console.log("\nSending setOracle transaction...");
  const tx = await dr.setOracle(autoResolverAddress);
  console.log("TX sent:", tx.hash);
  await tx.wait();
  console.log("TX confirmed!");

  // Verify
  const newOracle = await dr.oracle();
  console.log("\nNew oracle on DisputeResolver:", newOracle);
  console.log("Match:", newOracle.toLowerCase() === autoResolverAddress.toLowerCase());
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
