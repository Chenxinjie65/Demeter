// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title DataTypes
 * @notice Common parameter and helper structs used across Demeter vault modules.
 *
 * @dev
 * This library is intentionally kept free of storage logic. It only defines
 * reusable data structures to keep function signatures small and expressive.
 *
 * IMPORTANT:
 * - These structs are intended for in-memory / calldata use (e.g. function params).
 * - Do NOT rely on their field order for storage layout; storage layout is defined
 *   separately in {VaultStorage}.
 */
library DataTypes {
    // -------------------------------------------------------------------------
    // Vault initialization & configuration
    // -------------------------------------------------------------------------

    /**
     * @notice Vault initialization parameters (mirrors IDemeterVault.InitializeParams).
     * @dev
     * This struct can be reused in factories / deployment scripts for clarity.
     */
    struct VaultInitializeParams {
        address baseAsset;        // Base asset used for ERC4626-style accounting (e.g. USDC).
        address manager;          // Address with portfolio management permissions.
        address[] assets;         // Underlying portfolio assets (e.g. WBTC, WETH).
        uint256[] weights;        // Target weights in basis points; must sum to 10_000.
        address addressProvider;  // Global protocol address provider.
        string name;              // ERC-20 name for the share token.
        string symbol;            // ERC-20 symbol for the share token.
    }

    /**
     * @notice Parameters for updating vault weights.
     */
    struct WeightsUpdateParams {
        address[] assets;   // Optional explicit asset list (if needed by implementation).
        uint256[] weights;  // New weights in basis points; must match assets length.
    }

    /**
     * @notice Parameters for setting or updating a single strategy adapter.
     */
    struct StrategyUpdateParams {
        address asset;        // Underlying asset address.
        address newAdapter;   // New adapter implementation for this asset.
    }

    // -------------------------------------------------------------------------
    // User deposit / withdraw flows
    // -------------------------------------------------------------------------

    /**
     * @notice Multi-asset withdrawal parameters, used by the core vault.
     * @dev
     * - The vault ALWAYS returns ALL portfolio assets proportionally (strict in-kind).
     * - `assets` is informational only and is ignored by the vault implementation.
     * - `minAmountsOut` MUST have the same length as the vault's asset list, ordered
     *   identically to the vault's `getAssets()` return value.
     */
    struct MultiAssetWithdrawParams {
        address owner;           // Share owner whose balance is being burned.
        address receiver;        // Address receiving the underlying assets.
        uint256 shares;          // Amount of vault shares to redeem.
        address[] assets;        // Informational only; vault returns all portfolio assets.
        uint256[] minAmountsOut; // Minimum acceptable amounts per asset (ordered by vault's asset list).
    }

    // -------------------------------------------------------------------------
    // Rebalance & portfolio management
    // -------------------------------------------------------------------------

    /**
     * @notice Parameters for a portfolio rebalance operation.
     * @dev
     * Implementations can interpret `minAmountsOut` as per-step safeguards
     * during rebalancing (e.g. DEX swaps, adapter withdraw/deposit).
     */
    struct RebalanceParams {
        uint256[] newWeights;    // New target weights in basis points.
        uint256[] minAmountsOut; // Minimum acceptable amounts per operation (implementation-defined).
    }
}