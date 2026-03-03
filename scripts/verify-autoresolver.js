/**
 * Verify AutoResolver on BaseScan.
 *
 * Usage:
 *   npx hardhat run scripts/verify-autoresolver.js --network baseMainnet
 *
 * Or directly:
 *   npx hardhat verify --network baseMainnet DEPLOYED_ADDRESS "0x2e4D0112A65C2e2DCE73e7f85bf5C2889c7709cA" "3600"
 */
const hre = require("hardhat");

async function main() {
  const DEPLOYED_ADDRESS = process.env.AUTORESOLVER_ADDRESS;
  if (!DEPLOYED_ADDRESS) {
    console.error("Set AUTORESOLVER_ADDRESS env var to the deployed address");
    process.exit(1);
  }

  const DISPUTE_RESOLVER = "0x2e4D0112A65C2e2DCE73e7f85bf5C2889c7709cA";
  const MAX_STALENESS = "3600";

  console.log("Verifying AutoResolver at:", DEPLOYED_ADDRESS);
  console.log("Constructor args:", DISPUTE_RESOLVER, MAX_STALENESS);

  await hre.run("verify:verify", {
    address: DEPLOYED_ADDRESS,
    constructorArguments: [DISPUTE_RESOLVER, MAX_STALENESS],
  });

  console.log("Verification complete!");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
