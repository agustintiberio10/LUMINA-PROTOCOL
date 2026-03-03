/**
 * Set the new TEE-derived wallet as the oracle on MutualPoolV3.
 * Usage: npx hardhat run scripts/set-oracle-tee.js --network baseMainnet
 */
const { ethers } = require("hardhat");
const artifact = require("../artifacts/contracts/MutualPoolV3.sol/MutualPoolV3.json");

const NEW_ORACLE = "0xf3D21A3A689AD889541d993A51e3109aC3E36c12";
const V3_ADDRESS = process.env.V3_CONTRACT_ADDRESS;

async function main() {
  const [signer] = await ethers.getSigners();
  console.log("Signer (owner):", signer.address);

  const v3 = new ethers.Contract(V3_ADDRESS, artifact.abi, signer);

  const currentOracle = await v3.oracle();
  const owner = await v3.owner();
  console.log("Contract owner:", owner);
  console.log("Current oracle:", currentOracle);
  console.log("New oracle (TEE):", NEW_ORACLE);

  if (currentOracle.toLowerCase() === NEW_ORACLE.toLowerCase()) {
    console.log("Oracle is already set to the TEE wallet. Nothing to do.");
    return;
  }

  if (signer.address.toLowerCase() !== owner.toLowerCase()) {
    console.error("ERROR: Signer is NOT the contract owner. Cannot call setOracle().");
    process.exit(1);
  }

  console.log("\nCalling setOracle()...");
  const tx = await v3.setOracle(NEW_ORACLE);
  console.log("TX sent:", tx.hash);
  console.log("Waiting for confirmation...");
  const receipt = await tx.wait(1);
  console.log("Confirmed in block:", receipt.blockNumber);
  console.log("Gas used:", receipt.gasUsed.toString());

  // Check events
  for (const log of receipt.logs) {
    try {
      const parsed = v3.interface.parseLog(log);
      if (parsed) console.log("Event:", parsed.name, parsed.args);
    } catch {}
  }

  const updatedOracle = await v3.oracle();
  console.log("\nOracle after update:", updatedOracle);
  console.log("Success:", updatedOracle.toLowerCase() === NEW_ORACLE.toLowerCase());
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
