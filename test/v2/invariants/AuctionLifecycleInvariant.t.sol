// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "@forge-std/StdInvariant.sol";
import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {AuctionRebalance} from "src/core/AuctionRebalance.sol";
import {DemeterManager} from "src/core/DemeterManager.sol";
import {DemeterShare} from "src/core/DemeterShare.sol";
import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {UniswapV3TwapOracle} from "src/oracle/UniswapV3TwapOracle.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {MockV2ChainlinkFeed} from "test/v2/mocks/MockV2ChainlinkFeed.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";
import {MockV2UniswapPool} from "test/v2/mocks/MockV2UniswapPool.sol";

contract AuctionLifecycleHandler is Test {
    address private constant GUARDIAN = address(0xB0B);
    address private constant TIMELOCK = address(0xA11CE);

    DemeterManager public immutable manager;
    AuctionRebalance public immutable auction;
    DemeterShare public immutable share;
    MockV2ERC20 public immutable sellToken;
    MockV2ERC20 public immutable buyToken;
    MockV2ChainlinkFeed public immutable sellFeed;
    MockV2ChainlinkFeed public immutable buyFeed;
    bytes32 public immutable poolId;

    address[] private _actors;

    constructor(
        DemeterManager manager_,
        AuctionRebalance auction_,
        DemeterShare share_,
        MockV2ERC20 sellToken_,
        MockV2ERC20 buyToken_,
        MockV2ChainlinkFeed sellFeed_,
        MockV2ChainlinkFeed buyFeed_,
        bytes32 poolId_,
        address[] memory actors_
    ) {
        manager = manager_;
        auction = auction_;
        share = share_;
        sellToken = sellToken_;
        buyToken = buyToken_;
        sellFeed = sellFeed_;
        buyFeed = buyFeed_;
        poolId = poolId_;
        _actors = actors_;
    }

    function issue(uint256 actorSeed, uint96 rawShares) external {
        if (auction.paused() || auction.isPoolLocked(poolId)) return;
        address actor = _actor(actorSeed);
        uint256 sharesOut = bound(uint256(rawShares), 1e12, 5e18);
        uint256[] memory quote = manager.quoteIssue(poolId, sharesOut);
        address[] memory assets = manager.getPoolAssets(poolId);
        for (uint256 i; i < assets.length; ++i) {
            MockV2ERC20(assets[i]).mint(actor, quote[i]);
            vm.prank(actor);
            IERC20(assets[i]).approve(address(manager), type(uint256).max);
        }
        PoolTypes.IssueParams memory params;
        params.poolId = poolId;
        params.sharesOut = sharesOut;
        params.receiver = actor;
        params.deadline = block.timestamp;
        params.maxAmountsIn = quote;
        vm.prank(actor);
        manager.issue(params);
    }

    function redeem(uint256 actorSeed, uint96 rawShares) external {
        address actor = _actor(actorSeed);
        uint256 balance = share.balanceOf(actor);
        uint256 supply = share.totalSupply();
        if (balance == 0 || supply <= 1) return;
        uint256 maximum = balance == supply ? balance - 1 : balance;
        if (maximum == 0) return;
        uint256 sharesIn = bound(uint256(rawShares), 1, maximum);
        PoolTypes.RedeemParams memory params;
        params.poolId = poolId;
        params.owner = actor;
        params.sharesIn = sharesIn;
        params.receiver = actor;
        params.deadline = block.timestamp;
        params.minAmountsOut = new uint256[](2);
        vm.prank(actor);
        manager.redeem(params);
    }

    function startPlan() external {
        if (auction.paused() || auction.isPoolLocked(poolId)) return;
        auction.startPlan(poolId);
    }

    function openAuction() external {
        if (auction.paused()) return;
        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(poolId);
        if (plan.state != RebalanceTypes.RebalanceState.PLANNED || block.timestamp > plan.expiresAt) return;
        auction.openAuction(poolId, address(sellToken), address(buyToken));
    }

    function bid(uint96 rawSellAmount, uint256 bidderSeed) external {
        RebalanceTypes.Auction memory active = auction.getAuction(poolId);
        if (!active.active) return;
        (uint256 capacity,) = auction.liveAuctionCapacity(poolId);
        if (capacity == 0) return;
        uint256 sellAmount = bound(uint256(rawSellAmount), 1, capacity);
        address bidder = _actor(bidderSeed);
        buyToken.mint(bidder, 1_000_000e18);
        vm.prank(bidder);
        buyToken.approve(address(manager), type(uint256).max);
        RebalanceTypes.BidParams memory params;
        params.poolId = poolId;
        params.auctionNonce = active.nonce;
        params.sellAmount = sellAmount;
        params.maxBuyAmount = type(uint256).max;
        params.receiver = bidder;
        vm.prank(bidder);
        auction.bid(params);
    }

    function expireAuction() external {
        RebalanceTypes.Auction memory active = auction.getAuction(poolId);
        if (!active.active) return;
        vm.warp(active.endTime + 1);
        auction.expireAuction(poolId);
    }

    function invalidatePlan() external {
        auction.invalidatePlan(poolId);
    }

    function finalizePlan() external {
        auction.finalizePlan(poolId);
    }

    function guardianCancel() external {
        if (!auction.isPoolLocked(poolId)) return;
        vm.prank(GUARDIAN);
        auction.cancelPlan(poolId);
    }

    function setPaused(bool paused_) external {
        vm.prank(paused_ ? GUARDIAN : TIMELOCK);
        auction.setPaused(paused_);
    }

    function warp(uint32 rawSeconds) external {
        vm.warp(block.timestamp + bound(uint256(rawSeconds), 0, 8 days));
    }

    function setPrices(uint96 rawSellPrice, uint96 rawBuyPrice) external {
        uint256 sellPrice = bound(uint256(rawSellPrice), 1e7, 5e8);
        uint256 buyPrice = bound(uint256(rawBuyPrice), 1e7, 5e8);
        uint80 sellRound = sellFeed.roundId() + 1;
        uint80 buyRound = buyFeed.roundId() + 1;
        sellFeed.setRound(sellRound, int256(sellPrice), block.timestamp, block.timestamp, sellRound);
        buyFeed.setRound(buyRound, int256(buyPrice), block.timestamp, block.timestamp, buyRound);
    }

    function restorePrices() external {
        uint80 sellRound = sellFeed.roundId() + 1;
        uint80 buyRound = buyFeed.roundId() + 1;
        sellFeed.setRound(sellRound, 2e8, block.timestamp, block.timestamp, sellRound);
        buyFeed.setRound(buyRound, 1e8, block.timestamp, block.timestamp, buyRound);
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[seed % _actors.length];
    }
}

