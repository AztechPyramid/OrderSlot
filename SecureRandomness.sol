// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ISecureRandomness.sol";

/**
 * @title SecureRandomness
 * @dev Güçlü rastgelelik sistemi - Commit-Reveal + Multi-Entropy kaynaklı
 * @notice Bu contract, manipüle edilemeyen rastgele sayılar sağlar
 * 
 * GÜVENLİK ÖZELLİKLERİ:
 * 1. Commit-Reveal Pattern: Kullanıcı önce hash commit eder, sonra reveal yapar
 * 2. Multi-Block Entropy: Birden fazla block'tan entropy toplar
 * 3. User Nonce: Her kullanıcı için unique nonce
 * 4. Time-based Delays: Commit ve reveal arasında minimum zaman gereklidir
 * 5. External Entropy: Block hash, timestamp, difficulty gibi external faktörler
 */

contract SecureRandomness is ISecureRandomness, Ownable {
    // Commit-Reveal yapısı
    struct EntropyBlock {
        bytes32 blockHash;
        uint256 blockNumber;
        uint256 timestamp;
        uint256 difficulty;
    }
    
    // Constants
    uint256 private constant MIN_COMMIT_DELAY = 2; // Minimum 2 block bekle
    uint256 private constant MAX_COMMIT_DELAY = 255; // Maximum 255 block (gas limit)
    uint256 private constant ENTROPY_BLOCKS = 5; // 5 block'tan entropy topla
    uint256 private constant NUM_SYMBOLS = 4; // 4 symbol generate et
    
    // State variables
    mapping(uint256 => CommitData) public commits;
    mapping(address => uint256) public userNonces;
    mapping(address => bool) public authorizedCallers;
    mapping(uint256 => EntropyBlock[]) private entropyHistory;
    
    uint256 private requestCounter;
    uint256 private globalEntropy;
    
    // Custom errors
    error UnauthorizedCaller();
    error InvalidCommitment();
    error CommitNotReady();
    error CommitExpired();
    error CommitAlreadyRevealed();
    error InvalidRevealData();
    constructor() Ownable(msg.sender) {
        // Initialize global entropy with contract deployment entropy
        globalEntropy = uint256(keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            block.number,
            msg.sender,
            address(this)
        )));
        
        // Start gathering entropy immediately
        _gatherBlockEntropy();
    }
    
    /**
     * @dev Authorize a contract to request randomness
     */
    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
    }
    
    /**
     * @dev PHASE 1: Commit to randomness request
     * @param betId The bet ID to associate with this randomness request
     * @param secretHash User's secret combined with other data (keccak256(secret + salt))
     * @return requestId The unique request ID
     */
    function commitRandomnessRequest(uint256 betId, bytes32 secretHash) 
        external 
        returns (uint256 requestId) 
    {
        if (!authorizedCallers[msg.sender]) revert UnauthorizedCaller();
        if (secretHash == bytes32(0)) revert InvalidCommitment();
        
        requestCounter++;
        requestId = requestCounter;
        
        // Increment user nonce for extra security
        userNonces[msg.sender]++;
        
        // Store commit data
        commits[requestId] = CommitData({
            commitment: secretHash,
            blockNumber: block.number,
            timestamp: block.timestamp,
            user: msg.sender,
            betId: betId,
            revealed: false,
            fulfilled: false
        });
        
        // Gather entropy from current block
        _gatherBlockEntropy();
        
        emit CommitMade(requestId, msg.sender, betId, secretHash);
        return requestId;
    }
    
    /**
     * @dev PHASE 2: Reveal and generate randomness
     * @param requestId The request ID from commit phase
     * @param secret The original secret used in commit
     * @param salt Additional salt used in commit
     */
    function revealRandomness(uint256 requestId, uint256 secret, uint256 salt) external {
        CommitData storage commit = commits[requestId];
        
        if (commit.user != msg.sender) revert UnauthorizedCaller();
        if (commit.revealed) revert CommitAlreadyRevealed();
        if (commit.blockNumber + MAX_COMMIT_DELAY < block.number) revert CommitExpired();
        if (commit.blockNumber + MIN_COMMIT_DELAY > block.number) revert CommitNotReady();
        
        // Verify commitment
        bytes32 computedHash = keccak256(abi.encodePacked(secret, salt, msg.sender, commit.betId));
        if (computedHash != commit.commitment) revert InvalidRevealData();
        
        commit.revealed = true;
        commit.fulfilled = true;
        
        // Generate secure randomness using multi-source entropy
        uint256[] memory symbols = _generateSecureRandomness(requestId, secret, salt);
        
        emit RandomnessRevealed(requestId, symbols);
        
        // Call back to the requesting contract
        IRandomnessConsumer(commit.user).fulfillRandomness(commit.betId, symbols);
    }
    
    /**
     * @dev Generate cryptographically secure randomness
     */
    function _generateSecureRandomness(uint256 requestId, uint256 secret, uint256 salt) 
        private 
        returns (uint256[] memory) 
    {
        CommitData storage commit = commits[requestId];
        
        // Gather multi-block entropy
        bytes32[] memory blockHashes = new bytes32[](ENTROPY_BLOCKS);
        for (uint256 i = 0; i < ENTROPY_BLOCKS; i++) {
            uint256 blockNum = block.number - 1 - i;
            if (blockNum < commit.blockNumber) break;
            blockHashes[i] = blockhash(blockNum);
        }
        
        // Update global entropy with current state
        globalEntropy = uint256(keccak256(abi.encodePacked(
            globalEntropy,
            block.prevrandao,
            secret,
            salt
        )));
        
        // Split entropy combination into smaller parts to avoid stack too deep
        bytes32 part1 = keccak256(abi.encodePacked(
            secret,
            salt,
            commit.user,
            commit.betId,
            userNonces[commit.user]
        ));
        
        bytes32 part2 = keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            block.number,
            globalEntropy
        ));
        
        bytes32 part3 = keccak256(abi.encodePacked(
            blockHashes,
            requestId,
            address(this).balance
        ));
        
        bytes32 finalSeed = keccak256(abi.encodePacked(part1, part2, part3));
        
        // Generate symbols using the secure seed
        uint256[] memory symbols = new uint256[](NUM_SYMBOLS);
        for (uint256 i = 0; i < NUM_SYMBOLS; i++) {
            bytes32 symbolSeed = keccak256(abi.encodePacked(finalSeed, i, userNonces[commit.user]));
            symbols[i] = uint256(symbolSeed) % 10; // 0-9 range for balanced gameplay
        }
        
        return symbols;
    }
    
    /**
     * @dev Gather entropy from current block
     */
    function _gatherBlockEntropy() private {
        EntropyBlock memory entropy = EntropyBlock({
            blockHash: blockhash(block.number - 1),
            blockNumber: block.number,
            timestamp: block.timestamp,
            difficulty: block.difficulty
        });
        
        entropyHistory[block.number].push(entropy);
        emit EntropyGathered(block.number, entropy.blockHash);
        
        // Update global entropy
        globalEntropy = uint256(keccak256(abi.encodePacked(
            globalEntropy,
            entropy.blockHash,
            entropy.timestamp,
            entropy.difficulty
        )));
    }
    
    /**
     * @dev Emergency function to force reveal (only owner, for stuck requests)
     */
    function emergencyReveal(uint256 requestId) external onlyOwner {
        CommitData storage commit = commits[requestId];
        
        if (commit.revealed || commit.fulfilled) revert CommitAlreadyRevealed();
        if (commit.blockNumber + MAX_COMMIT_DELAY >= block.number) revert CommitNotReady();
        
        commit.revealed = true;
        commit.fulfilled = true;
        
        // Generate emergency randomness using only blockchain entropy
        uint256[] memory symbols = _generateEmergencyRandomness(requestId);
        
        emit RandomnessRevealed(requestId, symbols);
        IRandomnessConsumer(commit.user).fulfillRandomness(commit.betId, symbols);
    }
    
    /**
     * @dev Generate emergency randomness (less secure, only for emergencies)
     */
    function _generateEmergencyRandomness(uint256 requestId) private view returns (uint256[] memory) {
        CommitData storage commit = commits[requestId];
        
        bytes32 emergencySeed = keccak256(abi.encodePacked(
            block.prevrandao,
            block.timestamp,
            block.number,
            commit.user,
            commit.betId,
            requestId,
            globalEntropy
        ));
        
        uint256[] memory symbols = new uint256[](NUM_SYMBOLS);
        for (uint256 i = 0; i < NUM_SYMBOLS; i++) {
            symbols[i] = uint256(keccak256(abi.encodePacked(emergencySeed, i))) % 10;
        }
        
        return symbols;
    }
    
    /**
     * @dev Check if a commit is ready to be revealed
     */
    function isCommitReady(uint256 requestId) external view returns (bool) {
        CommitData storage commit = commits[requestId];
        return (
            commit.blockNumber + MIN_COMMIT_DELAY <= block.number &&
            commit.blockNumber + MAX_COMMIT_DELAY >= block.number &&
            !commit.revealed
        );
    }
    
    /**
     * @dev Get commit information
     */
    function getCommitInfo(uint256 requestId) external view returns (
        bytes32 commitment,
        uint256 blockNumber,
        uint256 timestamp,
        address user,
        uint256 betId,
        bool revealed,
        bool fulfilled
    ) {
        CommitData storage commit = commits[requestId];
        return (
            commit.commitment,
            commit.blockNumber,
            commit.timestamp,
            commit.user,
            commit.betId,
            commit.revealed,
            commit.fulfilled
        );
    }
    
    /**
     * @dev Get system statistics
     */
    function getSystemStats() external view returns (
        uint256 totalRequests,
        uint256 currentGlobalEntropy,
        uint256 currentBlock
    ) {
        return (requestCounter, globalEntropy, block.number);
    }
    
    /**
     * @dev Helper function to generate commitment hash
     */
    function generateCommitmentHash(
        uint256 secret,
        uint256 salt,
        address user,
        uint256 betId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(secret, salt, user, betId));
    }
}
