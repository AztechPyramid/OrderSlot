// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface ISecureRandomness {
    // Structs
    struct CommitData {
        bytes32 commitment;
        uint256 blockNumber;
        uint256 timestamp;
        address user;
        uint256 betId;
        bool revealed;
        bool fulfilled;
    }

    // Events
    event CommitMade(uint256 indexed requestId, address indexed user, uint256 betId, bytes32 commitment);
    event RandomnessRevealed(uint256 indexed requestId, uint256[] symbols);
    event EntropyGathered(uint256 blockNumber, bytes32 blockHash);

    // Core Functions
    function commitRandomnessRequest(uint256 betId, bytes32 secretHash) external returns (uint256 requestId);
    function revealRandomness(uint256 requestId, uint256 secret, uint256 salt) external;
    function emergencyReveal(uint256 requestId) external;
    
    // View Functions
    function isCommitReady(uint256 requestId) external view returns (bool);
    function getCommitInfo(uint256 requestId) external view returns (
        bytes32 commitment,
        uint256 blockNumber,
        uint256 timestamp,
        address user,
        uint256 betId,
        bool revealed,
        bool fulfilled
    );
    function getSystemStats() external view returns (
        uint256 totalRequests,
        uint256 currentGlobalEntropy,
        uint256 currentBlock
    );
    function generateCommitmentHash(
        uint256 secret,
        uint256 salt,
        address user,
        uint256 betId
    ) external pure returns (bytes32);
    
    // Admin Functions
    function setAuthorizedCaller(address caller, bool authorized) external;
}

/**
 * @title Interface for contracts that consume randomness
 */
interface IRandomnessConsumer {
    function fulfillRandomness(uint256 betId, uint256[] memory symbols) external;
}
