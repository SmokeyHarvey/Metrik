// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./LendingPool.sol";
import "./Staking.sol";

/**
 * @title RewardDistribution
 * @dev Handles distribution of interest to LPs and stakers
 */
contract RewardDistribution is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant LP_REWARD_SHARE = 8000; // 80% to LPs
    uint256 public constant STAKER_REWARD_SHARE = 2000; // 20% to stakers

    // State variables
    IERC20 public immutable stablecoin;
    LendingPool public immutable lendingPool;
    Staking public immutable staking;

    // Reward tracking
    uint256 public totalRewardsDistributed;
    mapping(address => uint256) public lpRewards;
    mapping(address => uint256) public stakerRewards;

    // Events
    event RewardsDistributed(uint256 lpAmount, uint256 stakerAmount);
    event RewardClaimed(address indexed user, uint256 amount, bool isLP);

    constructor(
        address _stablecoin,
        address _lendingPool,
        address _staking
    ) Ownable(msg.sender) {
        stablecoin = IERC20(_stablecoin);
        lendingPool = LendingPool(_lendingPool);
        staking = Staking(_staking);
    }

    /**
     * @dev Distribute rewards from interest payments
     * @param amount Total amount of interest to distribute
     */
    function distributeRewards(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(
            stablecoin.balanceOf(address(this)) >= amount,
            "Insufficient balance"
        );

        uint256 lpAmount = (amount * LP_REWARD_SHARE) / BASIS_POINTS;
        uint256 stakerAmount = amount - lpAmount;

        // Calculate LP rewards based on their share in the pool
        uint256 totalDeposits = lendingPool.totalDeposits();
        if (totalDeposits > 0) {
            // Get all LPs and their deposits
            address[] memory lps = getActiveLPs();
            for (uint256 i = 0; i < lps.length; i++) {
                address lp = lps[i];
                (uint256 depositAmount,,) = lendingPool.lpInfo(lp);
                uint256 lpShare = depositAmount;
                if (lpShare > 0) {
                    uint256 reward = (lpAmount * lpShare) / totalDeposits;
                    lpRewards[lp] += reward;
                }
            }
        }

        // Calculate staker rewards based on their tier
        uint256 totalStakerPoints = 0;
        address[] memory stakers = getActiveStakers();
        for (uint256 i = 0; i < stakers.length; i++) {
            uint256 tier = staking.getTier(stakers[i]);
            if (tier > 0) {
                totalStakerPoints += tier;
            }
        }

        if (totalStakerPoints > 0) {
            for (uint256 i = 0; i < stakers.length; i++) {
                uint256 tier = staking.getTier(stakers[i]);
                if (tier > 0) {
                    uint256 reward = (stakerAmount * tier) / totalStakerPoints;
                    stakerRewards[stakers[i]] += reward;
                }
            }
        }

        totalRewardsDistributed += amount;
        emit RewardsDistributed(lpAmount, stakerAmount);
    }

    /**
     * @dev Get all active LPs
     * @return Array of LP addresses
     */
    function getActiveLPs() public view returns (address[] memory) {
        // This is a simplified version. In production, you would want to maintain
        // a list of active LPs and update it when deposits are made/withdrawn
        return new address[](0);
    }

    /**
     * @dev Claim LP rewards
     */
    function claimLPRewards() external nonReentrant {
        uint256 amount = lpRewards[msg.sender];
        require(amount > 0, "No rewards to claim");
        
        lpRewards[msg.sender] = 0;
        stablecoin.safeTransfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, amount, true);
    }

    /**
     * @dev Claim staker rewards
     */
    function claimStakerRewards() external nonReentrant {
        uint256 amount = stakerRewards[msg.sender];
        require(amount > 0, "No rewards to claim");
        
        stakerRewards[msg.sender] = 0;
        stablecoin.safeTransfer(msg.sender, amount);

        emit RewardClaimed(msg.sender, amount, false);
    }

    /**
     * @dev Get all active stakers
     * @return Array of staker addresses
     */
    function getActiveStakers() public view returns (address[] memory) {
        // This is a simplified version. In production, you would want to maintain
        // a list of active stakers and update it when stakes are created/removed
        return new address[](0);
    }

    /**
     * @dev Get pending rewards for an LP
     * @param lp Address of the LP
     * @return Amount of pending rewards
     */
    function getPendingLPRewards(address lp) external view returns (uint256) {
        return lpRewards[lp];
    }

    /**
     * @dev Get pending rewards for a staker
     * @param staker Address of the staker
     * @return Amount of pending rewards
     */
    function getPendingStakerRewards(address staker) external view returns (uint256) {
        return stakerRewards[staker];
    }
} 