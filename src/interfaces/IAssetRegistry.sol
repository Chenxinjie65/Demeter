// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolTypes} from "src/types/PoolTypes.sol";

/**
 * @title IAssetRegistry
 * @notice Read and governance surfaces for approved V2 assets.
 * @custom:security-contact security@demeter.protocol
 */
interface IAssetRegistry {
    event AssetConfigured(address indexed asset, uint64 indexed configVersion, bool enabled);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event GlobalBoundsUpdated(bytes32 indexed boundsHash);
    event SequencerConfigUpdated(address indexed feed, uint32 gracePeriod, uint64 configVersion);

    /// @notice Add or replace the oracle and risk configuration for an approved asset.
    /// @dev Timelock-only. Re-enables `asset` and increments both its config version and the global oracle version.
    /// BPS fields use 10_000 as 100%. The common TWAP quote asset must use a zero TWAP pool; every other asset
    /// must reference an approved asset/quote-asset pool.
    /// @param asset ERC-20 token contract to configure.
    /// @param config Oracle addresses, time windows in seconds, and per-asset BPS limits.
    function configureAsset(address asset, PoolTypes.AssetConfigInput calldata config) external;

    /// @notice Disable an asset for new pool operations and rebalance validation.
    /// @dev Timelock-only. Increments both the asset config version and global oracle version, invalidating plans
    /// that captured either previous version. Existing proportional redemption remains a Manager concern.
    /// @param asset Previously configured ERC-20 token to disable.
    function disableAsset(address asset) external;

    /// @notice Replace the emergency guardian used by protocol modules.
    /// @dev Timelock-only; `newGuardian` cannot be the zero address.
    /// @param newGuardian New emergency guardian address.
    function setGuardian(address newGuardian) external;

    /// @notice Replace protocol-wide structural bounds for permissionless pools.
    /// @dev Timelock-only. The supplied `configVersion` is ignored and replaced with the next monotonic version.
    /// Share-supply fields are raw 18-decimal share units; duration fields are seconds.
    /// @param bounds New pool creation and bootstrap bounds.
    function setGlobalPoolBounds(PoolTypes.GlobalPoolBounds calldata bounds) external;

    /// @notice Configure or disable the L2 sequencer uptime check used by oracle validation.
    /// @dev Timelock-only. Pass both fields as zero to disable; otherwise `feed` must be a contract and
    /// `gracePeriod` is measured in seconds. Every change increments the global oracle version.
    /// @param feed Chainlink-compatible sequencer uptime feed, or zero when disabled.
    /// @param gracePeriod Required recovery period after the sequencer comes back up, in seconds.
    function setSequencerConfig(address feed, uint32 gracePeriod) external;

    /// @notice Return whether an asset is currently approved for pool operations.
    /// @param asset ERC-20 token to query.
    /// @return True only when the latest stored configuration is enabled.
    function isAssetEnabled(address asset) external view returns (bool);

    /// @notice Return the latest stored configuration for an asset.
    /// @dev Returns an all-zero struct when `asset` has never been configured. BPS fields use 10_000 as 100%.
    /// @param asset ERC-20 token to query.
    /// @return config Latest asset and oracle configuration.
    function getAssetConfig(address asset) external view returns (PoolTypes.AssetConfig memory);

    /// @notice Return an asset's monotonic configuration version.
    /// @param asset ERC-20 token to query.
    /// @return version Zero when never configured; incremented on configuration and disable operations.
    function assetConfigVersion(address asset) external view returns (uint64);

    /// @notice Return the governance timelock authorized to mutate registry configuration.
    /// @return timelock_ Immutable timelock contract address.
    function timelock() external view returns (address);

    /// @notice Return the emergency guardian consumed by protocol modules.
    /// @return guardian_ Current guardian address.
    function guardian() external view returns (address);

    /// @notice Return the commitment to the current global pool bounds, including their assigned version.
    /// @return boundsHash Keccak-256 hash of the ABI-encoded current `GlobalPoolBounds` struct.
    function globalBounds() external view returns (bytes32 boundsHash);

    /// @notice Return the current protocol-wide pool creation and bootstrap bounds.
    /// @dev Initial supply values are raw 18-decimal share units; durations are seconds.
    /// @return bounds Current bounds with the registry-assigned monotonic config version.
    function getGlobalPoolBounds() external view returns (PoolTypes.GlobalPoolBounds memory bounds);

    /// @notice Return the immutable common quote token used by approved TWAP pools.
    /// @return quoteAsset ERC-20 quote asset address.
    function twapQuoteAsset() external view returns (address);

    /// @notice Return the optional L2 sequencer uptime feed.
    /// @return feed Feed address, or zero when sequencer validation is disabled.
    function sequencerUptimeFeed() external view returns (address);

    /// @notice Return the configured post-recovery sequencer grace period.
    /// @return gracePeriod Grace period in seconds, or zero when sequencer validation is disabled.
    function sequencerGracePeriod() external view returns (uint32);

    /// @notice Return the monotonic version covering all oracle-relevant registry configuration.
    /// @dev Asset configuration, asset disablement, and sequencer configuration each increment this value.
    /// Rebalance plans bind to it and become invalid after it changes.
    /// @return version Current global oracle configuration version.
    function oracleConfigVersion() external view returns (uint64);
}
