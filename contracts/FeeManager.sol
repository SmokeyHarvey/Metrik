// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title FeeManager
 * @dev Handles origination fees and treasury management
 */
contract FeeManager is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant DEFAULT_ORIGINATION_FEE = 150; // 1.5%

    // State variables
    IERC20 public immutable stablecoin;
    address public treasury;
    uint256 public originationFee;

    // Events
    event FeeCollected(address indexed payer, uint256 amount);
    event TreasuryUpdated(address indexed newTreasury);
    event OriginationFeeUpdated(uint256 newFee);

    constructor(
        address _stablecoin,
        address _treasury
    ) Ownable(msg.sender) {
        stablecoin = IERC20(_stablecoin);
        treasury = _treasury;
        originationFee = DEFAULT_ORIGINATION_FEE;
    }

    /**
     * @dev Calculate and collect origination fee
     * @param amount Amount to calculate fee from
     * @return feeAmount The calculated fee amount
     */
    function collectFee(uint256 amount) external nonReentrant returns (uint256) {
        require(amount > 0, "Amount must be greater than 0");
        
        uint256 feeAmount = (amount * originationFee) / BASIS_POINTS;
        require(feeAmount > 0, "Fee amount too small");

        stablecoin.safeTransferFrom(msg.sender, address(this), feeAmount);
        stablecoin.safeTransfer(treasury, feeAmount);

        emit FeeCollected(msg.sender, feeAmount);
        return feeAmount;
    }

    /**
     * @dev Update treasury address
     * @param newTreasury New treasury address
     */
    function updateTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury address");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    /**
     * @dev Update origination fee
     * @param newFee New fee in basis points (max 500 = 5%)
     */
    function updateOriginationFee(uint256 newFee) external onlyOwner {
        require(newFee <= 500, "Fee too high"); // Max 5%
        originationFee = newFee;
        emit OriginationFeeUpdated(newFee);
    }

    /**
     * @dev Calculate fee amount for a given amount
     * @param amount Amount to calculate fee from
     * @return feeAmount The calculated fee amount
     */
    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * originationFee) / BASIS_POINTS;
    }

    /**
     * @dev Get current fee settings
     * @return currentFee Current origination fee in basis points
     * @return treasuryAddress Current treasury address
     */
    function getFeeSettings() external view returns (uint256 currentFee, address treasuryAddress) {
        return (originationFee, treasury);
    }
} 