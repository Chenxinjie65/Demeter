// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Constants
 * @notice Global protocol-wide constants for the Demeter system.
 *
 * @dev
 * These values are intended to be reused across modules (vaults, adapters,
 * routers, etc.) to avoid magic numbers and keep configuration consistent.
 */
library Constants {
    // -------------------------------------------------------------------------
    // Basis points & percentages
    // -------------------------------------------------------------------------

    /// @notice Basis points denominator (1e4 = 100%).
    uint256 internal constant BPS = 10_000;

    /// @notice 100% in basis points.
    uint256 internal constant BPS_100_PERCENT = BPS;

    /// @notice 1% in basis points.
    uint256 internal constant BPS_1_PERCENT = 100;

    /// @notice 10% in basis points.
    uint256 internal constant BPS_10_PERCENT = 1_000;

    // -------------------------------------------------------------------------
    // Time-related constants
    // -------------------------------------------------------------------------

    /// @notice Number of seconds in one year (365 days).
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Number of seconds in one day.
    uint256 internal constant SECONDS_PER_DAY = 1 days;

    /// @notice Number of seconds in one hour.
    uint256 internal constant SECONDS_PER_HOUR = 1 hours;

    // -------------------------------------------------------------------------
    // Decimals / precision
    // -------------------------------------------------------------------------

    /// @notice Standard USD price decimals used by Chainlink feeds (8 decimals).
    uint8 internal constant ORACLE_PRICE_DECIMALS = 8;

    /// @notice Default decimals for AUM accounting (aligned with ORACLE_PRICE_DECIMALS).
    uint8 internal constant AUM_DECIMALS = ORACLE_PRICE_DECIMALS;

    /// @notice 1 unit in AUM precision (10 ** AUM_DECIMALS).
    uint256 internal constant AUM_UNIT = 10 ** uint256(AUM_DECIMALS);

    // -------------------------------------------------------------------------
    // Fee-related defaults (can be used as sane starting points)
    // -------------------------------------------------------------------------

    /// @notice Default performance fee (e.g. 10% = 1000 bps).
    uint16 internal constant DEFAULT_PERFORMANCE_FEE_BPS = 1_000;

    /// @notice Default management fee (e.g. 1% annualized = 100 bps).
    uint16 internal constant DEFAULT_MANAGEMENT_FEE_BPS = 100;
}