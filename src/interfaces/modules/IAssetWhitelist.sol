// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IAssetWhitelist
 * @notice Interface for managing the whitelist of assets supported by the Demeter protocol.
 *
 * @dev
 * This contract maintains a registry of assets that are approved for use in the protocol.
 * Only assets on the whitelist can be used in vaults and other protocol operations.
 * Management is controlled by the RiskAdmin role from ProtocolAddressProvider.
 */
interface IAssetWhitelist {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when an asset is added to the whitelist.
     * @param asset Address of the asset that was added.
     */
    event AssetAdded(address indexed asset);

    /**
     * @notice Emitted when an asset is removed from the whitelist.
     * @param asset Address of the asset that was removed.
     */
    event AssetRemoved(address indexed asset);

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /**
     * @notice Checks if an asset is whitelisted.
     * @param asset Address of the asset to check.
     * @return isWhitelisted True if the asset is whitelisted, false otherwise.
     */
    function isWhitelisted(address asset) external view returns (bool isWhitelisted);

    /**
     * @notice Returns the number of whitelisted assets.
     * @return count The total number of assets in the whitelist.
     */
    function getWhitelistCount() external view returns (uint256 count);

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /**
     * @notice Adds an asset to the whitelist.
     * @dev
     * - Only callable by the RiskAdmin role.
     * - Asset must not be the zero address.
     * - If asset is already whitelisted, the call will revert.
     * - Emits {AssetAdded} event.
     *
     * @param asset Address of the asset to add to the whitelist.
     */
    function addAsset(address asset) external;

    /**
     * @notice Removes an asset from the whitelist.
     * @dev
     * - Only callable by the RiskAdmin role.
     * - If asset is not whitelisted, the call will revert.
     * - Emits {AssetRemoved} event.
     *
     * @param asset Address of the asset to remove from the whitelist.
     */
    function removeAsset(address asset) external;

    /**
     * @notice Adds multiple assets to the whitelist in a single transaction.
     * @dev
     * - Only callable by the RiskAdmin role.
     * - All assets must not be the zero address.
     * - If any asset is already whitelisted, the call will revert.
     * - Emits {AssetAdded} event for each asset.
     *
     * @param assets Array of asset addresses to add to the whitelist.
     */
    function addAssets(address[] calldata assets) external;

    /**
     * @notice Removes multiple assets from the whitelist in a single transaction.
     * @dev
     * - Only callable by the RiskAdmin role.
     * - If any asset is not whitelisted, the call will revert.
     * - Emits {AssetRemoved} event for each asset.
     *
     * @param assets Array of asset addresses to remove from the whitelist.
     */
    function removeAssets(address[] calldata assets) external;
}

