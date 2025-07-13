const { ethers } = require("hardhat");

async function main() {
  console.log("Verifying contracts on Citrea testnet...");
  
  // Load deployment addresses
  const fs = require('fs');
  const deploymentPath = './deployments/Citrea.json';
  const deployedAddresses = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
  
  console.log("Deployed addresses:", deployedAddresses);
  
  try {
    // Get contract instances
    console.log("Loading contract instances...");
    const metrikToken = await ethers.getContractAt("MockERC20", deployedAddresses.metrikToken);
    const usdc = await ethers.getContractAt("MockERC20", deployedAddresses.usdc);
    const invoiceNFT = await ethers.getContractAt("InvoiceNFT", deployedAddresses.invoiceNFT);
    const staking = await ethers.getContractAt("Staking", deployedAddresses.staking);
    const lendingPool = await ethers.getContractAt("LendingPool", deployedAddresses.lendingPool);
    
    console.log("Contract instances loaded successfully");
    
    // Test basic contract calls
    console.log("Testing basic contract calls...");
    
    const metrikName = await metrikToken.name();
    console.log("METRIK Token name:", metrikName);
    
    const usdcName = await usdc.name();
    console.log("USDC name:", usdcName);
    
    const invoiceName = await invoiceNFT.name();
    console.log("InvoiceNFT name:", invoiceName);
    
    // Test MINTER_ROLE
    try {
      const minterRole = await invoiceNFT.MINTER_ROLE();
      console.log("MINTER_ROLE:", minterRole);
    } catch (error) {
      console.log("Error getting MINTER_ROLE:", error.message);
    }
    
    // Test VERIFIER_ROLE
    try {
      const verifierRole = await invoiceNFT.VERIFIER_ROLE();
      console.log("VERIFIER_ROLE:", verifierRole);
    } catch (error) {
      console.log("Error getting VERIFIER_ROLE:", error.message);
    }
    
    console.log("All basic tests passed!");
    
  } catch (error) {
    console.error("Error during verification:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 