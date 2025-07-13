const { ethers } = require("hardhat");

async function main() {
  console.log("Testing deployed contracts on Citrea testnet...");
  
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
    const borrowRegistry = await ethers.getContractAt("BorrowRegistry", deployedAddresses.borrowRegistry);
    
    console.log("Contract instances loaded successfully");
    
    // Test basic contract calls
    console.log("\n=== Testing Basic Contract Functions ===");
    
    const metrikName = await metrikToken.name();
    console.log("✅ METRIK Token name:", metrikName);
    
    const usdcName = await usdc.name();
    console.log("✅ USDC name:", usdcName);
    
    const invoiceName = await invoiceNFT.name();
    console.log("✅ InvoiceNFT name:", invoiceName);
    
    // Test MINTER_ROLE specifically
    console.log("\n=== Testing MINTER_ROLE ===");
    try {
      const minterRole = await invoiceNFT.MINTER_ROLE();
      console.log("✅ MINTER_ROLE:", minterRole);
      
      // Test VERIFIER_ROLE
      const verifierRole = await invoiceNFT.VERIFIER_ROLE();
      console.log("✅ VERIFIER_ROLE:", verifierRole);
      
      // Test if deployer has MINTER_ROLE
      const [deployer] = await ethers.getSigners();
      const hasMinterRole = await invoiceNFT.hasRole(minterRole, deployer.address);
      console.log("✅ Deployer has MINTER_ROLE:", hasMinterRole);
      
    } catch (error) {
      console.log("❌ Error getting MINTER_ROLE:", error.message);
    }
    
    // Test LendingPool functions
    console.log("\n=== Testing LendingPool Functions ===");
    try {
      const totalDeposits = await lendingPool.totalDeposits();
      console.log("✅ Total deposits:", ethers.formatUnits(totalDeposits, 6));
      
      // Test that general withdraw is removed
      console.log("Testing that general withdraw is removed...");
      try {
        await lendingPool.withdraw(ethers.parseUnits("1000", 6));
        console.log("❌ General withdraw still exists (should be removed)");
      } catch (error) {
        if (error.message.includes("withdraw is not a function")) {
          console.log("✅ General withdraw correctly removed");
        } else {
          console.log("❌ Unexpected error:", error.message);
        }
      }
      
      // Test tranche-specific functions exist
      console.log("Testing tranche-specific functions...");
      try {
        await lendingPool.withdrawJunior(ethers.parseUnits("1000", 6));
        console.log("❌ Should have failed with insufficient balance");
      } catch (error) {
        if (error.message.includes("Insufficient balance") || error.message.includes("Insufficient liquidity")) {
          console.log("✅ withdrawJunior function exists and working");
        } else {
          console.log("❌ Unexpected error:", error.message);
        }
      }
      
    } catch (error) {
      console.log("❌ Error testing LendingPool:", error.message);
    }
    
    console.log("\n=== All tests completed ===");
    
  } catch (error) {
    console.error("❌ Error during testing:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  }); 