const hre = require("hardhat");

async function main() {
  const mpoolAddr = process.env.MPOOL_TOKEN_ADDRESS;
  const [deployer] = await hre.ethers.getSigners();

  // Try to get contract code and check for common mint selectors
  const code = await hre.ethers.provider.getCode(mpoolAddr);

  // mint(address,uint256) selector = 0x40c10f19
  const hasMintSelector = code.includes("40c10f19");
  console.log("Has mint(address,uint256) selector:", hasMintSelector);

  // Try calling mint directly
  const mintAbi = [
    "function mint(address to, uint256 amount)",
    "function owner() view returns (address)",
    "function totalSupply() view returns (uint256)",
    "function decimals() view returns (uint8)",
    "function name() view returns (string)",
    "function symbol() view returns (string)",
  ];

  const token = new hre.ethers.Contract(mpoolAddr, mintAbi, deployer);

  try {
    const name = await token.name();
    const symbol = await token.symbol();
    const decimals = await token.decimals();
    const totalSupply = await token.totalSupply();
    console.log(`\nToken: ${name} (${symbol})`);
    console.log(`Decimals: ${decimals}`);
    console.log(`Total Supply (raw): ${totalSupply}`);
    console.log(`Total Supply (formatted): ${hre.ethers.formatUnits(totalSupply, decimals)}`);
  } catch (e) {
    console.log("Error reading token info:", e.message);
  }

  try {
    const owner = await token.owner();
    console.log(`\nOwner: ${owner}`);
    console.log(`Deployer: ${deployer.address}`);
    console.log(`Is owner: ${owner.toLowerCase() === deployer.address.toLowerCase()}`);
  } catch (e) {
    console.log("\nNo owner() function or error:", e.message);
  }

  if (hasMintSelector) {
    console.log("\n--- Attempting test mint (dry run via staticCall) ---");
    try {
      await token.mint.staticCall(deployer.address, hre.ethers.parseUnits("10000000", 18));
      console.log("✅ mint() staticCall succeeded! Minting is possible.");
    } catch (e) {
      console.log("❌ mint() staticCall failed:", e.message);
    }
  }
}

main();
