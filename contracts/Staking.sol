// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Staking
 * @dev Handles METRIK token staking and tier system
 */
contract Staking is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Custom Errors
    error StakingPeriodNotEnded();
    error NoStakeFound();
    error InvalidAmount();
    error InvalidDuration();

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant POINTS_PER_TOKEN = 1;
    uint256 public constant DURATION_MULTIPLIER = 2; // 2x points for longer staking

    // State variables
    IERC20 public immutable metrikToken;
    uint256 public totalStaked;
    uint256 public totalPoints;

    struct StakeInfo {
        uint256 amount;
        uint256 points;
        uint256 startTime;
        uint256 lastUpdateTime;
        uint256 duration;
    }

    // Mappings
    mapping(address => StakeInfo) public stakes;
    mapping(address => uint256) public userPoints;

    // Events
    event Staked(address indexed user, uint256 amount, uint256 duration);
    event Unstaked(address indexed user, uint256 amount);
    event PointsUpdated(address indexed user, uint256 points);
    event TokensSlashed(address indexed user, uint256 amount);

    constructor(address _metrikToken) Ownable(msg.sender) {
        metrikToken = IERC20(_metrikToken);
    }

    /**
     * @dev Stake METRIK tokens
     * @param amount Amount of tokens to stake
     * @param duration Staking duration in seconds
     */
    function stake(uint256 amount, uint256 duration) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (duration < 3 minutes) revert InvalidDuration();
        if (duration > 365 days) revert InvalidDuration();

        // Update existing stake if any
        if (stakes[msg.sender].amount > 0) {
            _updatePoints(msg.sender);
        }

        // Transfer tokens
        metrikToken.safeTransferFrom(msg.sender, address(this), amount);

        // Calculate points with duration multiplier
        uint256 points = amount * POINTS_PER_TOKEN;
        if (duration >= 180 days) {
            points = points * DURATION_MULTIPLIER;
        }

        // Update stake info
        stakes[msg.sender] = StakeInfo({
            amount: amount,
            points: points,
            startTime: block.timestamp,
            lastUpdateTime: block.timestamp,
            duration: duration
        });

        // Update totals
        totalStaked += amount;
        totalPoints += points;
        userPoints[msg.sender] += points;

        emit Staked(msg.sender, amount, duration);
        emit PointsUpdated(msg.sender, userPoints[msg.sender]);
    }

    /**
     * @dev Unstake METRIK tokens
     */
    function unstake() external nonReentrant {
        StakeInfo storage stakeInfo = stakes[msg.sender];
        if (stakeInfo.amount == 0) revert NoStakeFound();
        if (block.timestamp < stakeInfo.startTime + stakeInfo.duration) revert StakingPeriodNotEnded();

        _updatePoints(msg.sender);

        uint256 amount = stakeInfo.amount;
        uint256 points = stakeInfo.points;

        // Update totals
        totalStaked -= amount;
        totalPoints -= points;
        userPoints[msg.sender] -= points;

        // Clear stake info
        delete stakes[msg.sender];

        // Transfer tokens back
        metrikToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
        emit PointsUpdated(msg.sender, userPoints[msg.sender]);
    }

    /**
     * @dev Update points for a user
     * @param user Address of the user
     */
    function _updatePoints(address user) internal {
        StakeInfo storage stakeInfo = stakes[user];
        if (stakeInfo.amount == 0) return;

        uint256 timeElapsed = block.timestamp - stakeInfo.lastUpdateTime;
        uint256 additionalPoints = (stakeInfo.points * timeElapsed) / stakeInfo.duration;

        stakeInfo.points += additionalPoints;
        stakeInfo.lastUpdateTime = block.timestamp;
        userPoints[user] += additionalPoints;
        totalPoints += additionalPoints;

        emit PointsUpdated(user, userPoints[user]);
    }

    /**
     * @dev Get user's tier based on points
     * @param user Address of the user
     * @return Tier level (0-5)
     */
    function getTier(address user) external view returns (uint256) {
        uint256 points = userPoints[user];
        if (points >= 1000000) return 5;      // Diamond
        if (points >= 500000) return 4;       // Platinum
        if (points >= 250000) return 3;       // Gold
        if (points >= 100000) return 2;       // Silver
        if (points >= 50000) return 1;        // Bronze
        return 0;                             // No tier
    }

    /**
     * @dev Slash staked tokens (called by LendingPool)
     * @param user Address of the user
     */
    function slashStakedTokens(address user) external onlyOwner {
        StakeInfo storage stakeInfo = stakes[user];
        require(stakeInfo.amount > 0, "No stake found");

        uint256 amount = stakeInfo.amount;
        uint256 points = stakeInfo.points;

        // Update totals
        totalStaked -= amount;
        totalPoints -= points;
        userPoints[user] -= points;

        // Clear stake info
        delete stakes[user];

        // Transfer slashed tokens to owner
        metrikToken.safeTransfer(owner(), amount);

        emit TokensSlashed(user, amount);
        emit PointsUpdated(user, userPoints[user]);
    }

    /**
     * @dev Get user's stake info
     * @param user Address of the user
     * @return amount Stake amount
     * @return points Points
     * @return startTime Start time
     * @return lastUpdateTime Last update time
     * @return duration Duration
     */
    function getStakeInfo(address user) external view returns (
        uint256 amount,
        uint256 points,
        uint256 startTime,
        uint256 lastUpdateTime,
        uint256 duration
    ) {
        StakeInfo storage stakeInfo = stakes[user];
        return (
            stakeInfo.amount,
            stakeInfo.points,
            stakeInfo.startTime,
            stakeInfo.lastUpdateTime,
            stakeInfo.duration
        );
    }
} 