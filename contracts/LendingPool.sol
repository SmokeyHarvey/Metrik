// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./InvoiceNFT.sol";
import "./Staking.sol";
import "./IStaking.sol";
import "./IBorrowRegistry.sol";

// Junior Tranche: 12% APR (JUNIOR_LP_INTEREST_RATE = 1200 basis points), no lockup, can withdraw anytime, absorbs losses first
// Senior Tranche: 7% APR (SENIOR_LP_INTEREST_RATE = 700 basis points), lockup (45/90/180/365 days), can only withdraw after lockup, absorbs losses after Junior
// Both accrue interest linearly over time. Junior is higher risk/higher APY, Senior is lower risk/lower APY.
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
    uint256 public constant JUNIOR_LP_INTEREST_RATE = 1200; // 12% APR
    uint256 public constant SENIOR_LP_INTEREST_RATE = 700;  // 7% APR

    // State variables
    IERC20 public immutable metrikToken;
    IERC20 public immutable stablecoin;
    InvoiceNFT public immutable invoiceNFT;
    Staking public immutable staking;
    IStaking public immutable iStaking;
    IBorrowRegistry public borrowRegistry;
    uint256 public totalDeposits;
    uint256 public totalBorrowed;
    uint256 public platformFees;
    uint256 public lastInterestUpdate;
    uint256 public reserveRatio = 4000; // 40% in basis points (10000 = 100%)
    uint256 public maxLoanPercent = 2000; // 20% in basis points

    event ReserveRatioUpdated(uint256 newRatio);
    event MaxLoanPercentUpdated(uint256 newPercent);
    event LPRegistered(address indexed lp);
    event LPUnregistered(address indexed lp);

    // Owner can update reserve ratio
    function setReserveRatio(uint256 newRatio) external onlyOwner {
        require(newRatio <= 10000, "Invalid ratio");
        reserveRatio = newRatio;
        emit ReserveRatioUpdated(newRatio);
    }
    // Owner can update max loan percent
    function setMaxLoanPercent(uint256 newPercent) external onlyOwner {
        require(newPercent <= 10000, "Invalid percent");
        maxLoanPercent = newPercent;
        emit MaxLoanPercentUpdated(newPercent);
    }

    // Calculate protocol utilization (in basis points)
    function getUtilization() public view returns (uint256) {
        if (totalDeposits == 0) return 0;
        return (totalBorrowed * BASIS_POINTS) / totalDeposits;
    }

    // Calculate the safe lending amount for a borrower (enforces all risk controls)
    function getSafeLendingAmount(address user, uint256 invoiceAmount) public view returns (uint256) {
        uint256 borrowerMax = (invoiceAmount * getBorrowingCapacity(user)) / BASIS_POINTS;
        uint256 availableLiquidity = totalDeposits - totalBorrowed;
        uint256 utilization = getUtilization();
        // Dynamic reserve ratio
        uint256 dynamicReserveRatio = utilization > 8000 ? 6000 : reserveRatio; // 60% if utilization > 80%
        uint256 minReserve = (totalDeposits * dynamicReserveRatio) / BASIS_POINTS;
        uint256 platformMax = availableLiquidity > minReserve ? availableLiquidity - minReserve : 0;
        // Cap max loan as % of total liquidity
        uint256 maxLoanSize = (totalDeposits * maxLoanPercent) / BASIS_POINTS;
        uint256 safeLend = borrowerMax;
        if (safeLend > platformMax) safeLend = platformMax;
        if (safeLend > maxLoanSize) safeLend = maxLoanSize;
        // If utilization > 90%, no new loans
        require(utilization <= 9000, "Protocol utilization too high");
        // If safeLend is 0, revert
        require(safeLend > 0, "No safe lending capacity");
        return safeLend;
    }

    /**
     * @dev Returns the system-wide safe lending amount (total available for new loans)
     */
    function getSystemWideSafeLendingAmount() public view returns (uint256) {
        uint256 availableLiquidity = totalDeposits - totalBorrowed;
        uint256 utilization = getUtilization();
        // Dynamic reserve ratio
        uint256 dynamicReserveRatio = utilization > 8000 ? 6000 : reserveRatio; // 60% if utilization > 80%
        uint256 minReserve = (totalDeposits * dynamicReserveRatio) / BASIS_POINTS;
        uint256 platformMax = availableLiquidity > minReserve ? availableLiquidity - minReserve : 0;
        // Cap max loan as % of total liquidity
        uint256 maxLoanSize = (totalDeposits * maxLoanPercent) / BASIS_POINTS;
        uint256 safeLend = platformMax;
        if (safeLend > maxLoanSize) safeLend = maxLoanSize;
        // If utilization > 90%, no new loans
        if (utilization > 9000) return 0;
        return safeLend;
    }

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

    // Tranche types
    enum Tranche { Junior, Senior }

    struct LPDeposit {
        uint256 amount;
        uint256 depositTime;
        uint256 lastInterestClaimed;
        uint256 withdrawnAmount;
        uint256 depositId;
        Tranche tranche;
        uint256 lockupDuration; // Only for senior, 0 for junior
    }

    // Mappings
    mapping(uint256 => Loan) public loans;
    mapping(address => uint256[]) public userLoans;
    mapping(string => bool) public blacklistedSuppliers;
    mapping(address => mapping(uint256 => bool)) public userActiveLoans; // user => tokenId => isActive
    mapping(address => uint256) public userTotalBorrowed;
    mapping(address => LPDeposit[]) public lpDeposits;
    mapping(address => uint256) public lpTotalDeposits; // Total deposits per user
    mapping(address => uint256) public lpTotalInterest; // Total interest per user

    // Tranche liquidity tracking
    uint256 public totalJuniorLiquidity;
    uint256 public totalSeniorLiquidity;

    // LP Registry for production loss absorption
    address[] public lpAddresses;
    mapping(address => bool) public isRegisteredLP;
    mapping(address => uint256) public lpIndex;

    // Events
    event Deposit(address indexed user, uint256 amount, uint256 depositId);
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
    event DebugLogValue(string message, uint256 value);

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
        iStaking = IStaking(_staking);
        lastInterestUpdate = block.timestamp;
    }

    /// @notice Sets the BorrowRegistry address
    /// @param _borrowRegistry The address of the BorrowRegistry contract
    function setBorrowRegistry(address _borrowRegistry) external onlyOwner {
        borrowRegistry = IBorrowRegistry(_borrowRegistry);
    }

    /**
     * @dev Add LP to registry (internal function)
     * @param lp Address of the LP to add
     */
    function _addLPToRegistry(address lp) internal {
        if (!isRegisteredLP[lp]) {
            lpIndex[lp] = lpAddresses.length;
            lpAddresses.push(lp);
            isRegisteredLP[lp] = true;
            emit LPRegistered(lp);
        }
    }

    /**
     * @dev Remove LP from registry (internal function)
     * @param lp Address of the LP to remove
     */
    function _removeLPFromRegistry(address lp) internal {
        if (isRegisteredLP[lp]) {
            uint256 index = lpIndex[lp];
            uint256 lastIndex = lpAddresses.length - 1;
            
            // If not the last element, move the last element to this position
            if (index != lastIndex) {
                address lastLP = lpAddresses[lastIndex];
                lpAddresses[index] = lastLP;
                lpIndex[lastLP] = index;
            }
            
            lpAddresses.pop();
            isRegisteredLP[lp] = false;
            delete lpIndex[lp];
            emit LPUnregistered(lp);
        }
    }

    /**
     * @dev Get all registered LP addresses
     * @return Array of LP addresses
     */
    function getAllRegisteredLPs() external view returns (address[] memory) {
        return lpAddresses;
    }

    /**
     * @dev Check if LP has any active deposits
     * @param lp Address of the LP
     * @return True if LP has active deposits
     */
    function _hasActiveDeposits(address lp) internal view returns (bool) {
        LPDeposit[] storage deposits = lpDeposits[lp];
        for (uint256 i = 0; i < deposits.length; i++) {
            if (deposits[i].amount > deposits[i].withdrawnAmount) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Deposit invoice and borrow against it
     * @param tokenId Unique identifier for the invoice NFT
     * @param borrowAmount Amount to borrow (max LTV% of invoice amount)
     */
    function depositInvoiceAndBorrow(
        uint256 tokenId,
        uint256 borrowAmount
    ) external nonReentrant {
        if (borrowAmount == 0) revert InvalidAmount();
        // Get supplier from InvoiceNFT
        address supplier = invoiceNFT.ownerOf(tokenId);
        emit DebugLog("Supplier address", supplier);

        // Get LTV (basis points)
        uint256 ltv = getBorrowingCapacity(supplier);
        emit DebugLogValue("Calculated LTV", ltv);

        // Get invoice details
        InvoiceNFT.InvoiceDetails memory invoice = invoiceNFT.getInvoiceDetails(tokenId);
        emit DebugLogValue("Invoice credit amount", invoice.creditAmount);

        uint256 maxBorrow = getSafeLendingAmount(supplier, invoice.creditAmount);
        emit DebugLogValue("Max safe borrow amount", maxBorrow);
        emit DebugLogValue("Requested borrow amount", borrowAmount);

        if (borrowAmount > maxBorrow) revert InvalidBorrowAmount();
        if (invoice.dueDate <= block.timestamp) revert InvoiceExpired();
        if (userActiveLoans[supplier][tokenId]) revert LoanAlreadyExists();
        if (!invoice.isVerified) revert InvoiceNotVerified();

        // Transfer invoice NFT to lending pool
        invoiceNFT.transferFrom(supplier, address(this), tokenId);

        // Create loan
        loans[tokenId] = Loan({
            invoiceId: tokenId,
            amount: borrowAmount,
            dueDate: invoice.dueDate,
            isRepaid: false,
            isLiquidated: false,
            interestAccrued: 0,
            lastInterestUpdate: block.timestamp,
            supplier: supplier,
            borrowAmount: borrowAmount,
            borrowTime: block.timestamp
        });

        // Update user loan tracking
        userLoans[supplier].push(tokenId);
        userActiveLoans[supplier][tokenId] = true;
        userTotalBorrowed[supplier] += borrowAmount;
        totalBorrowed += borrowAmount;

        // Record borrow event
        if (address(borrowRegistry) != address(0)) {
            borrowRegistry.recordBorrow(supplier, tokenId);
        }

        // Transfer borrowed amount to supplier
        stablecoin.safeTransfer(supplier, borrowAmount);

        emit LoanCreated(tokenId, supplier, borrowAmount);
    }

    /**
     * @dev Deposit stablecoins as LP (default to Junior for backward compatibility)
     * @param amount Amount of stablecoins to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        uint256 depositId = lpDeposits[msg.sender].length;
        lpDeposits[msg.sender].push(LPDeposit({
            amount: amount,
            depositTime: block.timestamp,
            lastInterestClaimed: block.timestamp,
            withdrawnAmount: 0,
            depositId: depositId,
            tranche: Tranche.Junior,
            lockupDuration: 0
        }));
        lpTotalDeposits[msg.sender] += amount;
        totalDeposits += amount;
        totalJuniorLiquidity += amount;
        // Add LP to registry if this is their first deposit
        _addLPToRegistry(msg.sender);
        emit Deposit(msg.sender, amount, depositId);
    }

    /**
     * @dev Deposit stablecoins as LP (with tranche selection)
     * @param amount Amount of stablecoins to deposit
     * @param tranche Tranche type (0 = Junior, 1 = Senior)
     * @param lockupDuration Lockup duration in seconds (only for Senior, 0 for Junior)
     */
    function depositWithTranche(uint256 amount, Tranche tranche, uint256 lockupDuration) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        if (tranche == Tranche.Senior) {
            require(lockupDuration > 0, "Senior tranche requires lockup");
        } else {
            require(lockupDuration == 0, "Junior tranche cannot have lockup");
        }
        stablecoin.safeTransferFrom(msg.sender, address(this), amount);
        uint256 depositId = lpDeposits[msg.sender].length;
        lpDeposits[msg.sender].push(LPDeposit({
            amount: amount,
            depositTime: block.timestamp,
            lastInterestClaimed: block.timestamp,
            withdrawnAmount: 0,
            depositId: depositId,
            tranche: tranche,
            lockupDuration: lockupDuration
        }));
        lpTotalDeposits[msg.sender] += amount;
        totalDeposits += amount;
        if (tranche == Tranche.Junior) {
            totalJuniorLiquidity += amount;
        } else {
            totalSeniorLiquidity += amount;
        }
        // Add LP to registry if this is their first deposit
        _addLPToRegistry(msg.sender);
        emit Deposit(msg.sender, amount, depositId);
    }

    // General withdraw function removed for security - use withdrawJunior() or withdrawSenior() instead

    /**
     * @dev Withdraw from specific tranche
     * @param amount Amount to withdraw
     * @param tranche Tranche to withdraw from (0 = Junior, 1 = Senior)
     */
    function withdrawByTranche(uint256 amount, Tranche tranche) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        // Check if there's enough liquidity
        uint256 availableLiquidity = totalDeposits - totalBorrowed;
        if (availableLiquidity < amount) revert InsufficientLiquidity();

        // Calculate available amount in the specified tranche
        uint256 availableInTranche = 0;
        LPDeposit[] storage deposits = lpDeposits[msg.sender];
        
        for (uint256 i = 0; i < deposits.length; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche == tranche) {
                uint256 available = dep.amount - dep.withdrawnAmount;
                if (available > 0) {
                    if (tranche == Tranche.Senior) {
                        // Check lockup for senior tranche
                        if (block.timestamp >= dep.depositTime + dep.lockupDuration) {
                            availableInTranche += available;
                        }
                    } else {
                        // Junior tranche has no lockup
                        availableInTranche += available;
                    }
                }
            }
        }
        
        if (availableInTranche < amount) {
            revert("Insufficient unlocked balance in specified tranche");
        }

        // Withdraw from the specified tranche
        uint256 remaining = amount;
        for (uint256 i = 0; i < deposits.length && remaining > 0; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche != tranche) continue;
            
            uint256 available = dep.amount - dep.withdrawnAmount;
            if (available == 0) continue;
            
            if (tranche == Tranche.Senior) {
                // Enforce lockup for senior tranche
                if (block.timestamp < dep.depositTime + dep.lockupDuration) {
                    continue; // skip locked senior deposit
                }
            }
            
            uint256 delta = available < remaining ? available : remaining;
            dep.withdrawnAmount += delta;
            remaining -= delta;
            
            // Update tranche liquidity
            if (tranche == Tranche.Junior) {
                totalJuniorLiquidity -= delta;
            } else {
                totalSeniorLiquidity -= delta;
            }
        }
        
        // Update state before transfer
        lpTotalDeposits[msg.sender] -= amount;
        totalDeposits -= amount;
        
        // Remove LP from registry if they have no more active deposits
        if (!_hasActiveDeposits(msg.sender)) {
            _removeLPFromRegistry(msg.sender);
        }
        
        // Transfer after state updates
        stablecoin.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /**
     * @dev Withdraw from Junior tranche only
     * @param amount Amount to withdraw
     */
    function withdrawJunior(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        // Check if there's enough liquidity
        uint256 availableLiquidity = totalDeposits - totalBorrowed;
        if (availableLiquidity < amount) revert InsufficientLiquidity();

        // Calculate available amount in Junior tranche
        uint256 availableInTranche = 0;
        LPDeposit[] storage deposits = lpDeposits[msg.sender];
        
        for (uint256 i = 0; i < deposits.length; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche == Tranche.Junior) {
                uint256 available = dep.amount - dep.withdrawnAmount;
                if (available > 0) {
                    availableInTranche += available;
                }
            }
        }
        
        if (availableInTranche < amount) {
            revert("Insufficient balance in Junior tranche");
        }

        // Withdraw from Junior tranche
        uint256 remaining = amount;
        for (uint256 i = 0; i < deposits.length && remaining > 0; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche != Tranche.Junior) continue;
            
            uint256 available = dep.amount - dep.withdrawnAmount;
            if (available == 0) continue;
            
            uint256 delta = available < remaining ? available : remaining;
            dep.withdrawnAmount += delta;
            remaining -= delta;
            totalJuniorLiquidity -= delta;
        }
        
        // Update state before transfer
        lpTotalDeposits[msg.sender] -= amount;
        totalDeposits -= amount;
        
        // Remove LP from registry if they have no more active deposits
        if (!_hasActiveDeposits(msg.sender)) {
            _removeLPFromRegistry(msg.sender);
        }
        
        // Transfer after state updates
        stablecoin.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    /**
     * @dev Withdraw from Senior tranche only (respects lockup)
     * @param amount Amount to withdraw
     */
    function withdrawSenior(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        // Check if there's enough liquidity
        uint256 availableLiquidity = totalDeposits - totalBorrowed;
        if (availableLiquidity < amount) revert InsufficientLiquidity();

        // Calculate available amount in Senior tranche
        uint256 availableInTranche = 0;
        LPDeposit[] storage deposits = lpDeposits[msg.sender];
        
        for (uint256 i = 0; i < deposits.length; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche == Tranche.Senior) {
                uint256 available = dep.amount - dep.withdrawnAmount;
                if (available > 0) {
                    // Check lockup for senior tranche
                    if (block.timestamp >= dep.depositTime + dep.lockupDuration) {
                        availableInTranche += available;
                    }
                }
            }
        }
        
        if (availableInTranche < amount) {
            revert("Insufficient unlocked balance in Senior tranche");
        }

        // Withdraw from Senior tranche
        uint256 remaining = amount;
        for (uint256 i = 0; i < deposits.length && remaining > 0; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche != Tranche.Senior) continue;
            
            uint256 available = dep.amount - dep.withdrawnAmount;
            if (available == 0) continue;
            
            // Enforce lockup for senior tranche
            if (block.timestamp < dep.depositTime + dep.lockupDuration) {
                continue; // skip locked senior deposit
            }
            
            uint256 delta = available < remaining ? available : remaining;
            dep.withdrawnAmount += delta;
            remaining -= delta;
            totalSeniorLiquidity -= delta;
        }
        
        // Update state before transfer
        lpTotalDeposits[msg.sender] -= amount;
        totalDeposits -= amount;
        
        // Remove LP from registry if they have no more active deposits
        if (!_hasActiveDeposits(msg.sender)) {
            _removeLPFromRegistry(msg.sender);
        }
        
        // Transfer after state updates
        stablecoin.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    // General withdrawInterest function removed for security - use withdrawJuniorInterest() or withdrawSeniorInterest() instead

    /**
     * @dev Withdraw interest from Junior tranche only
     */
    function withdrawJuniorInterest() external nonReentrant {
        LPDeposit[] storage deposits = lpDeposits[msg.sender];
        uint256 totalInterest = 0;
        
        for (uint256 i = 0; i < deposits.length; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche != Tranche.Junior) continue;
            
            uint256 principal = dep.amount - dep.withdrawnAmount;
            if (principal == 0) continue;
            
            uint256 timeElapsed = block.timestamp - dep.lastInterestClaimed;
            uint256 timeInYears = (timeElapsed * 1e18) / (365 days);
            uint256 interest = (principal * JUNIOR_LP_INTEREST_RATE * timeInYears) / (BASIS_POINTS * 1e18);
            
            if (interest > 0) {
                dep.lastInterestClaimed = block.timestamp;
                totalInterest += interest;
            }
        }
        
        require(totalInterest > 0, "No Junior interest to withdraw");
        lpTotalInterest[msg.sender] += totalInterest;
        stablecoin.safeTransfer(msg.sender, totalInterest);
        emit InterestWithdraw(msg.sender, totalInterest);
    }

    /**
     * @dev Withdraw interest from Senior tranche only (respects lockup)
     */
    function withdrawSeniorInterest() external nonReentrant {
        LPDeposit[] storage deposits = lpDeposits[msg.sender];
        uint256 totalInterest = 0;
        
        for (uint256 i = 0; i < deposits.length; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche != Tranche.Senior) continue;
            
            uint256 principal = dep.amount - dep.withdrawnAmount;
            if (principal == 0) continue;
            
            // Enforce lockup for Senior tranche
            if (block.timestamp < dep.depositTime + dep.lockupDuration) {
                continue; // skip locked senior deposit for interest
            }
            
            uint256 timeElapsed = block.timestamp - dep.lastInterestClaimed;
            uint256 timeInYears = (timeElapsed * 1e18) / (365 days);
            uint256 interest = (principal * SENIOR_LP_INTEREST_RATE * timeInYears) / (BASIS_POINTS * 1e18);
            
            if (interest > 0) {
                dep.lastInterestClaimed = block.timestamp;
                totalInterest += interest;
            }
        }
        
        require(totalInterest > 0, "No Senior interest to withdraw");
        lpTotalInterest[msg.sender] += totalInterest;
        stablecoin.safeTransfer(msg.sender, totalInterest);
        emit InterestWithdraw(msg.sender, totalInterest);
    }

    /**
     * @dev Repay a loan
     * @param invoiceId ID of the invoice NFT
     */
    function repay(uint256 invoiceId) external nonReentrant {
        Loan storage loan = loans[invoiceId];
        require(!loan.isRepaid && !loan.isLiquidated, "Loan already settled");
        bool isLate = block.timestamp > loan.dueDate;
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

        // Record repayment event
        if (address(borrowRegistry) != address(0)) {
            borrowRegistry.recordRepayment(msg.sender, invoiceId, isLate);
        }

        // Burn the invoice NFT
        invoiceNFT.burn(invoiceId);

        emit LoanRepaid(invoiceId, loan.supplier, totalAmount);
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

        // Record default event
        if (address(borrowRegistry) != address(0)) {
            borrowRegistry.recordDefault(loan.supplier, invoiceId);
        }

        // Blacklist supplier
        blacklistedSuppliers[supplierId] = true;

        // Debug log before slashing
        emit DebugLog("Before slashing", loan.supplier);

        // Slash staked tokens
        staking.slashStakedTokens(loan.supplier);

        // Debug log after slashing
        emit DebugLog("After slashing", loan.supplier);

        // --- LOSS ABSORPTION LOGIC ---
        uint256 loss = totalAmount; // Assume full loss (no recovery)
        uint256 juniorLoss = loss > totalJuniorLiquidity ? totalJuniorLiquidity : loss;
        uint256 seniorLoss = loss > totalJuniorLiquidity ? loss - totalJuniorLiquidity : 0;
        
        if (juniorLoss > 0) {
            // Distribute juniorLoss proportionally across all active junior deposits of all registered LPs
            uint256 totalActiveJunior = 0;
            // First pass: calculate total active junior liquidity
            for (uint256 h = 0; h < lpAddresses.length; h++) {
                address lp = lpAddresses[h];
                LPDeposit[] storage deposits = lpDeposits[lp];
                for (uint256 i = 0; i < deposits.length; i++) {
                    LPDeposit storage dep = deposits[i];
                    if (dep.tranche == Tranche.Junior) {
                        uint256 principal = dep.amount - dep.withdrawnAmount;
                        totalActiveJunior += principal;
                    }
                }
            }
            // Second pass: distribute loss proportionally
            if (totalActiveJunior > 0) {
                for (uint256 h = 0; h < lpAddresses.length; h++) {
                    address lp = lpAddresses[h];
                    LPDeposit[] storage deposits = lpDeposits[lp];
                    for (uint256 i = 0; i < deposits.length; i++) {
                        LPDeposit storage dep = deposits[i];
                        if (dep.tranche == Tranche.Junior) {
                            uint256 principal = dep.amount - dep.withdrawnAmount;
                            if (principal == 0) continue;
                            uint256 share = (principal * juniorLoss) / totalActiveJunior;
                            dep.amount -= share;
                        }
                    }
                }
            }
            totalJuniorLiquidity -= juniorLoss;
        }
        
        if (seniorLoss > 0) {
            // Distribute seniorLoss proportionally across all active senior deposits of all registered LPs
            uint256 totalActiveSenior = 0;
            // First pass: calculate total active senior liquidity
            for (uint256 h = 0; h < lpAddresses.length; h++) {
                address lp = lpAddresses[h];
                LPDeposit[] storage deposits = lpDeposits[lp];
                for (uint256 i = 0; i < deposits.length; i++) {
                    LPDeposit storage dep = deposits[i];
                    if (dep.tranche == Tranche.Senior) {
                        uint256 principal = dep.amount - dep.withdrawnAmount;
                        totalActiveSenior += principal;
                    }
                }
            }
            // Second pass: distribute loss proportionally
            if (totalActiveSenior > 0) {
                for (uint256 h = 0; h < lpAddresses.length; h++) {
                    address lp = lpAddresses[h];
                    LPDeposit[] storage deposits = lpDeposits[lp];
                    for (uint256 i = 0; i < deposits.length; i++) {
                        LPDeposit storage dep = deposits[i];
                        if (dep.tranche == Tranche.Senior) {
                            uint256 principal = dep.amount - dep.withdrawnAmount;
                            if (principal == 0) continue;
                            uint256 share = (principal * seniorLoss) / totalActiveSenior;
                            dep.amount -= share;
                        }
                    }
                }
            }
            totalSeniorLiquidity -= seniorLoss;
        }
        emit DebugLogValue("Junior loss absorbed", juniorLoss);
        emit DebugLogValue("Senior loss absorbed", seniorLoss);
        // --- END LOSS ABSORPTION LOGIC ---

        // Burn the invoice NFT
        invoiceNFT.burn(invoiceId);

        emit LoanLiquidated(invoiceId, loan.supplier, totalAmount);
        emit SupplierBlacklisted(supplierId);
        emit InvoiceBurned(invoiceId);
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
        LPDeposit[] storage deposits = lpDeposits[lp];
        uint256 totalInterest = 0;
        
        for (uint256 i = 0; i < deposits.length; i++) {
            uint256 principal = deposits[i].amount - deposits[i].withdrawnAmount;
            if (principal == 0) continue;
            
            uint256 timeElapsed = block.timestamp - deposits[i].lastInterestClaimed;
            uint256 timeInYears = (timeElapsed * 1e18) / (365 days);
            uint256 interest = (principal * LP_INTEREST_RATE * timeInYears) / (BASIS_POINTS * 1e18);
            totalInterest += interest;
        }
        
        return totalInterest;
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

    /**
     * @dev Get user's LP deposits
     * @param user Address of the user
     * @return Array of deposit details
     */
    function getUserLPDeposits(address user) external view returns (LPDeposit[] memory) {
        return lpDeposits[user];
    }

    /**
     * @dev Get user's total LP deposits
     * @param user Address of the user
     * @return Total deposits
     */
    function getUserTotalLPDeposits(address user) external view returns (uint256) {
        return lpTotalDeposits[user];
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

    /**
     * @notice Returns the borrowing capacity (LTV%) for a supplier based on staking, tier, and history
     * @param user The supplier address
     * @return ltv The computed LTV percentage (in basis points, e.g. 4500 = 45%)
     */
    function getBorrowingCapacity(address user) public view returns (uint256 ltv) {
        uint256 points = staking.getTotalPoints(user);
        uint256 baseLTV;
        if (points >= 10000) {
            baseLTV = 7500; // 75%
        } else if (points >= 5000) {
            baseLTV = 6000; // 60%
        } else if (points >= 2500) {
            baseLTV = 5000; // 50%
        } else if (points >= 1000) {
            baseLTV = 4000; // 40%
        } else {
            baseLTV = 3000; // 30%
        }

        int256 historyScore = _calculateHistoryScore(user); // in basis points (can be negative)
        uint256 total = baseLTV;
        if (historyScore > 0) {
            total += uint256(historyScore);
        } else if (historyScore < 0) {
            uint256 penalty = uint256(-historyScore);
            if (total > penalty) {
                total -= penalty;
            } else {
                total = 0;
            }
        }
        if (total > 7500) {
            total = 7500;
        } else if (total < 3000) {
            total = 3000;
        }
        return total;
    }

    /**
     * @notice Calculates the history score for a user
     * @param user The supplier address
     * @return score The history score in basis points (can be negative)
     */
    function _calculateHistoryScore(address user) internal view returns (int256 score) {
        if (address(borrowRegistry) == address(0)) return 0;

        uint256 defaults = borrowRegistry.getDefaults(user);
        uint256 lateRepayments = borrowRegistry.getLateRepayments(user);
        uint256 successfulLoans = borrowRegistry.getSuccessfulLoans(user);

        int256 currentScore = 0;

        if (defaults == 0) {
            currentScore += 1000; // +10%
        } else if (defaults >= 2) {
            currentScore -= 1500; // -15%
        }

        if (lateRepayments >= 1 && lateRepayments <= 2) {
            currentScore -= 500; // -5%
        }

        if (successfulLoans >= 5) {
            currentScore += 500; // +5%
        }

        return currentScore;
    }

    /**
     * @dev Get LP's active principal in each tranche
     * @param lp Address of the LP
     * @return juniorPrincipal Active principal in Junior tranche
     * @return seniorPrincipal Active principal in Senior tranche
     */
    function getLPTrancheBreakdown(address lp) external view returns (uint256 juniorPrincipal, uint256 seniorPrincipal) {
        LPDeposit[] storage deposits = lpDeposits[lp];
        for (uint256 i = 0; i < deposits.length; i++) {
            uint256 principal = deposits[i].amount - deposits[i].withdrawnAmount;
            if (principal == 0) continue;
            if (deposits[i].tranche == Tranche.Junior) {
                juniorPrincipal += principal;
            } else {
                seniorPrincipal += principal;
            }
        }
    }

    /**
     * @dev Get all active (not fully withdrawn) deposits for an LP
     * @param lp Address of the LP
     * @return Array of active LPDeposit structs
     */
    function getLPActiveDeposits(address lp) external view returns (LPDeposit[] memory) {
        LPDeposit[] storage deposits = lpDeposits[lp];
        uint256 count = 0;
        for (uint256 i = 0; i < deposits.length; i++) {
            if (deposits[i].amount > deposits[i].withdrawnAmount) {
                count++;
            }
        }
        LPDeposit[] memory active = new LPDeposit[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < deposits.length; i++) {
            if (deposits[i].amount > deposits[i].withdrawnAmount) {
                active[idx] = deposits[i];
                idx++;
            }
        }
        return active;
    }

    /**
     * @dev Get user's total deposits in a specific tranche
     * @param user Address of the user
     * @param tranche Tranche to check (0 = Junior, 1 = Senior)
     * @return Total deposits in the specified tranche
     */
    function getTrancheDeposits(address user, Tranche tranche) external view returns (uint256) {
        uint256 total = 0;
        LPDeposit[] storage deposits = lpDeposits[user];
        for (uint256 i = 0; i < deposits.length; i++) {
            if (deposits[i].tranche == tranche) {
                total += deposits[i].amount;
            }
        }
        return total;
    }

    /**
     * @dev Get user's available (unlocked) deposits in a specific tranche
     * @param user Address of the user
     * @param tranche Tranche to check (0 = Junior, 1 = Senior)
     * @return Available deposits in the specified tranche
     */
    function getTrancheAvailableBalance(address user, Tranche tranche) external view returns (uint256) {
        uint256 available = 0;
        LPDeposit[] storage deposits = lpDeposits[user];
        for (uint256 i = 0; i < deposits.length; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche == tranche) {
                uint256 depositAvailable = dep.amount - dep.withdrawnAmount;
                if (depositAvailable > 0) {
                    if (tranche == Tranche.Senior) {
                        // Check lockup for senior tranche
                        if (block.timestamp >= dep.depositTime + dep.lockupDuration) {
                            available += depositAvailable;
                        }
                    } else {
                        // Junior tranche has no lockup
                        available += depositAvailable;
                    }
                }
            }
        }
        return available;
    }

    /**
     * @dev Get user's locked deposits in Senior tranche
     * @param user Address of the user
     * @return Locked deposits in Senior tranche
     */
    function getSeniorLockedBalance(address user) external view returns (uint256) {
        uint256 locked = 0;
        LPDeposit[] storage deposits = lpDeposits[user];
        for (uint256 i = 0; i < deposits.length; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche == Tranche.Senior) {
                uint256 depositAvailable = dep.amount - dep.withdrawnAmount;
                if (depositAvailable > 0) {
                    if (block.timestamp < dep.depositTime + dep.lockupDuration) {
                        locked += depositAvailable;
                    }
                }
            }
        }
        return locked;
    }

    /**
     * @dev Get deposit details for a specific deposit
     * @param user Address of the user
     * @param depositIndex Index of the deposit
     * @return amount The deposit amount
     * @return depositTime The deposit timestamp
     * @return lastInterestClaimed The last time interest was claimed
     * @return withdrawnAmount The amount already withdrawn
     * @return depositId The deposit ID
     * @return tranche The tranche type (Junior/Senior)
     * @return lockupDuration The lockup duration for senior tranche
     * @return isLocked Whether the deposit is currently locked
     */
    function getDepositDetails(address user, uint256 depositIndex) external view returns (
        uint256 amount,
        uint256 depositTime,
        uint256 lastInterestClaimed,
        uint256 withdrawnAmount,
        uint256 depositId,
        Tranche tranche,
        uint256 lockupDuration,
        bool isLocked
    ) {
        require(depositIndex < lpDeposits[user].length, "Invalid deposit index");
        LPDeposit storage dep = lpDeposits[user][depositIndex];
        amount = dep.amount;
        depositTime = dep.depositTime;
        lastInterestClaimed = dep.lastInterestClaimed;
        withdrawnAmount = dep.withdrawnAmount;
        depositId = dep.depositId;
        tranche = dep.tranche;
        lockupDuration = dep.lockupDuration;
        isLocked = (tranche == Tranche.Senior && block.timestamp < dep.depositTime + dep.lockupDuration);
    }

    /**
     * @dev Get total number of deposits for a user
     * @param user Address of the user
     * @return Number of deposits
     */
    function getUserDepositCount(address user) external view returns (uint256) {
        return lpDeposits[user].length;
    }

    /**
     * @dev Get pending interest for a specific tranche
     * @param user Address of the user
     * @param tranche Tranche to check (0 = Junior, 1 = Senior)
     * @return Pending interest in the specified tranche
     */
    function getTranchePendingInterest(address user, Tranche tranche) external view returns (uint256) {
        uint256 totalInterest = 0;
        LPDeposit[] storage deposits = lpDeposits[user];
        
        for (uint256 i = 0; i < deposits.length; i++) {
            LPDeposit storage dep = deposits[i];
            if (dep.tranche != tranche) continue;
            
            uint256 principal = dep.amount - dep.withdrawnAmount;
            if (principal == 0) continue;
            
            // For Senior tranche, check lockup
            if (tranche == Tranche.Senior) {
                if (block.timestamp < dep.depositTime + dep.lockupDuration) {
                    continue; // skip locked senior deposit
                }
            }
            
            uint256 timeElapsed = block.timestamp - dep.lastInterestClaimed;
            uint256 timeInYears = (timeElapsed * 1e18) / (365 days);
            uint256 rate = tranche == Tranche.Junior ? JUNIOR_LP_INTEREST_RATE : SENIOR_LP_INTEREST_RATE;
            uint256 interest = (principal * rate * timeInYears) / (BASIS_POINTS * 1e18);
            
            totalInterest += interest;
        }
        
        return totalInterest;
    }

    // General getTotalPendingInterest function removed for security - use getTranchePendingInterest() instead
} 