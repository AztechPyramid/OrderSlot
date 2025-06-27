// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IRewardsManager.sol";
import "./interfaces/IPoolManager.sol";

contract RewardsManager is IRewardsManager, Ownable, ReentrancyGuard {
    // Constants
    uint256 public constant MINIMUM_DISTRIBUTION_AMOUNT = 1 * 10**15; // 0.001 ORDER minimum

    // Contract references
    IPoolManager public poolManager;
    address public orderSlotCore;

    // State variables
    mapping(address => mapping(address => uint256)) public claimableRewards; // user => token => amount
    mapping(address => mapping(address => uint256)) public pendingRewards; // user => token => amount
    address[] public supportedTokens;

    // Custom errors
    error TokenNotSupported();
    error NoRewardsToClaim();
    error Unauthorized();

    constructor(address _poolManager) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
    }

    function setOrderSlotCore(address _orderSlotCore) external onlyOwner {
        orderSlotCore = _orderSlotCore;
    }

    function distributeRewards(address token, uint256 amount) external override {
        // Only OrderSlotCore should call this
        address[] memory contributors = poolManager.getTokenContributors(token);
        
        if (contributors.length == 0) {
            // If no contributors, keep the tokens (could be sent back to pool)
            return;
        }

        // Calculate total contributions for weight distribution
        uint256 totalContributions = 0;
        for (uint256 i = 0; i < contributors.length; i++) {
            (uint256 contributorAmount,,,) = poolManager.getUserContribution(contributors[i], token);
            if (contributorAmount > 0) {
                totalContributions += contributorAmount;
            }
        }

        if (totalContributions == 0) {
            return;
        }

        uint256 distributedAmount = 0;
        
        for (uint256 i = 0; i < contributors.length; i++) {
            (uint256 contributorAmount,,,) = poolManager.getUserContribution(contributors[i], token);
            
            if (contributorAmount > 0) {
                uint256 contributorShare = (amount * contributorAmount) / totalContributions;
                
                // Check minimum distribution
                if (contributorShare >= MINIMUM_DISTRIBUTION_AMOUNT) {
                    claimableRewards[contributors[i]][token] += contributorShare;
                    distributedAmount += contributorShare;
                }
            }
        }
        
        // Emit distribution event
        if (distributedAmount > 0) {
            emit RewardDistributed(token, distributedAmount, contributors.length);
        }
    }

    function claimRewards(address token) external override nonReentrant {
        uint256 rewardAmount = claimableRewards[msg.sender][token];
        if (rewardAmount == 0) revert NoRewardsToClaim();
        
        // Reset claimable rewards
        claimableRewards[msg.sender][token] = 0;
        
        // Transfer rewards to user
        IERC20(token).transfer(msg.sender, rewardAmount);
        
        emit RewardClaimed(msg.sender, token, rewardAmount);
    }

    function claimAllRewards() external override nonReentrant {
        bool hasClaimed = false;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            uint256 rewardAmount = claimableRewards[msg.sender][token];
            
            if (rewardAmount > 0) {
                claimableRewards[msg.sender][token] = 0;
                IERC20(token).transfer(msg.sender, rewardAmount);
                emit RewardClaimed(msg.sender, token, rewardAmount);
                hasClaimed = true;
            }
        }
        
        if (!hasClaimed) revert NoRewardsToClaim();
    }

    function claimPendingRewards(address token) external override nonReentrant {
        uint256 amount = pendingRewards[msg.sender][token];
        if (amount == 0) revert NoRewardsToClaim();
        
        pendingRewards[msg.sender][token] = 0;
        IERC20(token).transfer(msg.sender, amount);
        
        emit PendingRewardClaimed(msg.sender, token, amount);
    }

    function claimAllPendingRewards() external override nonReentrant {
        bool hasClaimed = false;
        
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            uint256 amount = pendingRewards[msg.sender][token];
            
            if (amount > 0) {
                pendingRewards[msg.sender][token] = 0;
                IERC20(token).transfer(msg.sender, amount);
                emit PendingRewardClaimed(msg.sender, token, amount);
                hasClaimed = true;
            }
        }
        
        if (!hasClaimed) revert NoRewardsToClaim();
    }

    function getClaimableRewards(address user, address token) external view override returns (uint256) {
        return claimableRewards[user][token];
    }

    function getAllClaimableRewards(address user) external view override returns (
        address[] memory tokens, 
        uint256[] memory amounts
    ) {
        address[] memory userTokens = poolManager.getUserContributedTokens(user);
        tokens = new address[](userTokens.length);
        amounts = new uint256[](userTokens.length);
        
        for (uint256 i = 0; i < userTokens.length; i++) {
            tokens[i] = userTokens[i];
            amounts[i] = claimableRewards[user][userTokens[i]];
        }
        
        return (tokens, amounts);
    }

    function getPendingRewards(address user, address token) external view override returns (uint256) {
        return pendingRewards[user][token];
    }

    function getAllPendingRewards(address user) external view override returns (
        address[] memory tokens, 
        uint256[] memory amounts
    ) {
        uint256 count = 0;
        
        // Count non-zero rewards
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (pendingRewards[user][supportedTokens[i]] > 0) {
                count++;
            }
        }
        
        tokens = new address[](count);
        amounts = new uint256[](count);
        
        uint256 index = 0;
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            address token = supportedTokens[i];
            uint256 amount = pendingRewards[user][token];
            if (amount > 0) {
                tokens[index] = token;
                amounts[index] = amount;
                index++;
            }
        }
        
        return (tokens, amounts);
    }

    function addPendingReward(address user, address token, uint256 amount) external override {
        // Only authorized contracts should call this
        pendingRewards[user][token] += amount;
        emit PendingRewardAdded(user, token, amount);
    }

    function getSupportedTokens() external view override returns (address[] memory) {
        return supportedTokens;
    }

    // Admin functions
    function addSupportedToken(address token) external onlyOwner {
        supportedTokens.push(token);
    }

    function removeSupportedToken(address token) external onlyOwner {
        for (uint256 i = 0; i < supportedTokens.length; i++) {
            if (supportedTokens[i] == token) {
                supportedTokens[i] = supportedTokens[supportedTokens.length - 1];
                supportedTokens.pop();
                break;
            }
        }
    }

    function setPoolManager(address _poolManager) external onlyOwner {
        poolManager = IPoolManager(_poolManager);
    }

    // Emergency function to recover stuck tokens
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).transfer(owner(), amount);
    }
}
