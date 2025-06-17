// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./InvoiceNFT.sol";
import "./Staking.sol";

/**
 * @title LendingPool
 * @dev Handles lending and borrowing against invoice NFTs
 */
contract LendingPool is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Custom Errors
    error NoStakedTokensFound();
    error InsufficientBalance();
    error InsufficientLiquidity();
    error InvalidAmount();
    error InvalidBorrowAmount();
    error InvoiceExpired();
    error LoanAlreadyExists();
    error InvoiceNotVerified();
    error NotInvoiceSupplier();
    error LoanAlreadySettled();
    error LoanNotOverdue();
    error NotLoanOwner();

    // Constants
    uint256 public constant BORROW_CAP_PERCENTAGE = 60; // 60% of invoice amount
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant BORROWER_INTEREST_RATE = 1000; // 10% APR
    uint256 public constant LP_INTEREST_RATE = 800; // 8% APR
    uint256 public constant PLATFORM_FEE = 200; // 2% APR

    // State variables
    IERC20 public immutable metrikToken;
    IERC20 public immutable stablecoin;
    InvoiceNFT public immutable invoiceNFT;
    Staking public immutable staking;
    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public platformFees;
    uint256 public lastInterestUpdate;

    struct Loan {
        uint256 invoiceId;
        uint256 amount;
        uint256 dueDate;
        bool isRepaid;
        bool isLiquidated;
        uint256 interestAccrued;
        uint256 lastInterestUpdate;
        address supplier;
        uint256 borrowAmount;
        uint256 borrowTime;
    }

    struct LPInfo {
        uint256 depositAmount;
        uint256 interestAccrued;
        uint256 lastInterestUpdate;
    }

    // Mappings
    mapping(address => LPInfo) public lpInfo;
    mapping(uint256 => Loan) public loans;
    mapping(address => uint256[]) public userLoans;
    mapping(string => bool) public blacklistedSuppliers;
    mapping(address => mapping(uint256 => bool)) public userActiveLoans; // user => tokenId => isActive
    mapping(address => uint256) public userTotalBorrowed;

    // Events
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event InterestWithdraw(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 invoiceId, uint256 amount);
    event Repay(address indexed user, uint256 invoiceId, uint256 amount);
    event Liquidate(uint256 indexed invoiceId, address indexed liquidator, uint256 amount);
    event SupplierBlacklisted(string supplierId);
    event InvoiceBurned(uint256 indexed invoiceId);
    event LoanCreated(uint256 indexed invoiceId, address indexed supplier, uint256 amount);
    event LoanRepaid(uint256 indexed invoiceId, address indexed supplier, uint256 amount);
    event LoanLiquidated(uint256 indexed invoiceId, address indexed supplier, uint256 amount);
    event DebugLog(string message, address indexed supplier);

    constructor(
        address _metrikToken,
        address _stablecoin,
        address _invoiceNFT,
        address _staking
    ) Ownable(msg.sender) {
        metrikToken = IERC20(_metrikToken);
        stablecoin = IERC20(_stablecoin);
        invoiceNFT = InvoiceNFT(_invoiceNFT);
        staking = Staking(_staking);
        lastInterestUpdate = block.timestamp;
    }

    /**
     * @dev Deposit invoice and borrow against it
     * @param tokenId Unique identifier for the invoice NFT
     * @param borrowAmount Amount to borrow (max 60% of invoice amount)
     */
    function depositInvoiceAndBorrow(
        uint256 tokenId,
        uint256 borrowAmount
    ) external nonReentrant {
        if (borrowAmount == 0) revert InvalidAmount();
        if (borrowAmount > getMaxBorrowAmount(tokenId)) revert InvalidBorrowAmount();

        // Check if supplier has staked tokens first
        (uint256 stakedAmount,,,,) = staking.getStakeInfo(msg.sender);
        if (stakedAmount == 0) revert NoStakedTokensFound();

        // Get invoice details
        InvoiceNFT.InvoiceDetails memory invoice = invoiceNFT.getInvoiceDetails(tokenId);
        if (invoice.supplier != msg.sender) revert NotInvoiceSupplier();
        if (invoice.dueDate <= block.timestamp) revert InvoiceExpired();
        if (userActiveLoans[msg.sender][tokenId]) revert LoanAlreadyExists();
        if (!invoice.isVerified) revert InvoiceNotVerified();

        // Transfer invoice NFT to lending pool
        invoiceNFT.transferFrom(msg.sender, address(this), tokenId);

        // Create loan
        loans[tokenId] = Loan({
            invoiceId: tokenId,
            amount: borrowAmount,
            dueDate: invoice.dueDate,
            isRepaid: false,
            isLiquidated: false,
            interestAccrued: 0,
            lastInterestUpdate: block.timestamp,
            supplier: msg.sender,
            borrowAmount: borrowAmount,
            borrowTime: block.timestamp
        });

        // Update user loan tracking
        userLoans[msg.sender].push(tokenId);
        userActiveLoans[msg.sender][tokenId] = true;
        userTotalBorrowed[msg.sender] += borrowAmount;
        totalBorrowed += borrowAmount;

        // Transfer borrowed amount to supplier
        stablecoin.safeTransfer(msg.sender, borrowAmount);

        emit LoanCreated(tokenId, msg.sender, borrowAmount);
    }

    /**
     * @dev Deposit stablecoins as LP
     * @param amount Amount of stablecoins to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        // Update existing interest if there's a previous deposit
        if (lpInfo[msg.sender].depositAmount > 0) {
            _updateLPInterest(msg.sender);
        }
        
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        lpInfo[msg.sender].depositAmount += amount;
        lpInfo[msg.sender].lastInterestUpdate = block.timestamp; // Initialize to current time
        totalDeposits += amount;

        emit Deposit(msg.sender, amount);
    }

    /**
     * @dev Withdraw LP deposit
     * @param amount Amount to withdraw
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (lpInfo[msg.sender].depositAmount < amount) revert InsufficientBalance();
        
        // Update interest before checking liquidity
        _updateLPInterest(msg.sender);
        
        // Check if there's enough liquidity after updating interest
        uint256 availableLiquidity = totalDeposits - totalBorrowed;
        if (availableLiquidity < amount) revert InsufficientLiquidity();
        
        // Update state before transfer
        lpInfo[msg.sender].depositAmount -= amount;
        totalDeposits -= amount;
        
        // Transfer after state updates
        stablecoin.safeTransfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    /**
     * @dev Withdraw accumulated interest
     */
    function withdrawInterest() external nonReentrant {
        _updateLPInterest(msg.sender);
        uint256 interest = lpInfo[msg.sender].interestAccrued;
        require(interest > 0, "No interest to withdraw");
        
        lpInfo[msg.sender].interestAccrued = 0;
        stablecoin.safeTransfer(msg.sender, interest);

        emit InterestWithdraw(msg.sender, interest);
    }

    /**
     * @dev Repay a loan
     * @param invoiceId ID of the invoice NFT
     */
    function repay(uint256 invoiceId) external nonReentrant {
        Loan storage loan = loans[invoiceId];
        require(!loan.isRepaid && !loan.isLiquidated, "Loan already settled");
        require(block.timestamp <= loan.dueDate, "Loan overdue");
        require(loan.supplier == msg.sender, "Not loan owner");

        // Update interest accrued
        uint256 interest = calculateInterest(loan.amount, loan.lastInterestUpdate, BORROWER_INTEREST_RATE);
        loan.interestAccrued += interest;
        loan.lastInterestUpdate = block.timestamp;

        uint256 totalAmount = loan.amount + loan.interestAccrued;

        stablecoin.safeTransferFrom(msg.sender, address(this), totalAmount);
        
        // Update platform fees
        uint256 platformFee = (loan.interestAccrued * PLATFORM_FEE) / BORROWER_INTEREST_RATE;
        platformFees += platformFee;
        
        // Update loan status
        loan.isRepaid = true;
        userActiveLoans[msg.sender][invoiceId] = false;
        userTotalBorrowed[msg.sender] -= loan.amount;
        totalBorrowed -= loan.amount;

        // Burn the invoice NFT
        invoiceNFT.burn(invoiceId);

        emit LoanRepaid(invoiceId, msg.sender, totalAmount);
        emit InvoiceBurned(invoiceId);
    }

    /**
     * @dev Liquidate an overdue loan
     * @param invoiceId ID of the invoice NFT
     * @param supplierId Supplier's unique identifier
     */
    function liquidate(uint256 invoiceId, string calldata supplierId) external nonReentrant {
        Loan storage loan = loans[invoiceId];
        require(!loan.isRepaid && !loan.isLiquidated, "Loan already settled");
        require(block.timestamp > loan.dueDate, "Loan not overdue");

        // Update interest accrued
        uint256 interest = calculateInterest(loan.amount, loan.lastInterestUpdate, BORROWER_INTEREST_RATE);
        loan.interestAccrued += interest;
        loan.lastInterestUpdate = block.timestamp;

        uint256 totalAmount = loan.amount + interest;

        // Update platform fees
        uint256 platformFee = (loan.interestAccrued * PLATFORM_FEE) / BORROWER_INTEREST_RATE;
        platformFees += platformFee;
        
        // Update loan status
        loan.isLiquidated = true;
        userActiveLoans[loan.supplier][invoiceId] = false;
        userTotalBorrowed[loan.supplier] -= loan.amount;
        totalBorrowed -= loan.amount;

        // Blacklist supplier
        blacklistedSuppliers[supplierId] = true;

        // Debug log before slashing
        emit DebugLog("Before slashing", loan.supplier);

        // Slash staked tokens
        staking.slashStakedTokens(loan.supplier);

        // Debug log after slashing
        emit DebugLog("After slashing", loan.supplier);

        // Burn the invoice NFT
        invoiceNFT.burn(invoiceId);

        emit LoanLiquidated(invoiceId, loan.supplier, totalAmount);
        emit SupplierBlacklisted(supplierId);
        emit InvoiceBurned(invoiceId);
    }

    /**
     * @dev Update LP interest
     * @param lp Address of the LP
     */
    function _updateLPInterest(address lp) internal {
        LPInfo storage info = lpInfo[lp];
        if (info.depositAmount > 0) {
            // Calculate new interest since last update
            uint256 newInterest = calculateInterest(
                info.depositAmount,
                info.lastInterestUpdate,
                LP_INTEREST_RATE
            );
            // Add only the new interest
            info.interestAccrued += newInterest;
            info.lastInterestUpdate = block.timestamp;
        }
    }

    /**
     * @dev Calculate interest
     * @param principal Principal amount
     * @param startTime Start time
     * @param rate Interest rate
     * @return Interest amount
     */
    function calculateInterest(
        uint256 principal,
        uint256 startTime,
        uint256 rate
    ) public view returns (uint256) {
        uint256 timeElapsed = block.timestamp - startTime;
        // Convert timeElapsed to years (with 18 decimals for precision)
        uint256 timeInYears = (timeElapsed * 1e18) / (365 days);
        // Calculate interest: principal * rate * timeInYears / BASIS_POINTS
        return (principal * rate * timeInYears) / (BASIS_POINTS * 1e18);
    }

    /**
     * @dev Get LP's accumulated interest
     * @param lp Address of the LP
     * @return Interest amount
     */
    function getLPInterest(address lp) external view returns (uint256) {
        LPInfo storage info = lpInfo[lp];
        if (info.depositAmount == 0) return info.interestAccrued;
        
        // Calculate current interest including accrued and new interest
        uint256 currentInterest = info.interestAccrued + calculateInterest(
            info.depositAmount,
            info.lastInterestUpdate,
            LP_INTEREST_RATE
        );
        
        return currentInterest;
    }

    /**
     * @dev Get user's active loans
     * @param user Address of the user
     * @return Array of loan IDs
     */
    function getUserLoans(address user) external view returns (uint256[] memory) {
        return userLoans[user];
    }

    /**
     * @dev Get user's active loans
     * @param user Address of the user
     * @return Array of loan IDs
     */
    function getUserActiveLoans(address user) external view returns (uint256[] memory) {
        uint256[] memory allLoans = userLoans[user];
        uint256 activeCount = 0;
        
        // Count active loans
        for (uint256 i = 0; i < allLoans.length; i++) {
            if (userActiveLoans[user][allLoans[i]]) {
                activeCount++;
            }
        }
        
        // Create array of active loans
        uint256[] memory activeLoans = new uint256[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < allLoans.length; i++) {
            if (userActiveLoans[user][allLoans[i]]) {
                activeLoans[currentIndex] = allLoans[i];
                currentIndex++;
            }
        }
        
        return activeLoans;
    }

    function getUserLoanDetails(address user, uint256 tokenId) external view returns (
        uint256 amount,
        uint256 dueDate,
        bool isRepaid,
        bool isLiquidated,
        uint256 interestAccrued
    ) {
        require(userActiveLoans[user][tokenId], "Loan not found or not active");
        Loan storage loan = loans[tokenId];
        
        // Calculate current interest
        uint256 currentInterest = loan.interestAccrued;
        if (!loan.isRepaid && !loan.isLiquidated) {
            currentInterest += calculateInterest(
                loan.amount,
                loan.lastInterestUpdate,
                BORROWER_INTEREST_RATE
            );
        }
        
        return (
            loan.amount,
            loan.dueDate,
            loan.isRepaid,
            loan.isLiquidated,
            currentInterest
        );
    }

    function getUserTotalBorrowed(address user) external view returns (uint256) {
        return userTotalBorrowed[user];
    }

    /**
     * @dev Withdraw platform fees (only owner)
     */
    function withdrawPlatformFees() external onlyOwner {
        uint256 amount = platformFees;
        platformFees = 0;
        stablecoin.safeTransfer(owner(), amount);
    }

    /**
     * @dev Get the maximum borrow amount for a given invoice
     * @param tokenId Unique identifier for the invoice NFT
     * @return Maximum borrow amount
     */
    function getMaxBorrowAmount(uint256 tokenId) public view returns (uint256) {
        InvoiceNFT.InvoiceDetails memory invoice = invoiceNFT.getInvoiceDetails(tokenId);
        uint256 maxBorrowAmount = (invoice.creditAmount * BORROW_CAP_PERCENTAGE) / 100;
        uint256 tier = staking.getTier(msg.sender);
        if (tier > 0) {
            maxBorrowAmount = (maxBorrowAmount * (100 + tier * 10)) / 100; // Each tier increases cap by 10%
        }
        return maxBorrowAmount;
    }
} 