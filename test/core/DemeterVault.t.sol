// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DemeterVault} from "../../src/core/DemeterVault.sol";
import {ProtocolAddressProvider} from "../../src/core/ProtocolAddressProvider.sol";
import {IDemeterVault} from "../../src/interfaces/core/IDemeterVault.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {Constants} from "../../src/libraries/Constants.sol";
import {VaultMath} from "../../src/libraries/VaultMath.sol";
import {Errors} from "../../src/libraries/Errors.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";
import {MockAssetAdapter} from "../mocks/MockAssetAdapter.sol";
import {MockSwapRouter} from "../mocks/MockSwapRouter.sol";
import {MockCircuitBreaker} from "../mocks/MockCircuitBreaker.sol";

/**
 * @title DemeterVaultTest
 * @notice Comprehensive unit, fuzz, and invariant tests for the DemeterVault core contract.
 *
 * @dev
 * Test portfolio: 2-asset basket — WETH (18 dec, 50%) and WBTC (8 dec, 50%).
 * Prices: WETH = $2,000, WBTC = $50,000.
 * All prices in 8-decimal USD units (Chainlink convention).
 *
 * Key test pattern:
 * - All withdrawal params are PRE-BUILT before vm.prank/vm.expectRevert, because
 *   `_buildWithdrawParams` calls `vault.getAssets()` externally and would otherwise
 *   consume the prank — leaving withdrawMulti called from the test contract (not the user).
 *
 * Deployment pattern: DemeterVault uses `_disableInitializers()` in the constructor.
 * Tests deploy through an ERC1967Proxy and call `initialize` via the proxy.
 */
