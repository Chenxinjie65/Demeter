// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICircuitBreaker} from "../../src/interfaces/modules/ICircuitBreaker.sol";

/**
 * @title MockCircuitBreaker
 * @notice Configurable ICircuitBreaker mock for withdrawal rate-limiting tests.
 *
 * @dev
 * - When `shouldBlock` is true, every call to `checkAndRecordOutflow` reverts,
 *   simulating a fully saturated circuit breaker.
 * - `lastRecordedValue` allows tests to assert that the correct USD value was
 *   passed to the circuit breaker during a withdrawal.
 */
contract MockCircuitBreaker is ICircuitBreaker {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Causes checkAndRecordOutflow to revert when true.
    bool public shouldBlock;

    /// @notice Remaining capacity returned by remainingOutflowCapacity().
    uint256 public capacity = type(uint256).max;

    /// @notice Last USD value recorded by checkAndRecordOutflow (for assertions).
    uint256 public lastRecordedValue;

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setShouldBlock(bool block_) external {
        shouldBlock = block_;
    }

    function setCapacity(uint256 capacity_) external {
        capacity = capacity_;
    }

    // -------------------------------------------------------------------------
    // ICircuitBreaker
    // -------------------------------------------------------------------------

    function checkAndRecordOutflow(uint256 usdValue) external override {
        if (shouldBlock) revert("MockCircuitBreaker: outflow cap exceeded");
        lastRecordedValue = usdValue;
    }

    function remainingOutflowCapacity() external view override returns (uint256) {
        return capacity;
    }
}
