const hre = require("hardhat");

const MPOOL_V2 = "0x1F6d3ba2BEA4883a9b1834E6b6cFcCf5DD159787";
const STAKING_V2 = "0x6c86d5E24Bfb6D154B05d2a3cCD233548A038FD5";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const abi = [
    "function transfer(address to, uint256 amount) returns (bool)",
    "function balanceOf(address) view returns (uint256)",
  ];
  const mpool = new hre.ethers.Contract(MPOOL_V2, abi, deployer);

  const ownerBal = await mpool.balanceOf(deployer.address);
  console.log(`Owner MPOOL: ${hre.ethers.formatUnits(ownerBal, 18)}`);

  const amount = hre.ethers.parseUnits("2500000", 18);
  console.log("Transferring 2.5M MPOOL to staking...");
  const tx = await mpool.transfer(STAKING_V2, amount);
  console.log(`Tx: ${tx.hash}`);
  await tx.wait();
  console.log("✅ Done!");

  const stakingBal = await mpool.balanceOf(STAKING_V2);
  const ownerAfter = await mpool.balanceOf(deployer.address);
  console.log(`Staking MPOOL: ${hre.ethers.formatUnits(stakingBal, 18)}`);
  console.log(`Owner MPOOL:   ${hre.ethers.formatUnits(ownerAfter, 18)}`);
}
main().catch(e => { console.error(e); process.exit(1); });
