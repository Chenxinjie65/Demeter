// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {DemeterBasketRouter} from "src/core/DemeterBasketRouter.sol";
import {DemeterManager} from "src/core/DemeterManager.sol";
import {DemeterShare} from "src/core/DemeterShare.sol";
import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {IDemeterBasketRouter} from "src/interfaces/IDemeterBasketRouter.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {MockV2AuctionAuthority} from "test/v2/mocks/MockV2AuctionAuthority.sol";
import {MockV2ChainlinkFeed} from "test/v2/mocks/MockV2ChainlinkFeed.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";
import {MockV2UniswapPool} from "test/v2/mocks/MockV2UniswapPool.sol";

contract DemeterBasketRouterTest is Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BOOTSTRAPPER = address(0xB007);
    address private constant ALICE = address(0xA11);
    address private constant BOB = address(0xB0B0);
    address private constant RECEIVER = address(0xCAFE);
    bytes32 private constant FAMILY = keccak256("STATIC_INDEX_V1");
    bytes32 private constant SALT = keccak256("router-pool-salt");

    AssetRegistry private registry;
    DemeterManager private manager;
    DemeterBasketRouter private router;
    IndexPolicy private policy;
    MockV2ERC20 private usdc;
    MockV2ERC20 private weth;
    bytes32 private poolId;

    function setUp() public {
        vm.etch(TIMELOCK, hex"00");
        usdc = new MockV2ERC20("USD Coin", "USDC", 6);
        weth = new MockV2ERC20("Wrapped Ether", "WETH", 18);
        MockV2ChainlinkFeed usdcFeed = new MockV2ChainlinkFeed(8);
        MockV2ChainlinkFeed wethFeed = new MockV2ChainlinkFeed(8);
        MockV2UniswapPool twapPool = new MockV2UniswapPool(address(usdc), address(weth));

        registry = new AssetRegistry(TIMELOCK, GUARDIAN, address(usdc), _poolBounds());
        vm.startPrank(TIMELOCK);
        registry.configureAsset(address(usdc), _assetInput(address(usdcFeed), address(0)));
        registry.configureAsset(address(weth), _assetInput(address(wethFeed), address(twapPool)));
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
        _publishActivateAndBootstrap();
        router = new DemeterBasketRouter(address(manager));
    }

    function test_ConstructorRejectsInvalidManager() public {
        vm.expectRevert(
            abi.encodeWithSelector(IDemeterBasketRouter.DemeterBasketRouter__InvalidManager.selector, address(0))
        );
        new DemeterBasketRouter(address(0));

        address noCode = address(0x1234);
        vm.expectRevert(
            abi.encodeWithSelector(IDemeterBasketRouter.DemeterBasketRouter__InvalidManager.selector, noCode)
        );
        new DemeterBasketRouter(noCode);
    }

    function test_IssuePullsExactBasketAndClearsRouterState() public {
        uint256 sharesOut = 10e18;
        PoolTypes.IssueParams memory params = _fundAndApproveIssue(BOB, sharesOut);
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256[] memory quote = manager.quoteIssue(poolId, sharesOut);
        uint256[] memory payerBalancesBefore = _balancesOf(assets, BOB);

        vm.prank(BOB);
        uint256[] memory amountsIn = router.issue(params);

        assertEq(amountsIn, quote);
        assertEq(DemeterShare(manager.poolShare(poolId)).balanceOf(RECEIVER), sharesOut);
        for (uint256 i; i < assets.length; ++i) {
            assertEq(IERC20(assets[i]).balanceOf(BOB), payerBalancesBefore[i] - quote[i]);
            assertEq(manager.reserveOf(poolId, assets[i]), _seedFor(assets[i]) + quote[i]);
            assertEq(IERC20(assets[i]).balanceOf(address(router)), 0);
            assertEq(IERC20(assets[i]).allowance(address(router), address(manager)), 0);
        }
    }

    function test_IssueRespectsMaximumAndRevertsWithoutMovement() public {
        PoolTypes.IssueParams memory params = _fundAndApproveIssue(BOB, 10e18);
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256[] memory quote = manager.quoteIssue(poolId, params.sharesOut);
        params.maxAmountsIn[0] = quote[0] - 1;
        uint256 managerBalanceBefore = IERC20(assets[0]).balanceOf(address(manager));

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDemeterBasketRouter.DemeterBasketRouter__AmountInAboveMaximum.selector,
                assets[0],
                quote[0],
                params.maxAmountsIn[0]
            )
        );
        router.issue(params);

        assertEq(IERC20(assets[0]).balanceOf(address(manager)), managerBalanceBefore);
        assertEq(DemeterShare(manager.poolShare(poolId)).balanceOf(RECEIVER), 0);
    }

    function test_IssueRespectsDeadlineBeforePullingAssets() public {
        PoolTypes.IssueParams memory params = _fundAndApproveIssue(BOB, 10e18);
        params.deadline = block.timestamp - 1;
        uint256 usdcBefore = usdc.balanceOf(BOB);
        uint256 wethBefore = weth.balanceOf(BOB);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.V2Errors__DeadlineExpired.selector, params.deadline, block.timestamp)
        );
        router.issue(params);

        assertEq(usdc.balanceOf(BOB), usdcBefore);
        assertEq(weth.balanceOf(BOB), wethBefore);
    }

    function test_IssueRefundsUnsolicitedBasketBalanceToCurrentCaller() public {
        PoolTypes.IssueParams memory params = _fundAndApproveIssue(BOB, 1e18);
        usdc.mint(address(router), 7);
        uint256 usdcBefore = usdc.balanceOf(BOB);
        uint256[] memory quote = manager.quoteIssue(poolId, params.sharesOut);
        address[] memory assets = manager.getPoolAssets(poolId);

        vm.prank(BOB);
        router.issue(params);

        uint256 usdcQuote = assets[0] == address(usdc) ? quote[0] : quote[1];
        assertEq(usdc.balanceOf(BOB), usdcBefore + 7 - usdcQuote);
        assertEq(usdc.balanceOf(address(router)), 0);
    }

    function test_IssueRejectsNonExactTokenBalanceDeltaAtomically() public {
        MockRouterFeeToken feeToken = new MockRouterFeeToken();
        MockRouterQuoteManager quoteManager = new MockRouterQuoteManager(address(feeToken), 100);
        DemeterBasketRouter exactRouter = new DemeterBasketRouter(address(quoteManager));
        feeToken.mint(BOB, 100);
        vm.prank(BOB);
        feeToken.approve(address(exactRouter), 100);

        PoolTypes.IssueParams memory params;
        params.poolId = keccak256("fee-token-pool");
        params.sharesOut = 1e18;
        params.receiver = RECEIVER;
        params.deadline = block.timestamp;
        params.maxAmountsIn = new uint256[](1);
        params.maxAmountsIn[0] = 100;

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(V2Errors.V2Errors__ExactTransferMismatch.selector, address(feeToken), 100, 99)
        );
        exactRouter.issue(params);

        assertEq(feeToken.balanceOf(BOB), 100);
        assertEq(feeToken.balanceOf(address(exactRouter)), 0);
        assertEq(feeToken.allowance(address(exactRouter), address(quoteManager)), 0);
    }

    function test_RedeemBurnsCallerSharesAndSendsBasketDirectlyToReceiver() public {
        uint256 sharesIn = 10e18;
        PoolTypes.RedeemParams memory params = _redeemParams(ALICE, sharesIn, RECEIVER);
        uint256[] memory quote = manager.quoteRedeem(poolId, sharesIn);
        params.minAmountsOut = quote;
        DemeterShare share = DemeterShare(manager.poolShare(poolId));
        vm.prank(ALICE);
        share.approve(address(router), sharesIn);
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256[] memory receiverBalancesBefore = _balancesOf(assets, RECEIVER);

        vm.prank(ALICE);
        uint256[] memory amountsOut = router.redeem(params);

        assertEq(amountsOut, quote);
        assertEq(share.balanceOf(ALICE), 90e18);
        assertEq(share.balanceOf(address(router)), 0);
        assertEq(share.allowance(ALICE, address(router)), 0);
        for (uint256 i; i < assets.length; ++i) {
            assertEq(IERC20(assets[i]).balanceOf(RECEIVER), receiverBalancesBefore[i] + quote[i]);
            assertEq(manager.reserveOf(poolId, assets[i]), _seedFor(assets[i]) - quote[i]);
            assertEq(IERC20(assets[i]).balanceOf(address(router)), 0);
            assertEq(IERC20(assets[i]).allowance(address(router), address(manager)), 0);
        }
    }

    function test_RedeemRequiresShareAllowance() public {
        PoolTypes.RedeemParams memory params = _redeemParams(ALICE, 1e18, RECEIVER);
        address share = manager.poolShare(poolId);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                V2Errors.V2Errors__InsufficientAllowance.selector, share, ALICE, address(router), params.sharesIn, 0
            )
        );
        router.redeem(params);
    }

    function test_RedeemCannotSpendAnotherOwnersShares() public {
        PoolTypes.RedeemParams memory params = _redeemParams(ALICE, 1e18, RECEIVER);
        DemeterShare share = DemeterShare(manager.poolShare(poolId));
        vm.prank(ALICE);
        share.approve(address(router), params.sharesIn);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(IDemeterBasketRouter.DemeterBasketRouter__InvalidOwner.selector, BOB, ALICE)
        );
        router.redeem(params);
    }

    function test_RedeemRespectsMinimumWithoutBurningShares() public {
        PoolTypes.RedeemParams memory params = _redeemParams(ALICE, 1e18, RECEIVER);
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256[] memory quote = manager.quoteRedeem(poolId, params.sharesIn);
        params.minAmountsOut[0] = quote[0] + 1;
        DemeterShare share = DemeterShare(manager.poolShare(poolId));
        vm.prank(ALICE);
        share.approve(address(router), params.sharesIn);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IDemeterBasketRouter.DemeterBasketRouter__AmountOutBelowMinimum.selector,
                assets[0],
                quote[0],
                params.minAmountsOut[0]
            )
        );
        router.redeem(params);

        assertEq(share.balanceOf(ALICE), 100e18);
        assertEq(share.allowance(ALICE, address(router)), params.sharesIn);
    }

    function testFuzz_IssueThenRedeemMatchesManagerQuotes(uint96 rawShares) public {
        uint256 shares = bound(uint256(rawShares), 1e12, 20e18);
        PoolTypes.IssueParams memory issueParams = _fundAndApproveIssue(BOB, shares);
        issueParams.receiver = BOB;
        uint256[] memory issueQuote = manager.quoteIssue(poolId, shares);

        vm.prank(BOB);
        uint256[] memory amountsIn = router.issue(issueParams);
        assertEq(amountsIn, issueQuote);

        PoolTypes.RedeemParams memory redeemParams = _redeemParams(BOB, shares, BOB);
        uint256[] memory redeemQuote = manager.quoteRedeem(poolId, shares);
        redeemParams.minAmountsOut = redeemQuote;
        DemeterShare share = DemeterShare(manager.poolShare(poolId));
        vm.prank(BOB);
        share.approve(address(router), shares);
        vm.prank(BOB);
        uint256[] memory amountsOut = router.redeem(redeemParams);

        assertEq(amountsOut, redeemQuote);
        assertEq(share.balanceOf(BOB), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(weth.balanceOf(address(router)), 0);
        assertEq(usdc.allowance(address(router), address(manager)), 0);
        assertEq(weth.allowance(address(router), address(manager)), 0);
    }

    function _fundAndApproveIssue(address payer, uint256 sharesOut)
        private
        returns (PoolTypes.IssueParams memory params)
    {
        usdc.mint(payer, 50_000e6);
        weth.mint(payer, 25e18);
        vm.startPrank(payer);
        usdc.approve(address(router), type(uint256).max);
        weth.approve(address(router), type(uint256).max);
        vm.stopPrank();

        params.poolId = poolId;
        params.sharesOut = sharesOut;
        params.receiver = RECEIVER;
        params.deadline = block.timestamp;
        params.maxAmountsIn = manager.quoteIssue(poolId, sharesOut);
    }

    function _redeemParams(address owner, uint256 shares, address receiver)
        private
        view
        returns (PoolTypes.RedeemParams memory params)
    {
        params.poolId = poolId;
        params.owner = owner;
        params.sharesIn = shares;
        params.receiver = receiver;
        params.deadline = block.timestamp;
        params.minAmountsOut = new uint256[](2);
    }

    function _balancesOf(address[] memory assets, address owner) private view returns (uint256[] memory balances) {
        balances = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            balances[i] = IERC20(assets[i]).balanceOf(owner);
        }
    }

    function _createPool() private returns (bytes32 createdPoolId) {
        address[] memory assets = _sortedAssets();
        createdPoolId = manager.derivePoolId(CREATOR, assets, FAMILY, SALT);
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
        bytes32 initialHash =
            policy.computeInitialPolicyHash(createdPoolId, CREATOR, PoolTypes.PoolKind.MANAGED_INDEX, initial);

        PoolTypes.CreatePoolParams memory params;
        params.assets = assets;
        params.policyFamilyId = FAMILY;
        params.creatorSalt = SALT;
        params.name = "Demeter Router Test Index";
        params.symbol = "DRTEST";
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

    function _publishActivateAndBootstrap() private {
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
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

    function _seedFor(address asset) private view returns (uint256) {
        return asset == address(usdc) ? 100_000e6 : 50e18;
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

    function _assetInput(address feed, address twapPool)
        private
        pure
        returns (PoolTypes.AssetConfigInput memory input)
    {
        input.chainlinkFeed = feed;
        input.twapPool = twapPool;
        input.twapWindow = 30 minutes;
        input.maxChainlinkStale = 1 hours;
        input.maxOracleDeviationBps = 200;
        input.maxReferenceMoveBps = 500;
    }
}

contract MockRouterFeeToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, amount);
            return;
        }
        uint256 fee = amount / 100;
        super._update(from, to, amount - fee);
        if (fee != 0) super._update(from, address(0), fee);
    }
}

contract MockRouterQuoteManager {
    address private immutable _asset;
    uint256 private immutable _quote;

    constructor(address asset, uint256 quote) {
        _asset = asset;
        _quote = quote;
    }

    function getPoolAssets(bytes32) external view returns (address[] memory assets) {
        assets = new address[](1);
        assets[0] = _asset;
    }

    function quoteIssue(bytes32, uint256) external view returns (uint256[] memory amountsIn) {
        amountsIn = new uint256[](1);
        amountsIn[0] = _quote;
    }
}
