// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {AuctionRebalance} from "src/core/AuctionRebalance.sol";
import {DemeterManager} from "src/core/DemeterManager.sol";
import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {UniswapV3TwapOracle} from "src/oracle/UniswapV3TwapOracle.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {MockV2ChainlinkFeed} from "test/v2/mocks/MockV2ChainlinkFeed.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";
import {MockV2UniswapPool} from "test/v2/mocks/MockV2UniswapPool.sol";

contract AuctionTargetPrecisionTest is Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BOOTSTRAPPER = address(0xB007);
    address private constant HOLDER = address(0xA11);
    bytes32 private constant FAMILY = keccak256("STATIC_INDEX_V1");

    AssetRegistry private registry;
    DemeterManager private manager;
    IndexPolicy private policy;
    AuctionRebalance private auction;
    MockV2ERC20 private quote;
    MockV2ERC20 private asset;
    MockV2ChainlinkFeed private quoteFeed;
    MockV2ChainlinkFeed private assetFeed;
    bytes32 private poolId;

    function setUp() public {
        vm.etch(TIMELOCK, hex"00");
        vm.warp(1_000_000);
        quote = new MockV2ERC20("Six Decimal Quote", "Q6", 6);
        asset = new MockV2ERC20("Six Decimal Asset", "A6", 6);
        quoteFeed = new MockV2ChainlinkFeed(8);
        assetFeed = new MockV2ChainlinkFeed(8);
        address token0 = address(asset) < address(quote) ? address(asset) : address(quote);
        address token1 = address(asset) < address(quote) ? address(quote) : address(asset);
        MockV2UniswapPool pool = new MockV2UniswapPool(token0, token1);
        registry = new AssetRegistry(TIMELOCK, GUARDIAN, address(quote), _poolBounds());
        vm.startPrank(TIMELOCK);
        registry.configureAsset(address(quote), _assetInput(address(quoteFeed), address(0)));
        registry.configureAsset(address(asset), _assetInput(address(assetFeed), address(pool)));
        vm.stopPrank();

        manager = new DemeterManager(address(registry), TIMELOCK);
        policy = new IndexPolicy(TIMELOCK, address(manager), _policyBounds());
        UniswapV3TwapOracle twap = new UniswapV3TwapOracle();
        auction = new AuctionRebalance(address(manager), address(policy), address(registry), address(twap));
        vm.startPrank(TIMELOCK);
        policy.setPolicyFamily(FAMILY, true);
        manager.setIndexPolicy(address(policy));
        manager.setAuctionRebalance(address(auction));
        vm.stopPrank();

        poolId = _createPool();
        _activateAndBootstrap();
    }

    function test_LowDecimalTargetDoesNotRoundToZeroAtMaximumShareSupply() public {
        auction.startPlan(poolId);
        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(poolId);
        assertEq(plan.referenceShareSupply, 1e30);
        assertEq(plan.targetRawAmounts[_index(address(asset))], 50e6);
        assertEq(plan.targetRawAmounts[_index(address(quote))], 50e6);

        auction.openAuction(poolId, address(asset), address(quote));
        PoolTypes.RedeemParams memory redeem;
        redeem.poolId = poolId;
        redeem.owner = HOLDER;
        redeem.sharesIn = 5e29;
        redeem.receiver = HOLDER;
        redeem.deadline = block.timestamp;
        redeem.minAmountsOut = new uint256[](2);
        vm.prank(HOLDER);
        manager.redeem(redeem);

        (uint256 sellAvailable, uint256 buyAvailable) = auction.liveAuctionCapacity(poolId);
        assertEq(sellAvailable, 12.5e6);
        assertEq(buyAvailable, 12.5e6);
    }

    function _createPool() private returns (bytes32 createdPoolId) {
        address[] memory assets = _sortedAssets();
        bytes32 salt = keccak256("precision-pool");
        createdPoolId = manager.derivePoolId(CREATOR, assets, FAMILY, salt);
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 hours));
        bytes32 initialHash =
            policy.computeInitialPolicyHash(createdPoolId, CREATOR, PoolTypes.PoolKind.MANAGED_INDEX, initial);
        PoolTypes.CreatePoolParams memory create;
        create.assets = assets;
        create.policyFamilyId = FAMILY;
        create.creatorSalt = salt;
        create.name = "Precision Index";
        create.symbol = "PREC";
        create.bootstrapper = BOOTSTRAPPER;
        create.bootstrapDeadline = uint64(block.timestamp + 10 days);
        create.initialShareSupply = 1e30;
        create.kind = PoolTypes.PoolKind.MANAGED_INDEX;
        create.seedAmounts = new uint256[](2);
        create.seedAmounts[0] = assets[0] == address(asset) ? 75e6 : 25e6;
        create.seedAmounts[1] = assets[1] == address(asset) ? 75e6 : 25e6;
        create.initialShareRecipient = HOLDER;
        create.initialPolicyHash = initialHash;
        vm.prank(CREATOR);
        manager.createPool(create);
    }

    function _activateAndBootstrap() private {
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 hours));
        vm.prank(CREATOR);
        policy.publishPolicy(poolId, initial);
        vm.warp(initial.effectiveAt);
        _refreshFeeds();
        policy.activatePolicy(poolId);
        quote.mint(BOOTSTRAPPER, 25e6);
        asset.mint(BOOTSTRAPPER, 75e6);
        vm.startPrank(BOOTSTRAPPER);
        quote.approve(address(manager), type(uint256).max);
        asset.approve(address(manager), type(uint256).max);
        vm.stopPrank();
        vm.prank(BOOTSTRAPPER);
        manager.bootstrap(poolId);
    }

    function _refreshFeeds() private {
        quoteFeed.setRound(2, 1e8, block.timestamp, block.timestamp, 2);
        assetFeed.setRound(2, 1e8, block.timestamp, block.timestamp, 2);
    }

    function _index(address token) private view returns (uint256) {
        return manager.getPoolAssets(poolId)[0] == token ? 0 : 1;
    }

    function _sortedAssets() private view returns (address[] memory assets) {
        assets = new address[](2);
        if (address(asset) < address(quote)) {
            assets[0] = address(asset);
            assets[1] = address(quote);
        } else {
            assets[0] = address(quote);
            assets[1] = address(asset);
        }
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
        bounds.minPolicyDelay = 1 hours;
        bounds.maxPolicyDelay = 30 days;
        bounds.minPlanInterval = 1 hours;
        bounds.maxPlanDuration = 14 days;
        bounds.maxTurnoverBps = 5_000;
        bounds.maxAssetAdjustmentBps = 5_000;
        bounds.maxStartPremiumBps = 500;
        bounds.maxDiscountBps = 1_000;
        bounds.minAuctionDuration = 5 minutes;
        bounds.maxAuctionDuration = 2 days;
        bounds.maxOracleDeviationBps = 500;
        bounds.maxReferenceMoveBps = 1_000;
    }

    function _policyParams(uint64 effectiveAt) private pure returns (RebalanceTypes.PolicyParams memory params) {
        params.weightsBps = new uint16[](2);
        params.weightsBps[0] = 5_000;
        params.weightsBps[1] = 5_000;
        params.epoch = effectiveAt;
        params.effectiveAt = effectiveAt;
        params.minPlanInterval = 1 hours;
        params.planDuration = 7 days;
        params.triggerBps = 200;
        params.destinationBps = 50;
        params.maxTurnoverBps = 5_000;
        params.maxAssetAdjustmentBps = 5_000;
        params.startPremiumBps = 100;
        params.maxDiscountBps = 200;
        params.auctionDuration = 1 hours;
        params.maxOracleDeviationBps = 200;
        params.maxReferenceMoveBps = 500;
        params.policyFamilyId = FAMILY;
    }

    function _assetInput(address feed, address pool) private pure returns (PoolTypes.AssetConfigInput memory input) {
        input.chainlinkFeed = feed;
        input.twapPool = pool;
        input.twapWindow = 30 minutes;
        input.maxChainlinkStale = 7 days;
        input.maxOracleDeviationBps = 200;
        input.maxReferenceMoveBps = 500;
    }
}
