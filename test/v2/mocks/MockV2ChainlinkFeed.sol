// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockV2ChainlinkFeed {
    uint8 public immutable decimals;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;
    bool public shouldRevert;

    error MockV2ChainlinkFeed__Reverted();

    constructor(uint8 decimals_) {
        decimals = decimals_;
        answer = int256(10 ** uint256(decimals_));
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldRevert) revert MockV2ChainlinkFeed__Reverted();
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