contract AuctionLifecycleInvariant is StdInvariant, Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BOOTSTRAPPER = address(0xB007);
    address private constant HOLDER = address(0xA11);
    address private constant BIDDER = address(0xB1D);
    address private constant OTHER = address(0xCA201);
    bytes32 private constant FAMILY = keccak256("STATIC_INDEX_V1");
    bytes32 private constant SALT = keccak256("auction-invariant");

    AssetRegistry private registry;
    DemeterManager private manager;
    IndexPolicy private policy;
    AuctionRebalance private auction;
    MockV2ERC20 private quote;
    MockV2ERC20 private asset;
    MockV2ChainlinkFeed private quoteFeed;
    MockV2ChainlinkFeed private assetFeed;
    DemeterShare private share;
    AuctionLifecycleHandler private handler;
    bytes32 private poolId;
    address[] private actors;

    function setUp() public {
        vm.warp(1_000_000);
        vm.etch(TIMELOCK, hex"00");
        quote = new MockV2ERC20("Quote", "QUOTE", 18);
        asset = new MockV2ERC20("Asset", "ASSET", 18);
        quoteFeed = new MockV2ChainlinkFeed(8);
        assetFeed = new MockV2ChainlinkFeed(8);
        quoteFeed.setRound(1, 1e8, block.timestamp, block.timestamp, 1);
        assetFeed.setRound(1, 2e8, block.timestamp, block.timestamp, 1);
        address token0 = address(asset) < address(quote) ? address(asset) : address(quote);
        address token1 = address(asset) < address(quote) ? address(quote) : address(asset);
        MockV2UniswapPool twapPool = new MockV2UniswapPool(token0, token1);
        twapPool.setMeanTick(address(asset) < address(quote) ? int24(6931) : int24(-6931));

        registry = new AssetRegistry(TIMELOCK, GUARDIAN, address(quote), _poolBounds());
        vm.startPrank(TIMELOCK);
        registry.configureAsset(address(quote), _assetInput(address(quoteFeed), address(0)));
        registry.configureAsset(address(asset), _assetInput(address(assetFeed), address(twapPool)));
        vm.stopPrank();
        manager = new DemeterManager(address(registry), TIMELOCK);
        policy = new IndexPolicy(TIMELOCK, address(manager), _policyBounds());
        UniswapV3TwapOracle twapOracle = new UniswapV3TwapOracle();
        auction = new AuctionRebalance(address(manager), address(policy), address(registry), address(twapOracle));
        vm.startPrank(TIMELOCK);
        policy.setPolicyFamily(FAMILY, true);
        manager.setIndexPolicy(address(policy));
        manager.setAuctionRebalance(address(auction));
        vm.stopPrank();

        poolId = _createPool();
        _activateAndBootstrap();
        share = DemeterShare(manager.poolShare(poolId));
        actors.push(HOLDER);
        actors.push(BIDDER);
        actors.push(OTHER);
        handler =
            new AuctionLifecycleHandler(manager, auction, share, asset, quote, assetFeed, quoteFeed, poolId, actors);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.issue.selector;
        selectors[1] = handler.redeem.selector;
        selectors[2] = handler.startPlan.selector;
        selectors[3] = handler.openAuction.selector;
        selectors[4] = handler.bid.selector;
        selectors[5] = handler.expireAuction.selector;
        selectors[6] = handler.guardianCancel.selector;
        selectors[7] = handler.setPaused.selector;
        selectors[8] = handler.warp.selector;
        selectors[9] = handler.restorePrices.selector;
        selectors[10] = handler.setPrices.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ManagerAccountingIsAlwaysCovered() public view {
        address[] memory assets = manager.getPoolAssets(poolId);
        for (uint256 i; i < assets.length; ++i) {
            assertEq(manager.reserveOf(poolId, assets[i]), manager.accountedReserve(assets[i]));
            assertGe(IERC20(assets[i]).balanceOf(address(manager)), manager.accountedReserve(assets[i]));
        }
    }

    function invariant_PlanTurnoverNeverExceedsBudget() public view {
        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(poolId);
        assertLe(plan.turnoverConsumedWad, plan.turnoverBudgetWad);
    }

    function invariant_AuctionFillsAndLiveCapacityStayBounded() public view {
        RebalanceTypes.Auction memory active = auction.getAuction(poolId);
        assertLe(active.sellFilled, active.sellLimit);
        assertLe(active.buyReceived, active.buyLimit);
        if (!active.active) return;

        RebalanceTypes.RebalancePlan memory plan = auction.getPlan(poolId);
        assertEq(uint8(plan.state), uint8(RebalanceTypes.RebalanceState.AUCTION_ACTIVE));
        (uint256 sellAvailable, uint256 buyAvailable) = auction.liveAuctionCapacity(poolId);
        assertLe(sellAvailable, active.sellLimit - active.sellFilled);
        assertLe(buyAvailable, active.buyLimit - active.buyReceived);
        assertLe(sellAvailable, manager.reserveOf(poolId, active.sellToken));
        uint256 price = auction.currentPrice(poolId);
        assertGe(price, active.endPriceWad);
        assertLe(price, active.startPriceWad);
    }

    function invariant_ShareSupplyEqualsKnownHolderBalances() public view {
        uint256 balances;
        for (uint256 i; i < actors.length; ++i) {
            balances += share.balanceOf(actors[i]);
        }
        assertEq(share.totalSupply(), balances);
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
        params.name = "Auction Invariant";
        params.symbol = "AINV";
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

    function _refreshPrices() private {
        uint80 quoteRound = quoteFeed.roundId() + 1;
        uint80 assetRound = assetFeed.roundId() + 1;
        quoteFeed.setRound(quoteRound, 1e8, block.timestamp, block.timestamp, quoteRound);
        assetFeed.setRound(assetRound, 2e8, block.timestamp, block.timestamp, assetRound);
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

    function _assetInput(address feed, address pool) private pure returns (PoolTypes.AssetConfigInput memory input) {
        input.chainlinkFeed = feed;
        input.twapPool = pool;
        input.twapWindow = 30 minutes;
        input.maxChainlinkStale = 7 days;
        input.maxOracleDeviationBps = 200;
        input.maxReferenceMoveBps = 500;
    }
}
