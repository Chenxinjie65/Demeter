// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {StdInvariant} from "@forge-std/StdInvariant.sol";
import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {DemeterManager} from "src/core/DemeterManager.sol";
import {DemeterShare} from "src/core/DemeterShare.sol";
import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {MockV2AuctionAuthority} from "test/v2/mocks/MockV2AuctionAuthority.sol";
import {MockV2ChainlinkFeed} from "test/v2/mocks/MockV2ChainlinkFeed.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";
import {MockV2UniswapPool} from "test/v2/mocks/MockV2UniswapPool.sol";

contract ProportionalClaimsHandler is Test {
    DemeterManager public immutable manager;
    DemeterShare public immutable share;
    MockV2ERC20 public immutable firstToken;
    MockV2ERC20 public immutable secondToken;
    bytes32 public immutable poolId;

    address[] private _actors;

    constructor(
        DemeterManager manager_,
        DemeterShare share_,
        MockV2ERC20 firstToken_,
        MockV2ERC20 secondToken_,
        bytes32 poolId_,
        address[] memory actors_
    ) {
        manager = manager_;
        share = share_;
        firstToken = firstToken_;
        secondToken = secondToken_;
        poolId = poolId_;
        _actors = actors_;
    }

    function issue(uint256 actorSeed, uint96 rawShares) external {
        address actor = _actor(actorSeed);
        uint256 sharesOut = bound(uint256(rawShares), 1e12, 10e18);
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

    function transferShares(uint256 fromSeed, uint256 toSeed, uint96 rawAmount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;
        uint256 balance = share.balanceOf(from);
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        vm.prank(from);
        share.transfer(to, amount);
    }

    function approveAndTransferShares(uint256 ownerSeed, uint256 spenderSeed, uint256 receiverSeed, uint96 rawAmount)
        external
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address receiver = _actor(receiverSeed);
        if (owner == spender) return;
        uint256 balance = share.balanceOf(owner);
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        vm.prank(owner);
        share.approve(spender, amount);
        vm.prank(spender);
        share.transferFrom(owner, receiver, amount);
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

    function approveAndRedeem(uint256 ownerSeed, uint256 operatorSeed, uint96 rawShares) external {
        address owner = _actor(ownerSeed);
        address operator = _actor(operatorSeed);
        if (owner == operator) return;
        uint256 balance = share.balanceOf(owner);
        uint256 supply = share.totalSupply();
        if (balance == 0 || supply <= 1) return;
        uint256 maximum = balance == supply ? balance - 1 : balance;
        if (maximum == 0) return;
        uint256 sharesIn = bound(uint256(rawShares), 1, maximum);
        vm.prank(owner);
        share.approve(operator, sharesIn);

        PoolTypes.RedeemParams memory params;
        params.poolId = poolId;
        params.owner = owner;
        params.sharesIn = sharesIn;
        params.receiver = operator;
        params.deadline = block.timestamp;
        params.minAmountsOut = new uint256[](2);
        vm.prank(operator);
        manager.redeem(params);
    }

    function donate(uint256 tokenSeed, uint96 rawAmount) external {
        MockV2ERC20 token = tokenSeed % 2 == 0 ? firstToken : secondToken;
        uint256 amount = bound(uint256(rawAmount), 1, 1e24);
        token.mint(address(manager), amount);
    }

    function actors() external view returns (address[] memory) {
        return _actors;
    }

    function _actor(uint256 seed) private view returns (address) {
        return _actors[seed % _actors.length];
    }
}

contract ProportionalClaimsInvariant is StdInvariant, Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BOOTSTRAPPER = address(0xB007);
    address private constant ALICE = address(0xA11);
    address private constant BOB = address(0xB0B0);
    address private constant CAROL = address(0xCA201);
    bytes32 private constant FAMILY = keccak256("STATIC_INDEX_V1");
    bytes32 private constant SALT = keccak256("claims-invariant");

    AssetRegistry private registry;
    DemeterManager private manager;
    IndexPolicy private policy;
    MockV2ERC20 private usdc;
    MockV2ERC20 private weth;
    DemeterShare private share;
    ProportionalClaimsHandler private handler;
    bytes32 private poolId;
    address[] private actors;

    function setUp() public {
        vm.etch(TIMELOCK, hex"00");
        usdc = new MockV2ERC20("USD Coin", "USDC", 6);
        weth = new MockV2ERC20("Wrapped Ether", "WETH", 18);
        MockV2ChainlinkFeed usdcFeed = new MockV2ChainlinkFeed(8);
        MockV2ChainlinkFeed wethFeed = new MockV2ChainlinkFeed(8);
        MockV2UniswapPool pool = new MockV2UniswapPool(address(usdc), address(weth));
        registry = new AssetRegistry(TIMELOCK, GUARDIAN, address(usdc), _poolBounds());
        vm.startPrank(TIMELOCK);
        registry.configureAsset(address(usdc), _assetInput(address(usdcFeed), address(0)));
        registry.configureAsset(address(weth), _assetInput(address(wethFeed), address(pool)));
        vm.stopPrank();

        manager = new DemeterManager(address(registry), TIMELOCK);
        policy = new IndexPolicy(TIMELOCK, address(manager), _policyBounds());
        MockV2AuctionAuthority auction = new MockV2AuctionAuthority();
        auction.configure(address(manager), address(policy), address(registry));
        vm.startPrank(TIMELOCK);
        policy.setPolicyFamily(FAMILY, true);
        manager.setIndexPolicy(address(policy));
        manager.setAuctionRebalance(address(auction));
        vm.stopPrank();

        poolId = _createPool();
        _activateAndBootstrap();
        share = DemeterShare(manager.poolShare(poolId));
        actors.push(ALICE);
        actors.push(BOB);
        actors.push(CAROL);
        handler = new ProportionalClaimsHandler(manager, share, usdc, weth, poolId, actors);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.issue.selector;
        selectors[1] = handler.transferShares.selector;
        selectors[2] = handler.approveAndTransferShares.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.approveAndRedeem.selector;
        selectors[5] = handler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_RecordedReservesAreCoveredByManagerBalances() public view {
        address[] memory assets = manager.getPoolAssets(poolId);
        for (uint256 i; i < assets.length; ++i) {
            uint256 reserve = manager.reserveOf(poolId, assets[i]);
            assertEq(reserve, manager.accountedReserve(assets[i]));
            assertGe(IERC20(assets[i]).balanceOf(address(manager)), manager.accountedReserve(assets[i]));
        }
    }

    function invariant_ShareSupplyEqualsActorBalances() public view {
        uint256 balances;
        for (uint256 i; i < actors.length; ++i) {
            balances += share.balanceOf(actors[i]);
        }
        assertEq(share.totalSupply(), balances);
    }

    function invariant_AggregateActorClaimsNeverExceedRecordedReserves() public view {
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256[] memory aggregateClaims = new uint256[](assets.length);
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = share.balanceOf(actors[i]);
            if (balance == 0) continue;
            uint256[] memory claims = manager.quoteRedeem(poolId, balance);
            for (uint256 j; j < claims.length; ++j) {
                aggregateClaims[j] += claims[j];
            }
        }
        for (uint256 i; i < assets.length; ++i) {
            assertLe(aggregateClaims[i], manager.reserveOf(poolId, assets[i]));
        }
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
        params.name = "Claims Invariant";
        params.symbol = "CLAIM";
        params.bootstrapper = BOOTSTRAPPER;
        params.bootstrapDeadline = uint64(block.timestamp + 10 days);
        params.initialShareSupply = 100e18;
        params.kind = PoolTypes.PoolKind.MANAGED_INDEX;
        params.seedAmounts = new uint256[](2);
        params.seedAmounts[0] = _seedFor(assets[0]);
        params.seedAmounts[1] = _seedFor(assets[1]);
        params.initialShareRecipient = ALICE;
        params.initialPolicyHash = initialHash;
        vm.prank(CREATOR);
        manager.createPool(params);
    }

    function _activateAndBootstrap() private {
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 hours));
        vm.prank(CREATOR);
        policy.publishPolicy(poolId, initial);
        vm.warp(initial.effectiveAt);
        policy.activatePolicy(poolId);
        usdc.mint(BOOTSTRAPPER, 100_000e6);
        weth.mint(BOOTSTRAPPER, 50e18);
        vm.startPrank(BOOTSTRAPPER);
        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        vm.stopPrank();
        vm.prank(BOOTSTRAPPER);
        manager.bootstrap(poolId);
    }

    function _sortedAssets() private view returns (address[] memory assets) {
        assets = new address[](2);
        if (address(usdc) < address(weth)) {
            assets[0] = address(usdc);
            assets[1] = address(weth);
        } else {
            assets[0] = address(weth);
            assets[1] = address(usdc);
        }
    }

    function _seedFor(address token) private view returns (uint256) {
        return token == address(usdc) ? 100_000e6 : 50e18;
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
        bounds.maxAssetAdjustmentBps = 2_500;
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
        params.epoch = 1;
        params.effectiveAt = effectiveAt;
        params.minPlanInterval = 1 hours;
        params.planDuration = 7 days;
        params.triggerBps = 200;
        params.destinationBps = 100;
        params.maxTurnoverBps = 2_000;
        params.maxAssetAdjustmentBps = 1_000;
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
        input.maxChainlinkStale = 1 days;
        input.maxOracleDeviationBps = 200;
        input.maxReferenceMoveBps = 500;
    }
}
