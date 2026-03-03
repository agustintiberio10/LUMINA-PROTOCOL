require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");

const AGENT_PRIVATE_KEY = process.env.AGENT_PRIVATE_KEY || "0x" + "0".repeat(64);

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      viaIR: true,
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    baseMainnet: {
      url: process.env.BASE_RPC_URL || "https://mainnet.base.org",
      accounts: [AGENT_PRIVATE_KEY],
      chainId: 8453,
    },
    baseSepolia: {
      url: process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org",
      accounts: [AGENT_PRIVATE_KEY],
      chainId: 84532,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
  },
  sourcify: {
    enabled: true,
  },
};
