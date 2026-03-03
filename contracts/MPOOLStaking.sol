// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MPOOLStaking
 * @notice Stake MPOOL tokens, earn USDC rewards from protocol fees.
 *
 * Reward model: Synthetix StakingRewards pattern.
 * - Rewards are in USDC (exogenous yield, NOT more MPOOL).
 * - Only the FeeRouter/owner can deposit rewards via notifyRewardAmount().
 * - Stakers claim proportional USDC based on their MPOOL stake.
 *
 * CRITICAL INVARIANTS:
 * - MPOOL is NEVER used as collateral in insurance pools.
 * - Yield is exogenous (USDC from protocol fees).
 * - No inflationary emission — staking rewards come from real revenue.
 */
contract MPOOLStaking is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;   // MPOOL
    IERC20 public immutable rewardsToken;   // USDC

    address public owner;
    address public feeRouter;               // Only feeRouter or owner can notify rewards

    // Reward state (Synthetix pattern)
    uint256 public rewardPerTokenStored;
    uint256 public totalStaked;

    mapping(address => uint256) public stakedBalance;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // Stats
    uint256 public totalRewardsDistributed;
    uint256 public totalRewardsClaimed;

    // Events
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardNotified(uint256 reward);
    event FeeRouterUpdated(address indexed newRouter);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyRewardDistributor() {
        require(msg.sender == owner || msg.sender == feeRouter, "Not authorized");
        _;
    }

    modifier updateReward(address account) {
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    constructor(address _stakingToken, address _rewardsToken) {
        require(_stakingToken != address(0), "Invalid staking token");
        require(_rewardsToken != address(0), "Invalid rewards token");
        stakingToken = IERC20(_stakingToken);
        rewardsToken = IERC20(_rewardsToken);
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════
    // STAKING
    // ═══════════════════════════════════════════════════════════

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        totalStaked += amount;
        stakedBalance[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot unstake 0");
        require(stakedBalance[msg.sender] >= amount, "Insufficient staked balance");
        totalStaked -= amount;
        stakedBalance[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimReward() external nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            totalRewardsClaimed += reward;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function unstakeAndClaim() external nonReentrant updateReward(msg.sender) {
        uint256 staked = stakedBalance[msg.sender];
        uint256 reward = rewards[msg.sender];

        if (staked > 0) {
            totalStaked -= staked;
            stakedBalance[msg.sender] = 0;
            stakingToken.safeTransfer(msg.sender, staked);
            emit Unstaked(msg.sender, staked);
        }

        if (reward > 0) {
            rewards[msg.sender] = 0;
            totalRewardsClaimed += reward;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    // ═══════════════════════════════════════════════════════════
    // REWARD DISTRIBUTION (called by FeeRouter)
    // ═══════════════════════════════════════════════════════════

    /**
     * @notice Distribute USDC rewards to stakers. Instantly updates rewardPerToken.
     * @param reward Amount of USDC to distribute (must be pre-approved/transferred).
     */
    function notifyRewardAmount(uint256 reward) external onlyRewardDistributor {
        require(reward > 0, "Reward must be > 0");

        // Transfer USDC from caller
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);

        if (totalStaked > 0) {
            rewardPerTokenStored += (reward * 1e18) / totalStaked;
        }
        // If no stakers, reward stays in contract for next distribution cycle

        totalRewardsDistributed += reward;
        emit RewardNotified(reward);
    }

    // ═══════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════

    function earned(address account) public view returns (uint256) {
        return
            ((stakedBalance[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account])) / 1e18) +
            rewards[account];
    }

    function rewardPerToken() external view returns (uint256) {
        return rewardPerTokenStored;
    }

    function getStakeInfo(address account) external view returns (
        uint256 staked,
        uint256 pendingReward,
        uint256 totalStakedGlobal,
        uint256 totalDistributed,
        uint256 totalClaimed
    ) {
        return (
            stakedBalance[account],
            earned(account),
            totalStaked,
            totalRewardsDistributed,
            totalRewardsClaimed
        );
    }

    // ═══════════════════════════════════════════════════════════
    // ADMIN
    // ═══════════════════════════════════════════════════════════

    function setFeeRouter(address _feeRouter) external onlyOwner {
        feeRouter = _feeRouter;
        emit FeeRouterUpdated(_feeRouter);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}
