// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolTypes} from "src/types/PoolTypes.sol";

contract MockV2ManagerForPolicy {
    mapping(bytes32 poolId => PoolTypes.PoolConfig config) private _configs;
    mapping(bytes32 poolId => address[] assets) private _assets;
    bool public isOperationActive;

    function setPool(bytes32 poolId, PoolTypes.PoolConfig calldata config, address[] calldata assets) external {
        _configs[poolId] = config;
        _assets[poolId] = assets;
    }

    function setOperationActive(bool active) external {
        isOperationActive = active;
    }

    function getPoolConfig(bytes32 poolId) external view returns (PoolTypes.PoolConfig memory) {
        return _configs[poolId];
    }

    function getPoolAssets(bytes32 poolId) external view returns (address[] memory) {
        return _assets[poolId];
    }

    function poolCreator(bytes32 poolId) external view returns (address) {
        return _configs[poolId].creator;
    }
}
