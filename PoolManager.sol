// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IPoolManager.sol";
import "./interfaces/IOrderSlotCore.sol";

// Interface for the external staking contract
interface IStakingContract {
    function balanceOf(address user) external view returns (uint256);
}

contract PoolManager is IPoolManager, Ownable, ReentrancyGuard {
    // Constants
    address public constant TEAM_WALLET = 0xB799CD1f2ED5dB96ea94EdF367fBA2d90dfd9634;
    uint256 public constant MINIMUM_STAKE_REQUIREMENT = 10_000_000 * 10**18; // 10M ORDER
    uint256 public constant LOCK_PERIOD = 7 days;
    uint256 public constant EMERGENCY_PENALTY = 25; // 25% penalty

    // State variables
    address public orderSlotCore;
    address public stakingContractAddress; // External staking contract
    
    // Pool contributions in supported tokens (USDT, USDC, etc.) - NOT ORDER tokens
    mapping(address => mapping(address => PoolContribution)) public poolContributions;
    mapping(address => address[]) public userContributedTokens;
    mapping(address => address[]) public tokenContributors;
    mapping(address => bool) public supportedTokens;

    // Custom errors
    error InsufficientStaking(); // User doesn't have 10M ORDER staked
    error TokenNotSupported();
    error ContributionLocked();
    error NoActiveContribution();
    error InsufficientAmount();
    error StakingContractNotSet();

    constructor(address _stakingContractAddress) Ownable(msg.sender) {
        stakingContractAddress = _stakingContractAddress;
    }

    function setOrderSlotCore(address _orderSlotCore) external onlyOwner {
        orderSlotCore = _orderSlotCore;
    }

    function setStakingContract(address _stakingContractAddress) external onlyOwner {
        stakingContractAddress = _stakingContractAddress;
    }

    function setSupportedToken(address token, bool supported) external onlyOwner {
        supportedTokens[token] = supported;
    }

    function contributeToPool(address token, uint256 amount) external nonReentrant {
        if (stakingContractAddress == address(0)) revert StakingContractNotSet();
        if (!supportedTokens[token]) revert TokenNotSupported();
        
        // Check if user has staked at least 10M ORDER in the staking contract
        if (!_hasMinimumStake(msg.sender)) revert InsufficientStaking();
        
        // Transfer supported tokens (USDT, USDC, etc.) from user to contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        // Update user's contribution
        PoolContribution storage contribution = poolContributions[msg.sender][token];
        
        if (!contribution.isActive) {
            // First time contributing to this token
            userContributedTokens[msg.sender].push(token);
            tokenContributors[token].push(msg.sender);
        }
        
        contribution.amount += amount;
        contribution.lockTime = block.timestamp + LOCK_PERIOD;
        contribution.isActive = true;
        
        // Notify OrderSlotCore about pool contribution
        if (orderSlotCore != address(0)) {
            IOrderSlotCore(orderSlotCore).addToPool(token, amount);
        }
        
        emit PoolContributionMade(msg.sender, token, amount);
    }

    function withdrawContribution(address token, uint256 amount) external nonReentrant {
        PoolContribution storage contribution = poolContributions[msg.sender][token];
        
        if (!contribution.isActive) revert NoActiveContribution();
        if (contribution.amount < amount) revert InsufficientAmount();
        if (block.timestamp < contribution.lockTime) revert ContributionLocked();
        
        contribution.amount -= amount;
        
        if (contribution.amount == 0) {
            contribution.isActive = false;
            _removeFromContributorLists(msg.sender, token);
        }
        
        // Transfer supported tokens back to user
        IERC20(token).transfer(msg.sender, amount);
        
        emit PoolContributionWithdrawn(msg.sender, token, amount);
    }

    function emergencyWithdraw(address token) external nonReentrant {
        PoolContribution storage contribution = poolContributions[msg.sender][token];
        
        if (!contribution.isActive) revert NoActiveContribution();
        if (contribution.amount == 0) revert InsufficientAmount();
        
        uint256 amount = contribution.amount;
        uint256 penalty = (amount * EMERGENCY_PENALTY) / 100;
        uint256 withdrawAmount = amount - penalty;
        
        // Reset contribution
        contribution.amount = 0;
        contribution.isActive = false;
        
        // Remove from contributor lists
        _removeFromContributorLists(msg.sender, token);
        
        // Transfer penalty to team wallet
        IERC20(token).transfer(TEAM_WALLET, penalty);
        
        // Transfer remaining amount to user
        IERC20(token).transfer(msg.sender, withdrawAmount);
        
        emit EmergencyWithdrawal(msg.sender, token, withdrawAmount, penalty);
    }

    function hasMinimumContribution(address user, address token) external view returns (bool) {
        // User must have 10M ORDER staked AND have active contribution in the token
        return _hasMinimumStake(user) && 
               poolContributions[user][token].isActive;
    }

    function getUserContribution(address user, address token) external view returns (
        uint256 amount,
        uint256 lockTime,
        bool isActive,
        bool canWithdraw
    ) {
        PoolContribution storage contribution = poolContributions[user][token];
        return (
            contribution.amount,
            contribution.lockTime,
            contribution.isActive,
            block.timestamp >= contribution.lockTime
        );
    }

    function getUserContributedTokens(address user) external view returns (address[] memory) {
        return userContributedTokens[user];
    }

    function getTokenContributors(address token) external view returns (address[] memory) {
        return tokenContributors[token];
    }

    function getTotalContributions(address token) external view returns (uint256) {
        address[] memory contributors = tokenContributors[token];
        uint256 total = 0;
        
        for (uint256 i = 0; i < contributors.length; i++) {
            if (poolContributions[contributors[i]][token].isActive) {
                total += poolContributions[contributors[i]][token].amount;
            }
        }
        
        return total;
    }

    // Private functions
    function _removeFromContributorLists(address user, address token) private {
        // Remove from userContributedTokens
        address[] storage userTokens = userContributedTokens[user];
        for (uint256 i = 0; i < userTokens.length; i++) {
            if (userTokens[i] == token) {
                userTokens[i] = userTokens[userTokens.length - 1];
                userTokens.pop();
                break;
            }
        }
        
        // Remove from tokenContributors
        address[] storage contributors = tokenContributors[token];
        for (uint256 i = 0; i < contributors.length; i++) {
            if (contributors[i] == user) {
                contributors[i] = contributors[contributors.length - 1];
                contributors.pop();
                break;
            }
        }
    }

    // Admin functions
    function setStakingContractAddress(address _stakingContractAddress) external onlyOwner {
        stakingContractAddress = _stakingContractAddress;
    }

    function getContributorInfo(address user, address token) external view returns (PoolContribution memory) {
        return poolContributions[user][token];
    }

    function getUserContributions(address user) external view returns (address[] memory tokens, uint256[] memory amounts) {
        address[] memory userTokens = userContributedTokens[user];
        tokens = new address[](userTokens.length);
        amounts = new uint256[](userTokens.length);
        
        for (uint256 i = 0; i < userTokens.length; i++) {
            tokens[i] = userTokens[i];
            amounts[i] = poolContributions[user][userTokens[i]].amount;
        }
    }

    // Pool deduction function for payouts (called by OrderSlotCore)
    function deductFromPools(address token, uint256 payoutAmount) external {
        require(msg.sender == orderSlotCore, "Only OrderSlotCore can deduct from pools");
        require(supportedTokens[token], "Token not supported");
        
        // Get all contributors for this token
        address[] memory contributors = tokenContributors[token];
        uint256 totalContributions = this.getTotalContributions(token);
        
        require(totalContributions >= payoutAmount, "Insufficient pool funds");
        
        // Deduct proportionally from each contributor
        for (uint256 i = 0; i < contributors.length; i++) {
            address contributor = contributors[i];
            PoolContribution storage contribution = poolContributions[contributor][token];
            
            if (contribution.isActive && contribution.amount > 0) {
                uint256 contributorShare = (contribution.amount * payoutAmount) / totalContributions;
                contribution.amount -= contributorShare;
                
                // If contribution becomes zero, deactivate
                if (contribution.amount == 0) {
                    contribution.isActive = false;
                    _removeFromContributorLists(contributor, token);
                }
            }
        }
        
        // Transfer payout to OrderSlotCore
        IERC20(token).transfer(orderSlotCore, payoutAmount);
    }

    // Private helper function to check staking requirement
    function _hasMinimumStake(address user) private view returns (bool) {
        if (stakingContractAddress == address(0)) return false;
        
        // Call the staking contract to check if user has staked at least 10M ORDER
        // Using balanceOf which returns the staked amount in the real staking contract
        try IStakingContract(stakingContractAddress).balanceOf(user) returns (uint256 stakedAmount) {
            return stakedAmount >= MINIMUM_STAKE_REQUIREMENT;
        } catch {
            return false;
        }
    }
}
