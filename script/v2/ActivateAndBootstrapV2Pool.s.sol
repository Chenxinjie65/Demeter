// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "@forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IDemeterShare} from "src/interfaces/IDemeterShare.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";

/**
 * @title ActivateAndBootstrapV2Pool
 * @notice Activates policy v1 after its delay and seeds the committed basket.
 */
contract ActivateAndBootstrapV2Pool is Script {
    using SafeERC20 for IERC20;

    function run() external {
        uint256 bootstrapperKey = vm.envUint("POOL_BOOTSTRAPPER_PRIVATE_KEY");
        address bootstrapper = vm.addr(bootstrapperKey);
        bytes32 poolId = vm.envBytes32("V2_POOL_ID");
        IDemeterManager manager = IDemeterManager(vm.envAddress("V2_MANAGER"));
        IIndexPolicy policy = IIndexPolicy(vm.envAddress("V2_INDEX_POLICY"));
        PoolTypes.PoolConfig memory config = manager.getPoolConfig(poolId);
        require(config.bootstrapper == bootstrapper, "V2: wrong bootstrapper key");

        address[] memory assets = manager.getPoolAssets(poolId);
        uint256[] memory seedAmounts = manager.getSeedAmounts(poolId);
        require(assets.length == seedAmounts.length, "V2: seed length mismatch");

        vm.startBroadcast(bootstrapperKey);
        policy.activatePolicy(poolId);
        for (uint256 i; i < assets.length; ++i) {
            IERC20(assets[i]).forceApprove(address(manager), seedAmounts[i]);
        }
        manager.bootstrap(poolId);
        vm.stopBroadcast();

        require(manager.isPoolActive(poolId), "V2: pool did not activate");
        for (uint256 i; i < assets.length; ++i) {
            require(manager.reserveOf(poolId, assets[i]) == seedAmounts[i], "V2: seed reserve mismatch");
        }
        require(
            IDemeterShare(config.share).totalSupply() == config.initialShareSupply, "V2: initial share supply mismatch"
        );
        console2.logBytes32(poolId);
        console2.log("Demeter V2 pool bootstrapped");
    }
}
