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
    // Fee-related defaults
    // -------------------------------------------------------------------------

    /// @notice Default performance fee (10% = 1000 bps).
    uint16 internal constant DEFAULT_PERFORMANCE_FEE_BPS = 1_000;

    /// @notice Default management fee (1% annualized = 100 bps).
    uint16 internal constant DEFAULT_MANAGEMENT_FEE_BPS = 100;

    // -------------------------------------------------------------------------
    // Share minting — inflation attack defence
    // -------------------------------------------------------------------------

    /**
     * @notice Virtual share offset used in {VaultMath.calcSharesToMint}.
     *
     * @dev
     * Inspired by the OpenZeppelin ERC-4626 decimal-offset pattern.
     * Together with VIRTUAL_AUM, this anchors the initial share price at
     * approximately $1 per share (1e18 share units per 1e8 AUM units).
     *
     * Ratio: VIRTUAL_SHARES / VIRTUAL_AUM = 1e10 = 1e18 share_units / 1e8 AUM_units → $1/share.
     */
    uint256 internal constant VIRTUAL_SHARES = 1e10;

    /**
     * @notice Virtual AUM offset paired with VIRTUAL_SHARES.
     * 1 AUM unit = $0.00000001 (one hundred-millionth of a dollar).
     * Prevents division by zero on first deposit without needing dead-share minting.
     */
    uint256 internal constant VIRTUAL_AUM = 1;

    // -------------------------------------------------------------------------
    // Vault operational defaults
    // -------------------------------------------------------------------------

    /// @notice Default idle liquidity buffer (10% of total assets per token stays in vault).
    uint256 internal constant DEFAULT_BUFFER_RATIO_BPS = 1_000;

    /// @notice Default minimum interval between rebalances (24 hours).
    uint256 internal constant DEFAULT_REBALANCE_COOLDOWN = 24 hours;

    /// @notice Default maximum swap slippage allowed during rebalancing (1%).
    uint256 internal constant DEFAULT_MAX_SLIPPAGE_BPS = 100;

    // -------------------------------------------------------------------------
    // Keeper reward parameters
    // -------------------------------------------------------------------------

    /**
     * @notice Base keeper reward expressed as a fraction of total outstanding shares.
     * 0.1% of total shares are minted to the keeper per rebalance.
     * Aligns keeper incentives with long-term vault performance.
     */
    uint256 internal constant KEEPER_BASE_REWARD_BPS = 10;
}
