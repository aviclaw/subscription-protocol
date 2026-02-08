require("@nomicfoundation/hardhat-toolbox");

const PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000001";

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: { enabled: true, runs: 200 }
    }
  },
  networks: {
    "base-sepolia": {
      url: "https://sepolia.base.org",
      chainId: 84532,
      accounts: [PRIVATE_KEY]
    },
    "ethereum-sepolia": {
      url: "https://ethereum-sepolia-rpc.publicnode.com",
      chainId: 11155111,
      accounts: [PRIVATE_KEY]
    }
  }
};
