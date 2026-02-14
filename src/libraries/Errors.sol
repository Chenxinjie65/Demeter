// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Errors
 * @notice Library containing all custom errors used across the Demeter protocol.
 */
library Errors {
    // -------------------------------------------------------------------------
    // Price Oracle Errors
    // -------------------------------------------------------------------------

    /// @dev Thrown when addresses provider is zero address.
    error AddressesProviderIsZero();

    /// @dev Thrown when caller is not the RiskAdmin.
    error CallerNotRiskAdmin();

    /// @dev Thrown when arrays length mismatch.
    error ArraysLengthMismatch();

    /// @dev Thrown when feed is not set for an asset.
    error FeedNotSet();

    /// @dev Thrown when Chainlink answer is invalid (non-positive).
    error InvalidAnswer();

    /// @dev Thrown when Chainlink round is stale.
    error StaleRound();

    /// @dev Thrown when price is stale beyond maxStaleTime.
    error PriceStale();

    /// @dev Thrown when sequencer is down.
    error SequencerDown();

    /// @dev Thrown when grace period is not over after sequencer recovery.
    error GracePeriodNotOver();
}

