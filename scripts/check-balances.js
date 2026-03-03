const hre = require("hardhat");
async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Wallet:", deployer.address);

  const ethBal = await hre.ethers.provider.getBalance(deployer.address);
  console.log("ETH:", hre.ethers.formatEther(ethBal));

  const abi = ["function balanceOf(address) view returns (uint256)"];
  const mpool = new hre.ethers.Contract(process.env.MPOOL_TOKEN_ADDRESS, abi, deployer);
  const mpoolBal = await mpool.balanceOf(deployer.address);
  console.log("MPOOL:", hre.ethers.formatUnits(mpoolBal, 18));

  const usdc = new hre.ethers.Contract(process.env.USDC_ADDRESS, abi, deployer);
  const usdcBal = await usdc.balanceOf(deployer.address);
  console.log("USDC:", hre.ethers.formatUnits(usdcBal, 6));
}
main();
