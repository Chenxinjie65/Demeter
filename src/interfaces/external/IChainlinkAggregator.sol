// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IChainlinkAggregator
 * @notice Minimal Chainlink AggregatorV3 interface used by V2.
 * @custom:security-contact https://github.com/Chenxinjie65/Demeter/security/advisories/new
 */
interface IChainlinkAggregator {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
