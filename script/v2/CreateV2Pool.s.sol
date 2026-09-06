// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "@forge-std/Script.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IAuctionRebalance} from "src/interfaces/IAuctionRebalance.sol";
import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";

/**
 * @title CreateV2Pool
 * @notice Permissionlessly creates a pool and publishes its committed policy v1.
 * @dev Address and integer arrays use comma-separated environment values.
 */
contract CreateV2Pool is Script {
    function run() external returns (bytes32 poolId, address share) {
        uint256 creatorKey = vm.envUint("POOL_CREATOR_PRIVATE_KEY");
        address creator = vm.addr(creatorKey);
        IDemeterManager manager = IDemeterManager(vm.envAddress("V2_MANAGER"));
        IIndexPolicy policy = IIndexPolicy(vm.envAddress("V2_INDEX_POLICY"));
        _validateWiring(manager, policy);
        address[] memory assets = vm.envAddress("V2_POOL_ASSETS", ",");
        uint256[] memory seedAmounts = vm.envUint("V2_POOL_SEED_AMOUNTS", ",");
        bytes32 familyId = vm.envBytes32("V2_POLICY_FAMILY_ID");
        bytes32 creatorSalt = vm.envBytes32("V2_POOL_CREATOR_SALT");
        PoolTypes.PoolKind kind =
            vm.envBool("V2_POOL_MANAGED") ? PoolTypes.PoolKind.MANAGED_INDEX : PoolTypes.PoolKind.IMMUTABLE_INDEX;

        RebalanceTypes.PolicyParams memory policyParams = _policyParams(familyId);
        poolId = manager.derivePoolId(creator, assets, familyId, creatorSalt);
        bytes32 policyHash = policy.computeInitialPolicyHash(poolId, creator, kind, policyParams);
        PoolTypes.CreatePoolParams memory createParams = PoolTypes.CreatePoolParams({
            assets: assets,
            policyFamilyId: familyId,
            creatorSalt: creatorSalt,
            name: vm.envString("V2_POOL_NAME"),
            symbol: vm.envString("V2_POOL_SYMBOL"),
            bootstrapper: vm.envAddress("V2_POOL_BOOTSTRAPPER"),
            bootstrapDeadline: _u64(vm.envUint("V2_POOL_BOOTSTRAP_DEADLINE")),
            initialShareSupply: vm.envUint("V2_POOL_INITIAL_SHARE_SUPPLY"),
            kind: kind,
            seedAmounts: seedAmounts,
            initialShareRecipient: vm.envAddress("V2_POOL_SHARE_RECIPIENT"),
            initialPolicyHash: policyHash
        });

        vm.startBroadcast(creatorKey);
        (bytes32 createdId, address createdShare) = manager.createPool(createParams);
        (uint64 version, bytes32 publishedHash) = policy.publishPolicy(poolId, policyParams);
        vm.stopBroadcast();

        require(createdId == poolId, "V2: derived pool ID mismatch");
        require(version == 1, "V2: initial policy is not version 1");
        require(publishedHash == policyHash, "V2: published policy hash mismatch");
        share = createdShare;
        console2.logBytes32(poolId);
        console2.log("Demeter V2 share:", share);
    }

    function _validateWiring(IDemeterManager manager, IIndexPolicy policy) private view {
        require(address(manager).code.length != 0, "V2: manager has no code");
        require(address(policy).code.length != 0, "V2: policy has no code");
        IAssetRegistry registry = manager.registry();
        address timelock = manager.timelock();
        address auctionAddress = manager.auctionRebalance();
        require(address(registry).code.length != 0, "V2: registry has no code");
        require(timelock.code.length != 0, "V2: timelock has no code");
        require(registry.timelock() == timelock, "V2: registry timelock mismatch");
        require(registry.guardian() != address(0), "V2: guardian is zero");
        require(manager.indexPolicy() == address(policy), "V2: manager policy mismatch");
        require(auctionAddress.code.length != 0, "V2: manager auction missing");
        require(address(policy.manager()) == address(manager), "V2: policy manager mismatch");
        require(policy.timelock() == timelock, "V2: policy timelock mismatch");

        IAuctionRebalance auction = IAuctionRebalance(auctionAddress);
        require(address(auction.manager()) == address(manager), "V2: auction manager mismatch");
        require(address(auction.policy()) == address(policy), "V2: auction policy mismatch");
        require(address(auction.registry()) == address(registry), "V2: auction registry mismatch");
        require(address(auction.twapOracle()).code.length != 0, "V2: auction oracle has no code");
    }

    function _policyParams(bytes32 familyId) private view returns (RebalanceTypes.PolicyParams memory params) {
        uint256[] memory rawWeights = vm.envUint("V2_POLICY_WEIGHTS_BPS", ",");
        params.weightsBps = new uint16[](rawWeights.length);
        for (uint256 i; i < rawWeights.length; ++i) {
            params.weightsBps[i] = _u16(rawWeights[i]);
        }
        params.epoch = _u64(vm.envUint("V2_POLICY_EPOCH"));
        params.effectiveAt = _u64(vm.envUint("V2_POLICY_EFFECTIVE_AT"));
        params.minPlanInterval = _u32(vm.envUint("V2_POLICY_MIN_PLAN_INTERVAL"));
        params.planDuration = _u32(vm.envUint("V2_POLICY_PLAN_DURATION"));
        params.triggerBps = _u16(vm.envUint("V2_POLICY_TRIGGER_BPS"));
        params.destinationBps = _u16(vm.envUint("V2_POLICY_DESTINATION_BPS"));
        params.maxTurnoverBps = _u16(vm.envUint("V2_POLICY_MAX_TURNOVER_BPS"));
        params.maxAssetAdjustmentBps = _u16(vm.envUint("V2_POLICY_MAX_ASSET_ADJUSTMENT_BPS"));
        params.startPremiumBps = _u16(vm.envUint("V2_POLICY_START_PREMIUM_BPS"));
        params.maxDiscountBps = _u16(vm.envUint("V2_POLICY_MAX_DISCOUNT_BPS"));
        params.auctionDuration = _u32(vm.envUint("V2_POLICY_AUCTION_DURATION"));
        params.maxOracleDeviationBps = _u16(vm.envUint("V2_POLICY_MAX_ORACLE_DEVIATION_BPS"));
        params.maxReferenceMoveBps = _u16(vm.envUint("V2_POLICY_MAX_REFERENCE_MOVE_BPS"));
        params.policyFamilyId = familyId;
    }

    function _u16(uint256 value) private pure returns (uint16) {
        require(value <= type(uint16).max, "V2: uint16 overflow");
        return uint16(value);
    }

    function _u32(uint256 value) private pure returns (uint32) {
        require(value <= type(uint32).max, "V2: uint32 overflow");
        return uint32(value);
    }

    function _u64(uint256 value) private pure returns (uint64) {
        require(value <= type(uint64).max, "V2: uint64 overflow");
        return uint64(value);
    }
}
