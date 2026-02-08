const hre = require("hardhat");

async function main() {
  const USDC_ADDRESSES = {
    "base-sepolia": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    "ethereum-sepolia": "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238"
  };

  const network = hre.network.name;
  const usdcAddress = USDC_ADDRESSES[network];
  const [deployer] = await hre.ethers.getSigners();

  if (!usdcAddress) {
    throw new Error(`No USDC address for network: ${network}`);
  }

  console.log(`\nDeploying SubscriptionProtocol to ${network}...`);
  console.log(`Deployer: ${deployer.address}`);
  console.log(`USDC: ${usdcAddress}`);

  const PROTOCOL_FEE_BPS = 100; // 1%
  const FEE_RECIPIENT = deployer.address; // Change for production

  const SubscriptionProtocol = await hre.ethers.getContractFactory("SubscriptionProtocol");
  const protocol = await SubscriptionProtocol.deploy(
    usdcAddress,
    PROTOCOL_FEE_BPS,
    FEE_RECIPIENT
  );

  await protocol.waitForDeployment();
  const address = await protocol.getAddress();

  console.log(`\n✅ SubscriptionProtocol deployed to: ${address}`);
  console.log(`   Protocol fee: ${PROTOCOL_FEE_BPS / 100}%`);
  console.log(`   Fee recipient: ${FEE_RECIPIENT}`);

  console.log(`\n📖 Example Usage:`);
  console.log(`\n1. Provider creates a plan:`);
  console.log(`   protocol.createPlan(10_000000, 2592000, 259200, "Pro Plan", "{}")`);
  console.log(`   // 10 USDC, 30-day interval, 3-day grace period`);
  console.log(`\n2. Subscriber subscribes (must approve USDC first):`);
  console.log(`   USDC.approve(${address}, MAX_UINT256)`);
  console.log(`   protocol.subscribe(1)`);
  console.log(`\n3. Charge when due:`);
  console.log(`   protocol.charge(subscriptionId)`);

  return address;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
