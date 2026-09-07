// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";

/**
 * @title IIndexPolicy
 * @notice Permissionless, delayed policy publication within global bounds.
 * @custom:security-contact security@demeter.protocol
 */
interface IIndexPolicy {
    event PolicyPublished(bytes32 indexed poolId, uint64 indexed version, address indexed creator, bytes32 policyHash);
    event PolicyActivated(bytes32 indexed poolId, uint64 indexed version);
    event PendingPolicyCancelled(bytes32 indexed poolId, uint64 indexed version, address indexed caller);
    event GlobalPolicyBoundsUpdated(bytes32 indexed boundsHash);
    event PolicyFamilyUpdated(bytes32 indexed familyId, bool enabled);

    /// @notice Publish the next delayed creator policy version within global bounds.
    /// @param poolId Creator-owned pool ID.
    /// @param params Target weights in BPS, timestamps and bounded auction parameters.
    function publishPolicy(bytes32 poolId, RebalanceTypes.PolicyParams calldata params)
        external
        returns (uint64 version, bytes32 policyHash);

    /// @notice Activate the pending policy after its effective timestamp.
    /// @param poolId Creator-owned pool whose pending policy is activated.
    function activatePolicy(bytes32 poolId) external;

    /// @notice Cancel the pending policy; stale policies may be cancelled permissionlessly.
    /// @param poolId Creator-owned pool whose pending policy is cancelled.
    function cancelPendingPolicy(bytes32 poolId) external;

    /// @notice Return the active policy version and normalized weights.
    /// @param poolId Pool identifier.
    /// @return policy Active policy snapshot, or an empty policy when none is active.
    function activePolicy(bytes32 poolId) external view returns (RebalanceTypes.PolicyVersion memory policy);

    /// @notice Return an immutable published policy version.
    /// @param poolId Pool identifier.
    /// @param version Append-only policy version to query.
    /// @return policy Published policy snapshot.
    function policy(bytes32 poolId, uint64 version)
        external
        view
        returns (RebalanceTypes.PolicyVersion memory policy);

    /// @notice Return the pending policy version, or zero when none exists.
    function pendingVersion(bytes32 poolId) external view returns (uint64 version);

    /// @notice Set protocol-wide policy bounds through governance.
    /// @param bounds New hard policy bounds; its version is assigned by the module.
    function setGlobalBounds(RebalanceTypes.GlobalPolicyBounds calldata bounds) external;

    /// @notice Return current policy bounds and configuration version.
    /// @return bounds Current policy bounds and monotonic configuration version.
    function getGlobalBounds() external view returns (RebalanceTypes.GlobalPolicyBounds memory bounds);

    /// @notice Enable or disable a policy family through governance.
    /// @param familyId Policy family identifier.
    /// @param enabled Whether creators may publish this family.
    function setPolicyFamily(bytes32 familyId, bool enabled) external;

    /// @notice Return whether a policy family is enabled.
    /// @param familyId Policy family identifier.
    /// @return enabled True when the family is currently enabled.
    function isPolicyFamilyEnabled(bytes32 familyId) external view returns (bool);

    /// @notice Return whether the active policy is effective and within current bounds.
    /// @param poolId Pool identifier.
    /// @return active True when the policy is time-effective, family-enabled, and bound-compliant.
    function isPolicyActive(bytes32 poolId) external view returns (bool);

    /// @notice Return the creator that published a specific version.
    /// @param poolId Pool identifier.
    /// @param version Append-only policy version to query.
    /// @return creator Address that published the version.
    function policyCreator(bytes32 poolId, uint64 version) external view returns (address creator);

    /// @notice Validate pool kind, family, and asset count against policy creation rules.
    function validatePoolCreation(
        bytes32 poolId,
        address creator,
        PoolTypes.PoolKind kind,
        bytes32 policyFamilyId,
        uint256 assetCount
    ) external view;

    /// @notice Return the initial policy commitment stored for a pool.
    /// @param poolId Pool identifier.
    /// @return policyHash Hash committed at pool creation, or zero when unset.
    function initialPolicyHash(bytes32 poolId) external view returns (bytes32 policyHash);

    /// @notice Compute a versioned policy commitment without publishing it.
    function computePolicyHash(bytes32 poolId, uint64 version, RebalanceTypes.PolicyParams calldata params)
        external
        view
        returns (bytes32 policyHash);

    /// @notice Compute the creator-bound initial policy commitment.
    function computeInitialPolicyHash(
        bytes32 poolId,
        address creator,
        PoolTypes.PoolKind kind,
        RebalanceTypes.PolicyParams calldata params
    ) external view returns (bytes32 policyHash);

    /// @notice Return the monotonic version of a policy family configuration.
    /// @param familyId Policy family identifier.
    /// @return version Current family configuration version.
    function familyVersion(bytes32 familyId) external view returns (uint64 version);

    /// @notice Return the immutable Manager dependency.
    function manager() external view returns (IDemeterManager);

    /// @notice Return the governance timelock.
    function timelock() external view returns (address);
}
