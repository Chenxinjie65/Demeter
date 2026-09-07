// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PoolTypes
 * @notice Data structures shared by the Demeter V2 pool and registry contracts.
 * @custom:security-contact https://github.com/Chenxinjie65/Demeter/security/advisories/new
 */
library PoolTypes {
    /// @notice Whether a pool's creator may publish later policy versions.
    enum PoolKind {
        IMMUTABLE_INDEX,
        MANAGED_INDEX
    }

    /// @notice Immutable inputs used to derive a pool identifier.
    struct PoolKey {
        address creator;
        address[] assets;
        bytes32 policyFamilyId;
        bytes32 creatorSalt;
    }

    /// @notice Inputs for permissionless pool creation.
    struct CreatePoolParams {
        address[] assets;
        bytes32 policyFamilyId;
        bytes32 creatorSalt;
        string name;
        string symbol;
        address bootstrapper;
        uint64 bootstrapDeadline;
        uint256 initialShareSupply;
        PoolKind kind;
        uint256[] seedAmounts;
        address initialShareRecipient;
        bytes32 initialPolicyHash;
    }

    /// @notice Parameters for a direct proportional issue.
    struct IssueParams {
        bytes32 poolId;
        uint256 sharesOut;
        address receiver;
        uint256 deadline;
        uint256[] maxAmountsIn;
    }

    /// @notice Parameters for a direct proportional redemption.
    struct RedeemParams {
        bytes32 poolId;
        address owner;
        uint256 sharesIn;
        address receiver;
        uint256 deadline;
        uint256[] minAmountsOut;
    }

    /// @notice The non-array metadata held by the singleton manager for a pool.
    struct PoolConfig {
        address creator;
        address share;
        address bootstrapper;
        bytes32 policyFamilyId;
        PoolKind kind;
        uint64 createdAt;
        uint64 bootstrapDeadline;
        bool bootstrapped;
        bool closed;
        address initialShareRecipient;
        uint256 initialShareSupply;
        bytes32 seedHash;
        bytes32 initialPolicyHash;
        bool bootstrapExpired;
    }

    /// @notice Global asset and oracle configuration.
    struct AssetConfig {
        bool enabled;
        uint8 decimals;
        address chainlinkFeed;
        address twapPool;
        address twapQuoteAsset;
        uint32 twapWindow;
        uint32 maxChainlinkStale;
        uint16 maxOracleDeviationBps;
        uint16 maxReferenceMoveBps;
        uint64 configVersion;
    }

    /// @notice Mutable oracle/risk inputs supplied by governance.
    struct AssetConfigInput {
        address chainlinkFeed;
        address twapPool;
        uint32 twapWindow;
        uint32 maxChainlinkStale;
        uint16 maxOracleDeviationBps;
        uint16 maxReferenceMoveBps;
    }

    /// @notice Protocol-wide structural limits for permissionless pool creation.
    struct GlobalPoolBounds {
        uint16 minAssets;
        uint16 maxAssets;
        uint16 maxNameBytes;
        uint16 maxSymbolBytes;
        uint256 minInitialShareSupply;
        uint256 maxInitialShareSupply;
        uint64 minBootstrapDuration;
        uint64 maxBootstrapDuration;
        uint64 configVersion;
    }
}
