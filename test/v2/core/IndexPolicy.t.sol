// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";

import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {MockV2ManagerForPolicy} from "test/v2/mocks/MockV2ManagerForPolicy.sol";

contract IndexPolicyTest is Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant CREATOR = address(0xB0B);
    address private constant ATTACKER = address(0xBAD);
    bytes32 private constant POOL_ID = keccak256("pool");
    bytes32 private constant FAMILY = keccak256("STATIC_INDEX_V1");

    IndexPolicy private policy;
    MockV2ManagerForPolicy private manager;

    function setUp() public {
        manager = new MockV2ManagerForPolicy();
        policy = new IndexPolicy(TIMELOCK, address(manager), _bounds());
        vm.prank(TIMELOCK);
        policy.setPolicyFamily(FAMILY, true);
    }

    function test_PublishAndPermissionlessActivateInitialPolicy() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());

        vm.prank(CREATOR);
        (uint64 version, bytes32 policyHash) = policy.publishPolicy(POOL_ID, params);
        assertEq(version, 1);
        assertEq(policyHash, config.initialPolicyHash);

        vm.warp(params.effectiveAt);
        vm.prank(ATTACKER);
        policy.activatePolicy(POOL_ID);
        assertTrue(policy.isPolicyActive(POOL_ID));
    }

    function test_ActivationIsBlockedDuringManagerAssetOperation() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());
        vm.prank(CREATOR);
        policy.publishPolicy(POOL_ID, params);
        vm.warp(params.effectiveAt);
        manager.setOperationActive(true);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PoolLocked.selector, POOL_ID));
        policy.activatePolicy(POOL_ID);
    }

    function test_RevertWhen_NonCreatorPublishes() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__UnauthorizedCreator.selector, ATTACKER, CREATOR));
        policy.publishPolicy(POOL_ID, params);
    }

    function test_RevertWhen_InitialCommitmentDoesNotMatch() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = bytes32(uint256(1));
        manager.setPool(POOL_ID, config, _assets());

        bytes32 actual = policy.computePolicyHash(POOL_ID, 1, params);
        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.V2Errors__InitialPolicyHashMismatch.selector, config.initialPolicyHash, actual
            )
        );
        policy.publishPolicy(POOL_ID, params);
    }

    function test_ImmutablePoolRejectsSecondPolicy() public {
        RebalanceTypes.PolicyParams memory first = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.IMMUTABLE_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, first);
        manager.setPool(POOL_ID, config, _assets());

        vm.prank(CREATOR);
        policy.publishPolicy(POOL_ID, first);
        vm.warp(first.effectiveAt);
        policy.activatePolicy(POOL_ID);

        RebalanceTypes.PolicyParams memory second = _params(uint64(block.timestamp + 2 days));
        second.epoch = 2;
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__ImmutablePolicy.selector, POOL_ID));
        policy.publishPolicy(POOL_ID, second);
    }

    function test_GlobalBoundsChangeInvalidatesPendingPolicy() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());
        vm.prank(CREATOR);
        policy.publishPolicy(POOL_ID, params);

        RebalanceTypes.GlobalPolicyBounds memory bounds = _bounds();
        bounds.maxPlanDuration = 8 days;
        vm.prank(TIMELOCK);
        policy.setGlobalBounds(bounds);

        vm.warp(params.effectiveAt);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__ConfigVersionChanged.selector, 1, 2));
        policy.activatePolicy(POOL_ID);
    }

    function test_FamilyChangeInvalidatesPendingPolicy() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());
        vm.prank(CREATOR);
        policy.publishPolicy(POOL_ID, params);

        vm.prank(TIMELOCK);
        policy.setPolicyFamily(FAMILY, false);
        vm.warp(params.effectiveAt);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PolicyFamilyDisabled.selector, FAMILY));
        policy.activatePolicy(POOL_ID);
    }

    function test_HarmlessGlobalBoundsUpdateKeepsActivePolicyUsable() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.IMMUTABLE_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());
        vm.prank(CREATOR);
        policy.publishPolicy(POOL_ID, params);
        vm.warp(params.effectiveAt);
        policy.activatePolicy(POOL_ID);

        RebalanceTypes.GlobalPolicyBounds memory bounds = _bounds();
        bounds.maxPlanDuration = 13 days;
        vm.prank(TIMELOCK);
        policy.setGlobalBounds(bounds);

        assertTrue(policy.isPolicyActive(POOL_ID));
        assertEq(policy.activePolicy(POOL_ID).version, 1);
    }

    function test_TightenedBoundsFreezeOnlyNonCompliantActivePolicy() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());
        vm.prank(CREATOR);
        policy.publishPolicy(POOL_ID, params);
        vm.warp(params.effectiveAt);
        policy.activatePolicy(POOL_ID);

        RebalanceTypes.GlobalPolicyBounds memory bounds = _bounds();
        bounds.maxTurnoverBps = 1_000;
        vm.prank(TIMELOCK);
        policy.setGlobalBounds(bounds);

        assertFalse(policy.isPolicyActive(POOL_ID));
    }

    function test_StalePendingPolicyCanBeCancelledPermissionlessly() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());
        vm.prank(CREATOR);
        policy.publishPolicy(POOL_ID, params);

        RebalanceTypes.GlobalPolicyBounds memory bounds = _bounds();
        bounds.maxPlanDuration = 13 days;
        vm.prank(TIMELOCK);
        policy.setGlobalBounds(bounds);

        vm.prank(ATTACKER);
        policy.cancelPendingPolicy(POOL_ID);
        assertEq(policy.pendingVersion(POOL_ID), 0);
    }

    function test_CancelledInitialPolicyCannotBeRewritten() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());
        vm.startPrank(CREATOR);
        (, bytes32 publishedHash) = policy.publishPolicy(POOL_ID, params);
        policy.cancelPendingPolicy(POOL_ID);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__InitialPolicyRequired.selector, POOL_ID));
        policy.publishPolicy(POOL_ID, params);
        vm.stopPrank();

        assertEq(policy.policy(POOL_ID, 1).policyHash, publishedHash);
        assertEq(policy.pendingVersion(POOL_ID), 0);
    }

    function test_RevertWhen_PlanCannotContainFullAuction() public {
        RebalanceTypes.PolicyParams memory params = _params(uint64(block.timestamp + 1 days));
        params.planDuration = 30 minutes;
        params.auctionDuration = 1 hours;
        PoolTypes.PoolConfig memory config = _poolConfig(PoolTypes.PoolKind.MANAGED_INDEX);
        config.initialPolicyHash = policy.computeInitialPolicyHash(POOL_ID, CREATOR, config.kind, params);
        manager.setPool(POOL_ID, config, _assets());

        vm.prank(CREATOR);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.V2Errors__InvalidTime.selector, bytes32("planDuration"), 30 minutes)
        );
        policy.publishPolicy(POOL_ID, params);
    }

    function test_RevertWhen_GlobalAuctionMinimumIsUnsafe() public {
        RebalanceTypes.GlobalPolicyBounds memory bounds = _bounds();
        bounds.minAuctionDuration = 1;
        vm.expectRevert(
            abi.encodeWithSelector(IndexPolicy.IndexPolicy__InvalidBounds.selector, bytes32("auctionDuration"), 2 days)
        );
        new IndexPolicy(TIMELOCK, address(manager), bounds);
    }

    function test_RevertWhen_GlobalTimingBoundsAreUnsafe() public {
        RebalanceTypes.GlobalPolicyBounds memory bounds = _bounds();
        bounds.minPolicyDelay = 5 minutes - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IndexPolicy.IndexPolicy__InvalidBounds.selector, bytes32("policyDelay"), 30 days)
        );
        new IndexPolicy(TIMELOCK, address(manager), bounds);

        bounds = _bounds();
        bounds.minPlanInterval = 5 minutes - 1;
        vm.expectRevert(
            abi.encodeWithSelector(IndexPolicy.IndexPolicy__InvalidBounds.selector, bytes32("planTiming"), 14 days)
        );
        new IndexPolicy(TIMELOCK, address(manager), bounds);

        bounds = _bounds();
        bounds.maxPlanDuration = 30 days + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IndexPolicy.IndexPolicy__InvalidBounds.selector, bytes32("planTiming"), 30 days + 1)
        );
        new IndexPolicy(TIMELOCK, address(manager), bounds);
    }

    function _poolConfig(PoolTypes.PoolKind kind) private pure returns (PoolTypes.PoolConfig memory config) {
        config.creator = CREATOR;
        config.policyFamilyId = FAMILY;
        config.kind = kind;
    }

    function _assets() private pure returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = address(0x1000);
        assets[1] = address(0x2000);
    }

    function _params(uint64 effectiveAt) private pure returns (RebalanceTypes.PolicyParams memory params) {
        params.weightsBps = new uint16[](2);
        params.weightsBps[0] = 5_000;
        params.weightsBps[1] = 5_000;
        params.epoch = 1;
        params.effectiveAt = effectiveAt;
        params.minPlanInterval = 1 days;
        params.planDuration = 7 days;
        params.triggerBps = 200;
        params.destinationBps = 175;
        params.maxTurnoverBps = 2_000;
        params.maxAssetAdjustmentBps = 1_000;
        params.startPremiumBps = 100;
        params.maxDiscountBps = 200;
        params.auctionDuration = 1 hours;
        params.maxOracleDeviationBps = 200;
        params.maxReferenceMoveBps = 500;
        params.policyFamilyId = FAMILY;
    }

    function _bounds() private pure returns (RebalanceTypes.GlobalPolicyBounds memory bounds) {
        bounds.minAssets = 2;
        bounds.maxAssets = 16;
        bounds.minWeightBps = 100;
        bounds.maxWeightBps = 9_000;
        bounds.minPolicyDelay = 1 hours;
        bounds.maxPolicyDelay = 30 days;
        bounds.minPlanInterval = 1 hours;
        bounds.maxPlanDuration = 14 days;
        bounds.maxTurnoverBps = 5_000;
        bounds.maxAssetAdjustmentBps = 2_500;
        bounds.maxStartPremiumBps = 500;
        bounds.maxDiscountBps = 1_000;
        bounds.minAuctionDuration = 5 minutes;
        bounds.maxAuctionDuration = 2 days;
        bounds.maxOracleDeviationBps = 500;
        bounds.maxReferenceMoveBps = 1_000;
    }
}
