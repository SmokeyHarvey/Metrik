import { expect } from "chai";
import { ethers } from "hardhat";

describe("Simple Withdrawal Tests - Citrea", function () {
  let lendingPool: any;
  let owner: any;

  before(async function () {
    console.log("Setting up simple withdrawal tests on Citrea...");

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

  describe("Withdrawal Function Tests", function () {
    it("Should verify that general withdraw functions are removed", async function () {
      try {
        console.log("Testing that general withdraw functions are removed...");
        
        // Test that general withdraw function doesn't exist
        expect(() => {
          lendingPool.connect(owner).withdraw(ethers.parseUnits("1000", 6));
        }).to.throw("withdraw is not a function");
        
        // Test that general withdrawInterest function doesn't exist
        expect(() => {
          lendingPool.connect(owner).withdrawInterest();
        }).to.throw("withdrawInterest is not a function");
        
        console.log("✅ General withdraw functions correctly removed");
        
      } catch (e: any) {
        console.log("❌ General withdraw test failed:", e.message);
        throw e;
      }
    });

    it("Should test that tranche-specific withdrawal functions exist", async function () {
      try {
        console.log("Testing tranche-specific withdrawal functions...");
        
        // Test that withdrawJunior function exists and can be called
        await expect(
          lendingPool.connect(owner).withdrawJunior(ethers.parseUnits("1000", 6))
        ).to.be.reverted; // Should revert with insufficient balance or other error
        
        // Test that withdrawSenior function exists and can be called
        await expect(
          lendingPool.connect(owner).withdrawSenior(ethers.parseUnits("1000", 6))
        ).to.be.reverted; // Should revert with insufficient balance or other error
        
        console.log("✅ Tranche-specific withdrawal functions exist and are callable");
        
      } catch (e: any) {
        console.log("❌ Tranche-specific withdrawal test failed:", e.message);
        throw e;
      }
    });

    it("Should test that interest withdrawal functions exist", async function () {
      try {
        console.log("Testing interest withdrawal functions...");
        
        // Test that withdrawJuniorInterest function exists and can be called
        await expect(
          lendingPool.connect(owner).withdrawJuniorInterest()
        ).to.be.reverted; // Should revert with "No Junior interest to withdraw"
        
        // Test that withdrawSeniorInterest function exists and can be called
        await expect(
          lendingPool.connect(owner).withdrawSeniorInterest()
        ).to.be.reverted; // Should revert with "No Senior interest to withdraw"
        
        console.log("✅ Interest withdrawal functions exist and are callable");
        
      } catch (e: any) {
        console.log("❌ Interest withdrawal test failed:", e.message);
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

    it("Should test deposit details function", async function () {
      try {
        console.log("Testing deposit details function...");
        
        // Test deposit count
        const depositCount = await lendingPool.getUserDepositCount(owner.address);
        console.log("User deposit count:", depositCount);
        
        if (depositCount > 0) {
          // Test deposit details
          const depositDetails = await lendingPool.getDepositDetails(owner.address, 0);
          console.log("Deposit details:", {
            amount: ethers.formatUnits(depositDetails.amount, 6),
            tranche: depositDetails.tranche,
            isLocked: depositDetails.isLocked,
            lockupDuration: depositDetails.lockupDuration
          });
          
          expect(depositDetails.amount).to.be.gt(0);
        } else {
          console.log("ℹ️ No deposits found (expected for new user)");
        }
        
        console.log("✅ Deposit details function test passed!");
        
      } catch (e: any) {
        console.log("❌ Deposit details test failed:", e.message);
        throw e;
      }
    });
  });
}); 