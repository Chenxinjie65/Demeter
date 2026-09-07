// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PoolId
 * @notice Deterministic, creator-bound identifiers for permissionless pools.
 * @custom:security-contact https://github.com/Chenxinjie65/Demeter/security/advisories/new
 */
library PoolId {
    function derive(
        uint256 chainId,
        address manager,
        address creator,
        address[] calldata orderedAssets,
        bytes32 policyFamilyId,
        bytes32 creatorSalt
    ) internal pure returns (bytes32 poolId) {
        poolId = keccak256(abi.encode(chainId, manager, creator, orderedAssets, policyFamilyId, creatorSalt));
    }

    function deriveMemory(
        uint256 chainId,
        address manager,
        address creator,
        address[] memory orderedAssets,
        bytes32 policyFamilyId,
        bytes32 creatorSalt
    ) internal pure returns (bytes32 poolId) {
        poolId = keccak256(abi.encode(chainId, manager, creator, orderedAssets, policyFamilyId, creatorSalt));
    }
}
