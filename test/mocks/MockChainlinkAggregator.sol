// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV2V3Interface} from "../../src/interfaces/external/AggregatorInterface.sol";

/**
 * @title MockChainlinkAggregator
 * @notice Mock implementation of Chainlink AggregatorV2V3Interface for testing
 */
contract MockChainlinkAggregator is AggregatorV2V3Interface {
    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    uint8 private _decimals;
    string private _description;
    uint256 private _version;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        uint8 decimals_,
        string memory description_,
        uint256 version_
    ) {
        _decimals = decimals_;
        _description = description_;
        _version = version_;
        _roundId = 1;
        _answeredInRound = 1;
    }

    // -------------------------------------------------------------------------
    // AggregatorV3Interface
    // -------------------------------------------------------------------------

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external view override returns (uint256) {
        return _version;
    }

    function getRoundData(
        uint80 /* roundId_ */
    )
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    // -------------------------------------------------------------------------
    // AggregatorInterface
    // -------------------------------------------------------------------------

    function latestAnswer() external view override returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view override returns (uint256) {
        return _updatedAt;
    }

    function latestRound() external view override returns (uint256) {
        return uint256(_roundId);
    }

    function getAnswer(uint256 roundId_) external view override returns (int256) {
        require(roundId_ == uint256(_roundId), "Round not found");
        return _answer;
    }

    function getTimestamp(uint256 roundId_) external view override returns (uint256) {
        require(roundId_ == uint256(_roundId), "Round not found");
        return _updatedAt;
    }

    // -------------------------------------------------------------------------
    // Setters for Testing
    // -------------------------------------------------------------------------

    /**
     * @notice Updates the price data for testing
     * @param answer_ New price answer
     * @param updatedAt_ Timestamp of the update
     */
    function updateRoundData(int256 answer_, uint256 updatedAt_) external {
        _roundId++;
        _answer = answer_;
        _startedAt = updatedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = _roundId;
    }

    /**
     * @notice Updates the price data with stale round for testing
     * @param answer_ New price answer
     * @param updatedAt_ Timestamp of the update
     */
    function updateRoundDataStale(int256 answer_, uint256 updatedAt_) external {
        _roundId++;
        _answer = answer_;
        _startedAt = updatedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = _roundId - 1; // Stale: answeredInRound < roundId
    }

    /**
     * @notice Sets the decimals for testing
     */
    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }
}

