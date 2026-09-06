// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";
import {IAuctionRebalance} from "src/interfaces/IAuctionRebalance.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IDemeterShare} from "src/interfaces/IDemeterShare.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {ITwapOracle} from "src/interfaces/ITwapOracle.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {V2Validation} from "src/libraries/V2Validation.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";

contract V2ValidationHarness {
    function validateAssetList(address[] calldata assets) external pure {
        V2Validation.validateAssetList(assets);
    }

    function validateWeights(uint16[] calldata weights, uint256 expectedLength) external pure {
        V2Validation.validateWeights(weights, expectedLength);
    }

    function validateDestination(uint16 triggerBps, uint16 destinationBps) external pure {
        V2Validation.validateDestination(triggerBps, destinationBps);
    }

    function validateFuture(uint64 timestamp, uint256 currentTime) external pure {
        V2Validation.validateFuture(timestamp, currentTime);
    }
}

contract V2TypesAndInterfacesTest is Test {
    V2ValidationHarness private harness;

    function setUp() public {
        harness = new V2ValidationHarness();
    }

    function test_InterfacesCompileWithoutLegacyDependencies() public pure {
        // Referencing every interface and representative struct field keeps this
        // fixture useful as the V2 ABI evolves, without deploying implementations.
        IDemeterManager manager;
        IAssetRegistry registry;
        IDemeterShare share;
        IIndexPolicy policy;
        IAuctionRebalance auction;
        ITwapOracle twap;
        PoolTypes.PoolKey memory poolKey;
        PoolTypes.CreatePoolParams memory createParams;
        PoolTypes.IssueParams memory issueParams;
        PoolTypes.RedeemParams memory redeemParams;
        RebalanceTypes.PolicyParams memory policyParams;
        RebalanceTypes.PriceSnapshot memory snapshot;
        RebalanceTypes.RebalancePlan memory plan;
        RebalanceTypes.Auction memory auctionState;
        RebalanceTypes.BidParams memory bidParams;

        assertTrue(address(manager) == address(0));
        assertTrue(address(registry) == address(0));
        assertTrue(address(share) == address(0));
        assertTrue(address(policy) == address(0));
        assertTrue(address(auction) == address(0));
        assertTrue(address(twap) == address(0));
        assertTrue(poolKey.creator == address(0));
        assertTrue(createParams.bootstrapper == address(0));
        assertTrue(issueParams.receiver == address(0));
        assertTrue(redeemParams.receiver == address(0));
        assertTrue(policyParams.effectiveAt == 0);
        assertTrue(snapshot.capturedAt == 0);
        assertTrue(plan.nonce == 0);
        assertTrue(auctionState.nonce == 0);
        assertTrue(bidParams.receiver == address(0));
    }

    function test_Validation_RejectsEmptyAssetList() public {
        address[] memory assets = new address[](0);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__EmptyArray.selector, bytes32("assets")));
        harness.validateAssetList(assets);
    }

    function test_Validation_RejectsZeroAsset() public {
        address[] memory assets = new address[](1);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__ZeroAddress.selector, bytes32("asset")));
        harness.validateAssetList(assets);
    }

    function test_Validation_RejectsDuplicateAsset() public {
        address[] memory assets = new address[](2);
        assets[0] = address(0x1001);
        assets[1] = assets[0];

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__DuplicateAsset.selector, assets[0]));
        harness.validateAssetList(assets);
    }

    function test_Validation_RejectsUnsortedAssets() public {
        address[] memory assets = new address[](2);
        assets[0] = address(0x2002);
        assets[1] = address(0x1001);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__AssetsNotSorted.selector, assets[0], assets[1]));
        harness.validateAssetList(assets);
    }

    function testFuzz_Validation_AcceptsDistinctNonzeroAssets(address first, address second) public {
        if (first == address(0) || second == address(0) || first >= second) return;

        address[] memory assets = new address[](2);
        assets[0] = first;
        assets[1] = second;
        harness.validateAssetList(assets);
    }

    function test_Validation_RejectsWeightLengthMismatch() public {
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10_000;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__ArrayLengthMismatch.selector, 2, 1));
        harness.validateWeights(weights, 2);
    }

    function test_Validation_RejectsZeroWeight() public {
        uint16[] memory weights = new uint16[](2);
        weights[0] = 0;
        weights[1] = 10_000;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__ZeroWeight.selector, 0));
        harness.validateWeights(weights, 2);
    }

    function test_Validation_RejectsUnnormalizedWeights() public {
        uint16[] memory weights = new uint16[](2);
        weights[0] = 4_000;
        weights[1] = 5_999;

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__InvalidWeights.selector, 9_999));
        harness.validateWeights(weights, 2);
    }

    function testFuzz_Validation_AcceptsNormalizedWeights(uint16 firstWeight) public {
        firstWeight = uint16(bound(firstWeight, 1, 9_999));
        uint16[] memory weights = new uint16[](2);
        weights[0] = firstWeight;
        weights[1] = uint16(10_000 - firstWeight);

        harness.validateWeights(weights, 2);
    }

    function test_Validation_RejectsDestinationAtTrigger() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__InvalidBps.selector, bytes32("destinationBps"), 100));
        harness.validateDestination(100, 100);
    }

    function test_Validation_RejectsZeroTrigger() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__InvalidBps.selector, bytes32("triggerBps"), 0));
        harness.validateDestination(0, 0);
    }

    function test_Validation_AcceptsStrictDestination() public {
        harness.validateDestination(200, 175);
    }

    function test_Validation_RejectsNonFuturePolicy() public {
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PolicyNotDelayed.selector, 100, 100));
        harness.validateFuture(100, 100);
    }

    function test_Validation_AcceptsFuturePolicy() public {
        harness.validateFuture(101, 100);
    }
}
