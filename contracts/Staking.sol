// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./mocks/MockERC20.sol";

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
    error AlreadyStaked();

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant POINTS_PER_TOKEN = 1;
    uint256 public constant DURATION_MULTIPLIER = 2; // 2x points for longer staking
    uint256 public constant BRONZE_TIER_MIN = 1000 * 1e18;
    uint256 public constant SILVER_TIER_MIN = 2500 * 1e18;
    uint256 public constant GOLD_TIER_MIN = 5000 * 1e18;
    uint256 public constant DIAMOND_TIER_MIN = 10000 * 1e18;

    // State variables
    IERC20 public immutable metrikToken;
    uint256 public totalStaked;
    uint256 public totalPoints;

    struct StakeInfo {
        uint256 amount;
        uint256 points; // amount * multiplier
        uint256 startTime;
        uint256 lastUpdateTime;
        uint256 duration;
        uint256 stakeId;
        bool isActive;
        uint256 apy; // APY in basis points (e.g., 100 = 1%)
        uint256 multiplier; // e.g., 10 = 1x, 13 = 1.3x, 15 = 1.5x, 20 = 2x
        uint256 rewardDebt;        // Total rewards already claimed
        uint256 lastClaimedTime;   // Last time rewards were claimed
    }

    struct StakeRecord {
        uint256 amount;
        uint256 startTime;
        uint256 duration;
        uint256 usedForBorrow; // amount of this stake currently locked as collateral
        uint256 stakeId;
    }

    // Mappings
    mapping(address => StakeInfo[]) public stakes;
    mapping(address => uint256) public userPoints;
    mapping(address => StakeRecord[]) public stakeHistory;
    mapping(address => uint256) public userTotalStaked;
    mapping(address => uint256) public userTotalUsedForBorrow;

    // Events
    event Staked(address indexed user, uint256 amount, uint256 duration, uint256 stakeId);
    event Unstaked(address indexed user, uint256 amount, uint256 stakeId);
    event PointsUpdated(address indexed user, uint256 points);
    event TokensSlashed(address indexed user, uint256 amount);
    event DebugLog(string message, address indexed user);
    event RewardsClaimed(address indexed user, uint256 stakeIndex, uint256 amount);

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
        if (duration < 45 days) revert InvalidDuration();
        if (duration != 45 days && duration != 90 days && duration != 180 days && duration != 365 days) revert InvalidDuration();

        metrikToken.safeTransferFrom(msg.sender, address(this), amount);

        // Determine multiplier and APY
        uint256 multiplier;
        uint256 apy;
        if (duration == 45 days) {
            multiplier = 10; // 1.0x
            apy = 100; // 1%
        } else if (duration == 90 days) {
            multiplier = 13; // 1.3x
            apy = 300; // 3%
        } else if (duration == 180 days) {
            multiplier = 15; // 1.5x
            apy = 500; // 5%
        } else if (duration == 365 days) {
            multiplier = 20; // 2.0x
            apy = 800; // 8%
        }
        uint256 points = amount * multiplier / 10; // e.g., 1000 * 13 / 10 = 1300

        uint256 stakeId = stakes[msg.sender].length;
        stakes[msg.sender].push(StakeInfo({
            amount: amount,
            points: points,
            startTime: block.timestamp,
            lastUpdateTime: block.timestamp,
            duration: duration,
            stakeId: stakeId,
            isActive: true,
            apy: apy,
            multiplier: multiplier,
            rewardDebt: 0,
            lastClaimedTime: block.timestamp
        }));
        stakeHistory[msg.sender].push(StakeRecord({
            amount: amount,
            startTime: block.timestamp,
            duration: duration,
            usedForBorrow: 0,
            stakeId: stakeId
        }));
        totalStaked += amount;
        totalPoints += points;
        userPoints[msg.sender] += points;
        userTotalStaked[msg.sender] += amount;
        emit Staked(msg.sender, amount, duration, stakeId);
        emit PointsUpdated(msg.sender, userPoints[msg.sender]);
    }

    /**
     * @dev Unstake METRIK tokens
     * @param stakeIndex Index of the stake to unstake
     */
    function unstake(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < stakes[msg.sender].length, "Invalid stake index");
        StakeInfo storage stakeInfo = stakes[msg.sender][stakeIndex];
        if (stakeInfo.amount == 0 || !stakeInfo.isActive) revert NoStakeFound();
        if (block.timestamp < stakeInfo.startTime + stakeInfo.duration) revert StakingPeriodNotEnded();

        // Auto-claim any remaining rewards
        uint256 rewards = pendingRewards(msg.sender, stakeIndex);
        if (rewards > 0) {
            stakeInfo.rewardDebt += rewards;
            stakeInfo.lastClaimedTime = block.timestamp > stakeInfo.startTime + stakeInfo.duration
                ? stakeInfo.startTime + stakeInfo.duration
                : block.timestamp;
            MockERC20(address(metrikToken)).mint(msg.sender, rewards);
            emit RewardsClaimed(msg.sender, stakeIndex, rewards);
        }

        _updatePoints(msg.sender, stakeIndex);

        uint256 amount = stakeInfo.amount;
        uint256 points = stakeInfo.points;

        // Update totals
        totalStaked -= amount;
        totalPoints -= points;
        userPoints[msg.sender] -= points;
        userTotalStaked[msg.sender] -= amount;

        // Mark stake as inactive
        stakeInfo.isActive = false;
        stakeInfo.amount = 0;
        stakeInfo.points = 0;

        // Transfer tokens back
        metrikToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount, stakeInfo.stakeId);
        emit PointsUpdated(msg.sender, userPoints[msg.sender]);
    }

    /**
     * @dev Update points for a user
     * @param user Address of the user
     * @param stakeIndex Index of the stake to update
     */
    function _updatePoints(address user, uint256 stakeIndex) internal {
        StakeInfo storage stakeInfo = stakes[user][stakeIndex];
        if (stakeInfo.amount == 0 || !stakeInfo.isActive) return;

        uint256 timeElapsed = block.timestamp - stakeInfo.lastUpdateTime;
        uint256 additionalPoints = (stakeInfo.points * timeElapsed) / stakeInfo.duration;

        stakeInfo.points += additionalPoints;
        stakeInfo.lastUpdateTime = block.timestamp;
        userPoints[user] += additionalPoints;
        totalPoints += additionalPoints;

        emit PointsUpdated(user, userPoints[user]);
    }

    /**
     * @dev Get user's staking tier based on total staked amount and duration
     * @param user Address of the user
     * @return Tier (0-4)
     */
    function getTier(address user) public view returns (uint8) {
        uint256 points = getTotalPoints(user);
        if (points >= 10000) {
            return 4; // Diamond
        } else if (points >= 5000) {
            return 3; // Gold
        } else if (points >= 2500) {
            return 2; // Silver
        } else if (points >= 1000) {
            return 1; // Bronze
        }
        return 0; // No tier
    }

    /**
     * @dev Get user's staked amount
     * @param user Address of the user
     * @return Staked amount
     */
    function getStakedAmount(address user) public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < stakes[user].length; i++) {
            if (stakes[user][i].isActive) {
                total += stakes[user][i].amount;
            }
        }
        return total;
    }

    /**
     * @dev Get user's average stake duration in days
     * @param user Address of the user
     * @return Duration in days
     */
    function getAverageStakeDuration(address user) public view returns (uint256) {
        uint256 totalDuration = 0;
        uint256 activeStakes = 0;
        
        for (uint256 i = 0; i < stakes[user].length; i++) {
            if (stakes[user][i].isActive) {
                totalDuration += stakes[user][i].duration;
                activeStakes++;
            }
        }
        
        if (activeStakes == 0) return 0;
        return totalDuration / activeStakes / 1 days;
    }

    /**
     * @dev Get user's stake duration in days (legacy function for compatibility)
     * @param user Address of the user
     * @return Duration in days
     */
    function getStakeDuration(address user) external view returns (uint256) {
        return getAverageStakeDuration(user);
    }

    /**
     * @dev Slash staked tokens (called by LendingPool)
     * @param user Address of the user
     */
    function slashStakedTokens(address user) external onlyOwner {
        uint256 totalSlashed = 0;
        
        // Slash from all active stakes
        for (uint256 i = 0; i < stakes[user].length; i++) {
            StakeInfo storage stakeInfo = stakes[user][i];
            if (stakeInfo.isActive && stakeInfo.amount > 0) {
                uint256 amount = stakeInfo.amount;
                uint256 points = stakeInfo.points;
                
                // Update totals
                totalStaked -= amount;
                totalPoints -= points;
                userPoints[user] -= points;
                userTotalStaked[user] -= amount;
                totalSlashed += amount;
                
                // Mark stake as inactive
                stakeInfo.isActive = false;
                stakeInfo.amount = 0;
                stakeInfo.points = 0;
            }
        }
        
        require(totalSlashed > 0, "No active stakes found");

        // Debug log before burning
        emit DebugLog("Before burning", user);

        // Burn the slashed tokens
        MockERC20(address(metrikToken)).burn(totalSlashed);

        // Debug log after burning
        emit DebugLog("After burning", user);

        emit TokensSlashed(user, totalSlashed);
        emit PointsUpdated(user, userPoints[user]);
    }

    /**
     * @dev Get user's stake info
     * @param user Address of the user
     * @param stakeIndex Index of the stake
     * @return amount Stake amount
     * @return points Points
     * @return startTime Start time
     * @return lastUpdateTime Last update time
     * @return duration Duration
     * @return isActive Whether stake is active
     */
    function getStakeInfo(address user, uint256 stakeIndex) external view returns (
        uint256 amount,
        uint256 points,
        uint256 startTime,
        uint256 lastUpdateTime,
        uint256 duration,
        bool isActive
    ) {
        require(stakeIndex < stakes[user].length, "Invalid stake index");
        StakeInfo storage stakeInfo = stakes[user][stakeIndex];
        return (
            stakeInfo.amount,
            stakeInfo.points,
            stakeInfo.startTime,
            stakeInfo.lastUpdateTime,
            stakeInfo.duration,
            stakeInfo.isActive
        );
    }

    /**
     * @dev Update usedForBorrow for a user's stake records (FIFO)
     * @param user Address of the user
     * @param amount Amount to update
     * @param increase Whether to increase or decrease usage
     */
    function updateStakeUsage(address user, uint256 amount, bool increase) external onlyOwner {
        StakeRecord[] storage records = stakeHistory[user];
        uint256 remaining = amount;
        
        for (uint256 i = 0; i < records.length && remaining > 0; i++) {
            uint256 available = increase
                ? records[i].amount - records[i].usedForBorrow
                : records[i].usedForBorrow;
            uint256 delta = available < remaining ? available : remaining;
            
            if (increase) {
                records[i].usedForBorrow += delta;
                userTotalUsedForBorrow[user] += delta;
            } else {
                records[i].usedForBorrow -= delta;
                userTotalUsedForBorrow[user] -= delta;
            }
            remaining -= delta;
        }
    }

    /**
     * @dev Get stake usage for a user
     * @param user Address of the user
     * @return total Total staked amount
     * @return used Amount used for borrowing
     * @return free Free amount available
     */
    function getStakeUsage(address user) external view returns (uint256 total, uint256 used, uint256 free) {
        total = userTotalStaked[user];
        used = userTotalUsedForBorrow[user];
        free = total - used;
    }

    /**
     * @dev Get the length of stake history for a user
     * @param user Address of the user
     * @return Length of stake history
     */
    function getStakeHistoryLength(address user) external view returns (uint256) {
        return stakeHistory[user].length;
    }

    /**
     * @dev Get all active stakes for a user
     * @param user Address of the user
     * @return Array of active stakes
     */
    function getActiveStakes(address user) external view returns (StakeInfo[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < stakes[user].length; i++) {
            if (stakes[user][i].isActive) {
                activeCount++;
            }
        }
        
        StakeInfo[] memory activeStakes = new StakeInfo[](activeCount);
        uint256 currentIndex = 0;
        
        for (uint256 i = 0; i < stakes[user].length; i++) {
            if (stakes[user][i].isActive) {
                activeStakes[currentIndex] = stakes[user][i];
                currentIndex++;
            }
        }
        
        return activeStakes;
    }

    /**
     * @dev Get stake bonus table for display
     * @return amounts Array of tier amounts
     * @return durations Array of tier durations
     * @return bonuses Array of tier bonuses
     */
    function getStakeBonusTable() external pure returns (
        uint256[] memory amounts,
        uint256[] memory durations,
        uint256[] memory bonuses
    ) {
        amounts = new uint256[](4);
        durations = new uint256[](4);
        bonuses = new uint256[](4);
        
        // Bronze tier
        amounts[0] = BRONZE_TIER_MIN;
        durations[0] = 45 days;
        bonuses[0] = 500; // 5%
        
        // Silver tier
        amounts[1] = SILVER_TIER_MIN;
        durations[1] = 90 days;
        bonuses[1] = 1000; // 10%
        
        // Gold tier
        amounts[2] = GOLD_TIER_MIN;
        durations[2] = 180 days;
        bonuses[2] = 1500; // 15%
        
        // Diamond tier
        amounts[3] = DIAMOND_TIER_MIN;
        durations[3] = 365 days;
        bonuses[3] = 2000; // 20%
    }

    // Helper: get total points for a user
    function getTotalPoints(address user) public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < stakes[user].length; i++) {
            if (stakes[user][i].isActive) {
                total += stakes[user][i].points;
            }
        }
        return total;
    }

    /**
     * @dev Returns the APY for a given stake index for a user
     * @param user Address of the user
     * @param stakeIndex Index of the stake
     * @return apy APY in basis points (e.g., 800 = 8%)
     */
    function getStakeAPY(address user, uint256 stakeIndex) external view returns (uint256 apy) {
        require(stakeIndex < stakes[user].length, "Invalid stake index");
        return stakes[user][stakeIndex].apy;
    }

    /**
     * @dev Returns the APY for a given duration (in seconds)
     * @param duration Duration in seconds
     * @return apy APY in basis points (e.g., 800 = 8%)
     */
    function getAPYForDuration(uint256 duration) public pure returns (uint256 apy) {
        if (duration == 45 days) return 100; // 1%
        if (duration == 90 days) return 300; // 3%
        if (duration == 180 days) return 500; // 5%
        if (duration == 365 days) return 800; // 8%
        return 0;
    }
    // APY Table:
    // 45 days: 1%
    // 90 days: 3%
    // 180 days: 5%
    // 365 days: 8%

    // Helper: get multiplier for a specific stake
    function getStakeMultiplier(address user, uint256 stakeIndex) external view returns (uint256) {
        require(stakeIndex < stakes[user].length, "Invalid stake index");
        return stakes[user][stakeIndex].multiplier;
    }

    function pendingRewards(address user, uint256 stakeIndex) public view returns (uint256) {
        require(stakeIndex < stakes[user].length, "Invalid stake index");
        StakeInfo storage stake = stakes[user][stakeIndex];
        if (!stake.isActive || stake.amount == 0) return 0;
        uint256 endTime = block.timestamp > stake.startTime + stake.duration
            ? stake.startTime + stake.duration
            : block.timestamp;
        if (stake.lastClaimedTime >= endTime) return 0;
        uint256 timeElapsed = endTime - stake.lastClaimedTime;
        uint256 rewards = (stake.amount * stake.apy * timeElapsed) / (BASIS_POINTS * 365 days);
        return rewards;
    }

    function claimRewards(uint256 stakeIndex) external nonReentrant {
        require(stakeIndex < stakes[msg.sender].length, "Invalid stake index");
        StakeInfo storage stake = stakes[msg.sender][stakeIndex];
        require(stake.isActive && stake.amount > 0, "No active stake");
        uint256 rewards = pendingRewards(msg.sender, stakeIndex);
        require(rewards > 0, "No rewards to claim");
        stake.rewardDebt += rewards;
        stake.lastClaimedTime = block.timestamp > stake.startTime + stake.duration
            ? stake.startTime + stake.duration
            : block.timestamp;
        MockERC20(address(metrikToken)).mint(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, stakeIndex, rewards);
    }
} 