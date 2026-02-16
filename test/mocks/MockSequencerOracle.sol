// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISequencerOracle} from "../../src/interfaces/external/ISequencerOracle.sol";

/**
 * @title MockSequencerOracle
 * @notice Mock implementation of ISequencerOracle for testing
 */
contract MockSequencerOracle is ISequencerOracle {
    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    uint80 private _roundId;
    int256 private _answer; // 0 = up, 1 = down
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    // -------------------------------------------------------------------------
    // ISequencerOracle
    // -------------------------------------------------------------------------

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
    // Setters for Testing
    // -------------------------------------------------------------------------

    /**
     * @notice Sets the sequencer status to up
     * @param updatedAt_ Timestamp of the update
     */
    function setSequencerUp(uint256 updatedAt_) external {
        _roundId++;
        _answer = 0; // 0 = sequencer is up
        _startedAt = updatedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = _roundId;
    }

    /**
     * @notice Sets the sequencer status to down
     * @param updatedAt_ Timestamp of the update
     */
    function setSequencerDown(uint256 updatedAt_) external {
        _roundId++;
        _answer = 1; // 1 = sequencer is down
        _startedAt = updatedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = _roundId;
    }

    /**
     * @notice Manually sets all round data for testing
     */
    function setRoundData(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }
}

