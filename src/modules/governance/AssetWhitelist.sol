// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IAssetWhitelist} from "../../interfaces/modules/IAssetWhitelist.sol";
import {IProtocolAddressProvider} from "../../interfaces/core/IProtocolAddressProvider.sol";
import {Errors} from "../../libraries/Errors.sol";

/**
 * @title AssetWhitelist
 * @notice Manages the whitelist of assets supported by the Demeter protocol.
 *
 * @dev
 * This contract maintains a registry of approved assets that can be used
 * in protocol operations. Only assets on the whitelist are allowed in vaults
 * and other protocol functions.
 *
 * SECURITY NOTES:
 * - Only the RiskAdmin role (from ProtocolAddressProvider) can manage the whitelist.
 * - Assets are stored in a mapping for O(1) lookup efficiency.
 * - A counter is maintained to track the total number of whitelisted assets.
 */
contract AssetWhitelist is IAssetWhitelist {
    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Protocol address provider contract.
    IProtocolAddressProvider public immutable ADDRESSES_PROVIDER;

    /// @notice Mapping from asset address to whitelist status.
    mapping(address => bool) private _whitelisted;

    /// @notice Total number of whitelisted assets.
    uint256 private _whitelistCount;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param addressesProvider_ Protocol address provider contract address.
     */
    constructor(address addressesProvider_) {
        if (addressesProvider_ == address(0)) revert Errors.AddressesProviderIsZero();
        ADDRESSES_PROVIDER = IProtocolAddressProvider(addressesProvider_);
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @dev Modifier to check that the caller is the RiskAdmin.
     */
    modifier onlyRiskAdmin() {
        if (msg.sender != ADDRESSES_PROVIDER.getRiskAdmin()) revert Errors.CallerNotRiskAdmin();
        _;
    }

    // -------------------------------------------------------------------------
    // IAssetWhitelist implementation
    // -------------------------------------------------------------------------

    /// @inheritdoc IAssetWhitelist
    function isWhitelisted(address asset) external view override returns (bool) {
        return _whitelisted[asset];
    }

    /// @inheritdoc IAssetWhitelist
    function getWhitelistCount() external view override returns (uint256 count) {
        return _whitelistCount;
    }

    /// @inheritdoc IAssetWhitelist
    function addAsset(address asset) external override onlyRiskAdmin {
        if (asset == address(0)) revert Errors.AssetIsZero();
        if (_whitelisted[asset]) revert Errors.AssetAlreadyWhitelisted();

        _whitelisted[asset] = true;
        _whitelistCount++;
        emit IAssetWhitelist.AssetAdded(asset);
    }

    /// @inheritdoc IAssetWhitelist
    function removeAsset(address asset) external override onlyRiskAdmin {
        if (!_whitelisted[asset]) revert Errors.AssetNotWhitelisted();

        _whitelisted[asset] = false;
        _whitelistCount--;
        emit IAssetWhitelist.AssetRemoved(asset);
    }

    /// @inheritdoc IAssetWhitelist
    function addAssets(address[] calldata assets) external override onlyRiskAdmin {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            if (asset == address(0)) revert Errors.AssetIsZero();
            if (_whitelisted[asset]) revert Errors.AssetAlreadyWhitelisted();

            _whitelisted[asset] = true;
            _whitelistCount++;
            emit IAssetWhitelist.AssetAdded(asset);
        }
    }

    /// @inheritdoc IAssetWhitelist
    function removeAssets(address[] calldata assets) external override onlyRiskAdmin {
        uint256 len = assets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            if (!_whitelisted[asset]) revert Errors.AssetNotWhitelisted();

            _whitelisted[asset] = false;
            _whitelistCount--;
            emit IAssetWhitelist.AssetRemoved(asset);
        }
    }
}

