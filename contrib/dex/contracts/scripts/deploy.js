const hre = require("hardhat");

async function main() {
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("  PIV2_HTLC Deployment Script");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("");

  // Get network info
  const network = hre.network.name;
  const chainId = hre.network.config.chainId;
  console.log(`Network: ${network} (chainId: ${chainId})`);

  // Get deployer
  const [deployer] = await hre.ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);

  // Get balance
  const balance = await hre.ethers.provider.getBalance(deployer.address);
  console.log(`Balance: ${hre.ethers.formatEther(balance)} ETH/MATIC`);
  console.log("");

  // Deploy contract
  console.log("Deploying PIV2_HTLC...");
  const PIV2_HTLC = await hre.ethers.getContractFactory("PIV2_HTLC");
  const htlc = await PIV2_HTLC.deploy();

  await htlc.waitForDeployment();
  const address = await htlc.getAddress();

  console.log("");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("  DEPLOYMENT SUCCESSFUL");
  console.log("═══════════════════════════════════════════════════════════════");
  console.log("");
  console.log(`  Contract: PIV2_HTLC`);
  console.log(`  Address:  ${address}`);
  console.log(`  Network:  ${network}`);
  console.log(`  ChainId:  ${chainId}`);
  console.log("");

  // Verify on block explorer (if not localhost)
  if (network !== "hardhat" && network !== "localhost") {
    console.log("Waiting 30s for block confirmations before verification...");
    await new Promise(resolve => setTimeout(resolve, 30000));

    console.log("Verifying contract on block explorer...");
    try {
      await hre.run("verify:verify", {
        address: address,
        constructorArguments: []
      });
      console.log("Contract verified!");
    } catch (error) {
      if (error.message.includes("Already Verified")) {
        console.log("Contract already verified!");
      } else {
        console.log("Verification failed:", error.message);
      }
    }
  }

  // Save deployment info
  const deploymentInfo = {
    contract: "PIV2_HTLC",
    address: address,
    network: network,
    chainId: chainId,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    txHash: htlc.deploymentTransaction()?.hash
  };

  console.log("");
  console.log("Deployment info (save this!):");
  console.log(JSON.stringify(deploymentInfo, null, 2));

  return deploymentInfo;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
