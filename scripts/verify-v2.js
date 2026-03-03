const hre = require("hardhat");

async function main() {
  const tokenAddr = "0x1F6d3ba2BEA4883a9b1834E6b6cFcCf5DD159787";
  const abi = [
    "function name() view returns (string)",
    "function symbol() view returns (string)",
    "function totalSupply() view returns (uint256)",
    "function balanceOf(address) view returns (uint256)",
  ];

  try {
    const token = new hre.ethers.Contract(tokenAddr, abi, hre.ethers.provider);
    const name = await token.name();
    const symbol = await token.symbol();
    const supply = await token.totalSupply();
    const ownerBal = await token.balanceOf("0x2b4D825417f568231e809E31B9332ED146760337");
    console.log(`Token: ${name} (${symbol})`);
    console.log(`Address: ${tokenAddr}`);
    console.log(`Total Supply: ${hre.ethers.formatUnits(supply, 18)} MPOOL`);
    console.log(`Owner balance: ${hre.ethers.formatUnits(ownerBal, 18)} MPOOL`);
    console.log("✅ Token verified!");
  } catch (e) {
    console.log(`❌ Token at ${tokenAddr} - Error: ${e.message}`);
  }
}
main();
