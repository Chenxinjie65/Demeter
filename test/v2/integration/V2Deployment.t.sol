// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {AuctionRebalance} from "src/core/AuctionRebalance.sol";
import {DemeterBasketRouter} from "src/core/DemeterBasketRouter.sol";
import {DemeterManager} from "src/core/DemeterManager.sol";
import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {UniswapV3TwapOracle} from "src/oracle/UniswapV3TwapOracle.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";

contract V2DeploymentTest is Test {
    uint256 private constant DELAY = 1 days;
    address private constant GUARDIAN = address(0xB0B);

    function test_RealTimelockAtomicallyFreezesManagerLinks() public {
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        TimelockController timelock = new TimelockController(DELAY, proposers, executors, address(this));
        MockV2ERC20 quote = new MockV2ERC20("Quote", "QUOTE", 6);
        AssetRegistry registry = new AssetRegistry(address(timelock), GUARDIAN, address(quote), _poolBounds());
        DemeterManager manager = new DemeterManager(address(registry), address(timelock));
        IndexPolicy policy = new IndexPolicy(address(timelock), address(manager), _policyBounds());
        UniswapV3TwapOracle twap = new UniswapV3TwapOracle();
        AuctionRebalance auction =
            new AuctionRebalance(address(manager), address(policy), address(registry), address(twap));
        DemeterBasketRouter router = new DemeterBasketRouter(address(manager));

        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) =
            _wiringBatch(address(manager), address(policy), address(auction));
        bytes32 salt = keccak256("v2-wiring");
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertEq(manager.indexPolicy(), address(policy));
        assertEq(manager.auctionRebalance(), address(auction));
        assertEq(address(manager.registry()), address(registry));
        assertEq(manager.timelock(), address(timelock));
        assertEq(address(auction.manager()), address(manager));
        assertEq(address(auction.policy()), address(policy));
        assertEq(address(auction.registry()), address(registry));
        assertEq(address(auction.twapOracle()), address(twap));
        assertEq(address(router.manager()), address(manager));

        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(DemeterManager.DemeterManager__AlreadyConfigured.selector, bytes32("indexPolicy"))
        );
        manager.setIndexPolicy(address(policy));
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSelector(
                DemeterManager.DemeterManager__AlreadyConfigured.selector, bytes32("auctionRebalance")
            )
        );
        manager.setAuctionRebalance(address(auction));
    }

    function _wiringBatch(address manager, address policy, address auction)
        private
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        targets = new address[](2);
        values = new uint256[](2);
        payloads = new bytes[](2);
        targets[0] = manager;
        targets[1] = manager;
        payloads[0] = abi.encodeCall(IDemeterManager.setIndexPolicy, (policy));
        payloads[1] = abi.encodeCall(IDemeterManager.setAuctionRebalance, (auction));
    }

    function _poolBounds() private pure returns (PoolTypes.GlobalPoolBounds memory bounds) {
        bounds.minAssets = 2;
        bounds.maxAssets = 16;
        bounds.maxNameBytes = 64;
        bounds.maxSymbolBytes = 16;
        bounds.minInitialShareSupply = 1e18;
        bounds.maxInitialShareSupply = 1e30;
        bounds.minBootstrapDuration = 1 hours;
        bounds.maxBootstrapDuration = 30 days;
    }

    function _policyBounds() private pure returns (RebalanceTypes.GlobalPolicyBounds memory bounds) {
        bounds.minAssets = 2;
        bounds.maxAssets = 16;
        bounds.minWeightBps = 100;
        bounds.maxWeightBps = 9_000;
        bounds.minPolicyDelay = 1 days;
        bounds.maxPolicyDelay = 30 days;
        bounds.minPlanInterval = 1 days;
        bounds.maxPlanDuration = 14 days;
        bounds.maxTurnoverBps = 2_000;
        bounds.maxAssetAdjustmentBps = 1_000;
        bounds.maxStartPremiumBps = 200;
        bounds.maxDiscountBps = 500;
        bounds.minAuctionDuration = 30 minutes;
        bounds.maxAuctionDuration = 12 hours;
        bounds.maxOracleDeviationBps = 300;
        bounds.maxReferenceMoveBps = 500;
    }
}
