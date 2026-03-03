/**
 * Fix v2: Link FeeRouter to MPOOLStaking + Transfer 2.5M MPOOL
 *
 * Hardcoded v2 addresses to avoid .env confusion.
 */
const hre = require("hardhat");

// ── v2 Addresses (verified on-chain) ──
const MPOOL_V2 = "0x1F6d3ba2BEA4883a9b1834E6b6cFcCf5DD159787";
const STAKING_V2 = "0x6c86d5E24Bfb6D154B05d2a3cCD233548A038FD5";
const FEE_ROUTER_V2 = "0x82b4be13b4756c483bE9bCD73A0c24837513e627";

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("╔══════════════════════════════════════════════════════════╗");
  console.log("║     FIX v2: LINK FEE ROUTER + TRANSFER MPOOL           ║");
  console.log("╚══════════════════════════════════════════════════════════╝\n");
  console.log(`Deployer: ${deployer.address}`);

  const bal = await hre.ethers.provider.getBalance(deployer.address);
  console.log(`ETH Balance: ${hre.ethers.formatEther(bal)}\n`);

  // ── Step 1: Link FeeRouter to Staking ──
  console.log("[1/2] Linking FeeRouter to MPOOLStaking v2...");
  const stakingAbi = ["function setFeeRouter(address)", "function feeRouter() view returns (address)"];
  const staking = new hre.ethers.Contract(STAKING_V2, stakingAbi, deployer);

  try {
    const currentRouter = await staking.feeRouter();
    console.log(`  Current feeRouter: ${currentRouter}`);
    if (currentRouter.toLowerCase() === FEE_ROUTER_V2.toLowerCase()) {
      console.log("  ✅ Already linked! Skipping.");
    } else {
      const tx = await staking.setFeeRouter(FEE_ROUTER_V2);
      console.log(`  Tx: ${tx.hash}`);
      await tx.wait();
      console.log("  ✅ FeeRouter linked to staking.");
    }
  } catch (e) {
    console.error("  ❌ Failed:", e.message);
  }

  // ── Step 2: Transfer 2.5M MPOOL to Staking ──
  console.log("\n[2/2] Transferring 2.5M MPOOL to staking...");
  const tokenAbi = [
    "function transfer(address to, uint256 amount) returns (bool)",
    "function balanceOf(address) view returns (uint256)",
  ];
  const mpool = new hre.ethers.Contract(MPOOL_V2, tokenAbi, deployer);

  const ownerBal = await mpool.balanceOf(deployer.address);
  console.log(`  Owner MPOOL balance: ${hre.ethers.formatUnits(ownerBal, 18)}`);

  const transferAmount = hre.ethers.parseUnits("2500000", 18);
  if (ownerBal >= transferAmount) {
    const tx = await mpool.transfer(STAKING_V2, transferAmount);
    console.log(`  Tx: ${tx.hash}`);
    await tx.wait();
    console.log("  ✅ 2.5M MPOOL transferred to staking.");
  } else {
    console.log("  ⚠ Insufficient MPOOL. Skipping transfer.");
  }

  // ── Verify ──
  console.log("\n── Final Verification ──");
  const stakingBal = await mpool.balanceOf(STAKING_V2);
  const ownerBalAfter = await mpool.balanceOf(deployer.address);
  const router = await staking.feeRouter();
  console.log(`FeeRouter in staking: ${router}`);
  console.log(`Staking MPOOL balance: ${hre.ethers.formatUnits(stakingBal, 18)}`);
  console.log(`Owner MPOOL balance:   ${hre.ethers.formatUnits(ownerBalAfter, 18)}`);

  console.log("\n╔══════════════════════════════════════════════════════════╗");
  console.log("║              v2 FIX COMPLETE!                            ║");
  console.log("╚══════════════════════════════════════════════════════════╝");
}

main().catch((err) => {
  console.error("FATAL:", err);
  process.exit(1);
});
