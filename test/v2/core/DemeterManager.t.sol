// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {DemeterManager} from "src/core/DemeterManager.sol";
import {DemeterShare} from "src/core/DemeterShare.sol";
import {IndexPolicy} from "src/core/IndexPolicy.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {MockV2AuctionAuthority} from "test/v2/mocks/MockV2AuctionAuthority.sol";
import {MockV2ChainlinkFeed} from "test/v2/mocks/MockV2ChainlinkFeed.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";
import {MockV2FailingERC20} from "test/v2/mocks/MockV2FailingERC20.sol";
import {MockV2UniswapPool} from "test/v2/mocks/MockV2UniswapPool.sol";

contract DemeterManagerTest is Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);
    address private constant CREATOR = address(0xC0FFEE);
    address private constant BOOTSTRAPPER = address(0xB007);
    address private constant ALICE = address(0xA11);
    address private constant BOB = address(0xB0B0);
    bytes32 private constant FAMILY = keccak256("STATIC_INDEX_V1");
    bytes32 private constant SALT = keccak256("pool-salt");

    AssetRegistry private registry;
    DemeterManager private manager;
    IndexPolicy private policy;
    MockV2AuctionAuthority private auction;
    MockV2ERC20 private usdc;
    MockV2ERC20 private weth;
    bytes32 private poolId;

    function setUp() public {
        vm.etch(TIMELOCK, hex"00");
        // Both assets use the failure-capable test token so either sorted position
        // can be selected as the transfer that fails after a state mutation.
        usdc = new MockV2FailingERC20("USD Coin", "USDC", 6);
        weth = new MockV2FailingERC20("Wrapped Ether", "WETH", 18);
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
        auction = new MockV2AuctionAuthority();
        auction.configure(address(manager), address(policy), address(registry));
        vm.startPrank(TIMELOCK);
        policy.setPolicyFamily(FAMILY, true);
        manager.setIndexPolicy(address(policy));
        manager.setAuctionRebalance(address(auction));
        vm.stopPrank();

        poolId = _createPool(PoolTypes.PoolKind.MANAGED_INDEX);
        _publishActivateAndBootstrap();
    }

    function test_CreatePoolIsPermissionlessAndCreatorBound() public view {
        PoolTypes.PoolConfig memory config = manager.getPoolConfig(poolId);
        assertEq(config.creator, CREATOR);
        assertEq(config.bootstrapper, BOOTSTRAPPER);
        assertTrue(config.bootstrapped);
        assertEq(DemeterShare(config.share).poolId(), poolId);
        assertEq(DemeterShare(config.share).manager(), address(manager));

        address[] memory assets = manager.getPoolAssets(poolId);
        bytes32 attackerId = manager.derivePoolId(BOB, assets, FAMILY, SALT);
        assertNotEq(poolId, attackerId);
    }

    function test_Create2ShareAddressMatchesPoolCommitment() public view {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(DemeterShare).creationCode, abi.encode("Demeter Test Index", "DTEST", poolId, address(manager))
            )
        );
        address predicted = vm.computeCreate2Address(poolId, initCodeHash, address(manager));
        assertEq(manager.poolShare(poolId), predicted);
    }

    function test_BootstrapBalancesAndSupplyMatchCommitment() public view {
        PoolTypes.PoolConfig memory config = manager.getPoolConfig(poolId);
        assertEq(DemeterShare(config.share).totalSupply(), 100e18);
        assertEq(DemeterShare(config.share).balanceOf(ALICE), 100e18);
        assertEq(manager.reserveOf(poolId, address(usdc)), 100_000e6);
        assertEq(manager.reserveOf(poolId, address(weth)), 50e18);
        assertEq(manager.accountedReserve(address(usdc)), usdc.balanceOf(address(manager)));
        assertEq(manager.accountedReserve(address(weth)), weth.balanceOf(address(manager)));
    }

    function test_BootstrapCallerMustMatchRecordedBootstrapper() public {
        bytes32 secondPoolId = _createPoolWithSalt(PoolTypes.PoolKind.MANAGED_INDEX, keccak256("bootstrap-caller"));
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
        vm.prank(CREATOR);
        policy.publishPolicy(secondPoolId, initial);
        vm.warp(initial.effectiveAt);
        policy.activatePolicy(secondPoolId);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__UnauthorizedBootstrapper.selector, BOB, BOOTSTRAPPER));
        manager.bootstrap(secondPoolId);
    }

    function test_BootstrapCannotRunAfterDeadlineOrTwice() public {
        vm.prank(BOOTSTRAPPER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PoolAlreadyBootstrapped.selector, poolId));
        manager.bootstrap(poolId);

        bytes32 secondPoolId = _createPoolWithSalt(PoolTypes.PoolKind.MANAGED_INDEX, keccak256("expired-bootstrap"));
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
        vm.prank(CREATOR);
        policy.publishPolicy(secondPoolId, initial);
        vm.warp(initial.effectiveAt);
        policy.activatePolicy(secondPoolId);

        uint256 deadline = manager.getPoolConfig(secondPoolId).bootstrapDeadline;
        vm.warp(deadline + 1);
        vm.prank(BOOTSTRAPPER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__BootstrapExpired.selector, deadline, block.timestamp));
        manager.bootstrap(secondPoolId);

        manager.expireBootstrap(secondPoolId);
        vm.prank(BOOTSTRAPPER);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__BootstrapExpired.selector, deadline, block.timestamp));
        manager.bootstrap(secondPoolId);
    }

    function test_IssueAndRedeemAreReserveProportional() public {
        usdc.mint(BOB, 10_000e6);
        weth.mint(BOB, 5e18);
        vm.startPrank(BOB);
        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        PoolTypes.IssueParams memory issueParams;
        issueParams.poolId = poolId;
        issueParams.sharesOut = 10e18;
        issueParams.receiver = BOB;
        issueParams.deadline = block.timestamp;
        issueParams.maxAmountsIn = new uint256[](2);
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256[] memory quote = manager.quoteIssue(poolId, 10e18);
        issueParams.maxAmountsIn[0] = quote[0];
        issueParams.maxAmountsIn[1] = quote[1];
        manager.issue(issueParams);
        vm.stopPrank();

        assertEq(DemeterShare(manager.poolShare(poolId)).balanceOf(BOB), 10e18);
        assertEq(manager.reserveOf(poolId, assets[0]), _seedFor(assets[0]) * 11 / 10);
        assertEq(manager.reserveOf(poolId, assets[1]), _seedFor(assets[1]) * 11 / 10);

        vm.startPrank(BOB);
        PoolTypes.RedeemParams memory redeemParams;
        redeemParams.poolId = poolId;
        redeemParams.owner = BOB;
        redeemParams.sharesIn = 10e18;
        redeemParams.receiver = BOB;
        redeemParams.deadline = block.timestamp;
        redeemParams.minAmountsOut = new uint256[](2);
        manager.redeem(redeemParams);
        vm.stopPrank();
        assertEq(DemeterShare(manager.poolShare(poolId)).balanceOf(BOB), 0);
    }

    function test_NonIntegralIssueRoundsUpAndRedeemRoundsDown() public {
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256[] memory issueQuote = manager.quoteIssue(poolId, 1);
        uint256[] memory redeemQuote = manager.quoteRedeem(poolId, 1);
        for (uint256 i; i < assets.length; ++i) {
            // The initial reserves are not integral at one share wei: issue must
            // charge one raw unit, while redeem must retain the sub-unit dust.
            assertEq(issueQuote[i], 1);
            assertEq(redeemQuote[i], 0);
            MockV2ERC20(assets[i]).mint(BOB, issueQuote[i]);
            vm.prank(BOB);
            IERC20(assets[i]).approve(address(manager), issueQuote[i]);
        }

        PoolTypes.IssueParams memory issueParams;
        issueParams.poolId = poolId;
        issueParams.sharesOut = 1;
        issueParams.receiver = BOB;
        issueParams.deadline = block.timestamp;
        issueParams.maxAmountsIn = issueQuote;
        vm.prank(BOB);
        manager.issue(issueParams);

        PoolTypes.RedeemParams memory redeemParams = _redeemParams(BOB, 1, BOB);
        vm.prank(BOB);
        uint256[] memory amountsOut = manager.redeem(redeemParams);
        for (uint256 i; i < amountsOut.length; ++i) {
            assertEq(amountsOut[i], 0);
            assertEq(manager.reserveOf(poolId, assets[i]), _seedFor(assets[i]) + 1);
        }
    }

    function test_ClaimArrayLengthsMustMatchPoolAssets() public {
        PoolTypes.IssueParams memory issueParams;
        issueParams.poolId = poolId;
        issueParams.sharesOut = 1e18;
        issueParams.receiver = BOB;
        issueParams.deadline = block.timestamp;
        issueParams.maxAmountsIn = new uint256[](1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__ArrayLengthMismatch.selector, 2, 1));
        manager.issue(issueParams);

        PoolTypes.RedeemParams memory redeemParams = _redeemParams(ALICE, 1e18, ALICE);
        redeemParams.minAmountsOut = new uint256[](1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__ArrayLengthMismatch.selector, 2, 1));
        manager.redeem(redeemParams);
    }

    function test_ZeroSharesAndInsufficientAssetBalanceRevertAtomically() public {
        PoolTypes.IssueParams memory zeroShares;
        zeroShares.poolId = poolId;
        zeroShares.receiver = BOB;
        zeroShares.deadline = block.timestamp;
        zeroShares.maxAmountsIn = new uint256[](2);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__InvalidShareAmount.selector, 0));
        manager.issue(zeroShares);

        uint256 sharesOut = 1e18;
        uint256[] memory quote = manager.quoteIssue(poolId, sharesOut);
        address[] memory assets = manager.getPoolAssets(poolId);
        // Fund and approve only the first asset. The first pull succeeds, then
        // the second pull fails, proving the complete operation is atomic.
        MockV2ERC20(assets[0]).mint(BOB, quote[0]);
        vm.prank(BOB);
        IERC20(assets[0]).approve(address(manager), quote[0]);

        uint256 supplyBefore = DemeterShare(manager.poolShare(poolId)).totalSupply();
        uint256 shareBalanceBefore = DemeterShare(manager.poolShare(poolId)).balanceOf(BOB);
        uint256[] memory reservesBefore = _reserves(poolId, assets);
        uint256[] memory balancesBefore = _balances(address(manager), assets);
        uint256[] memory allowancesBefore = _allowances(BOB, address(manager), assets);

        PoolTypes.IssueParams memory params;
        params.poolId = poolId;
        params.sharesOut = sharesOut;
        params.receiver = BOB;
        params.deadline = block.timestamp;
        params.maxAmountsIn = quote;
        vm.prank(BOB);
        vm.expectRevert();
        manager.issue(params);

        assertEq(DemeterShare(manager.poolShare(poolId)).totalSupply(), supplyBefore);
        assertEq(DemeterShare(manager.poolShare(poolId)).balanceOf(BOB), shareBalanceBefore);
        _assertReservesAndBalances(poolId, assets, reservesBefore, balancesBefore);
        _assertAllowances(BOB, address(manager), assets, allowancesBefore);
    }

    function test_RedeemInsufficientShareBalanceRevertAtomically() public {
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256 supplyBefore = DemeterShare(manager.poolShare(poolId)).totalSupply();
        uint256[] memory reservesBefore = _reserves(poolId, assets);
        uint256[] memory balancesBefore = _balances(address(manager), assets);

        PoolTypes.RedeemParams memory params = _redeemParams(BOB, 1e18, BOB);
        vm.prank(BOB);
        vm.expectRevert();
        manager.redeem(params);

        assertEq(DemeterShare(manager.poolShare(poolId)).totalSupply(), supplyBefore);
        _assertReservesAndBalances(poolId, assets, reservesBefore, balancesBefore);
    }

    function test_ThirdPartyRedeemUsesShareAllowance() public {
        DemeterShare share = DemeterShare(manager.poolShare(poolId));
        vm.prank(ALICE);
        share.approve(BOB, 1e18);

        PoolTypes.RedeemParams memory params;
        params.poolId = poolId;
        params.owner = ALICE;
        params.sharesIn = 1e18;
        params.receiver = BOB;
        params.deadline = block.timestamp;
        params.minAmountsOut = new uint256[](2);
        vm.prank(BOB);
        manager.redeem(params);
        assertEq(share.allowance(ALICE, BOB), 0);
    }

    function test_DisabledAssetBlocksIssueButNotRedeem() public {
        address[] memory assets = manager.getPoolAssets(poolId);
        vm.prank(TIMELOCK);
        registry.disableAsset(assets[0]);

        PoolTypes.IssueParams memory issueParams;
        issueParams.poolId = poolId;
        issueParams.sharesOut = 1e18;
        issueParams.receiver = BOB;
        issueParams.deadline = block.timestamp;
        issueParams.maxAmountsIn = new uint256[](2);
        issueParams.maxAmountsIn[0] = type(uint256).max;
        issueParams.maxAmountsIn[1] = type(uint256).max;
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__AssetNotEnabled.selector, assets[0]));
        manager.issue(issueParams);

        PoolTypes.RedeemParams memory redeemParams;
        redeemParams.poolId = poolId;
        redeemParams.owner = ALICE;
        redeemParams.sharesIn = 1e18;
        redeemParams.receiver = ALICE;
        redeemParams.deadline = block.timestamp;
        redeemParams.minAmountsOut = new uint256[](2);
        vm.prank(ALICE);
        manager.redeem(redeemParams);
    }

    function test_IssueRejectsInactivePolicyBeforePullingAssets() public {
        vm.prank(TIMELOCK);
        policy.setPolicyFamily(FAMILY, false);

        PoolTypes.IssueParams memory params;
        params.poolId = poolId;
        params.sharesOut = 1e18;
        params.receiver = BOB;
        params.deadline = block.timestamp;
        params.maxAmountsIn = manager.quoteIssue(poolId, params.sharesOut);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PolicyNotActive.selector, 0, block.timestamp));
        manager.issue(params);
    }

    function test_LockBlocksIssueAndFullRedemptionButAllowsPartialRedemption() public {
        auction.setLocked(poolId, true);
        PoolTypes.IssueParams memory issueParams;
        issueParams.poolId = poolId;
        issueParams.sharesOut = 1e18;
        issueParams.receiver = BOB;
        issueParams.deadline = block.timestamp;
        issueParams.maxAmountsIn = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PoolLocked.selector, poolId));
        manager.issue(issueParams);

        PoolTypes.RedeemParams memory full = _redeemParams(ALICE, 100e18, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PoolLocked.selector, poolId));
        manager.redeem(full);

        PoolTypes.RedeemParams memory partialParams = _redeemParams(ALICE, 1e18, ALICE);
        vm.prank(ALICE);
        manager.redeem(partialParams);
    }

    function test_FullRedemptionClosesPool() public {
        PoolTypes.RedeemParams memory params = _redeemParams(ALICE, 100e18, ALICE);
        vm.prank(ALICE);
        manager.redeem(params);
        assertTrue(manager.isPoolClosed(poolId));
        assertEq(DemeterShare(manager.poolShare(poolId)).totalSupply(), 0);
        assertEq(manager.reserveOf(poolId, address(usdc)), 0);
        assertEq(manager.reserveOf(poolId, address(weth)), 0);
    }

    function test_ClosedPoolRejectsFurtherIssueAndRedeem() public {
        vm.prank(ALICE);
        manager.redeem(_redeemParams(ALICE, 100e18, ALICE));

        PoolTypes.IssueParams memory issueParams;
        issueParams.poolId = poolId;
        issueParams.sharesOut = 1e18;
        issueParams.receiver = BOB;
        issueParams.deadline = block.timestamp;
        issueParams.maxAmountsIn = new uint256[](2);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PoolClosed.selector, poolId));
        manager.issue(issueParams);

        PoolTypes.RedeemParams memory redeemParams = _redeemParams(ALICE, 1, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PoolClosed.selector, poolId));
        manager.redeem(redeemParams);
    }

    function test_CreatePoolRejectsSeedArrayLengthMismatch() public {
        bytes32 salt = keccak256("bad-seed-length");
        PoolTypes.CreatePoolParams memory params = _poolParams(PoolTypes.PoolKind.MANAGED_INDEX, salt);
        params.seedAmounts = new uint256[](1);

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__ArrayLengthMismatch.selector, 2, 1));
        manager.createPool(params);
    }

    function test_CreatePoolRejectsDuplicatePoolId() public {
        PoolTypes.CreatePoolParams memory params = _poolParams(PoolTypes.PoolKind.MANAGED_INDEX, SALT);
        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(DemeterManager.DemeterManager__DuplicatePool.selector, poolId));
        manager.createPool(params);
    }

    function test_IssueTransferFailureRollsBackAllState() public {
        uint256 sharesOut = 10e18;
        uint256[] memory quote = manager.quoteIssue(poolId, sharesOut);
        address[] memory assets = manager.getPoolAssets(poolId);
        for (uint256 i; i < assets.length; ++i) {
            MockV2ERC20(assets[i]).mint(BOB, quote[i]);
            vm.prank(BOB);
            IERC20(assets[i]).approve(address(manager), quote[i]);
        }

        address failingAsset = assets[assets.length - 1];
        MockV2FailingERC20(failingAsset).setFailAfterTransferFrom(true);
        DemeterShare share = DemeterShare(manager.poolShare(poolId));
        uint256 supplyBefore = share.totalSupply();
        uint256 shareBalanceBefore = share.balanceOf(BOB);
        uint256[] memory reservesBefore = _reserves(poolId, assets);
        uint256[] memory managerBalancesBefore = _balances(address(manager), assets);
        uint256[] memory payerBalancesBefore = _balances(BOB, assets);
        uint256[] memory allowancesBefore = _allowances(BOB, address(manager), assets);

        PoolTypes.IssueParams memory params;
        params.poolId = poolId;
        params.sharesOut = sharesOut;
        params.receiver = BOB;
        params.deadline = block.timestamp;
        params.maxAmountsIn = quote;
        vm.prank(BOB);
        vm.expectRevert(MockV2FailingERC20.MockV2FailingERC20__TransferFailed.selector);
        manager.issue(params);

        assertEq(share.totalSupply(), supplyBefore);
        assertEq(share.balanceOf(BOB), shareBalanceBefore);
        _assertReservesAndBalances(poolId, assets, reservesBefore, managerBalancesBefore);
        _assertBalances(BOB, assets, payerBalancesBefore);
        _assertAllowances(BOB, address(manager), assets, allowancesBefore);
    }

    function test_RedeemTransferFailureRollsBackAllState() public {
        uint256 sharesIn = 10e18;
        address[] memory assets = manager.getPoolAssets(poolId);
        address receiver = BOB;
        DemeterShare share = DemeterShare(manager.poolShare(poolId));
        uint256 supplyBefore = share.totalSupply();
        uint256 shareBalanceBefore = share.balanceOf(ALICE);
        uint256[] memory reservesBefore = _reserves(poolId, assets);
        uint256[] memory managerBalancesBefore = _balances(address(manager), assets);
        uint256[] memory receiverBalancesBefore = _balances(receiver, assets);

        MockV2FailingERC20(assets[assets.length - 1]).setFailAfterTransfer(true);
        vm.prank(ALICE);
        vm.expectRevert(MockV2FailingERC20.MockV2FailingERC20__TransferFailed.selector);
        manager.redeem(_redeemParams(ALICE, sharesIn, receiver));

        assertEq(share.totalSupply(), supplyBefore);
        assertEq(share.balanceOf(ALICE), shareBalanceBefore);
        _assertReservesAndBalances(poolId, assets, reservesBefore, managerBalancesBefore);
        _assertBalances(receiver, assets, receiverBalancesBefore);
    }

    function test_RevertWhen_BootstrapNoLongerHasInitialPolicyActive() public {
        address[] memory assets = _sortedAssets();
        bytes32 secondSalt = keccak256("second-bootstrap-pool");
        bytes32 secondPoolId = manager.derivePoolId(CREATOR, assets, FAMILY, secondSalt);
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
        bytes32 initialHash =
            policy.computeInitialPolicyHash(secondPoolId, CREATOR, PoolTypes.PoolKind.MANAGED_INDEX, initial);
        PoolTypes.CreatePoolParams memory create;
        create.assets = assets;
        create.policyFamilyId = FAMILY;
        create.creatorSalt = secondSalt;
        create.name = "Delayed Bootstrap";
        create.symbol = "DELAY";
        create.bootstrapper = BOOTSTRAPPER;
        create.bootstrapDeadline = uint64(block.timestamp + 20 days);
        create.initialShareSupply = 100e18;
        create.kind = PoolTypes.PoolKind.MANAGED_INDEX;
        create.seedAmounts = new uint256[](2);
        create.seedAmounts[0] = _seedFor(assets[0]);
        create.seedAmounts[1] = _seedFor(assets[1]);
        create.initialShareRecipient = ALICE;
        create.initialPolicyHash = initialHash;
        vm.prank(CREATOR);
        manager.createPool(create);
        vm.prank(CREATOR);
        policy.publishPolicy(secondPoolId, initial);
        vm.warp(initial.effectiveAt);
        policy.activatePolicy(secondPoolId);

        RebalanceTypes.PolicyParams memory second = _policyParams(uint64(initial.effectiveAt + 1 days));
        second.epoch = 2;
        vm.prank(CREATOR);
        policy.publishPolicy(secondPoolId, second);
        vm.warp(second.effectiveAt);
        policy.activatePolicy(secondPoolId);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__PolicyVersionMismatch.selector, 1, 2));
        vm.prank(BOOTSTRAPPER);
        manager.bootstrap(secondPoolId);
    }

    function test_DisabledAssetBlocksBootstrapBeforeAnyTransfer() public {
        bytes32 secondPoolId = _createPoolWithSalt(PoolTypes.PoolKind.MANAGED_INDEX, keccak256("disabled-seed"));
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
        vm.prank(CREATOR);
        policy.publishPolicy(secondPoolId, initial);
        vm.warp(initial.effectiveAt);
        policy.activatePolicy(secondPoolId);
        address[] memory assets = manager.getPoolAssets(secondPoolId);
        uint256 bootstrapperUsdcBefore = usdc.balanceOf(BOOTSTRAPPER);
        uint256 bootstrapperWethBefore = weth.balanceOf(BOOTSTRAPPER);
        vm.prank(TIMELOCK);
        registry.disableAsset(assets[0]);

        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__AssetNotEnabled.selector, assets[0]));
        vm.prank(BOOTSTRAPPER);
        manager.bootstrap(secondPoolId);
        assertEq(usdc.balanceOf(BOOTSTRAPPER), bootstrapperUsdcBefore);
        assertEq(weth.balanceOf(BOOTSTRAPPER), bootstrapperWethBefore);
        assertEq(manager.reserveOf(secondPoolId, address(usdc)), 0);
        assertEq(manager.reserveOf(secondPoolId, address(weth)), 0);
    }

    function test_CrossPoolBootstrapAllowanceCannotBeConsumedByAnotherCaller() public {
        address[] memory assets = _sortedAssets();
        bytes32 maliciousSalt = keccak256("allowance-isolation");
        bytes32 maliciousPoolId = manager.derivePoolId(CREATOR, assets, FAMILY, maliciousSalt);
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
        bytes32 initialHash =
            policy.computeInitialPolicyHash(maliciousPoolId, CREATOR, PoolTypes.PoolKind.MANAGED_INDEX, initial);

        PoolTypes.CreatePoolParams memory create;
        create.assets = assets;
        create.policyFamilyId = FAMILY;
        create.creatorSalt = maliciousSalt;
        create.name = "Allowance Isolation";
        create.symbol = "ISO";
        create.bootstrapper = ALICE;
        create.bootstrapDeadline = uint64(block.timestamp + 10 days);
        create.initialShareSupply = 100e18;
        create.kind = PoolTypes.PoolKind.MANAGED_INDEX;
        create.seedAmounts = new uint256[](2);
        create.seedAmounts[0] = _seedFor(assets[0]);
        create.seedAmounts[1] = _seedFor(assets[1]);
        create.initialShareRecipient = BOB;
        create.initialPolicyHash = initialHash;
        vm.prank(CREATOR);
        manager.createPool(create);
        vm.prank(CREATOR);
        policy.publishPolicy(maliciousPoolId, initial);
        vm.warp(initial.effectiveAt);
        policy.activatePolicy(maliciousPoolId);

        usdc.mint(ALICE, 100_000e6);
        weth.mint(ALICE, 50e18);
        vm.startPrank(ALICE);
        usdc.approve(address(manager), type(uint256).max);
        weth.approve(address(manager), type(uint256).max);
        vm.stopPrank();

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__UnauthorizedBootstrapper.selector, BOB, ALICE));
        manager.bootstrap(maliciousPoolId);
        assertEq(manager.reserveOf(maliciousPoolId, address(usdc)), 0);
        assertEq(manager.reserveOf(maliciousPoolId, address(weth)), 0);

        vm.prank(ALICE);
        manager.bootstrap(maliciousPoolId);
        assertEq(manager.reserveOf(maliciousPoolId, address(usdc)), 100_000e6);
        assertEq(manager.reserveOf(maliciousPoolId, address(weth)), 50e18);
    }

    function test_AggregateReserveCoversTwoPermissionlessPools() public {
        bytes32 secondPoolId = _createPoolWithSalt(PoolTypes.PoolKind.MANAGED_INDEX, keccak256("second-live-pool"));
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
        vm.prank(CREATOR);
        policy.publishPolicy(secondPoolId, initial);
        vm.warp(initial.effectiveAt);
        policy.activatePolicy(secondPoolId);
        usdc.mint(BOOTSTRAPPER, 100_000e6);
        weth.mint(BOOTSTRAPPER, 50e18);
        vm.prank(BOOTSTRAPPER);
        manager.bootstrap(secondPoolId);

        assertEq(manager.reserveOf(poolId, address(usdc)), 100_000e6);
        assertEq(manager.reserveOf(secondPoolId, address(usdc)), 100_000e6);
        assertEq(manager.accountedReserve(address(usdc)), 200_000e6);
        assertEq(manager.accountedReserve(address(weth)), 100e18);
        assertEq(usdc.balanceOf(address(manager)), manager.accountedReserve(address(usdc)));
        assertEq(weth.balanceOf(address(manager)), manager.accountedReserve(address(weth)));
    }

    function _createPool(PoolTypes.PoolKind kind) private returns (bytes32 createdPoolId) {
        return _createPoolWithSalt(kind, SALT);
    }

    function _createPoolWithSalt(PoolTypes.PoolKind kind, bytes32 salt) private returns (bytes32 createdPoolId) {
        PoolTypes.CreatePoolParams memory params = _poolParams(kind, salt);
        createdPoolId = manager.derivePoolId(CREATOR, params.assets, FAMILY, salt);
        vm.prank(CREATOR);
        manager.createPool(params);
    }

    function _poolParams(PoolTypes.PoolKind kind, bytes32 salt)
        private
        view
        returns (PoolTypes.CreatePoolParams memory params)
    {
        address[] memory assets = _sortedAssets();
        bytes32 createdPoolId = manager.derivePoolId(CREATOR, assets, FAMILY, salt);
        RebalanceTypes.PolicyParams memory initial = _policyParams(uint64(block.timestamp + 1 days));
        bytes32 initialHash = policy.computeInitialPolicyHash(createdPoolId, CREATOR, kind, initial);

        params.assets = assets;
        params.policyFamilyId = FAMILY;
        params.creatorSalt = salt;
        params.name = "Demeter Test Index";
        params.symbol = "DTEST";
        params.bootstrapper = BOOTSTRAPPER;
        params.bootstrapDeadline = uint64(block.timestamp + 10 days);
        params.initialShareSupply = 100e18;
        params.kind = kind;
        params.seedAmounts = new uint256[](2);
        params.seedAmounts[0] = _seedFor(assets[0]);
        params.seedAmounts[1] = _seedFor(assets[1]);
        params.initialShareRecipient = ALICE;
        params.initialPolicyHash = initialHash;
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

    function _reserves(bytes32 id, address[] memory assets) private view returns (uint256[] memory values) {
        values = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            values[i] = manager.reserveOf(id, assets[i]);
        }
    }

    function _balances(address owner, address[] memory assets) private view returns (uint256[] memory values) {
        values = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            values[i] = IERC20(assets[i]).balanceOf(owner);
        }
    }

    function _allowances(address owner, address spender, address[] memory assets)
        private
        view
        returns (uint256[] memory values)
    {
        values = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            values[i] = IERC20(assets[i]).allowance(owner, spender);
        }
    }

    function _assertReservesAndBalances(
        bytes32 id,
        address[] memory assets,
        uint256[] memory expectedReserves,
        uint256[] memory expectedBalances
    ) private view {
        for (uint256 i; i < assets.length; ++i) {
            assertEq(manager.reserveOf(id, assets[i]), expectedReserves[i]);
            assertEq(IERC20(assets[i]).balanceOf(address(manager)), expectedBalances[i]);
            assertEq(manager.accountedReserve(assets[i]), expectedReserves[i]);
        }
    }

    function _assertBalances(address owner, address[] memory assets, uint256[] memory expected) private view {
        for (uint256 i; i < assets.length; ++i) {
            assertEq(IERC20(assets[i]).balanceOf(owner), expected[i]);
        }
    }

    function _assertAllowances(address owner, address spender, address[] memory assets, uint256[] memory expected)
        private
        view
    {
        for (uint256 i; i < assets.length; ++i) {
            assertEq(IERC20(assets[i]).allowance(owner, spender), expected[i]);
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
