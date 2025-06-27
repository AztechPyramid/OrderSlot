// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IRewardsManager {
    event RewardClaimed(address indexed user, address indexed token, uint256 amount);
    event PendingRewardClaimed(address indexed user, address indexed token, uint256 amount);
    event RewardDistributed(address indexed token, uint256 totalAmount, uint256 contributorCount);
    event PendingRewardAdded(address indexed user, address indexed token, uint256 amount);

    function distributeRewards(address token, uint256 amount) external;
    function claimRewards(address token) external;
    function claimAllRewards() external;
    function claimPendingRewards(address token) external;
    function claimAllPendingRewards() external;
    
    function getClaimableRewards(address user, address token) external view returns (uint256);
    function getAllClaimableRewards(address user) external view returns (address[] memory tokens, uint256[] memory amounts);
    function getPendingRewards(address user, address token) external view returns (uint256);
    function getAllPendingRewards(address user) external view returns (address[] memory tokens, uint256[] memory amounts);
    
    function addPendingReward(address user, address token, uint256 amount) external;
    function getSupportedTokens() external view returns (address[] memory);
}
