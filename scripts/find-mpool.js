const hre = require("hardhat");

async function main() {
  const mpoolAddr = process.env.MPOOL_TOKEN_ADDRESS;
  const abi = [
    "function balanceOf(address) view returns (uint256)",
    "function totalSupply() view returns (uint256)",
    "function owner() view returns (address)"
  ];
  const mpool = new hre.ethers.Contract(mpoolAddr, abi, hre.ethers.provider);

  const totalSupply = await mpool.totalSupply();
  console.log("Total Supply:", hre.ethers.formatUnits(totalSupply, 18), "MPOOL\n");

  // Check known addresses
  const addresses = {
    "Owner wallet": process.env.PROTOCOL_OWNER,
    "MutualPool contract": process.env.CONTRACT_ADDRESS,
    "MPOOLStaking": process.env.MPOOL_STAKING_ADDRESS,
    "FeeRouter": process.env.FEE_ROUTER_ADDRESS,
    "MPOOL Token (self)": process.env.MPOOL_TOKEN_ADDRESS,
    "LP Pool": "0xad860dd5E7874cd610E48DE57F0A87A9051c0CeA",
  };

  let accounted = 0n;
  for (const [name, addr] of Object.entries(addresses)) {
    if (!addr) continue;
    try {
      const bal = await mpool.balanceOf(addr);
      const formatted = hre.ethers.formatUnits(bal, 18);
      if (bal > 0n) {
        console.log(`✅ ${name} (${addr}): ${formatted} MPOOL`);
      } else {
        console.log(`   ${name} (${addr}): 0 MPOOL`);
      }
      accounted += bal;
    } catch (e) {
      console.log(`❌ ${name} (${addr}): error - ${e.message}`);
    }
  }

  console.log("\nAccounted:", hre.ethers.formatUnits(accounted, 18), "MPOOL");
  console.log("Unaccounted:", hre.ethers.formatUnits(totalSupply - accounted, 18), "MPOOL");
}

main();
