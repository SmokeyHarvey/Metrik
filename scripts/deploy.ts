import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function sleep(ms: number) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy METRIK Token
  const MetrikToken = await ethers.getContractFactory("MockERC20");
  const metrikToken = await MetrikToken.deploy("METRIK Token", "METRIK", 18);
  await metrikToken.waitForDeployment();
  console.log("METRIK Token deployed to:", await metrikToken.getAddress());

  // Deploy USDC Mock
  const USDC = await ethers.getContractFactory("MockERC20");
  const usdc = await USDC.deploy("USD Coin", "USDC", 6);
  await usdc.waitForDeployment();
  console.log("USDC Mock deployed to:", await usdc.getAddress());

  // Deploy InvoiceNFT
  const InvoiceNFT = await ethers.getContractFactory("InvoiceNFT");
  const invoiceNFT = await InvoiceNFT.deploy();
  await invoiceNFT.waitForDeployment();
  console.log("InvoiceNFT deployed to:", await invoiceNFT.getAddress());

  // Deploy Staking
  const Staking = await ethers.getContractFactory("Staking");
  const staking = await Staking.deploy(await metrikToken.getAddress());
  await staking.waitForDeployment();
  console.log("Staking deployed to:", await staking.getAddress());

  // Deploy LendingPool
  const LendingPool = await ethers.getContractFactory("LendingPool");
  const lendingPool = await LendingPool.deploy(
    await metrikToken.getAddress(),
    await usdc.getAddress(),
    await invoiceNFT.getAddress(),
    await staking.getAddress()
  );
  await lendingPool.waitForDeployment();
  console.log("LendingPool deployed to:", await lendingPool.getAddress());

  // Grant LendingPool the verifier role in InvoiceNFT
  const invoiceNFTContract = await ethers.getContractAt("InvoiceNFT", await invoiceNFT.getAddress());
  await invoiceNFTContract.grantRole(await invoiceNFTContract.VERIFIER_ROLE(), await lendingPool.getAddress());
  console.log("Granted LendingPool verifier role in InvoiceNFT");

  // Grant MINTER_ROLE to supplier
  const supplierAddress = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"; // Hardhat's second account
  await invoiceNFTContract.grantRole(await invoiceNFTContract.MINTER_ROLE(), supplierAddress);
  console.log("Granted MINTER_ROLE to supplier");

  // Mint METRIK tokens to owner
  const mintMetrikTx = await metrikToken.mint(deployer.address, ethers.parseEther("1000000"));
  await mintMetrikTx.wait();
  console.log("Minted 1,000,000 METRIK tokens to owner");

  // Mint USDC tokens to owner
  const mintUSDCTx = await usdc.mint(deployer.address, ethers.parseUnits("1000000", 6));
  await mintUSDCTx.wait();
  console.log("Minted 1,000,000 USDC to owner");

  // Mint USDC tokens to LP
  const lpAddress = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"; // Hardhat's third account
  const mintUSDCToLPTx = await usdc.mint(lpAddress, ethers.parseUnits("1000000", 6));
  await mintUSDCToLPTx.wait();
  console.log("Minted 1,000,000 USDC to LP");

  // Approve METRIK tokens for staking
  const approveMetrikTx = await metrikToken.approve(await staking.getAddress(), ethers.parseEther("1000000"));
  await approveMetrikTx.wait();
  console.log("Approved 1,000,000 METRIK tokens for staking");

  // Approve USDC tokens for lending pool
  const approveUSDCTx = await usdc.approve(await lendingPool.getAddress(), ethers.parseUnits("1000000", 6));
  await approveUSDCTx.wait();
  console.log("Approved 1,000,000 USDC tokens for lending pool");

  // Save deployed addresses
  const deployedAddresses = {
    metrikToken: await metrikToken.getAddress(),
    usdc: await usdc.getAddress(),
    invoiceNFT: await invoiceNFT.getAddress(),
    staking: await staking.getAddress(),
    lendingPool: await lendingPool.getAddress(),
    network: (await ethers.provider.getNetwork()).name,
    deployer: deployer.address
  };

  // Create deployments directory if it doesn't exist
  const deploymentsDir = path.join(__dirname, "../deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir);
  }

  // Save addresses to a JSON file
  const networkName = (await ethers.provider.getNetwork()).name;
  const filePath = path.join(deploymentsDir, `${networkName}.json`);
  fs.writeFileSync(filePath, JSON.stringify(deployedAddresses, null, 2));
  console.log(`Deployed addresses saved to ${filePath}`);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 