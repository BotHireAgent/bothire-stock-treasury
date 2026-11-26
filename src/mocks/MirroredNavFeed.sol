// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MirroredNavFeed (testnet only)
/// @notice Chainlink-style NAV feed for a test stock on Base Sepolia. A keeper copies the answer and
///         timestamp of the real Base mainnet feed (e.g. "Coinbase NVDA") into it, so testnet prices
///         and staleness behave like mainnet. 8 decimals, total return (includes the multiplier).
contract MirroredNavFeed {
    address public immutable keeper;
    string public description;
    address public immutable sourceFeed; // the mainnet feed this one mirrors (informational)
    int256 internal answer_;
    uint256 internal updatedAt_;
    uint80 internal roundId_;

    event Mirrored(int256 answer, uint256 updatedAt);

    error NotKeeper();
    error BadAnswer();

    constructor(string memory description_, address sourceFeed_) {
        keeper = msg.sender;
        description = description_;
        sourceFeed = sourceFeed_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    /// @notice Copy the mainnet feed's latest answer and its update time.
    function mirror(int256 answer, uint256 updatedAt) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (answer <= 0 || updatedAt > block.timestamp) revert BadAnswer();
        answer_ = answer;
        updatedAt_ = updatedAt;
        roundId_++;
        emit Mirrored(answer, updatedAt);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId_, answer_, updatedAt_, updatedAt_, roundId_);
    }
}
