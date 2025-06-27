// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPoolManager {
    struct PoolContribution {
        uint256 amount;
        uint256 lockTime;
        bool isActive;
    }

    event PoolContributionMade(address indexed contributor, address indexed token, uint256 amount);
    event PoolContributionWithdrawn(address indexed contributor, address indexed token, uint256 amount);
    event EmergencyWithdrawal(address indexed contributor, address indexed token, uint256 amount, uint256 penalty);

    function contributeToPool(address token, uint256 amount) external;
    function withdrawContribution(address token, uint256 amount) external;
    function emergencyWithdraw(address token) external;
    function hasMinimumContribution(address user, address token) external view returns (bool);
    function getUserContribution(address user, address token) external view returns (
        uint256 amount,
        uint256 lockTime,
        bool isActive,
        bool canWithdraw
    );
    function getUserContributedTokens(address user) external view returns (address[] memory);
    function getUserContributions(address user) external view returns (address[] memory tokens, uint256[] memory amounts);
    function getTokenContributors(address token) external view returns (address[] memory);
    function getTotalContributions(address token) external view returns (uint256);
    function deductFromPools(address token, uint256 payoutAmount) external;
}