contract DemeterVaultTest is Test {
    // =========================================================================
    // Test actors & infrastructure
    // =========================================================================

    address internal constant MANAGER   = address(0xBEEF);
    address internal constant ALICE     = address(0xA11CE);
    address internal constant BOB       = address(0xB0B);
    address internal constant GUARDIAN  = address(0xDEAD);
    address internal constant TREASURY  = address(0xFEE5);
    address internal constant KEEPER    = address(0x4EEF);

    // =========================================================================
    // Price constants (8-decimal USD, Chainlink convention)
    // =========================================================================

    uint256 internal constant WETH_PRICE  = 2_000e8;   // $2,000
    uint256 internal constant WBTC_PRICE  = 50_000e8;  // $50,000

    // =========================================================================
    // Token amounts for standard tests
    // =========================================================================

    /// @dev 1 WETH (18 decimals)
    uint256 internal constant ONE_WETH = 1e18;
    /// @dev 1 WBTC (8 decimals)
    uint256 internal constant ONE_WBTC = 1e8;
    /// @dev 0.04 WBTC — fair-value equivalent of 1 WETH at the configured prices
    ///      1 WETH * ($2000/$50000) * (1e8 / 1e18) = 4e6 raw WBTC units
    uint256 internal constant WBTC_EQUIV_1_WETH = 4e6;

    // =========================================================================
    // Contracts
    // =========================================================================

    DemeterVault             internal vault;
    ProtocolAddressProvider  internal addressProvider;
    MockERC20                internal weth;
    MockERC20                internal wbtc;
    MockPriceOracle          internal oracle;
    MockAssetAdapter         internal adapter;
    MockSwapRouter           internal swapRouter;
    MockCircuitBreaker       internal circuitBreaker;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        // --- Deploy tokens ---
        weth = new MockERC20("Wrapped Ether",   "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC",  8);

        // --- Deploy oracle ---
        oracle = new MockPriceOracle();
        oracle.setPrice(address(weth), WETH_PRICE);
        oracle.setPrice(address(wbtc), WBTC_PRICE);

        // --- Deploy address provider ---
        addressProvider = new ProtocolAddressProvider(address(this));
        addressProvider.setGuardian(GUARDIAN);
        addressProvider.setTreasury(TREASURY);
        addressProvider.setPriceOracle(address(oracle));

        // --- Deploy helper mocks ---
        adapter        = new MockAssetAdapter();
        swapRouter     = new MockSwapRouter();
        circuitBreaker = new MockCircuitBreaker();

        // --- Deploy vault through proxy ---
        vault = _deployVault(true);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Deploys a fresh vault behind an ERC1967Proxy.
    function _deployVault(bool isMutable_) internal returns (DemeterVault) {
        address[] memory assets  = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(wbtc);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;

        IDemeterVault.InitializeParams memory params = IDemeterVault.InitializeParams({
            baseAsset:       address(0),
            manager:         MANAGER,
            assets:          assets,
            weights:         weights,
            addressProvider: address(addressProvider),
            name:            "Demeter WETH-WBTC Index",
            symbol:          "DMT-WB",
            isMutable:       isMutable_,
            circuitBreaker:  address(0)
        });

        DemeterVault impl = new DemeterVault();
        bytes memory initData = abi.encodeCall(DemeterVault.initialize, (params));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        return DemeterVault(address(proxy));
    }

    /// @dev Builds a maxAmountsIn array for depositMulti (ordered by vault's asset list).
    function _buildMaxAmounts(uint256 wethAmt, uint256 wbtcAmt)
        internal
        pure
        returns (uint256[] memory maxAmounts)
    {
        maxAmounts = new uint256[](2);
        maxAmounts[0] = wethAmt;
        maxAmounts[1] = wbtcAmt;
    }

    /**
     * @dev Computes the sharesOut parameter for a normal-path deposit (totalShares > 0).
     *      Returns 0 for bootstrap (totalShares == 0).
     */
    function _computeSharesOutForDeposit(uint256 wethAmt, uint256 wbtcAmt)
        internal
        view
        returns (uint256 sharesOut)
    {
        uint256 totalShares_ = vault.totalSupply();
        if (totalShares_ == 0) return 0;

        uint256 totalBalWeth = vault.getTotalBalance(address(weth));
        uint256 totalBalWbtc = vault.getTotalBalance(address(wbtc));

        uint256 s0 = totalBalWeth == 0 ? type(uint256).max
            : Math.mulDiv(wethAmt, totalShares_, totalBalWeth);
        uint256 s1 = totalBalWbtc == 0 ? type(uint256).max
            : Math.mulDiv(wbtcAmt, totalShares_, totalBalWbtc);
        sharesOut = s0 < s1 ? s0 : s1;
    }

    /**
     * @dev Builds a withdrawal params struct covering all portfolio assets.
     *
     * IMPORTANT: This helper calls `vault.getAssets()` (an external call).
     * Always call this helper BEFORE setting vm.prank or vm.expectRevert,
     * otherwise the external view call will consume the prank prematurely.
     */
    function _buildWithdrawParams(address owner, address receiver, uint256 shares)
        internal
        view
        returns (DataTypes.MultiAssetWithdrawParams memory)
    {
        address[] memory assets  = vault.getAssets(); // external call — see note above
        uint256[] memory minOut  = new uint256[](assets.length);
        return DataTypes.MultiAssetWithdrawParams({
            owner:         owner,
            receiver:      receiver,
            shares:        shares,
            assets:        assets,
            minAmountsOut: minOut
        });
    }

    /// @dev Mints tokens to `to` and approves the vault.
    function _fund(address to, uint256 wethAmt, uint256 wbtcAmt) internal {
        weth.mint(to, wethAmt);
        wbtc.mint(to, wbtcAmt);
        vm.startPrank(to);
        weth.approve(address(vault), type(uint256).max);
        wbtc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Helper: deposit and return shares received. Safe to call without vm.prank active.
    function _deposit(address depositor, uint256 wethAmt, uint256 wbtcAmt)
        internal
        returns (uint256 shares)
    {
        _fund(depositor, wethAmt, wbtcAmt);
        uint256[] memory maxAmounts = _buildMaxAmounts(wethAmt, wbtcAmt);
        uint256 sharesOut = _computeSharesOutForDeposit(wethAmt, wbtcAmt);
        uint256 balBefore = vault.balanceOf(depositor);
        vm.prank(depositor);
        vault.depositMulti(sharesOut, maxAmounts, depositor);
        shares = vault.balanceOf(depositor) - balBefore;
    }

    // =========================================================================
    // Initialization Tests
    // =========================================================================

    function test_Initialize_Success() public view {
        assertEq(vault.name(),    "Demeter WETH-WBTC Index");
        assertEq(vault.symbol(),  "DMT-WB");
        assertEq(vault.decimals(), 18);
        assertEq(vault.manager(), MANAGER);
        assertEq(vault.isMutable(), true);
        assertEq(vault.addressProvider(), address(addressProvider));
        assertEq(vault.feeRecipient(), TREASURY);

        address[] memory assets  = vault.getAssets();
        assertEq(assets.length, 2);
        assertEq(assets[0], address(weth));
        assertEq(assets[1], address(wbtc));

        uint256[] memory weights = vault.getWeights();
        assertEq(weights.length, 2);
        assertEq(weights[0], 5_000);
        assertEq(weights[1], 5_000);
    }

    function test_Initialize_RevertsIfCalledTwice() public {
        IDemeterVault.InitializeParams memory params = IDemeterVault.InitializeParams({
            baseAsset:       address(0),
            manager:         MANAGER,
            assets:          vault.getAssets(),
            weights:         vault.getWeights(),
            addressProvider: address(addressProvider),
            name:            "X",
            symbol:          "X",
            isMutable:       false,
            circuitBreaker:  address(0)
        });
        vm.expectRevert();
        vault.initialize(params);
    }

    function test_Initialize_RevertsOnWeightsMismatch() public {
        address[] memory assets  = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(wbtc);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;

        DemeterVault impl = new DemeterVault();
        IDemeterVault.InitializeParams memory params = IDemeterVault.InitializeParams({
            baseAsset: address(0), manager: MANAGER, assets: assets, weights: weights,
            addressProvider: address(addressProvider), name: "X", symbol: "X", isMutable: false, circuitBreaker: address(0)
        });
        vm.expectRevert();
        new ERC1967Proxy(address(impl), abi.encodeCall(DemeterVault.initialize, (params)));
    }

    function test_Initialize_RevertsOnWeightsNotNormalized() public {
        address[] memory assets  = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(wbtc);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 4_000;
        weights[1] = 4_000; // sum = 8000 != 10000

        DemeterVault impl = new DemeterVault();
        IDemeterVault.InitializeParams memory params = IDemeterVault.InitializeParams({
            baseAsset: address(0), manager: MANAGER, assets: assets, weights: weights,
            addressProvider: address(addressProvider), name: "X", symbol: "X", isMutable: false, circuitBreaker: address(0)
        });
        vm.expectRevert(Errors.WeightsNotNormalized.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(DemeterVault.initialize, (params)));
    }

    function test_Initialize_RevertsOnZeroWeight() public {
        address[] memory assets  = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(wbtc);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 10_000;
        weights[1] = 0; // invalid

        DemeterVault impl = new DemeterVault();
        IDemeterVault.InitializeParams memory params = IDemeterVault.InitializeParams({
            baseAsset: address(0), manager: MANAGER, assets: assets, weights: weights,
            addressProvider: address(addressProvider), name: "X", symbol: "X", isMutable: false, circuitBreaker: address(0)
        });
        vm.expectRevert(Errors.InvalidWeight.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(DemeterVault.initialize, (params)));
    }

    function test_Initialize_RevertsOnEmptyAssets() public {
        DemeterVault impl = new DemeterVault();
        IDemeterVault.InitializeParams memory params = IDemeterVault.InitializeParams({
            baseAsset: address(0), manager: MANAGER,
            assets: new address[](0), weights: new uint256[](0),
            addressProvider: address(addressProvider), name: "X", symbol: "X", isMutable: false, circuitBreaker: address(0)
        });
        vm.expectRevert();
        new ERC1967Proxy(address(impl), abi.encodeCall(DemeterVault.initialize, (params)));
    }

    // =========================================================================
    // ERC-20 Tests
    // =========================================================================

    function test_ERC20_MetadataCorrect() public view {
        assertEq(vault.name(),    "Demeter WETH-WBTC Index");
        assertEq(vault.symbol(),  "DMT-WB");
        assertEq(vault.decimals(), 18);
        assertEq(vault.totalSupply(), 0);
    }

    function test_ERC20_Transfer() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vault.transfer(BOB, shares);

        assertEq(vault.balanceOf(ALICE), 0);
        assertEq(vault.balanceOf(BOB),   shares);
    }

    function test_ERC20_Transfer_RevertsOnInsufficientBalance() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vm.expectRevert();
        vault.transfer(BOB, type(uint256).max);
    }

    function test_ERC20_Approve_And_TransferFrom() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vault.approve(BOB, shares);
        assertEq(vault.allowance(ALICE, BOB), shares);

        vm.prank(BOB);
        vault.transferFrom(ALICE, BOB, shares);
        assertEq(vault.balanceOf(BOB),        shares);
        assertEq(vault.allowance(ALICE, BOB), 0);
    }

    function test_ERC20_TransferFrom_RevertsOnInsufficientAllowance() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vault.approve(BOB, shares - 1);

        vm.prank(BOB);
        vm.expectRevert();
        vault.transferFrom(ALICE, BOB, shares);
    }

    function test_ERC20_MaxAllowance_NotDecrementedOnTransferFrom() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vault.approve(BOB, type(uint256).max);

        vm.prank(BOB);
        vault.transferFrom(ALICE, BOB, shares);

        assertEq(vault.allowance(ALICE, BOB), type(uint256).max,
            "Max allowance should not be decremented");
    }

    // =========================================================================
    // depositMulti Tests
    // =========================================================================

    function test_Deposit_FirstDeposit_MintsCorrectShares() public {
        // depositAUM = 1 WETH * $2000 + 0.04 WBTC * $50000 = $4000 = 4000e8
        // calcSharesToMint: depositAUM * (0 + VIRTUAL_SHARES) / (0 + VIRTUAL_AUM)
        //   = 4000e8 * 1e10 / 1 = 4e21 shares
        uint256 expectedShares = Math.mulDiv(
            4_000e8,
            Constants.VIRTUAL_SHARES,
            Constants.VIRTUAL_AUM
        );

        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        assertEq(shares, expectedShares, "shares minted");
        assertEq(vault.balanceOf(ALICE), shares, "ALICE balance");
        assertEq(vault.totalSupply(), shares, "total supply");
        assertEq(weth.balanceOf(address(vault)), ONE_WETH,          "vault WETH balance");
        assertEq(wbtc.balanceOf(address(vault)), WBTC_EQUIV_1_WETH, "vault WBTC balance");
    }

    function test_Deposit_SubsequentDeposit_DoublesAUMAndShares() public {
        uint256 aliceShares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // Second deposit of equal amounts → AUM doubles.
        // After first deposit, HWM is updated, so no perf fee on 2nd deposit.
        // BOB should receive approximately the same shares as ALICE (virtual-offset rounding aside).
        uint256 bobShares = _deposit(BOB, ONE_WETH, WBTC_EQUIV_1_WETH);

        // Allow <0.01% tolerance for virtual-offset arithmetic.
        assertApproxEqRel(bobShares, aliceShares, 0.0001e18,
            "Second deposit of same AUM should mint approximately same shares");
        assertEq(vault.totalSupply(), aliceShares + bobShares, "total supply after two deposits");
    }

    function test_Deposit_RevertsIfPaused() public {
        vm.prank(GUARDIAN);
        vault.pause();

        _fund(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        uint256[] memory maxAmounts = _buildMaxAmounts(ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault.depositMulti(0, maxAmounts, ALICE);
    }

    function test_Deposit_RevertsOnWrongAsset() public {
        // maxAmountsIn length must equal vault's asset count (2).
        // Passing 1 element should revert with ArraysLengthMismatch.
        uint256[] memory badAmounts = new uint256[](1);
        badAmounts[0] = ONE_WETH;

        vm.prank(ALICE);
        vm.expectRevert(Errors.ArraysLengthMismatch.selector);
        vault.depositMulti(0, badAmounts, ALICE);
    }

    function test_Deposit_RevertsOnZeroAmount() public {
        // Bootstrap path validates every maxAmountsIn[i] > 0.
        uint256[] memory maxAmounts = _buildMaxAmounts(0, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vm.expectRevert(Errors.ZeroAmount.selector);
        vault.depositMulti(0, maxAmounts, ALICE);
    }

    function test_Deposit_RevertsOnSlippage() public {
        _fund(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        uint256[] memory maxAmounts = _buildMaxAmounts(ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vm.expectRevert(); // SlippageExceeded: oracle shares < type(uint256).max
        vault.depositMulti(type(uint256).max, maxAmounts, ALICE);
    }

    function test_Deposit_EmitsDepositedEvent() public {
        _fund(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        uint256[] memory maxAmounts = _buildMaxAmounts(ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vm.expectEmit(true, false, false, false, address(vault));
        emit IDemeterVault.Deposited(ALICE, new address[](0), new uint256[](0), 0);
        vault.depositMulti(0, maxAmounts, ALICE);
    }

    function test_Deposit_WithAdapter_DeploysExcess() public {
        vm.prank(MANAGER);
        vault.setStrategy(address(weth), address(adapter));

        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // bufferRatioBps = 1000 = 10%; 90% should be in adapter.
        uint256 expectedDeployed = ONE_WETH * 9 / 10;
        uint256 expectedIdle     = ONE_WETH - expectedDeployed;

        assertApproxEqAbs(adapter.getBalance(address(weth), address(vault)), expectedDeployed, 1,
            "90% of WETH should be deployed to adapter");
        assertApproxEqAbs(weth.balanceOf(address(vault)), expectedIdle, 1,
            "10% of WETH should remain idle in vault");
    }

    // =========================================================================
    // withdrawMulti Tests
    //
    // IMPORTANT: Always pre-build params before vm.prank to avoid consuming the
    // prank with the internal vault.getAssets() call inside _buildWithdrawParams.
    // =========================================================================

    function test_Withdraw_BasicWithdraw_ReturnsAllAssets() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        uint256 aliceWethBefore = weth.balanceOf(ALICE);
        uint256 aliceWbtcBefore = wbtc.balanceOf(ALICE);

        // Pre-build params BEFORE setting prank (see class docstring).
        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares);

        vm.prank(ALICE);
        uint256[] memory amounts = vault.withdrawMulti(params);

        assertEq(amounts.length, 2, "amounts array must cover all portfolio assets");
        assertApproxEqAbs(amounts[0], ONE_WETH,          1, "WETH returned");
        assertApproxEqAbs(amounts[1], WBTC_EQUIV_1_WETH, 1, "WBTC returned");

        assertApproxEqAbs(weth.balanceOf(ALICE) - aliceWethBefore, ONE_WETH,          1);
        assertApproxEqAbs(wbtc.balanceOf(ALICE) - aliceWbtcBefore, WBTC_EQUIV_1_WETH, 1);

        assertEq(vault.totalSupply(),    0, "all shares burned");
        assertEq(vault.balanceOf(ALICE), 0, "ALICE balance is zero");
    }

    function test_Withdraw_StrictInKind_LengthMismatchReverts() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        uint256 shares = vault.balanceOf(ALICE);

        // Pass only 1 minAmountOut instead of 2 — should revert.
        uint256[] memory badMinOut = new uint256[](1);
        address[] memory assets    = vault.getAssets();

        vm.prank(ALICE);
        vm.expectRevert(Errors.ArraysLengthMismatch.selector);
        vault.withdrawMulti(DataTypes.MultiAssetWithdrawParams({
            owner: ALICE, receiver: ALICE, shares: shares,
            assets: assets, minAmountsOut: badMinOut
        }));
    }

    function test_Withdraw_RevertsOnZeroShares() public {
        // Pre-build params before expectRevert to avoid consuming it with getAssets().
        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, 0);

        vm.prank(ALICE);
        vm.expectRevert(Errors.ZeroShares.selector);
        vault.withdrawMulti(params);
    }

    function test_Withdraw_RevertsOnInsufficientShares() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares + 1);

        vm.prank(ALICE);
        vm.expectRevert();
        vault.withdrawMulti(params);
    }

    function test_Withdraw_WithAllowance_ThirdPartyCanRedeem() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vault.approve(BOB, shares);

        // Pre-build before prank.
        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, BOB, shares);

        vm.prank(BOB);
        vault.withdrawMulti(params);

        assertGt(weth.balanceOf(BOB), 0, "BOB should receive WETH");
        assertGt(wbtc.balanceOf(BOB), 0, "BOB should receive WBTC");
        assertEq(vault.balanceOf(ALICE), 0, "ALICE shares burned");
    }

    function test_Withdraw_RevertsOnInsufficientAllowance() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vault.approve(BOB, shares - 1);

        // Pre-build before prank.
        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, BOB, shares);

        vm.prank(BOB);
        vm.expectRevert();
        vault.withdrawMulti(params);
    }

    function test_Withdraw_RevertsOnSlippage() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        address[] memory assets  = vault.getAssets();
        uint256[] memory minOut  = new uint256[](2);
        minOut[0] = type(uint256).max; // impossible
        minOut[1] = type(uint256).max;

        DataTypes.MultiAssetWithdrawParams memory params = DataTypes.MultiAssetWithdrawParams({
            owner: ALICE, receiver: ALICE, shares: shares,
            assets: assets, minAmountsOut: minOut
        });

        vm.prank(ALICE);
        vm.expectRevert();
        vault.withdrawMulti(params);
    }

    function test_Withdraw_WorksWhenPaused() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(GUARDIAN);
        vault.pause();

        // Pre-build before prank.
        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares);

        // Withdrawals must work even when paused (critical safety property).
        vm.prank(ALICE);
        uint256[] memory amounts = vault.withdrawMulti(params);
        assertGt(amounts[0], 0, "WETH returned even when paused");
        assertGt(amounts[1], 0, "WBTC returned even when paused");
    }

    function test_Withdraw_WithAdapter_PullsFromAdapterWhenIdleInsufficient() public {
        vm.prank(MANAGER);
        vault.setStrategy(address(weth), address(adapter));

        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // After deposit, most WETH is in the adapter (90%).
        assertGt(adapter.getBalance(address(weth), address(vault)), 0,
            "Some WETH should be in adapter post-deposit");

        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares);

        vm.prank(ALICE);
        uint256[] memory amounts = vault.withdrawMulti(params);

        assertApproxEqAbs(amounts[0], ONE_WETH, 1, "Full WETH recovered via adapter");
    }

    function test_Withdraw_AaveDoS_RevertsWithClearError() public {
        vm.prank(MANAGER);
        vault.setStrategy(address(weth), address(adapter));

        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // Force adapter to revert (simulates Aave 100% utilization).
        adapter.setRevertWithdraw(true);

        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares);

        vm.prank(ALICE);
        // Revert selector is enough; exact shortfall amount is implementation detail.
        vm.expectRevert();
        vault.withdrawMulti(params);
    }

    function test_Withdraw_CircuitBreaker_BlocksExcessiveOutflow() public {
        vm.prank(MANAGER);
        vault.setCircuitBreaker(address(circuitBreaker));

        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        circuitBreaker.setShouldBlock(true);

        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares);

        vm.prank(ALICE);
        vm.expectRevert("MockCircuitBreaker: outflow cap exceeded");
        vault.withdrawMulti(params);
    }

    function test_Withdraw_CircuitBreaker_RecordsUsdValue() public {
        vm.prank(MANAGER);
        vault.setCircuitBreaker(address(circuitBreaker));

        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // Expected USD = ~$4000 = 4000e8 (ALICE's entire deposit).
        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares);

        vm.prank(ALICE);
        vault.withdrawMulti(params);

        assertApproxEqAbs(circuitBreaker.lastRecordedValue(), 4_000e8, 1e4,
            "Circuit breaker should record ~$4000 in USD outflow");
    }

    function test_Withdraw_EmitsWithdrawnEvent() public {
        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares);

        vm.prank(ALICE);
        // Check emitter address and first two indexed fields.
        vm.expectEmit(true, true, false, false, address(vault));
        emit IDemeterVault.Withdrawn(ALICE, ALICE, new address[](0), new uint256[](0), 0);
        vault.withdrawMulti(params);
    }

    // =========================================================================
    // Management Function Tests
    // =========================================================================

    function test_SetManager_UpdatesManager() public {
        vm.prank(MANAGER);
        vault.setManager(BOB);
        assertEq(vault.manager(), BOB);
    }

    function test_SetManager_RevertsIfNotManager() public {
        vm.prank(ALICE);
        vm.expectRevert(Errors.NotManager.selector);
        vault.setManager(BOB);
    }

    function test_SetWeights_UpdatesWeights() public {
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 7_000;
        newWeights[1] = 3_000;

        vm.prank(MANAGER);
        vault.setWeights(newWeights);

        uint256[] memory stored = vault.getWeights();
        assertEq(stored[0], 7_000);
        assertEq(stored[1], 3_000);
    }

    function test_SetWeights_RevertsOnImmutableVault() public {
        DemeterVault immutableVault = _deployVault(false);

        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 7_000;
        newWeights[1] = 3_000;

        vm.prank(MANAGER);
        vm.expectRevert(Errors.VaultImmutable.selector);
        immutableVault.setWeights(newWeights);
    }

    function test_SetWeights_RevertsIfNotManager() public {
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 7_000;
        newWeights[1] = 3_000;

        vm.prank(ALICE);
        vm.expectRevert(Errors.NotManager.selector);
        vault.setWeights(newWeights);
    }

    function test_SetWeights_RevertsOnInvalidSum() public {
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 6_000;
        newWeights[1] = 3_000; // sum = 9000 != 10000

        vm.prank(MANAGER);
        vm.expectRevert(Errors.WeightsNotNormalized.selector);
        vault.setWeights(newWeights);
    }

    function test_SetStrategy_UpdatesAdapter() public {
        vm.prank(MANAGER);
        vault.setStrategy(address(weth), address(adapter));
        assertEq(vault.getStrategy(address(weth)), address(adapter));
    }

    function test_SetStrategy_RevertsIfNotManager() public {
        vm.prank(ALICE);
        vm.expectRevert(Errors.NotManager.selector);
        vault.setStrategy(address(weth), address(adapter));
    }

    function test_SetStrategy_RevertsOnUnknownAsset() public {
        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(Errors.AssetNotInPortfolio.selector, address(this)));
        vault.setStrategy(address(this), address(adapter));
    }

    function test_Pause_BlocksDeposits() public {
        vm.prank(GUARDIAN);
        vault.pause();

        _fund(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        uint256[] memory maxAmounts = _buildMaxAmounts(ONE_WETH, WBTC_EQUIV_1_WETH);

        vm.prank(ALICE);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault.depositMulti(0, maxAmounts, ALICE);
    }

    function test_Unpause_RestoresDeposits() public {
        vm.prank(GUARDIAN);
        vault.pause();

        vm.prank(GUARDIAN);
        vault.unpause();

        uint256 shares = _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        assertGt(shares, 0, "deposit should succeed after unpause");
    }

    function test_Pause_RevertsIfCalledByUnauthorized() public {
        vm.prank(ALICE);
        vm.expectRevert(Errors.NotGuardian.selector);
        vault.pause();
    }

    function test_Pause_CanBeCalledByManager() public {
        // Manager is also authorized to pause.
        vm.prank(MANAGER);
        vault.pause();
    }

    function test_SetSwapRouter_CanBeSet() public {
        vm.prank(MANAGER);
        vault.setSwapRouter(address(swapRouter));
        // verified indirectly by rebalance tests
    }

    function test_SetCircuitBreaker_CanBeSet() public {
        vm.prank(MANAGER);
        vault.setCircuitBreaker(address(circuitBreaker));
        // verified indirectly by withdrawal circuit-breaker tests
    }

    // =========================================================================
    // Fee Tests
    // =========================================================================

    function test_ManagementFee_AccruesOverTime() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // Advance one year — management fee = 1% of AUM → ~1% of shares.
        vm.warp(block.timestamp + 365 days);

        // Trigger fee collection via second deposit.
        _deposit(BOB, ONE_WETH, WBTC_EQUIV_1_WETH);

        assertGt(vault.balanceOf(TREASURY), 0,
            "TREASURY should receive management fee shares after one year");
    }

    function test_PerformanceFee_MintedOnNAVGain() public {
        // After the first deposit, HWM is set to the post-deposit NAV (~$1/share).
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // Simulate a NAV gain: WETH price doubles → total AUM grows → NAV > HWM.
        oracle.setPrice(address(weth), WETH_PRICE * 2);

        // Second deposit triggers _collectFees → perf fee charged on the gain.
        _deposit(BOB, ONE_WETH, WBTC_EQUIV_1_WETH);

        assertGt(vault.balanceOf(TREASURY), 0,
            "Performance fee shares should be minted to treasury on NAV gain");
    }

    function test_PerformanceFee_NotChargedBelowHWM() public {
        // First deposit: HWM is set to the post-deposit NAV.
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // Second deposit: establishes HWM at the current NAV level, no fee yet.
        // (Must be called to update HWM after the price was set via oracle.)
        _deposit(BOB, ONE_WETH, WBTC_EQUIV_1_WETH);

        // Record treasury balance after initial deposits.
        uint256 treasurySharesBefore = vault.balanceOf(TREASURY);

        // Now drop the WETH price by 50% — NAV falls below HWM.
        oracle.setPrice(address(weth), WETH_PRICE / 2);

        // Third deposit: _collectFees runs, but currentNAV < HWM → no perf fee.
        address CHARLIE = address(0xC4);
        _deposit(CHARLIE, ONE_WETH, WBTC_EQUIV_1_WETH);

        assertEq(vault.balanceOf(TREASURY), treasurySharesBefore,
            "No performance fee should be charged when NAV is below HWM");
    }

    // =========================================================================
    // NAV & AUM Tests
    // =========================================================================

    function test_TotalAUM_ReflectsDeposit() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        // AUM = 1 WETH * $2000 + 0.04 WBTC * $50000 = $4000 = 4000e8
        assertApproxEqAbs(vault.totalAUM(), 4_000e8, 1e4,
            "AUM should match the USD value of deposited assets");
    }

    function test_NavPerShare_ApproximatelyOneUSD_AfterFirstDeposit() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        // AUM = $4000 (4000e8), shares ~= 4e21
        // navPerShare ~= 4000e8 * 1e18 / 4e21 = 1e8 = $1.00 per share (8-dec)
        assertApproxEqRel(vault.navPerShare(), 1e8, 0.01e18,
            "Initial NAV should be approximately $1 per share");
    }

    function test_NavPerShare_IncreasesOnPriceGain() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        uint256 navBefore = vault.navPerShare();

        oracle.setPrice(address(weth), WETH_PRICE * 2);

        assertGt(vault.navPerShare(), navBefore,
            "NAV should increase when underlying token price rises");
    }

    // =========================================================================
    // Rebalance Tests
    // =========================================================================

    function test_Rebalance_Success_UpdatesWeightsAndMintsKeeperReward() public {
        _deposit(ALICE, 10 * ONE_WETH, 10 * WBTC_EQUIV_1_WETH);

        vm.prank(MANAGER);
        vault.setSwapRouter(address(swapRouter));

        // Configure mock: 1 WETH → 0.04 WBTC (at-price swap).
        swapRouter.setAmountOut(address(wbtc), WBTC_EQUIV_1_WETH);
        wbtc.mint(address(swapRouter), WBTC_EQUIV_1_WETH);

        // Advance past cooldown.
        vm.warp(block.timestamp + Constants.DEFAULT_REBALANCE_COOLDOWN + 1);

        // Change weights: 40% WETH / 60% WBTC.
        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 4_000;
        newWeights[1] = 6_000;

        IDemeterVault.RebalanceSwap[] memory swaps = new IDemeterVault.RebalanceSwap[](1);
        swaps[0] = IDemeterVault.RebalanceSwap({
            tokenIn:      address(weth),
            tokenOut:     address(wbtc),
            fee:          3_000,
            amountIn:     ONE_WETH,
            minAmountOut: 0
        });

        vm.prank(KEEPER);
        vault.rebalance(newWeights, swaps);

        // Weights updated.
        uint256[] memory storedWeights = vault.getWeights();
        assertEq(storedWeights[0], 4_000, "WETH weight updated");
        assertEq(storedWeights[1], 6_000, "WBTC weight updated");

        // Keeper received reward shares (0.1% of totalShares post-fee-collection).
        assertGt(vault.balanceOf(KEEPER), 0, "Keeper should receive reward shares");
    }

    function test_Rebalance_RevertsBeforeCooldown() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);

        // warp to exactly 1 second before the cooldown elapses.
        vm.warp(Constants.DEFAULT_REBALANCE_COOLDOWN - 1);

        uint256[] memory newWeights = vault.getWeights();
        IDemeterVault.RebalanceSwap[] memory swaps = new IDemeterVault.RebalanceSwap[](0);

        vm.prank(KEEPER);
        vm.expectRevert(); // CooldownNotElapsed(remaining)
        vault.rebalance(newWeights, swaps);
    }

    function test_Rebalance_RevertsWhenPortfolioAlreadyBalanced() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        vm.warp(block.timestamp + Constants.DEFAULT_REBALANCE_COOLDOWN + 1);

        // Same weights, no swaps → balanced and no weight change.
        uint256[] memory sameWeights = vault.getWeights();
        IDemeterVault.RebalanceSwap[] memory swaps = new IDemeterVault.RebalanceSwap[](0);

        vm.prank(KEEPER);
        vm.expectRevert(Errors.DeviationBelowThreshold.selector);
        vault.rebalance(sameWeights, swaps);
    }

    function test_Rebalance_RevertsIfPaused() public {
        _deposit(ALICE, ONE_WETH, WBTC_EQUIV_1_WETH);
        vm.warp(block.timestamp + Constants.DEFAULT_REBALANCE_COOLDOWN + 1);

        vm.prank(GUARDIAN);
        vault.pause();

        uint256[] memory newWeights = vault.getWeights();
        IDemeterVault.RebalanceSwap[] memory swaps = new IDemeterVault.RebalanceSwap[](0);

        vm.prank(KEEPER);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault.rebalance(newWeights, swaps);
    }

    function test_Rebalance_RevertsOnSwapFailure() public {
        _deposit(ALICE, 10 * ONE_WETH, 10 * WBTC_EQUIV_1_WETH);

        vm.prank(MANAGER);
        vault.setSwapRouter(address(swapRouter));
        swapRouter.setShouldRevert(true);

        vm.warp(block.timestamp + Constants.DEFAULT_REBALANCE_COOLDOWN + 1);

        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 4_000;
        newWeights[1] = 6_000;

        IDemeterVault.RebalanceSwap[] memory swaps = new IDemeterVault.RebalanceSwap[](1);
        swaps[0] = IDemeterVault.RebalanceSwap({
            tokenIn: address(weth), tokenOut: address(wbtc),
            fee: 3_000, amountIn: ONE_WETH, minAmountOut: 0
        });

        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(Errors.SwapFailed.selector, address(weth), address(wbtc)));
        vault.rebalance(newWeights, swaps);
    }

    function test_Rebalance_RevertsIfSwapRouterNotSet() public {
        _deposit(ALICE, 10 * ONE_WETH, 10 * WBTC_EQUIV_1_WETH);
        vm.warp(block.timestamp + Constants.DEFAULT_REBALANCE_COOLDOWN + 1);

        uint256[] memory newWeights = new uint256[](2);
        newWeights[0] = 4_000;
        newWeights[1] = 6_000;

        IDemeterVault.RebalanceSwap[] memory swaps = new IDemeterVault.RebalanceSwap[](1);
        swaps[0] = IDemeterVault.RebalanceSwap({
            tokenIn: address(weth), tokenOut: address(wbtc),
            fee: 3_000, amountIn: ONE_WETH, minAmountOut: 0
        });

        vm.prank(KEEPER);
        vm.expectRevert(Errors.SwapRouterNotSet.selector);
        vault.rebalance(newWeights, swaps);
    }

    // =========================================================================
    // Fuzz Tests
    // =========================================================================

    /**
     * @notice Fuzz: deposit → withdraw roundtrip; user always gets back <= deposited.
     * @dev Rounding is vault-favourable (floor), so amounts received <= amounts deposited.
     */
    function testFuzz_DepositWithdraw_RoundTrip(uint128 rawWeth, uint128 rawWbtc) public {
        uint256 wethAmt = bound(uint256(rawWeth), 1e15, 1_000 * ONE_WETH);
        uint256 wbtcAmt = bound(uint256(rawWbtc), 1e4,   1_000 * ONE_WBTC);

        uint256 shares = _deposit(ALICE, wethAmt, wbtcAmt);

        uint256 wethBefore = weth.balanceOf(ALICE);
        uint256 wbtcBefore = wbtc.balanceOf(ALICE);

        // Pre-build params before prank (critical — see class docstring).
        DataTypes.MultiAssetWithdrawParams memory params =
            _buildWithdrawParams(ALICE, ALICE, shares);

        vm.prank(ALICE);
        uint256[] memory amounts = vault.withdrawMulti(params);

        uint256 wethReceived = weth.balanceOf(ALICE) - wethBefore;
        uint256 wbtcReceived = wbtc.balanceOf(ALICE) - wbtcBefore;

        // Rounding invariant: vault-favourable floor rounding guarantees received <= deposited.
        assertLe(wethReceived, wethAmt, "Cannot receive more WETH than deposited");
        assertLe(wbtcReceived, wbtcAmt, "Cannot receive more WBTC than deposited");

        assertEq(amounts.length, vault.getAssets().length,
            "amounts array length must equal number of portfolio assets");
        assertEq(vault.balanceOf(ALICE), 0, "all shares burned");
    }

    /**
     * @notice Fuzz: combined user withdrawals never exceed combined deposits.
     * @dev
     * The vault-favourable floor rounding guarantees that users collectively extract at most
     * (totalDeposited - roundingDust) tokens. We allow +1 wei per token for rounding.
     *
     * Note: individual withdrawers CAN receive more than their own deposit (they receive a
     * pro-rata share of the pooled balance), but the AGGREGATE is bounded by total deposits.
     */
    function testFuzz_MultipleDepositors_NoSurplusExtraction(
        uint128 rawAlice,
        uint128 rawBob
    ) public {
        uint256 aliceWeth = bound(uint256(rawAlice), 1e15, 100 * ONE_WETH);
        uint256 bobWeth   = bound(uint256(rawBob),   1e15, 100 * ONE_WETH);
        uint256 aliceWbtc = Math.mulDiv(aliceWeth, WBTC_EQUIV_1_WETH, ONE_WETH);
        uint256 bobWbtc   = Math.mulDiv(bobWeth,   WBTC_EQUIV_1_WETH, ONE_WETH);
        if (aliceWbtc == 0) aliceWbtc = 1;
        if (bobWbtc   == 0) bobWbtc   = 1;

        uint256 aliceShares = _deposit(ALICE, aliceWeth, aliceWbtc);
        uint256 bobShares   = _deposit(BOB,   bobWeth,   bobWbtc);

        uint256 aliceWethBefore = weth.balanceOf(ALICE);
        uint256 aliceWbtcBefore = wbtc.balanceOf(ALICE);
        uint256 bobWethBefore   = weth.balanceOf(BOB);
        uint256 bobWbtcBefore   = wbtc.balanceOf(BOB);

        DataTypes.MultiAssetWithdrawParams memory paramsAlice =
            _buildWithdrawParams(ALICE, ALICE, aliceShares);
        DataTypes.MultiAssetWithdrawParams memory paramsBob =
            _buildWithdrawParams(BOB, BOB, bobShares);

        vm.prank(ALICE);
        vault.withdrawMulti(paramsAlice);

        vm.prank(BOB);
        vault.withdrawMulti(paramsBob);

        uint256 totalWethReceived = (weth.balanceOf(ALICE) - aliceWethBefore)
                                  + (weth.balanceOf(BOB)   - bobWethBefore);
        uint256 totalWbtcReceived = (wbtc.balanceOf(ALICE) - aliceWbtcBefore)
                                  + (wbtc.balanceOf(BOB)   - bobWbtcBefore);

        // Combined extraction must not exceed combined deposits (+1 wei rounding tolerance per token).
        assertLe(totalWethReceived, aliceWeth + bobWeth + 1,
            "Combined WETH received must not exceed combined WETH deposited");
        assertLe(totalWbtcReceived, aliceWbtc + bobWbtc + 1,
            "Combined WBTC received must not exceed combined WBTC deposited");
    }

    /**
     * @notice Fuzz: virtual-offset inflation defence — first depositor always gets shares > 0.
     */
    function testFuzz_SharePrice_VirtualOffsetProtectsFirstDeposit(uint128 rawFirst) public {
        uint256 firstWeth = bound(uint256(rawFirst), 1e12, ONE_WETH);
        uint256 firstWbtc = 1; // dust WBTC

        uint256 firstShares = _deposit(ALICE, firstWeth, firstWbtc);
        assertGt(firstShares, 0,
            "Virtual offset ensures non-zero shares even for dust deposits");
    }
}
