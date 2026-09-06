// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";
import {Vm} from "@forge-std/Vm.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {AuctionRebalance} from "src/core/AuctionRebalance.sol";
import {DemeterManager} from "src/core/DemeterManager.sol";
import {DemeterShare} from "src/core/DemeterShare.sol";
import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {UniswapV3TwapOracle} from "src/oracle/UniswapV3TwapOracle.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {MockV2ChainlinkFeed} from "test/v2/mocks/MockV2ChainlinkFeed.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";
import {MockV2CallbackERC20} from "test/v2/mocks/MockV2CallbackERC20.sol";
import {MockV2UniswapPool} from "test/v2/mocks/MockV2UniswapPool.sol";

contract AuctionReentrancyHook {
    AuctionRebalance private immutable _auction;
    bytes32 private immutable _poolId;

    constructor(AuctionRebalance auction_, bytes32 poolId_) {
        _auction = auction_;
        _poolId = poolId_;
    }

    function startAndCancel() external {
        _auction.startPlan(_poolId);
        _auction.cancelPlan(_poolId);
    }

    function cancel() external {
        _auction.cancelPlan(_poolId);
    }

    function invalidate() external {
        _auction.invalidatePlan(_poolId);
    }
}

contract AuctionRebalanceTest is Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BOOTSTRAPPER = address(0xB007);
    address private constant HOLDER = address(0xA11);
    address private constant BIDDER = address(0xB1D);
    bytes32 private constant FAMILY = keccak256("STATIC_INDEX_V1");
    bytes32 private constant SALT = keccak256("auction-pool");

    AssetRegistry private registry;
    DemeterManager private manager;
    IndexPolicy private policy;
    UniswapV3TwapOracle private twapOracle;
    AuctionRebalance private auction;
    MockV2ERC20 private quote;
    MockV2CallbackERC20 private asset;
    MockV2ChainlinkFeed private quoteFeed;
    MockV2ChainlinkFeed private assetFeed;
    MockV2UniswapPool private twapPool;
    bytes32 private poolId;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(TIMELOCK, hex"00");
        quote = new MockV2ERC20("Quote", "QUOTE", 18);
        asset = new MockV2CallbackERC20("Asset", "ASSET", 18);
        quoteFeed = new MockV2ChainlinkFeed(8);
        assetFeed = new MockV2ChainlinkFeed(8);
        quoteFeed.setRound(1, 1e8, block.timestamp, block.timestamp, 1);
        assetFeed.setRound(1, 2e8, block.timestamp, block.timestamp, 1);

        address token0 = address(asset) < address(quote) ? address(asset) : address(quote);
        address token1 = address(asset) < address(quote) ? address(quote) : address(asset);
        twapPool = new MockV2UniswapPool(token0, token1);
        twapPool.setMeanTick(address(asset) < address(quote) ? int24(6931) : int24(-6931));

        registry = new AssetRegistry(TIMELOCK, GUARDIAN, address(quote), _poolBounds());
        vm.startPrank(TIMELOCK);
        registry.configureAsset(address(quote), _assetInput(address(quoteFeed), address(0)));
        registry.configureAsset(address(asset), _assetInput(address(assetFeed), address(twapPool)));
        vm.stopPrank();

        manager = new DemeterManager(address(registry), TIMELOCK);
        policy = new IndexPolicy(TIMELOCK, address(manager), _policyBounds());
        twapOracle = new UniswapV3TwapOracle();
        auction = new AuctionRebalance(address(manager), address(policy), address(registry), address(twapOracle));
        vm.startPrank(TIMELOCK);
        policy.setPolicyFamily(FAMILY, true);
        manager.setIndexPolicy(address(policy));
        manager.setAuctionRebalance(address(auction));
        vm.stopPrank();

        poolId = _createPool();
        _activateAndBootstrap();
    }

    function test_StartPlanStoresExactSnapshotTargetsWithoutMovingAssets() public {
        uint256 assetBefore = manager.reserveOf(poolId, address(asset));
        uint256 quoteBefore = manager.reserveOf(poolId, address(quote));
        uint256 supplyBefore = DemeterShare(manager.poolShare(poolId)).totalSupply();

        assertEq(auction.startPlan(poolId), 1);
        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(poolId);
        assertEq(uint8(plan.state), uint8(RebalanceTypes.RebalanceState.PLANNED));
        assertEq(plan.referenceShareSupply, supplyBefore);
        assertEq(plan.referenceValueWad, 200e18);
        assertEq(plan.targetRawAmounts[_assetIndex(address(asset))], 50e18);
        assertEq(plan.targetRawAmounts[_assetIndex(address(quote))], 100e18);
        assertEq(plan.turnoverBudgetWad, 50e18);
        assertEq(manager.reserveOf(poolId, address(asset)), assetBefore);
        assertEq(manager.reserveOf(poolId, address(quote)), quoteBefore);
        assertEq(DemeterShare(manager.poolShare(poolId)).totalSupply(), supplyBefore);
    }

    function test_OpenAuctionUsesFrozenCurveAndLiveSurplusDeficit() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        RebalanceTypes.Auction memory opened = auction.getAuction(poolId);

        assertEq(nonce, 1);
        assertTrue(opened.active);
        assertEq(opened.sellLimit, 25e18);
        assertEq(opened.buyLimit, 50e18);
        assertEq(opened.startPriceWad, 2.02e18);
        assertEq(opened.endPriceWad, 1.96e18);
        assertEq(opened.endTime - opened.startTime, 1 hours);
    }

    function test_RepeatedPartialBidsDoNotResetOrCloseAuction() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();

        uint256 firstPayment = _bid(nonce, 1e18);
        RebalanceTypes.Auction memory afterFirst = auction.getAuction(poolId);
        assertTrue(afterFirst.active);
        assertEq(afterFirst.sellFilled, 1e18);
        assertEq(afterFirst.buyReceived, firstPayment);
        assertEq(afterFirst.startTime, block.timestamp);

        uint256 secondPayment = _bid(nonce, 1e18);
        RebalanceTypes.Auction memory afterSecond = auction.getAuction(poolId);
        assertTrue(afterSecond.active);
        assertEq(afterSecond.sellFilled, 2e18);
        assertEq(afterSecond.buyReceived, firstPayment + secondPayment);
        assertEq(asset.balanceOf(BIDDER), 2e18);
        assertEq(manager.reserveOf(poolId, address(asset)), 73e18);
        assertEq(manager.reserveOf(poolId, address(quote)), 50e18 + firstPayment + secondPayment);
    }

    function test_QuoteBidMatchesExecutablePaymentInTheSameBlock() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();

        uint256 quoted = auction.quoteBid(poolId, nonce, 1e18);
        uint256 executed = _bid(nonce, 1e18);
        assertEq(quoted, executed);
    }

    function test_QuoteBidFailsClosedWhenAuctionExpires() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.V2Errors__AuctionExpired.selector, block.timestamp - 1, block.timestamp)
        );
        auction.quoteBid(poolId, nonce, 1e18);
    }

    function test_RedemptionShrinksLiveLotAndManagerCannotUseFrozenLargerLot() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));

        PoolTypes.RedeemParams memory redeem;
        redeem.poolId = poolId;
        redeem.owner = HOLDER;
        redeem.sharesIn = 50e18;
        redeem.receiver = HOLDER;
        redeem.deadline = block.timestamp;
        redeem.minAmountsOut = new uint256[](2);
        vm.prank(HOLDER);
        manager.redeem(redeem);

        (uint256 sellAvailable, uint256 buyAvailable) = auction.liveAuctionCapacity(poolId);
        assertEq(sellAvailable, 12.5e18);
        assertEq(buyAvailable, 25e18);

        _fundBidder();
        RebalanceTypes.BidParams memory bidParams = _bidParams(nonce, 13e18);
        vm.prank(BIDDER);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.V2Errors__BidTooLarge.selector, 13e18, 12_376_237_623_762_376_237)
        );
        auction.bid(bidParams);
    }

    function test_BidChecksBothAssetsAndFrozenPairReference() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();

        quoteFeed.setRound(2, 2e8, block.timestamp, block.timestamp, 2);
        assetFeed.setRound(2, 4e8, block.timestamp, block.timestamp, 2);
        RebalanceTypes.BidParams memory bidParams = _bidParams(nonce, 1e18);
        vm.prank(BIDDER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("referenceMove")));
        auction.bid(bidParams);
    }

    function test_OpenAuctionChecksLiveSequencerState() public {
        MockV2ChainlinkFeed sequencer = new MockV2ChainlinkFeed(0);
        sequencer.setRound(1, 0, block.timestamp - 1 hours, block.timestamp, 1);
        vm.prank(TIMELOCK);
        registry.setSequencerConfig(address(sequencer), 60);
        auction.startPlan(poolId);

        sequencer.setRound(2, 1, block.timestamp, block.timestamp, 2);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("sequencerDown")));
        auction.openAuction(poolId, address(asset), address(quote));
    }

    function test_ConfigChangeInvalidatesPlanPermissionlessly() public {
        auction.startPlan(poolId);
        vm.prank(TIMELOCK);
        registry.configureAsset(address(asset), _assetInput(address(assetFeed), address(twapPool)));

        vm.prank(address(0xCA11));
        auction.invalidatePlan(poolId);
        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(poolId);
        assertEq(uint8(plan.state), uint8(RebalanceTypes.RebalanceState.CANCELLED));
        assertFalse(auction.isPoolLocked(poolId));
    }

    function test_ExpiredAuctionReturnsPlanToPlannedWithoutMovingReserves() public {
        auction.startPlan(poolId);
        auction.openAuction(poolId, address(asset), address(quote));
        uint256 assetReserve = manager.reserveOf(poolId, address(asset));
        uint256 quoteReserve = manager.reserveOf(poolId, address(quote));

        vm.warp(block.timestamp + 1 hours + 1);
        auction.expireAuction(poolId);
        assertEq(uint8(auction.getPlan(poolId).state), uint8(RebalanceTypes.RebalanceState.PLANNED));
        assertEq(manager.reserveOf(poolId, address(asset)), assetReserve);
        assertEq(manager.reserveOf(poolId, address(quote)), quoteReserve);
    }

    function test_ExpiredPlanMustBeInvalidatedBeforeStartingNextEligiblePlan() public {
        auction.startPlan(poolId);
        vm.warp(block.timestamp + 7 days + 1);
        _refreshPrices();
        auction.invalidatePlan(poolId);
        assertEq(auction.startPlan(poolId), 2);
        assertEq(uint8(auction.getPlan(poolId).state), uint8(RebalanceTypes.RebalanceState.PLANNED));
    }

    function test_ExpiredPlanUnlocksFullRedemptionAfterPermissionlessInvalidation() public {
        auction.startPlan(poolId);
        vm.warp(block.timestamp + 7 days + 1);
        assertTrue(auction.isPoolLocked(poolId));

        auction.invalidatePlan(poolId);
        assertFalse(auction.isPoolLocked(poolId));

        PoolTypes.RedeemParams memory redeem;
        redeem.poolId = poolId;
        redeem.owner = HOLDER;
        redeem.sharesIn = 100e18;
        redeem.receiver = HOLDER;
        redeem.deadline = block.timestamp;
        redeem.minAmountsOut = new uint256[](2);
        vm.prank(HOLDER);
        manager.redeem(redeem);
        assertTrue(manager.isPoolClosed(poolId));
    }

    function test_EndedAuctionCannotBeReboundToANewPlan() public {
        auction.startPlan(poolId);
        uint64 firstAuction = auction.openAuction(poolId, address(asset), address(quote));
        RebalanceTypes.Auction memory opened = auction.getAuction(poolId);
        vm.warp(opened.endTime + 1);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PlanAlreadyActive.selector, poolId));
        auction.startPlan(poolId);
        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(poolId);
        RebalanceTypes.Auction memory stale = auction.getAuction(poolId);
        assertEq(plan.nonce, 1);
        assertTrue(stale.active);

        auction.expireAuction(poolId);
        assertFalse(auction.getAuction(poolId).active);

        _fundBidder();
        RebalanceTypes.BidParams memory params = _bidParams(firstAuction, 1e18);
        vm.prank(BIDDER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__AuctionNotActive.selector, poolId, firstAuction));
        auction.bid(params);
    }

    function test_PartialFillsSettleOnceDestinationIsReached() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();

        _bid(nonce, 24e18);
        assertTrue(auction.getAuction(poolId).active);
        _bid(nonce, 0.75e18);

        assertFalse(auction.getAuction(poolId).active);
        assertEq(uint8(auction.getPlan(poolId).state), uint8(RebalanceTypes.RebalanceState.SETTLED));
        assertFalse(auction.isPoolLocked(poolId));
    }

    function test_GuardianPauseBlocksIssueButNeverRedemption() public {
        vm.prank(GUARDIAN);
        auction.setPaused(true);

        PoolTypes.IssueParams memory issueParams;
        issueParams.poolId = poolId;
        issueParams.sharesOut = 1e18;
        issueParams.receiver = BIDDER;
        issueParams.deadline = block.timestamp;
        issueParams.maxAmountsIn = new uint256[](2);
        vm.prank(BIDDER);
        vm.expectRevert(V2Errors.V2Errors__Paused.selector);
        manager.issue(issueParams);

        PoolTypes.RedeemParams memory redeem;
        redeem.poolId = poolId;
        redeem.owner = HOLDER;
        redeem.sharesIn = 1e18;
        redeem.receiver = HOLDER;
        redeem.deadline = block.timestamp;
        redeem.minAmountsOut = new uint256[](2);
        vm.prank(HOLDER);
        manager.redeem(redeem);
        assertEq(DemeterShare(manager.poolShare(poolId)).balanceOf(HOLDER), 99e18);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(AuctionRebalance.AuctionRebalance__Unauthorized.selector, GUARDIAN));
        auction.setPaused(false);
        vm.prank(TIMELOCK);
        auction.setPaused(false);
        assertFalse(auction.paused());
    }

    function test_IssueRejectsCrossContractPlanReentrancyFromTokenCallback() public {
        AuctionReentrancyHook hook = new AuctionReentrancyHook(auction, poolId);
        vm.prank(TIMELOCK);
        registry.setGuardian(address(hook));
        asset.setTransferFromHook(address(hook), abi.encodeCall(AuctionReentrancyHook.startAndCancel, ()));

        asset.mint(BIDDER, 100e18);
        vm.prank(BIDDER);
        asset.approve(address(manager), type(uint256).max);
        quote.mint(BIDDER, 100e18);
        vm.prank(BIDDER);
        quote.approve(address(manager), type(uint256).max);

        PoolTypes.IssueParams memory params;
        params.poolId = poolId;
        params.sharesOut = 1e18;
        params.receiver = BIDDER;
        params.deadline = block.timestamp;
        params.maxAmountsIn = manager.quoteIssue(poolId, params.sharesOut);

        vm.prank(BIDDER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PoolLocked.selector, poolId));
        manager.issue(params);

        assertEq(DemeterShare(manager.poolShare(poolId)).totalSupply(), 100e18);
        assertEq(uint8(auction.getPlan(poolId).state), uint8(RebalanceTypes.RebalanceState.NONE));
    }

    function test_BidRejectsGuardianCancelReentrancyFromTokenCallback() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();

        AuctionReentrancyHook hook = new AuctionReentrancyHook(auction, poolId);
        vm.prank(TIMELOCK);
        registry.setGuardian(address(hook));
        asset.setTransferFromHook(address(hook), abi.encodeCall(AuctionReentrancyHook.cancel, ()));

        uint256 reserveBefore = manager.reserveOf(poolId, address(asset));
        vm.prank(BIDDER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PoolLocked.selector, poolId));
        auction.bid(_bidParams(nonce, 1e18));

        assertEq(manager.reserveOf(poolId, address(asset)), reserveBefore);
        assertEq(auction.getAuction(poolId).sellFilled, 0);
        assertEq(uint8(auction.getPlan(poolId).state), uint8(RebalanceTypes.RebalanceState.AUCTION_ACTIVE));
    }

    function test_RedeemKeepsValidPlanWhenTokenCallbackTriesToInvalidate() public {
        auction.startPlan(poolId);
        AuctionReentrancyHook hook = new AuctionReentrancyHook(auction, poolId);
        asset.setTransferFromHook(address(hook), abi.encodeCall(AuctionReentrancyHook.invalidate, ()));
        asset.setBubbleFailure(false);

        PoolTypes.RedeemParams memory redeem;
        redeem.poolId = poolId;
        redeem.owner = HOLDER;
        redeem.sharesIn = 1e18;
        redeem.receiver = HOLDER;
        redeem.deadline = block.timestamp;
        redeem.minAmountsOut = new uint256[](2);
        vm.prank(HOLDER);
        manager.redeem(redeem);

        assertEq(uint8(auction.getPlan(poolId).state), uint8(RebalanceTypes.RebalanceState.PLANNED));
        assertEq(DemeterShare(manager.poolShare(poolId)).balanceOf(HOLDER), 99e18);
    }

    function test_OnlyGuardianCanUnconditionallyCancelAuction() public {
        auction.startPlan(poolId);
        auction.openAuction(poolId, address(asset), address(quote));

        vm.prank(BIDDER);
        vm.expectRevert(abi.encodeWithSelector(AuctionRebalance.AuctionRebalance__Unauthorized.selector, BIDDER));
        auction.cancelPlan(poolId);

        vm.prank(GUARDIAN);
        auction.cancelPlan(poolId);
        assertFalse(auction.getAuction(poolId).active);
        assertEq(uint8(auction.getPlan(poolId).state), uint8(RebalanceTypes.RebalanceState.CANCELLED));
    }

    function test_OnlyGuardianCanCancelAPlannedButTemporarilyUnexecutablePlan() public {
        auction.startPlan(poolId);
        vm.prank(BIDDER);
        vm.expectRevert(abi.encodeWithSelector(AuctionRebalance.AuctionRebalance__Unauthorized.selector, BIDDER));
        auction.cancelPlan(poolId);

        vm.prank(GUARDIAN);
        auction.cancelPlan(poolId);
        assertEq(uint8(auction.getPlan(poolId).state), uint8(RebalanceTypes.RebalanceState.CANCELLED));
        assertFalse(auction.isPoolLocked(poolId));
    }

    function test_BidRejectsWrongNonceAndMaximumPayment() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();

        RebalanceTypes.BidParams memory params = _bidParams(nonce + 1, 1e18);
        vm.prank(BIDDER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__AuctionNotActive.selector, poolId, nonce + 1));
        auction.bid(params);

        params.auctionNonce = nonce;
        params.maxBuyAmount = 0;
        vm.prank(BIDDER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PriceTooLow.selector, 0, 2.02e18));
        auction.bid(params);
    }

    function test_ExactEndTimeStillUsesEndPriceAndNextSecondExpires() public {
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();
        RebalanceTypes.Auction memory opened = auction.getAuction(poolId);
        vm.warp(opened.endTime);

        assertEq(auction.currentPrice(poolId), opened.endPriceWad);
        _bid(nonce, 1e18);
        vm.warp(opened.endTime + 1);
        auction.expireAuction(poolId);
        assertFalse(auction.getAuction(poolId).active);
    }

    function test_ThreeAssetTargetsUseOneScaleAndPreservePlannedValue() public {
        MockV2ERC20 third = new MockV2ERC20("Third", "THIRD", 18);
        MockV2ChainlinkFeed thirdFeed = new MockV2ChainlinkFeed(8);
        thirdFeed.setRound(1, 1e8, block.timestamp, block.timestamp, 1);
        address token0 = address(third) < address(quote) ? address(third) : address(quote);
        address token1 = address(third) < address(quote) ? address(quote) : address(third);
        MockV2UniswapPool thirdPool = new MockV2UniswapPool(token0, token1);
        vm.prank(TIMELOCK);
        registry.configureAsset(address(third), _assetInput(address(thirdFeed), address(thirdPool)));

        address[] memory assets = new address[](3);
        assets[0] = address(asset);
        assets[1] = address(quote);
        assets[2] = address(third);
        _sortThree(assets);
        bytes32 salt = keccak256("three-asset-pool");
        bytes32 threePoolId = manager.derivePoolId(CREATOR, assets, FAMILY, salt);
        RebalanceTypes.PolicyParams memory initial = _threeAssetPolicy(uint64(block.timestamp + 1 hours));
        bytes32 initialHash =
            policy.computeInitialPolicyHash(threePoolId, CREATOR, PoolTypes.PoolKind.MANAGED_INDEX, initial);
        PoolTypes.CreatePoolParams memory create;
        create.assets = assets;
        create.policyFamilyId = FAMILY;
        create.creatorSalt = salt;
        create.name = "Three Asset Index";
        create.symbol = "THREE";
        create.bootstrapper = BOOTSTRAPPER;
        create.bootstrapDeadline = uint64(block.timestamp + 10 days);
        create.initialShareSupply = 100e18;
        create.kind = PoolTypes.PoolKind.MANAGED_INDEX;
        create.seedAmounts = new uint256[](3);
        for (uint256 i; i < assets.length; ++i) {
            create.seedAmounts[i] = assets[i] == address(asset) ? 300e18 : 1e18;
        }
        create.initialShareRecipient = HOLDER;
        create.initialPolicyHash = initialHash;
        vm.prank(CREATOR);
        manager.createPool(create);
        vm.prank(CREATOR);
        policy.publishPolicy(threePoolId, initial);
        vm.warp(initial.effectiveAt);
        _refreshPrices();
        thirdFeed.setRound(2, 1e8, block.timestamp, block.timestamp, 2);
        policy.activatePolicy(threePoolId);

        asset.mint(BOOTSTRAPPER, 300e18);
        quote.mint(BOOTSTRAPPER, 1e18);
        third.mint(BOOTSTRAPPER, 1e18);
        vm.startPrank(BOOTSTRAPPER);
        third.approve(address(manager), type(uint256).max);
        vm.stopPrank();
        vm.prank(BOOTSTRAPPER);
        manager.bootstrap(threePoolId);
        auction.startPlan(threePoolId);

        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(threePoolId);
        uint256 plannedSellValue;
        uint256 plannedBuyValue;
        uint256 perAssetCap = plan.referenceValueWad * 2_500 / 10_000;
        for (uint256 i; i < assets.length; ++i) {
            uint256 current = manager.reserveOf(threePoolId, assets[i]);
            uint256 target = plan.targetRawAmounts[i];
            uint256 delta = current > target ? current - target : target - current;
            uint256 deltaValue = delta * plan.referencePricesWad[i] / 1e18;
            assertLe(deltaValue, perAssetCap);
            if (current > target) plannedSellValue += deltaValue;
            else plannedBuyValue += deltaValue;
        }
        assertApproxEqAbs(plannedSellValue, plannedBuyValue, 10);
        assertEq(plan.turnoverBudgetWad, plannedSellValue < plannedBuyValue ? plannedSellValue : plannedBuyValue);

        twapPool.setMeanTick(address(asset) < address(quote) ? int24(7_120) : int24(-7_120));
        thirdPool.setMeanTick(address(third) < address(quote) ? int24(-192) : int24(192));
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("sourceDivergence")));
        auction.openAuction(threePoolId, address(asset), address(third));
    }

    function test_Integration_PermissionlessLifecycleThroughPartialAuctionFill() public {
        uint256 sharesOut = 10e18;
        uint256[] memory issueQuote = manager.quoteIssue(poolId, sharesOut);
        address[] memory assets = manager.getPoolAssets(poolId);
        for (uint256 i; i < assets.length; ++i) {
            MockV2ERC20(assets[i]).mint(BIDDER, issueQuote[i]);
            vm.prank(BIDDER);
            MockV2ERC20(assets[i]).approve(address(manager), type(uint256).max);
        }
        PoolTypes.IssueParams memory issue;
        issue.poolId = poolId;
        issue.sharesOut = sharesOut;
        issue.receiver = BIDDER;
        issue.deadline = block.timestamp;
        issue.maxAmountsIn = issueQuote;
        vm.prank(BIDDER);
        manager.issue(issue);

        PoolTypes.RedeemParams memory redeem;
        redeem.poolId = poolId;
        redeem.owner = BIDDER;
        redeem.sharesIn = 5e18;
        redeem.receiver = BIDDER;
        redeem.deadline = block.timestamp;
        redeem.minAmountsOut = new uint256[](2);
        vm.prank(BIDDER);
        manager.redeem(redeem);

        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();
        uint256 payment = _bid(nonce, 1e18);
        assertGt(payment, 0);
        assertEq(manager.accountedReserve(address(asset)), asset.balanceOf(address(manager)));
        assertEq(manager.accountedReserve(address(quote)), quote.balanceOf(address(manager)));
        assertEq(DemeterShare(manager.poolShare(poolId)).totalSupply(), 105e18);
    }

    function test_TurnoverBudgetExhaustionFinalizesPlan() public {
        address[] memory assets = _sortedAssets();
        bytes32 salt = keccak256("turnover-budget-pool");
        bytes32 budgetPoolId = manager.derivePoolId(CREATOR, assets, FAMILY, salt);
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 hours));
        initial.destinationBps = 0;
        initial.maxTurnoverBps = 1_000;
        bytes32 initialHash =
            policy.computeInitialPolicyHash(budgetPoolId, CREATOR, PoolTypes.PoolKind.MANAGED_INDEX, initial);
        PoolTypes.CreatePoolParams memory create;
        create.assets = assets;
        create.policyFamilyId = FAMILY;
        create.creatorSalt = salt;
        create.name = "Turnover Budget Index";
        create.symbol = "BUDGET";
        create.bootstrapper = BOOTSTRAPPER;
        create.bootstrapDeadline = uint64(block.timestamp + 10 days);
        create.initialShareSupply = 100e18;
        create.kind = PoolTypes.PoolKind.MANAGED_INDEX;
        create.seedAmounts = new uint256[](2);
        create.seedAmounts[0] = _seedFor(assets[0]);
        create.seedAmounts[1] = _seedFor(assets[1]);
        create.initialShareRecipient = HOLDER;
        create.initialPolicyHash = initialHash;
        vm.prank(CREATOR);
        manager.createPool(create);
        vm.prank(CREATOR);
        policy.publishPolicy(budgetPoolId, initial);
        vm.warp(initial.effectiveAt);
        _refreshPrices();
        policy.activatePolicy(budgetPoolId);
        asset.mint(BOOTSTRAPPER, 75e18);
        quote.mint(BOOTSTRAPPER, 50e18);
        vm.prank(BOOTSTRAPPER);
        manager.bootstrap(budgetPoolId);

        auction.startPlan(budgetPoolId);
        uint64 nonce = auction.openAuction(budgetPoolId, address(asset), address(quote));
        quote.mint(BIDDER, 100e18);
        vm.prank(BIDDER);
        quote.approve(address(manager), type(uint256).max);
        RebalanceTypes.Auction memory opened = auction.getAuction(budgetPoolId);
        vm.warp(opened.endTime);
        RebalanceTypes.BidParams memory bidParams;
        bidParams.poolId = budgetPoolId;
        bidParams.auctionNonce = nonce;
        bidParams.sellAmount = 10e18;
        bidParams.maxBuyAmount = type(uint256).max;
        bidParams.receiver = BIDDER;
        vm.prank(BIDDER);
        auction.bid(bidParams);

        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(budgetPoolId);
        assertEq(plan.turnoverConsumedWad, plan.turnoverBudgetWad);
        assertEq(uint8(plan.state), uint8(RebalanceTypes.RebalanceState.SETTLED));
        assertFalse(auction.getAuction(budgetPoolId).active);
        assertFalse(auction.isPoolLocked(budgetPoolId));
    }

    function test_EventsReconstructPlanAuctionAndFillViews() public {
        vm.recordLogs();
        auction.startPlan(poolId);
        uint64 nonce = auction.openAuction(poolId, address(asset), address(quote));
        _fundBidder();
        uint256 payment = _bid(nonce, 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 planSignature = keccak256("PlanStarted(bytes32,uint64,uint64,uint256,uint256,uint64)");
        bytes32 openSignature =
            keccak256("AuctionOpened(bytes32,uint64,address,address,uint256,uint256,uint256,uint256,uint64,uint64)");
        bytes32 bidSignature = keccak256("AuctionBid(bytes32,uint64,address,uint256,uint256,uint256)");
        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(poolId);
        RebalanceTypes.Auction memory opened = auction.getAuction(poolId);
        bool foundPlan;
        bool foundOpen;
        bool foundBid;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(auction) || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == planSignature) {
                (uint64 policyVersion, uint256 referenceValue, uint256 budget, uint64 expiresAt) =
                    abi.decode(logs[i].data, (uint64, uint256, uint256, uint64));
                assertEq(logs[i].topics[1], poolId);
                assertEq(uint64(uint256(logs[i].topics[2])), plan.nonce);
                assertEq(policyVersion, plan.policyVersion);
                assertEq(referenceValue, plan.referenceValueWad);
                assertEq(budget, plan.turnoverBudgetWad);
                assertEq(expiresAt, plan.expiresAt);
                foundPlan = true;
            } else if (logs[i].topics[0] == openSignature) {
                (
                    address sellToken,
                    address buyToken,
                    uint256 sellLimit,
                    uint256 buyLimit,
                    uint256 startPrice,
                    uint256 endPrice,
                    uint64 startTime,
                    uint64 endTime
                ) = abi.decode(logs[i].data, (address, address, uint256, uint256, uint256, uint256, uint64, uint64));
                assertEq(logs[i].topics[1], poolId);
                assertEq(uint64(uint256(logs[i].topics[2])), opened.nonce);
                assertEq(sellToken, opened.sellToken);
                assertEq(buyToken, opened.buyToken);
                assertEq(sellLimit, opened.sellLimit);
                assertEq(buyLimit, opened.buyLimit);
                assertEq(startPrice, opened.startPriceWad);
                assertEq(endPrice, opened.endPriceWad);
                assertEq(startTime, opened.startTime);
                assertEq(endTime, opened.endTime);
                foundOpen = true;
            } else if (logs[i].topics[0] == bidSignature) {
                (uint256 sellAmount, uint256 buyAmount, uint256 turnoverConsumed) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(logs[i].topics[1], poolId);
                assertEq(uint64(uint256(logs[i].topics[2])), opened.nonce);
                assertEq(address(uint160(uint256(logs[i].topics[3]))), BIDDER);
                assertEq(sellAmount, 1e18);
                assertEq(buyAmount, payment);
                assertEq(turnoverConsumed, plan.turnoverConsumedWad);
                foundBid = true;
            }
        }
        assertTrue(foundPlan && foundOpen && foundBid);
    }

    function _createPool() private returns (bytes32 createdPoolId) {
        address[] memory assets = _sortedAssets();
        createdPoolId = manager.derivePoolId(CREATOR, assets, FAMILY, SALT);
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 hours));
        bytes32 initialHash =
            policy.computeInitialPolicyHash(createdPoolId, CREATOR, PoolTypes.PoolKind.MANAGED_INDEX, initial);

        PoolTypes.CreatePoolParams memory params;
        params.assets = assets;
        params.policyFamilyId = FAMILY;
        params.creatorSalt = SALT;
        params.name = "Auction Index";
        params.symbol = "AIDX";
        params.bootstrapper = BOOTSTRAPPER;
        params.bootstrapDeadline = uint64(block.timestamp + 10 days);
        params.initialShareSupply = 100e18;
        params.kind = PoolTypes.PoolKind.MANAGED_INDEX;
        params.seedAmounts = new uint256[](2);
        params.seedAmounts[0] = _seedFor(assets[0]);
        params.seedAmounts[1] = _seedFor(assets[1]);
        params.initialShareRecipient = HOLDER;
        params.initialPolicyHash = initialHash;
        vm.prank(CREATOR);
        manager.createPool(params);
    }

    function _activateAndBootstrap() private {
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 hours));
        vm.prank(CREATOR);
        policy.publishPolicy(poolId, initial);
        vm.warp(initial.effectiveAt);
        _refreshPrices();
        policy.activatePolicy(poolId);

        quote.mint(BOOTSTRAPPER, 50e18);
        asset.mint(BOOTSTRAPPER, 75e18);
        vm.startPrank(BOOTSTRAPPER);
        quote.approve(address(manager), type(uint256).max);
        asset.approve(address(manager), type(uint256).max);
        vm.stopPrank();
        vm.prank(BOOTSTRAPPER);
        manager.bootstrap(poolId);
    }

    function _fundBidder() private {
        quote.mint(BIDDER, 1_000e18);
        vm.prank(BIDDER);
        quote.approve(address(manager), type(uint256).max);
    }

    function _bid(uint64 nonce, uint256 sellAmount) private returns (uint256 payment) {
        RebalanceTypes.BidParams memory params = _bidParams(nonce, sellAmount);
        vm.prank(BIDDER);
        payment = auction.bid(params);
    }

    function _bidParams(uint64 nonce, uint256 sellAmount)
        private
        view
        returns (RebalanceTypes.BidParams memory params)
    {
        params.poolId = poolId;
        params.auctionNonce = nonce;
        params.sellAmount = sellAmount;
        params.maxBuyAmount = type(uint256).max;
        params.receiver = BIDDER;
    }

    function _refreshPrices() private {
        quoteFeed.setRound(quoteFeed.roundId() + 1, 1e8, block.timestamp, block.timestamp, quoteFeed.roundId() + 1);
        assetFeed.setRound(assetFeed.roundId() + 1, 2e8, block.timestamp, block.timestamp, assetFeed.roundId() + 1);
    }

    function _assetIndex(address token) private view returns (uint256) {
        return manager.getPoolAssets(poolId)[0] == token ? 0 : 1;
    }

    function _sortThree(address[] memory assets) private pure {
        for (uint256 i; i < assets.length; ++i) {
            for (uint256 j = i + 1; j < assets.length; ++j) {
                if (assets[j] < assets[i]) (assets[i], assets[j]) = (assets[j], assets[i]);
            }
        }
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

    function _seedFor(address token) private view returns (uint256) {
        return token == address(asset) ? 75e18 : 50e18;
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

    function _threeAssetPolicy(uint64 effectiveAt) private pure returns (RebalanceTypes.PolicyParams memory params) {
        params = _policyParams(effectiveAt);
        params.weightsBps = new uint16[](3);
        params.weightsBps[0] = 3_334;
        params.weightsBps[1] = 3_333;
        params.weightsBps[2] = 3_333;
        params.maxAssetAdjustmentBps = 2_500;
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
