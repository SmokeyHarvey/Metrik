import { expect } from "chai";
import { ethers } from "hardhat";

describe("Withdrawal Tests - Citrea", function () {
  let metrikToken: any;
  let usdc: any;
  let lendingPool: any;
  let owner: any;
  let lp: any;
  let lp2: any;

  before(async function () {
    console.log("Setting up withdrawal tests on Citrea...");

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

    // Setup balances for testing
    const juniorAmount = ethers.parseUnits("1000", 6);
    const seniorAmount = ethers.parseUnits("2000", 6);

    // Mint tokens to test accounts
    await usdc.mint(lp.address, juniorAmount);
    await usdc.mint(lp2.address, seniorAmount);
    console.log("Minted tokens to test accounts");
  });

  describe("Tranche-Specific Withdrawal Tests", function () {
    it("Should test Junior tranche deposit and withdrawal", async function () {
      try {
        const juniorAmount = ethers.parseUnits("1000", 6);
        
        console.log("Testing Junior tranche deposit and withdrawal...");
        
        // Check initial balance
        const initialBalance = await usdc.balanceOf(lp.address);
        console.log("Initial LP balance:", ethers.formatUnits(initialBalance, 6));
        
        // Approve and deposit to Junior tranche
        await usdc.connect(lp).approve(lendingPool.target, juniorAmount);
        await lendingPool.connect(lp).depositWithTranche(juniorAmount, 0, 0); // Junior
        
        console.log("✅ Junior deposit successful");
        
        // Check Junior deposit
        const juniorDeposits = await lendingPool.getTrancheDeposits(lp.address, 0);
        console.log("Junior deposits:", ethers.formatUnits(juniorDeposits, 6));
        expect(juniorDeposits).to.equal(juniorAmount);
        
        // Check available balance
        const juniorAvailable = await lendingPool.getTrancheAvailableBalance(lp.address, 0);
        console.log("Junior available:", ethers.formatUnits(juniorAvailable, 6));
        expect(juniorAvailable).to.equal(juniorAmount);
        
        // Test Junior withdrawal
        await lendingPool.connect(lp).withdrawJunior(juniorAmount);
        console.log("✅ Junior withdrawal successful");
        
        // Verify withdrawal
        const juniorDepositsAfter = await lendingPool.getTrancheDeposits(lp.address, 0);
        const juniorAvailableAfter = await lendingPool.getTrancheAvailableBalance(lp.address, 0);
        console.log("Junior deposits after withdrawal:", ethers.formatUnits(juniorDepositsAfter, 6));
        console.log("Junior available after withdrawal:", ethers.formatUnits(juniorAvailableAfter, 6));
        
        // Check final balance
        const finalBalance = await usdc.balanceOf(lp.address);
        console.log("Final LP balance:", ethers.formatUnits(finalBalance, 6));
        
        console.log("✅ Junior tranche test completed successfully!");
        
      } catch (e: any) {
        console.log("❌ Junior tranche test failed:", e.message);
        throw e;
      }
    });

    it("Should test Senior tranche deposit and lockup", async function () {
      try {
        const seniorAmount = ethers.parseUnits("2000", 6);
        const lockupDuration = 365 * 24 * 60 * 60; // 1 year
        
        console.log("Testing Senior tranche deposit and lockup...");
        
        // Check initial balance
        const initialBalance = await usdc.balanceOf(lp2.address);
        console.log("Initial LP2 balance:", ethers.formatUnits(initialBalance, 6));
        
        // Approve and deposit to Senior tranche
        await usdc.connect(lp2).approve(lendingPool.target, seniorAmount);
        await lendingPool.connect(lp2).depositWithTranche(seniorAmount, 1, lockupDuration); // Senior
        
        console.log("✅ Senior deposit successful");
        
        // Check Senior deposit
        const seniorDeposits = await lendingPool.getTrancheDeposits(lp2.address, 1);
        console.log("Senior deposits:", ethers.formatUnits(seniorDeposits, 6));
        expect(seniorDeposits).to.equal(seniorAmount);
        
        // Check locked balance
        const seniorLocked = await lendingPool.getSeniorLockedBalance(lp2.address);
        console.log("Senior locked:", ethers.formatUnits(seniorLocked, 6));
        expect(seniorLocked).to.equal(seniorAmount);
        
        // Check available balance (should be 0 due to lockup)
        const seniorAvailable = await lendingPool.getTrancheAvailableBalance(lp2.address, 1);
        console.log("Senior available:", ethers.formatUnits(seniorAvailable, 6));
        expect(seniorAvailable).to.equal(0);
        
        // Test that Senior withdrawal fails due to lockup
        await expect(
          lendingPool.connect(lp2).withdrawSenior(seniorAmount)
        ).to.be.revertedWith("Insufficient unlocked balance in Senior tranche");
        
        console.log("✅ Senior withdrawal correctly blocked due to lockup");
        
        console.log("✅ Senior tranche test completed successfully!");
        
      } catch (e: any) {
        console.log("❌ Senior tranche test failed:", e.message);
        throw e;
      }
    });

    it("Should test that general withdraw functions are removed", async function () {
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

    it("Should test interest withdrawal functions", async function () {
      try {
        const depositAmount = ethers.parseUnits("500", 6);
        
        console.log("Testing interest withdrawal functions...");
        
        // Create a deposit for interest testing
        await usdc.connect(lp).approve(lendingPool.target, depositAmount);
        await lendingPool.connect(lp).depositWithTranche(depositAmount, 0, 0); // Junior
        
        console.log("✅ Deposit created for interest test");
        
        // Check pending interest
        const pendingInterest = await lendingPool.getTranchePendingInterest(lp.address, 0);
        console.log("Pending Junior interest:", ethers.formatUnits(pendingInterest, 6));
        
        // Test interest withdrawal (might be 0 initially)
        if (pendingInterest > 0) {
          await lendingPool.connect(lp).withdrawJuniorInterest();
          console.log("✅ Junior interest withdrawn successfully");
        } else {
          console.log("ℹ️ No interest to withdraw yet (expected for new deposit)");
        }
        
        // Test that general withdrawInterest doesn't exist
        expect(() => {
          lendingPool.connect(lp).withdrawInterest();
        }).to.throw("withdrawInterest is not a function");
        
        console.log("✅ Interest withdrawal tests completed!");
        
      } catch (e: any) {
        console.log("❌ Interest withdrawal test failed:", e.message);
        throw e;
      }
    });
  });
}); 