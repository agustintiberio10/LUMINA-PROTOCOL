const hre = require("hardhat");

async function main() {
  const addrs = {
    "MPOOL Token": "0x1F6d3ba2BEA4883a9b1834E6b6cFcCf5DD159787",
    "MPOOLStaking": "0x6c86d5E24Bfb6D154B05d2a3cCD233548A038FD5",
    "FeeRouter": "0x82b4be13b4756c483bE9bCD73A0c24837513e627",
  };

  for (const [name, addr] of Object.entries(addrs)) {
    const code = await hre.ethers.provider.getCode(addr);
    const isContract = code !== "0x";
    console.log(`${name}: ${addr} → ${isContract ? "✅ Contract exists" : "❌ No contract"}`);
  }
}
main();
