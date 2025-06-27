// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IOrderSlotCore {
    // Structs
    struct TokenInfo {
        bool supported;
        uint256 poolAmount;
        uint256 jackpotAmount;
        uint256 minBetAmount;
        uint256 totalBets;
        string tokenLogo;
    }
    
    struct Bet {
        address player;
        address token;
        uint256 amount;
        uint256 timestamp;
        bool processed;
        bool won;
        uint256 winAmount;
        uint256[] symbols;
        uint256 matchingSymbols;
    }

    struct PendingBet {
        address player;
        address token;
        uint256 amount;
        uint256 betId;
    }

    // Events
    event BetPlaced(address indexed player, address indexed token, uint256 amount, uint256 betId);
    event BetResult(address indexed player, address indexed token, uint256 amount, bool won, uint256 winAmount, uint256 matchingSymbols);
    event TokenAdded(address indexed token, uint256 minBetAmount, string tokenLogo);
    event TokenRemoved(address indexed token);
    event JackpotWon(address indexed player, address indexed token, uint256 amount);

    // Core Functions
    function addToken(address token, uint256 minBetAmount, string memory tokenLogo) external;
    function removeToken(address token) external;
    function placeBet(address token, uint256 amount, uint256 secret, uint256 salt) external;
    function revealBetResult(uint256 betId) external;
    function getMaxBetAmount(address token) external view returns (uint256);
    function getTokenInfo(address token) external view returns (TokenInfo memory);
    function isPendingBet(uint256 betId) external view returns (bool);
    
    // Pool management
    function addToPool(address token, uint256 amount) external;
    function addToJackpot(address token, uint256 amount) external;
    
    // Win calculation functions
    function calculateWinAmount(uint8[3] memory symbols, uint256 betAmount) external view returns (uint256);
    function checkWin(uint8[3] memory symbols) external pure returns (bool);
    function getMatchType(uint8[3] memory symbols) external pure returns (uint8);
}
