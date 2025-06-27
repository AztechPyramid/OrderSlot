// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IOrderSlotCore.sol";
import "./interfaces/IPoolManager.sol";
import "./interfaces/IRewardsManager.sol";
import "./interfaces/ISecureRandomness.sol";

contract OrderSlotCore is IOrderSlotCore, IRandomnessConsumer, Ownable, ReentrancyGuard {
    // Constants
    address public constant TEAM_WALLET = 0xB799CD1f2ED5dB96ea94EdF367fBA2d90dfd9634;
    uint256 public constant TEAM_PERCENTAGE = 10;
    uint256 public constant POOL_PERCENTAGE = 40;
    uint256 public constant CONTRIBUTORS_PERCENTAGE = 15;
    uint256 public constant MINIMUM_BET_AMOUNT = 1 * 10**18; // 1 ORDER
    uint256 public constant SYMBOLS_COUNT = 4;
    uint256 public constant FOUR_MATCHING_MULTIPLIER = 25;
    uint256 public constant THREE_MATCHING_MULTIPLIER = 8;
    uint256 public constant TWO_MATCHING_MULTIPLIER = 3;

    // Contract references
    IPoolManager public poolManager;
    IRewardsManager public rewardsManager;
    ISecureRandomness public secureRandomness;

    // State variables
    mapping(address => TokenInfo) public supportedTokens;
    address[] public supportedTokensList;
    mapping(uint256 => PendingBet) public pendingBets;
    mapping(address => Bet[]) public playerBets;
    mapping(uint256 => uint256) private randomnessRequestToBetId; // Randomness request ID to bet ID mapping
    mapping(uint256 => uint256) private betIdToRandomnessRequest; // Bet ID to randomness request ID mapping
    mapping(uint256 => bool) private betProcessed;
    mapping(uint256 => uint256) private betSecrets; // Store user secrets for reveal
    mapping(uint256 => uint256) private betSalts; // Store user salts for reveal
    
    uint256 private betCounter = 0;
    uint256 public lastJackpotTime;
    uint256 public jackpotMinDuration = 7 days;

    // Custom errors
    error TokenNotSupported();
    error BetTooLarge();
    error BetTooSmall();
    error InsufficientPoolSize();
    error InvalidBetId();
    error InsufficientContribution();
    error RandomnessNotReady();
    error UnauthorizedRandomnessCaller();

    constructor(
        address _poolManager,
        address _rewardsManager,
        address _secureRandomness
    ) Ownable(msg.sender) {
        poolManager = IPoolManager(_poolManager);
        rewardsManager = IRewardsManager(_rewardsManager);
        secureRandomness = ISecureRandomness(_secureRandomness);
        lastJackpotTime = block.timestamp;
    }

    function addToken(
        address token,
        uint256 minBetAmount,
        string memory tokenLogo
    ) external override onlyOwner {
        if (token == address(0)) revert TokenNotSupported();
        if (supportedTokens[token].supported) revert TokenNotSupported();

        supportedTokens[token] = TokenInfo({
            supported: true,
            poolAmount: 0,
            jackpotAmount: 0,
            minBetAmount: minBetAmount,
            totalBets: 0,
            tokenLogo: tokenLogo
        });

        supportedTokensList.push(token);
        emit TokenAdded(token, minBetAmount, tokenLogo);
    }

    function removeToken(address token) external override onlyOwner {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
        if (supportedTokens[token].poolAmount != 0) revert InsufficientPoolSize();
        if (supportedTokens[token].jackpotAmount != 0) revert InsufficientPoolSize();

        supportedTokens[token].supported = false;
        
        // Remove from list
        for (uint256 i = 0; i < supportedTokensList.length; i++) {
            if (supportedTokensList[i] == token) {
                supportedTokensList[i] = supportedTokensList[supportedTokensList.length - 1];
                supportedTokensList.pop();
                break;
            }
        }

        emit TokenRemoved(token);
    }

    function placeBet(address token, uint256 amount, uint256 secret, uint256 salt) external nonReentrant {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
        if (amount < MINIMUM_BET_AMOUNT) revert BetTooSmall();
        if (!poolManager.hasMinimumContribution(msg.sender, token)) revert InsufficientContribution();

        TokenInfo storage tokenInfo = supportedTokens[token];
        uint256 maxBetAmount = getMaxBetAmount(token);
        if (maxBetAmount == 0) revert InsufficientPoolSize();
        if (amount > maxBetAmount) revert BetTooLarge();

        // Transfer tokens
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        // Distribute bet amount
        uint256 teamAmount = (amount * TEAM_PERCENTAGE) / 100;
        uint256 poolAmount = (amount * POOL_PERCENTAGE) / 100;
        uint256 contributorsAmount = (amount * CONTRIBUTORS_PERCENTAGE) / 100;
        uint256 jackpotAmount = (amount * 10) / 100; // 10% to jackpot
        uint256 remainingAmount = amount - teamAmount - poolAmount - contributorsAmount - jackpotAmount;

        // Transfer team amount
        IERC20(token).transfer(TEAM_WALLET, teamAmount);

        // Update pool and jackpot
        tokenInfo.poolAmount += poolAmount;
        tokenInfo.jackpotAmount += jackpotAmount;
        tokenInfo.totalBets += amount;

        // Distribute to contributors via RewardsManager
        if (contributorsAmount > 0) {
            IERC20(token).transfer(address(rewardsManager), contributorsAmount);
            rewardsManager.distributeRewards(token, contributorsAmount);
        }

        // Create bet
        betCounter++;
        
        // Generate commitment hash (use contract address since SecureRandomness expects msg.sender=OrderSlotCore)
        bytes32 commitmentHash = keccak256(abi.encodePacked(secret, salt, address(this), betCounter));
        
        // Commit to randomness request
        uint256 randomnessRequestId = secureRandomness.commitRandomnessRequest(betCounter, commitmentHash);

        pendingBets[betCounter] = PendingBet({
            player: msg.sender,
            token: token,
            amount: amount,
            betId: betCounter
        });
        
        // Store secrets for later reveal
        betSecrets[betCounter] = secret;
        betSalts[betCounter] = salt;
        
        // Map randomness request to bet ID (both ways)
        randomnessRequestToBetId[randomnessRequestId] = betCounter;
        betIdToRandomnessRequest[betCounter] = randomnessRequestId;

        emit BetPlaced(msg.sender, token, amount, betCounter);
    }

    function revealBetResult(uint256 betId) external override nonReentrant {
        PendingBet memory bet = pendingBets[betId];
        if (bet.player != msg.sender) revert InvalidBetId();
        if (betProcessed[betId]) revert InvalidBetId();
        
        // Get stored secrets
        uint256 secret = betSecrets[betId];
        uint256 salt = betSalts[betId];
        
        // Find the randomness request ID for this bet
        uint256 randomnessRequestId = betIdToRandomnessRequest[betId];
        if (randomnessRequestId == 0) revert InvalidBetId();
        
        // Check if commit is ready to be revealed
        if (!secureRandomness.isCommitReady(randomnessRequestId)) revert RandomnessNotReady();
        
        // Reveal randomness - this will trigger the callback
        secureRandomness.revealRandomness(randomnessRequestId, secret, salt);
    }

    /**
     * @dev Callback function called by SecureRandomness contract
     * @param betId The bet ID to reveal
     * @param symbols The secure random symbols from Chainlink VRF
     */
    function fulfillRandomness(uint256 betId, uint256[] memory symbols) external override {
        if (msg.sender != address(secureRandomness)) revert UnauthorizedRandomnessCaller();
        if (betId == 0 || betId > betCounter) revert InvalidBetId();
        if (betProcessed[betId]) revert InvalidBetId();

        PendingBet memory bet = pendingBets[betId];
        if (bet.player == address(0)) revert InvalidBetId();

        betProcessed[betId] = true;
        
        // Process the symbols directly
        _processBetResult(bet.player, bet.token, bet.amount, symbols);
        delete pendingBets[betId];
    }

    function getMaxBetAmount(address token) public view override returns (uint256) {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
        TokenInfo storage tokenInfo = supportedTokens[token];

        if (tokenInfo.poolAmount == 0) return 0;
        return tokenInfo.poolAmount / FOUR_MATCHING_MULTIPLIER;
    }

    function getTokenInfo(address token) external view override returns (TokenInfo memory) {
        return supportedTokens[token];
    }

    function isPendingBet(uint256 betId) external view override returns (bool) {
        return pendingBets[betId].player != address(0) && !betProcessed[betId];
    }

    function addToPool(address token, uint256 amount) external override {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
        // Only update pool amount, don't transfer tokens (tokens are managed by PoolManager)
        supportedTokens[token].poolAmount += amount;
    }

    function addToJackpot(address token, uint256 amount) external override {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        supportedTokens[token].jackpotAmount += amount;
    }

    // Win calculation functions
    function calculateWinAmount(uint8[3] memory symbols, uint256 betAmount) external view returns (uint256) {
        uint8 matchType = this.getMatchType(symbols);
        
        if (matchType == 0) return 0; // No match
        
        uint256 multiplier;
        if (matchType == 4) {
            multiplier = FOUR_MATCHING_MULTIPLIER;
        } else if (matchType == 3) {
            multiplier = THREE_MATCHING_MULTIPLIER;
        } else if (matchType == 2) {
            multiplier = TWO_MATCHING_MULTIPLIER;
        }
        
        return (betAmount * multiplier) / 10;
    }
    
    function checkWin(uint8[3] memory symbols) external pure returns (bool) {
        return (symbols[0] == symbols[1] || symbols[1] == symbols[2] || symbols[0] == symbols[2]);
    }
    
    function getMatchType(uint8[3] memory symbols) external pure returns (uint8) {
        if (symbols[0] == symbols[1] && symbols[1] == symbols[2]) {
            return 4; // All match (treat as 4-match)
        } else if (symbols[0] == symbols[1] || symbols[1] == symbols[2] || symbols[0] == symbols[2]) {
            uint256 matches = 0;
            if (symbols[0] == symbols[1]) matches++;
            if (symbols[1] == symbols[2]) matches++;
            if (symbols[0] == symbols[2]) matches++;
            
            if (matches >= 2) return 3; // 3-match
            return 2; // 2-match
        }
        return 0; // No match
    }

    // Private functions

    function _processBetResult(
        address player,
        address token,
        uint256 amount,
        uint256[] memory symbols
    ) private {
        TokenInfo storage tokenInfo = supportedTokens[token];
        
        uint256 mostFrequentSymbol = _findMostFrequentSymbol(symbols);
        uint256 matchingCount = _countMatchingSymbols(symbols, mostFrequentSymbol);
        
        uint256 winAmount = 0;
        bool won = false;

        // Check for jackpot
        if (matchingCount == SYMBOLS_COUNT && 
            block.timestamp >= lastJackpotTime + jackpotMinDuration &&
            tokenInfo.jackpotAmount > 0) {
            winAmount = tokenInfo.jackpotAmount;
            tokenInfo.jackpotAmount = 0;
            lastJackpotTime = block.timestamp;
            won = true;
            emit JackpotWon(player, token, winAmount);
        }
        // Normal wins
        else if (matchingCount >= 2) {
            uint256 multiplier = 0;
            uint256 minimumPayout = 0;

            if (matchingCount == 4) {
                multiplier = FOUR_MATCHING_MULTIPLIER;
                minimumPayout = amount * 15;
            } else if (matchingCount == 3) {
                multiplier = THREE_MATCHING_MULTIPLIER;
                minimumPayout = amount * 5;
            } else if (matchingCount == 2) {
                multiplier = TWO_MATCHING_MULTIPLIER;
                minimumPayout = amount * 2;
            }

            uint256 baseWinAmount = (amount * multiplier) / 10;
            winAmount = baseWinAmount > minimumPayout ? baseWinAmount : minimumPayout;

            if (winAmount > tokenInfo.poolAmount) {
                winAmount = tokenInfo.poolAmount;
            }

            if (winAmount > 0) {
                tokenInfo.poolAmount -= winAmount;
                won = true;
            }
        }

        // Transfer winnings from pool via PoolManager
        if (winAmount > 0) {
            // Request payout from PoolManager - this will deduct from contributors
            IPoolManager(poolManager).deductFromPools(token, winAmount);
            // PoolManager will transfer the funds to this contract, then we transfer to player
            IERC20(token).transfer(player, winAmount);
        }

        // Record bet
        playerBets[player].push(Bet({
            player: player,
            token: token,
            amount: amount,
            timestamp: block.timestamp,
            processed: true,
            won: won,
            winAmount: winAmount,
            symbols: symbols,
            matchingSymbols: matchingCount
        }));

        emit BetResult(player, token, amount, won, winAmount, matchingCount);
    }

    function _findMostFrequentSymbol(uint256[] memory symbols) private pure returns (uint256) {
        uint256 mostFrequent = symbols[0];
        uint256 maxCount = 1;

        for (uint256 i = 0; i < symbols.length; i++) {
            uint256 current = symbols[i];
            uint256 count = 1;

            for (uint256 j = i + 1; j < symbols.length; j++) {
                if (symbols[j] == current) {
                    count++;
                }
            }

            if (count > maxCount) {
                maxCount = count;
                mostFrequent = current;
            }
        }

        return mostFrequent;
    }

    function _countMatchingSymbols(uint256[] memory symbols, uint256 symbol) private pure returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < symbols.length; i++) {
            if (symbols[i] == symbol) {
                count++;
            }
        }
        return count;
    }

    // Admin functions
    function withdrawFunds(address token, uint256 amount) external onlyOwner {
        if (!supportedTokens[token].supported) revert TokenNotSupported();
        if (amount > supportedTokens[token].poolAmount) revert InsufficientPoolSize();
        
        supportedTokens[token].poolAmount -= amount;
        IERC20(token).transfer(owner(), amount);
    }

    function setPoolManager(address _poolManager) external onlyOwner {
        poolManager = IPoolManager(_poolManager);
    }

    function setRewardsManager(address _rewardsManager) external onlyOwner {
        rewardsManager = IRewardsManager(_rewardsManager);
    }

    function setSecureRandomness(address _secureRandomness) external onlyOwner {
        secureRandomness = ISecureRandomness(_secureRandomness);
    }
}
