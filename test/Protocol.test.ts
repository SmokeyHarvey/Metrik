import { expect } from "chai";
import { ethers } from "hardhat";
import { time } from "@nomicfoundation/hardhat-network-helpers";
import * as fs from "fs";
import * as path from "path";

describe("DeFi Credit Protocol", function () {
  this.timeout(300000); // 5 minutes for all tests in this suite
  
  // Test accounts
  let owner: any;
  let supplier: any;
  let lp: any;
  let buyer: any;

  // Contract instances
  let metrikToken: any;
  let usdc: any;
  let invoiceNFT: any;
  let staking: any;
  let lendingPool: any;

  // Test constants
  const STAKE_AMOUNT = ethers.parseEther("10000"); // 10,000 METRIK
  const STAKE_DURATION = 180 * 24 * 60 * 60; // 180 days
  const LP_DEPOSIT = ethers.parseUnits("100000", 6); // 100,000 USDC
  const INVOICE_AMOUNT = ethers.parseUnits("50000", 6); // 50,000 USDC
  const BORROW_AMOUNT = ethers.parseUnits("30000", 6); // 30,000 USDC (60% of invoice)

  // Load deployed contracts
  before(async function() {
    console.log("Starting test setup...");
    [owner, supplier, lp, buyer] = await ethers.getSigners();
    console.log("Loaded signers");

    // Load deployed contract addresses
    const network = process.env.HARDHAT_NETWORK || "fuji";
    const deploymentPath = path.join(__dirname, "..", "deployments", `${network}.json`);
    const deployedAddresses = JSON.parse(fs.readFileSync(deploymentPath, "utf8"));
    console.log("Loaded deployment addresses");

    // Get contract instances
    console.log("Loading contract instances...");
    metrikToken = await ethers.getContractAt("MockERC20", deployedAddresses.metrikToken);
    usdc = await ethers.getContractAt("MockERC20", deployedAddresses.usdc);
    invoiceNFT = await ethers.getContractAt("InvoiceNFT", deployedAddresses.invoiceNFT);
    staking = await ethers.getContractAt("Staking", deployedAddresses.staking);
    lendingPool = await ethers.getContractAt("LendingPool", deployedAddresses.lendingPool);
    console.log("Contract instances loaded");

    // Grant necessary roles
    console.log("Setting up roles...");
    const MINTER_ROLE = await invoiceNFT.MINTER_ROLE();
    const VERIFIER_ROLE = await invoiceNFT.VERIFIER_ROLE();

    // Grant MINTER_ROLE to supplier if not already granted
    if (!await invoiceNFT.hasRole(MINTER_ROLE, supplier.address)) {
      console.log("Granting MINTER_ROLE to supplier...");
      const grantMinterTx = await invoiceNFT.grantRole(MINTER_ROLE, supplier.address);
      await grantMinterTx.wait();
      console.log("Granted MINTER_ROLE to supplier");
    } else {
      console.log("Supplier already has MINTER_ROLE");
    }

    // Grant VERIFIER_ROLE to owner if not already granted
    if (!await invoiceNFT.hasRole(VERIFIER_ROLE, owner.address)) {
      console.log("Granting VERIFIER_ROLE to owner...");
      const grantVerifierTx = await invoiceNFT.grantRole(VERIFIER_ROLE, owner.address);
      await grantVerifierTx.wait();
      console.log("Granted VERIFIER_ROLE to owner");
    } else {
      console.log("Owner already has VERIFIER_ROLE");
    }

    // Setup initial balances if needed
    console.log("Checking initial balances...");
    const supplierMetrikBalance = await metrikToken.balanceOf(supplier.address);
    const lpUSDCBalance = await usdc.balanceOf(lp.address);
    const supplierUSDCBalance = await usdc.balanceOf(supplier.address);

    if (supplierMetrikBalance < STAKE_AMOUNT) {
      console.log("Minting METRIK to supplier...");
      const mintMetrikTx = await metrikToken.mint(supplier.address, STAKE_AMOUNT);
      await mintMetrikTx.wait();
      console.log("Minted METRIK to supplier");
    }

    if (lpUSDCBalance < LP_DEPOSIT) {
      console.log("Minting USDC to LP...");
      const mintUsdcLpTx = await usdc.mint(lp.address, LP_DEPOSIT);
      await mintUsdcLpTx.wait();
      console.log("Minted USDC to LP");
    }

    if (supplierUSDCBalance < LP_DEPOSIT) {
      console.log("Minting USDC to supplier...");
      const mintUsdcSupplierTx = await usdc.mint(supplier.address, LP_DEPOSIT);
      await mintUsdcSupplierTx.wait();
      console.log("Minted USDC to supplier");
    }

    console.log("Test setup completed");
  });

  // Reset state between tests
  beforeEach(async function() {
    // No need to reset LP deposit as we want to keep it for borrowing
  });

  describe("Setup and Initial State", function () {
    it("Should load all contracts correctly", async function () {
      expect(await metrikToken.name()).to.equal("METRIK Token");
      expect(await usdc.name()).to.equal("USD Coin");
      expect(await invoiceNFT.name()).to.equal("InvoiceNFT");
    });

    it("Should have correct initial balances", async function () {
      const supplierMetrikBalance = await metrikToken.balanceOf(supplier.address);
      const lpUSDCBalance = await usdc.balanceOf(lp.address);
      
      // Check that balances are at least the required amounts
      expect(supplierMetrikBalance).to.be.gte(STAKE_AMOUNT);
      expect(lpUSDCBalance).to.be.gte(LP_DEPOSIT);
      
      console.log("Current balances:");
      console.log("Supplier METRIK:", ethers.formatEther(supplierMetrikBalance));
      console.log("LP USDC:", ethers.formatUnits(lpUSDCBalance, 6));
    });
  });

  describe("Staking Flow", function () {
    it("Should allow supplier to stake METRIK tokens", async function () {
      console.log("\nApproving METRIK tokens for staking...");
      const approveTx = await metrikToken.connect(supplier).approve(await staking.getAddress(), STAKE_AMOUNT);
      await approveTx.wait();
      console.log("Approved", ethers.formatEther(STAKE_AMOUNT), "METRIK tokens for staking");

      console.log("Staking METRIK tokens...");
      const stakeTx = await staking.connect(supplier).stake(STAKE_AMOUNT, STAKE_DURATION);
      await stakeTx.wait();
      console.log("Staked", ethers.formatEther(STAKE_AMOUNT), "METRIK tokens for", STAKE_DURATION, "seconds");

      const stakeInfo = await staking.getStakeInfo(supplier.address);
      expect(stakeInfo.amount).to.equal(STAKE_AMOUNT);
      expect(stakeInfo.duration).to.equal(STAKE_DURATION);
    });

    it("Should calculate correct tier based on staked amount", async function () {
      const tier = await staking.getTier(supplier.address);
      console.log("\nSupplier tier:", tier);
      expect(tier).to.be.gt(0);
    });
  });

  describe("Lending Pool Flow", function () {
    let tokenId: bigint;

    it("Should allow LP to deposit USDC", async function () {
      console.log("\nApproving USDC for LP deposit...");
      const approveTx = await usdc.connect(lp).approve(await lendingPool.getAddress(), LP_DEPOSIT);
      await approveTx.wait();
      console.log("Approved", ethers.formatUnits(LP_DEPOSIT, 6), "USDC for LP deposit");

      // Check LP's USDC balance before deposit
      const lpBalanceBefore = await usdc.balanceOf(lp.address);
      console.log("LP USDC balance before deposit:", ethers.formatUnits(lpBalanceBefore, 6));

      console.log("Depositing USDC to lending pool...");
      const depositTx = await lendingPool.connect(lp).deposit(LP_DEPOSIT);
      await depositTx.wait();
      console.log("Deposited", ethers.formatUnits(LP_DEPOSIT, 6), "USDC to lending pool");

      // Check LP's USDC balance after deposit
      const lpBalanceAfter = await usdc.balanceOf(lp.address);
      console.log("LP USDC balance after deposit:", ethers.formatUnits(lpBalanceAfter, 6));

      // Check lending pool's USDC balance
      const lendingPoolBalance = await usdc.balanceOf(await lendingPool.getAddress());
      console.log("Lending pool USDC balance:", ethers.formatUnits(lendingPoolBalance, 6));

      const lpInfo = await lendingPool.lpInfo(lp.address);
      console.log("LP info after deposit:", {
        depositAmount: ethers.formatUnits(lpInfo.depositAmount, 6),
        interestAccrued: ethers.formatUnits(lpInfo.interestAccrued, 6),
        lastInterestUpdate: new Date(Number(lpInfo.lastInterestUpdate) * 1000).toISOString()
      });

      expect(lpInfo.depositAmount).to.equal(LP_DEPOSIT);
    });

    it("Should handle invoice borrowing and repayment flow", async function () {
      // Create invoice
      console.log("\nCreating invoice...");
      const dueDate = Math.floor(Date.now() / 1000) + 30 * 24 * 60 * 60;
      const mintTx = await invoiceNFT.connect(supplier).mintInvoiceNFT(
        supplier.address,
        `INV-${Date.now()}-1`,
        INVOICE_AMOUNT,
        dueDate,
        "ipfs://test"
      );
      const mintReceipt = await mintTx.wait();
      tokenId = mintReceipt.logs[0].args.tokenId;
      console.log("Created invoice with token ID:", tokenId);

      // Verify the invoice
      console.log("\nVerifying invoice...");
      const verifyTx = await invoiceNFT.connect(owner).verifyInvoice(tokenId);
      await verifyTx.wait();
      console.log("Invoice verified");

      // Check invoice details
      const invoiceDetails = await invoiceNFT.getInvoiceDetails(tokenId);
      console.log("Invoice details:", {
        supplier: invoiceDetails.supplier,
        creditAmount: ethers.formatUnits(invoiceDetails.creditAmount, 6),
        dueDate: new Date(Number(invoiceDetails.dueDate) * 1000).toISOString(),
        isVerified: invoiceDetails.isVerified
      });

      // Approve and borrow against invoice
      console.log("\nApproving invoice for lending pool...");
      const invoiceApproveTx = await invoiceNFT.connect(supplier).approve(await lendingPool.getAddress(), tokenId);
      await invoiceApproveTx.wait();
      
      // Verify approval
      const approvedAddress = await invoiceNFT.getApproved(tokenId);
      console.log("Approved address:", approvedAddress);
      console.log("Lending pool address:", await lendingPool.getAddress());
      console.log("Approval successful:", approvedAddress === await lendingPool.getAddress());
      
      console.log("\nBorrowing against invoice...");
      
      // Check max borrow amount
      const maxBorrowAmount = await lendingPool.getMaxBorrowAmount(tokenId);
      console.log("Max borrow amount:", ethers.formatUnits(maxBorrowAmount, 6), "USDC");
      console.log("Attempting to borrow:", ethers.formatUnits(BORROW_AMOUNT, 6), "USDC");
      
      // Check if supplier has active loans
      const activeLoans = await lendingPool.getUserActiveLoans(supplier.address);
      console.log("Supplier active loans:", activeLoans.length);
      
      // Log addresses for debugging
      console.log("\nAddresses:");
      console.log("Supplier address:", supplier.address);
      console.log("Lending pool address:", await lendingPool.getAddress());
      console.log("Invoice NFT address:", await invoiceNFT.getAddress());
      
      // Check invoice ownership
      const invoiceOwner = await invoiceNFT.ownerOf(tokenId);
      console.log("Invoice owner:", invoiceOwner);
      console.log("Is supplier the owner?", invoiceOwner === supplier.address);
      
      // Check invoice approval
      const isApproved = await invoiceNFT.getApproved(tokenId);
      console.log("Invoice approved for:", isApproved);
      console.log("Is lending pool approved?", isApproved === await lendingPool.getAddress());

      // Check lending pool balance
      const lpBalance = await usdc.balanceOf(await lendingPool.getAddress());
      console.log("Lending pool USDC balance:", ethers.formatUnits(lpBalance, 6));
      
      try {
        const borrowTx = await lendingPool.connect(supplier).depositInvoiceAndBorrow(
          tokenId,
          BORROW_AMOUNT
        );
        await borrowTx.wait();
        console.log("Borrowed against invoice");
      } catch (error: any) {
        console.log("Borrow failed with error:", error.message);
        throw error;
      }

      // Check loan details
      const loan = await lendingPool.loans(tokenId);
      console.log("Loan details after creation:", {
        invoiceId: loan.invoiceId.toString(),
        amount: ethers.formatUnits(loan.amount, 6),
        borrowAmount: ethers.formatUnits(loan.borrowAmount, 6),
        dueDate: new Date(Number(loan.dueDate) * 1000).toISOString(),
        isRepaid: loan.isRepaid,
        isLiquidated: loan.isLiquidated,
        supplier: loan.supplier
      });
      expect(loan.amount).to.equal(BORROW_AMOUNT);
      expect(loan.borrowAmount).to.equal(BORROW_AMOUNT);
      expect(loan.isRepaid).to.be.false;

      // Calculate repayment amount (principal + interest)
      const loanDetails = await lendingPool.getUserLoanDetails(supplier.address, tokenId);
      const repayAmount = loanDetails.amount + loanDetails.interestAccrued;
      console.log("Repayment calculation:", {
        principal: ethers.formatUnits(loanDetails.amount, 6),
        interest: ethers.formatUnits(loanDetails.interestAccrued, 6),
        totalAmount: ethers.formatUnits(repayAmount, 6)
      });

      // Check supplier's USDC balance
      const supplierBalance = await usdc.balanceOf(supplier.address);
      console.log("Supplier USDC balance:", ethers.formatUnits(supplierBalance, 6));

      // Approve USDC for repayment with a small buffer for rounding
      const repayAmountWithBuffer = repayAmount + ethers.parseUnits("1", 6); // Add 1 USDC buffer
      console.log("Approving USDC for repayment...");
      const approveTx = await usdc.connect(supplier).approve(await lendingPool.getAddress(), repayAmountWithBuffer);
      await approveTx.wait();
      console.log("Approved", ethers.formatUnits(repayAmountWithBuffer, 6), "USDC for repayment");

      // Check approval
      const allowance = await usdc.allowance(supplier.address, await lendingPool.getAddress());
      console.log("USDC allowance:", ethers.formatUnits(allowance, 6));

      // Get LP interest before repayment
      const lpInterestBefore = await lendingPool.getLPInterest(lp.address);
      console.log("LP interest before repayment:", ethers.formatUnits(lpInterestBefore, 6));

      // Repay loan
      console.log("Repaying loan...");
      try {
        const repayTx = await lendingPool.connect(supplier).repay(tokenId);
        const repayReceipt = await repayTx.wait();
        console.log("Loan repaid successfully");
        
        // Log events from repayment
        const repayEvent = repayReceipt.logs.find(
          (log: any) => log.fragment && log.fragment.name === "LoanRepaid"
        );
        if (repayEvent) {
          console.log("Repayment event:", {
            invoiceId: repayEvent.args.invoiceId.toString(),
            supplier: repayEvent.args.supplier,
            amount: ethers.formatUnits(repayEvent.args.amount, 6)
          });
        }
      } catch (error: any) {
        console.log("Repay failed with error:", error.message);
        // Log more details about the error
        if (error.data) {
          console.log("Error data:", error.data);
        }
        throw error;
      }

      // Check LP interest after repayment
      const lpInterestAfter = await lendingPool.getLPInterest(lp.address);
      console.log("LP interest after repayment:", ethers.formatUnits(lpInterestAfter, 6));
      expect(lpInterestAfter).to.be.gt(lpInterestBefore);

      const updatedLoan = await lendingPool.loans(tokenId);
      expect(updatedLoan.isRepaid).to.be.true;

      // Verify final balances
      const finalSupplierBalance = await usdc.balanceOf(supplier.address);
      const finalLendingPoolBalance = await usdc.balanceOf(await lendingPool.getAddress());
      console.log("Final balances:", {
        supplierBalance: ethers.formatUnits(finalSupplierBalance, 6),
        lendingPoolBalance: ethers.formatUnits(finalLendingPoolBalance, 6)
      });
    });

    it("Should calculate LP interest correctly", async function () {
        // Get initial LP interest
        const initialInterest = await lendingPool.getLPInterest(lp.address);
        console.log("Initial LP interest:", ethers.formatUnits(initialInterest, 6));

        // Get LP info
        const lpInfo = await lendingPool.lpInfo(lp.address);
        console.log("LP info:", {
            depositAmount: ethers.formatUnits(lpInfo.depositAmount, 6),
            interestAccrued: ethers.formatUnits(lpInfo.interestAccrued, 6),
            lastInterestUpdate: new Date(Number(lpInfo.lastInterestUpdate) * 1000).toISOString()
        });

        // Calculate time elapsed since deposit
        const timeElapsed = Math.floor(Date.now() / 1000) - Number(lpInfo.lastInterestUpdate);
        console.log("Time elapsed since deposit (seconds):", timeElapsed);

        // Get current interest from contract
        const currentInterest = await lendingPool.getLPInterest(lp.address);
        console.log("Current LP interest:", ethers.formatUnits(currentInterest, 6));

        // Verify interest is greater than 0
        expect(currentInterest).to.be.gt(0);
        
        // Verify interest is proportional to deposit amount
        expect(currentInterest).to.be.lt(lpInfo.depositAmount);
    });
  });

  describe("Edge Cases and Error Conditions", function () {
    it("Should not allow unstaking before duration ends", async function () {
      console.log("\nAttempting to unstake before duration ends...");
      await expect(
        staking.connect(supplier).unstake()
      ).to.be.revertedWithCustomError(staking, "StakingPeriodNotEnded");
      console.log("Successfully prevented early unstaking");
    });
  });
}); 