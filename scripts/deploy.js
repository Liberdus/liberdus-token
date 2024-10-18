const hre = require("hardhat");

async function main() {
  const [deployer, signer1, signer2] = await hre.ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  console.log("Account balance:", (await deployer.provider.getBalance(deployer.address)).toString());

  const LiberdusToken = await hre.ethers.getContractFactory("Liberdus");
  const liberdusToken = await LiberdusToken.deploy([deployer.address, signer1.address, signer2.address]);

  await liberdusToken.waitForDeployment();

  console.log("LiberdusToken deployed to:", await liberdusToken.getAddress());
  console.log("Initial signers:");
  console.log("- Signer 1:", deployer.address);
  console.log("- Signer 2:", signer1.address);
  console.log("- Signer 3:", signer2.address);

  // Verify the contract on Etherscan
  if (hre.network.name !== "hardhat" && hre.network.name !== "localhost") {
    console.log("Waiting for block confirmations...");
    await liberdusToken.deploymentTransaction().wait(6);
    console.log("Verifying contract...");
    await hre.run("verify:verify", {
      address: await liberdusToken.getAddress(),
      constructorArguments: [[deployer.address, signer1.address, signer2.address]],
    });
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });