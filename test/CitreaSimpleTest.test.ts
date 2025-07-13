import { expect } from "chai";
import { ethers } from "hardhat";

describe("Simple Tranche Tests - Citrea", function () {
  let lendingPool: any;
  let owner: any;

  before(async function () {
    console.log("Setting up simple tranche tests...");

    // Get signers
    [owner] = await ethers.getSigners();
    console.log("Loaded signers");

    // Load deployment addresses
    const fs = require('fs');
    const deploymentPath = './deployments/Citrea.json';
    const deployedAddresses = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
    console.log("Loaded deployment addresses");

    // Get contract instances
    lendingPool = await ethers.getContractAt("LendingPool", deployedAddresses.lendingPool);
    console.log("Contract instances loaded");
  });

  describe("Tranche-Specific Withdrawal Functions", function () {
    it("Should verify that general withdraw function is removed", async function () {
      try {
        console.log("Testing that general withdraw function is removed...");
        
        // Test that general withdraw function doesn't exist
        expect(() => {
          lendingPool.connect(owner).withdraw(ethers.parseUnits("1000", 6));
        }).to.throw("withdraw is not a function");
        
        console.log("✅ General withdraw function correctly removed");
        
      } catch (e: any) {
        console.log("❌ General withdraw test failed:", e.message);
        throw e;
      }
    });

    it("Should test view functions for tranche information", async function () {
      try {
        console.log("Testing view functions...");
        
        // Test deposit count
        const depositCount = await lendingPool.getUserDepositCount(owner.address);
        console.log("User deposit count:", depositCount);
        expect(depositCount).to.be.gte(0);
        
        // Test tranche deposits (should be 0 for new user)
        const juniorDeposits = await lendingPool.getTrancheDeposits(owner.address, 0);
        const seniorDeposits = await lendingPool.getTrancheDeposits(owner.address, 1);
        console.log("Junior deposits:", ethers.formatUnits(juniorDeposits, 6));
        console.log("Senior deposits:", ethers.formatUnits(seniorDeposits, 6));
        
        // Test available balances
        const juniorAvailable = await lendingPool.getTrancheAvailableBalance(owner.address, 0);
        const seniorAvailable = await lendingPool.getTrancheAvailableBalance(owner.address, 1);
        console.log("Junior available:", ethers.formatUnits(juniorAvailable, 6));
        console.log("Senior available:", ethers.formatUnits(seniorAvailable, 6));
        
        // Test locked balance
        const seniorLocked = await lendingPool.getSeniorLockedBalance(owner.address);
        console.log("Senior locked:", ethers.formatUnits(seniorLocked, 6));
        
        // Test pending interest
        const juniorInterest = await lendingPool.getTranchePendingInterest(owner.address, 0);
        const seniorInterest = await lendingPool.getTranchePendingInterest(owner.address, 1);
        console.log("Junior interest:", ethers.formatUnits(juniorInterest, 6));
        console.log("Senior interest:", ethers.formatUnits(seniorInterest, 6));
        
        console.log("✅ View function tests passed!");
        
      } catch (e: any) {
        console.log("❌ View function test failed:", e.message);
        throw e;
      }
    });

    it("Should test that withdrawal functions exist and are callable", async function () {
      try {
        console.log("Testing withdrawal function existence...");
        
        // Test that the functions exist and can be called (they should revert with proper errors)
        await expect(
          lendingPool.connect(owner).withdrawJunior(ethers.parseUnits("1000", 6))
        ).to.be.reverted; // Should revert with insufficient balance or other error
        
        await expect(
          lendingPool.connect(owner).withdrawSenior(ethers.parseUnits("1000", 6))
        ).to.be.reverted; // Should revert with insufficient balance or other error
        
        console.log("✅ Withdrawal functions exist and are callable");
        
      } catch (e: any) {
        console.log("❌ Withdrawal function test failed:", e.message);
        throw e;
      }
    });

    it("Should test that interest withdrawal functions exist", async function () {
      try {
        console.log("Testing interest withdrawal function existence...");
        
        // Test that the functions exist and can be called
        await expect(
          lendingPool.connect(owner).withdrawJuniorInterest()
        ).to.be.reverted; // Should revert with "No Junior interest to withdraw"
        
        await expect(
          lendingPool.connect(owner).withdrawSeniorInterest()
        ).to.be.reverted; // Should revert with "No Senior interest to withdraw"
        
        // Test that general withdrawInterest function is removed
        expect(() => {
          lendingPool.connect(owner).withdrawInterest();
        }).to.throw("withdrawInterest is not a function");
        
        console.log("✅ Interest withdrawal functions exist and are callable");
        console.log("✅ General withdrawInterest function correctly removed");
        
      } catch (e: any) {
        console.log("❌ Interest withdrawal function test failed:", e.message);
        throw e;
      }
    });
  });
}); 