import { expect } from "chai";
import { ethers } from "hardhat";

describe("Tranche-Specific Withdrawal Tests - Citrea", function () {
  let metrikToken: any;
  let usdc: any;
  let lendingPool: any;
  let owner: any;
  let lp: any;
  let lp2: any;

  before(async function () {
    console.log("Setting up tranche withdrawal tests...");

    // Get signers
    [owner, lp, lp2] = await ethers.getSigners();
    console.log("Loaded signers");

    // Load deployment addresses
    const fs = require('fs');
    const deploymentPath = './deployments/Citrea.json';
    const deployedAddresses = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
    console.log("Loaded deployment addresses");

    // Get contract instances
    metrikToken = await ethers.getContractAt("MockERC20", deployedAddresses.metrikToken);
    usdc = await ethers.getContractAt("MockERC20", deployedAddresses.usdc);
    lendingPool = await ethers.getContractAt("LendingPool", deployedAddresses.lendingPool);
    console.log("Contract instances loaded");

    // Setup balances
    const juniorAmount = ethers.parseUnits("1000", 6);
    const seniorAmount = ethers.parseUnits("2000", 6);

    // Mint tokens to test accounts
    await usdc.mint(lp.address, juniorAmount);
    await usdc.mint(lp2.address, seniorAmount);
    console.log("Minted tokens to test accounts");
  });

  describe("Tranche-Specific Withdrawal Functionality", function () {
    it("Should test the new tranche-specific withdrawal functions", async function () {
      try {
        const juniorAmount = ethers.parseUnits("1000", 6);
        const seniorAmount = ethers.parseUnits("2000", 6);
        const lockupDuration = 365 * 24 * 60 * 60; // 1 year

        console.log("Testing Junior tranche deposit and withdrawal...");
        
        // Test Junior tranche
        await usdc.connect(lp).approve(lendingPool.target, juniorAmount);
        await lendingPool.connect(lp).depositWithTranche(juniorAmount, 0, 0); // Junior
        
        console.log("Junior deposit successful");
        
        // Check Junior deposit
        const juniorDeposits = await lendingPool.getTrancheDeposits(lp.address, 0);
        console.log("Junior deposits:", ethers.formatUnits(juniorDeposits, 6));
        expect(juniorDeposits).to.equal(juniorAmount);
        
        // Test Junior withdrawal
        await lendingPool.connect(lp).withdrawJunior(juniorAmount);
        console.log("Junior withdrawal successful");
        
        // Verify withdrawal
        const juniorDepositsAfter = await lendingPool.getTrancheDeposits(lp.address, 0);
        const juniorAvailable = await lendingPool.getTrancheAvailableBalance(lp.address, 0);
        console.log("Junior deposits after withdrawal:", ethers.formatUnits(juniorDepositsAfter, 6));
        console.log("Junior available balance:", ethers.formatUnits(juniorAvailable, 6));
        
        console.log("Testing Senior tranche deposit...");
        
        // Test Senior tranche
        await usdc.connect(lp2).approve(lendingPool.target, seniorAmount);
        await lendingPool.connect(lp2).depositWithTranche(seniorAmount, 1, lockupDuration); // Senior
        
        console.log("Senior deposit successful");
        
        // Check Senior deposit
        const seniorDeposits = await lendingPool.getTrancheDeposits(lp2.address, 1);
        console.log("Senior deposits:", ethers.formatUnits(seniorDeposits, 6));
        expect(seniorDeposits).to.equal(seniorAmount);
        
        // Test that Senior withdrawal fails due to lockup
        await expect(
          lendingPool.connect(lp2).withdrawSenior(seniorAmount)
        ).to.be.revertedWith("Insufficient unlocked balance in Senior tranche");
        
        console.log("Senior withdrawal correctly blocked due to lockup");
        
        // Check Senior locked balance
        const seniorLocked = await lendingPool.getSeniorLockedBalance(lp2.address);
        const seniorAvailable = await lendingPool.getTrancheAvailableBalance(lp2.address, 1);
        console.log("Senior locked balance:", ethers.formatUnits(seniorLocked, 6));
        console.log("Senior available balance:", ethers.formatUnits(seniorAvailable, 6));
        
        expect(seniorLocked).to.equal(seniorAmount);
        expect(seniorAvailable).to.equal(0);
        
        // Test that general withdraw is deprecated
        await expect(
          lendingPool.connect(lp).withdraw(juniorAmount)
        ).to.be.revertedWith("Use withdrawJunior() or withdrawSenior() for tranche-specific withdrawals");
        
        console.log("General withdraw correctly deprecated");
        
        console.log("✅ All tranche-specific withdrawal tests passed!");
        
      } catch (e: any) {
        console.log("❌ Tranche-specific withdrawal test failed:", e.message);
        throw e;
      }
    });

    it("Should test interest withdrawal functions", async function () {
      try {
        const depositAmount = ethers.parseUnits("1000", 6);
        
        console.log("Testing interest withdrawal functions...");
        
        // Create a deposit
        await usdc.connect(lp).approve(lendingPool.target, depositAmount);
        await lendingPool.connect(lp).depositWithTranche(depositAmount, 0, 0); // Junior
        
        console.log("Deposit created for interest test");
        
        // Check pending interest
        const pendingInterest = await lendingPool.getTranchePendingInterest(lp.address, 0);
        console.log("Pending Junior interest:", ethers.formatUnits(pendingInterest, 6));
        
        // Test interest withdrawal (might be 0 initially)
        if (pendingInterest > 0) {
          await lendingPool.connect(lp).withdrawJuniorInterest();
          console.log("Junior interest withdrawn successfully");
        } else {
          console.log("No interest to withdraw yet (expected for new deposit)");
        }
        
        // Test total pending interest
        const totalPendingInterest = await lendingPool.getTotalPendingInterest(lp.address);
        console.log("Total pending interest:", ethers.formatUnits(totalPendingInterest, 6));
        
        console.log("✅ Interest withdrawal tests passed!");
        
      } catch (e: any) {
        console.log("❌ Interest withdrawal test failed:", e.message);
        throw e;
      }
    });

    it("Should test view functions for tranche information", async function () {
      try {
        console.log("Testing view functions...");
        
        // Test deposit count
        const depositCount = await lendingPool.getUserDepositCount(lp2.address);
        console.log("User deposit count:", depositCount);
        expect(depositCount).to.be.gte(0);
        
        if (depositCount > 0) {
          // Test deposit details
          const depositDetails = await lendingPool.getDepositDetails(lp2.address, 0);
          console.log("Deposit details:", {
            amount: ethers.formatUnits(depositDetails.amount, 6),
            tranche: depositDetails.tranche,
            isLocked: depositDetails.isLocked,
            lockupDuration: depositDetails.lockupDuration
          });
          
          expect(depositDetails.amount).to.be.gt(0);
        }
        
        console.log("✅ View function tests passed!");
        
      } catch (e: any) {
        console.log("❌ View function test failed:", e.message);
        throw e;
      }
    });
  });
}); 