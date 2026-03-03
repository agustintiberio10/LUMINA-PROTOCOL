const hre = require("hardhat");

const MPOOL_V2 = "0x1F6d3ba2BEA4883a9b1834E6b6cFcCf5DD159787";
const STAKING_V2 = "0x6c86d5E24Bfb6D154B05d2a3cCD233548A038FD5";

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  // Check the transfer tx receipt
  const txHash = "0xea04a70fe098e2ce80b244c67fb1eb0536ff472af387978ef6a23406ddbc25e5";
  const receipt = await hre.ethers.provider.getTransactionReceipt(txHash);
  console.log("Transfer tx status:", receipt.status === 1 ? "SUCCESS" : "FAILED");
  console.log("Gas used:", receipt.gasUsed.toString());
  console.log("Logs count:", receipt.logs.length);

  if (receipt.logs.length > 0) {
    for (const log of receipt.logs) {
      console.log("\nLog:", {
        address: log.address,
        topics: log.topics,
        data: log.data,
      });
    }
  }

  // Check balances fresh
  const abi = [
    "function balanceOf(address) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function decimals() view returns (uint8)",
  ];
  const mpool = new hre.ethers.Contract(MPOOL_V2, abi, hre.ethers.provider);

  const decimals = await mpool.decimals();
  console.log("\nDecimals:", decimals);

  const ownerBal = await mpool.balanceOf(deployer.address);
  console.log(`Owner balance: ${hre.ethers.formatUnits(ownerBal, decimals)} (raw: ${ownerBal})`);

  const stakingBal = await mpool.balanceOf(STAKING_V2);
  console.log(`Staking balance: ${hre.ethers.formatUnits(stakingBal, decimals)} (raw: ${stakingBal})`);

  // Try a small transfer as test
  console.log("\nTesting small transfer (1 MPOOL)...");
  const tokenWrite = new hre.ethers.Contract(MPOOL_V2, ["function transfer(address,uint256) returns (bool)"], deployer);
  try {
    const tx = await tokenWrite.transfer(STAKING_V2, hre.ethers.parseUnits("1", decimals));
    const r = await tx.wait();
    console.log("Test tx status:", r.status === 1 ? "SUCCESS" : "FAILED");
    console.log("Test tx logs:", r.logs.length);

    const newStakingBal = await mpool.balanceOf(STAKING_V2);
    console.log(`Staking after test: ${hre.ethers.formatUnits(newStakingBal, decimals)}`);
  } catch (e) {
    console.log("Test transfer error:", e.message);
  }
}
main();
