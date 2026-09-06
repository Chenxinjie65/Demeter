// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ITwapOracle} from "src/interfaces/ITwapOracle.sol";
import {OracleGuard} from "src/libraries/OracleGuard.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {UniswapV3TwapOracle} from "src/oracle/UniswapV3TwapOracle.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {MockV2ChainlinkFeed} from "test/v2/mocks/MockV2ChainlinkFeed.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";
import {MockV2UniswapPool} from "test/v2/mocks/MockV2UniswapPool.sol";

contract OracleGuardHarness {
    function validatedPrice(IAssetRegistry registry, ITwapOracle twap, address asset, uint16 maxDeviation)
        external
        view
        returns (OracleGuard.ValidatedPrice memory)
    {
        return OracleGuard.validatedPrice(registry, twap, asset, maxDeviation);
    }

    function validateMove(uint256 referencePrice, uint256 currentPrice, uint16 maxMove) external pure {
        OracleGuard.validateReferenceMove(referencePrice, currentPrice, maxMove);
    }

    function validateDivergence(uint256 primaryPrice, uint256 secondaryPrice, uint16 maxDeviation) external pure {
        OracleGuard.validateSourceDivergence(primaryPrice, secondaryPrice, maxDeviation);
    }
}

contract OracleGuardTest is Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);

    AssetRegistry private registry;
    UniswapV3TwapOracle private twap;
    OracleGuardHarness private harness;
    MockV2ERC20 private quote;
    MockV2ERC20 private asset;
    MockV2ChainlinkFeed private quoteFeed;
    MockV2ChainlinkFeed private assetFeed;
    MockV2UniswapPool private pool;

    function setUp() public {
        vm.warp(10_000);
        vm.etch(TIMELOCK, hex"00");
        quote = new MockV2ERC20("Quote", "Q", 18);
        asset = new MockV2ERC20("Asset", "A", 18);
        quoteFeed = new MockV2ChainlinkFeed(8);
        assetFeed = new MockV2ChainlinkFeed(8);
        pool = new MockV2UniswapPool(address(asset), address(quote));
        twap = new UniswapV3TwapOracle();
        harness = new OracleGuardHarness();
        registry = new AssetRegistry(TIMELOCK, GUARDIAN, address(quote), _bounds());
        vm.startPrank(TIMELOCK);
        registry.configureAsset(address(quote), _input(address(quoteFeed), address(0)));
        registry.configureAsset(address(asset), _input(address(assetFeed), address(pool)));
        vm.stopPrank();
    }

    function test_ValidatedPriceUsesChainlinkAndCommonQuoteTwap() public view {
        OracleGuard.ValidatedPrice memory result = harness.validatedPrice(registry, twap, address(asset), 200);
        assertEq(result.chainlinkUsdWad, 1e18);
        assertEq(result.twapUsdWad, 1e18);
        assertEq(result.assetConfigVersion, 1);
    }

    function test_TwapAtTickZeroReturnsEqualRawAmount() public view {
        assertEq(twap.quote(address(pool), address(asset), address(quote), 1e18, 30 minutes), 1e18);
    }

    function test_RevertWhen_MeanTickIsOutsideInt24Range() public {
        pool.setRawDelta(int56(type(int24).max) + 1);
        vm.expectRevert(UniswapV3TwapOracle.UniswapV3TwapOracle__InvalidObservation.selector);
        twap.quote(address(pool), address(asset), address(quote), 1e18, 1);
    }

    function test_RevertWhen_ChainlinkIsStale() public {
        assetFeed.setRound(2, 1e8, 1, block.timestamp - 3601, 2);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("chainlinkStale")));
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_RevertWhen_ChainlinkAnswerIsZero() public {
        assetFeed.setRound(2, 0, 1, block.timestamp, 2);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("chainlinkAnswer")));
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_RevertWhen_ChainlinkAnswerIsNegative() public {
        assetFeed.setRound(2, -1, 1, block.timestamp, 2);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("chainlinkAnswer")));
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_FailsClosedWhenChainlinkFeedReverts() public {
        assetFeed.setShouldRevert(true);
        vm.expectRevert(MockV2ChainlinkFeed.MockV2ChainlinkFeed__Reverted.selector);
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_RevertWhen_RoundIsIncomplete() public {
        assetFeed.setRound(2, 1e8, 1, block.timestamp, 1);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("chainlinkRound")));
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_RevertWhen_RoundIdIsZero() public {
        assetFeed.setRound(0, 1e8, 1, block.timestamp, 0);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("chainlinkRound")));
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_RevertWhen_SourcesDiverge() public {
        assetFeed.setRound(2, 2e8, 1, block.timestamp, 2);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("sourceDivergence")));
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_RevertWhen_SequencerIsDown() public {
        MockV2ChainlinkFeed sequencer = new MockV2ChainlinkFeed(0);
        sequencer.setRound(1, 1, block.timestamp - 100, block.timestamp, 1);
        vm.prank(TIMELOCK);
        registry.setSequencerConfig(address(sequencer), 60);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("sequencerDown")));
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_RevertDuringSequencerGracePeriod() public {
        MockV2ChainlinkFeed sequencer = new MockV2ChainlinkFeed(0);
        sequencer.setRound(1, 0, block.timestamp - 30, block.timestamp, 1);
        vm.prank(TIMELOCK);
        registry.setSequencerConfig(address(sequencer), 60);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("sequencerGrace")));
        harness.validatedPrice(registry, twap, address(asset), 200);
    }

    function test_ReferenceMoveIsInclusiveAtLimit() public {
        harness.validateMove(1e18, 1.05e18, 500);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("referenceMove")));
        harness.validateMove(1e18, 1.0501e18, 500);
    }

    function test_PairSourceDivergenceIsInclusiveAtLimit() public {
        harness.validateDivergence(1e18, 1.02e18, 200);
        vm.expectRevert(abi.encodeWithSelector(V2Errors.V2Errors__OracleUnsafe.selector, bytes32("sourceDivergence")));
        harness.validateDivergence(1e18, 1.0201e18, 200);
    }

    function test_TwapNormalizesCrossTokenDecimalsInBothDirections() public {
        MockV2ERC20 decimalQuote = new MockV2ERC20("Decimal Quote", "DQ", 6);
        MockV2ERC20 decimalAsset = new MockV2ERC20("Decimal Asset", "DA", 18);
        MockV2ChainlinkFeed decimalQuoteFeed = new MockV2ChainlinkFeed(8);
        MockV2ChainlinkFeed decimalAssetFeed = new MockV2ChainlinkFeed(8);
        MockV2UniswapPool decimalPool = new MockV2UniswapPool(address(decimalQuote), address(decimalAsset));
        AssetRegistry decimalRegistry = new AssetRegistry(TIMELOCK, GUARDIAN, address(decimalQuote), _bounds());

        int24 decimalAdjustment = 276_324;
        decimalPool.setMeanTick(address(decimalAsset) < address(decimalQuote) ? -decimalAdjustment : decimalAdjustment);
        vm.startPrank(TIMELOCK);
        decimalRegistry.configureAsset(address(decimalQuote), _input(address(decimalQuoteFeed), address(0)));
        decimalRegistry.configureAsset(address(decimalAsset), _input(address(decimalAssetFeed), address(decimalPool)));
        vm.stopPrank();

        uint256 quoteRaw =
            twap.quote(address(decimalPool), address(decimalAsset), address(decimalQuote), 1e18, 30 minutes);
        uint256 assetRaw =
            twap.quote(address(decimalPool), address(decimalQuote), address(decimalAsset), 1e6, 30 minutes);
        assertApproxEqRel(quoteRaw, 1e6, 0.00001e18);
        assertApproxEqRel(assetRaw, 1e18, 0.00001e18);

        OracleGuard.ValidatedPrice memory result =
            harness.validatedPrice(decimalRegistry, twap, address(decimalAsset), 200);
        assertEq(result.chainlinkUsdWad, 1e18);
        assertApproxEqRel(result.twapUsdWad, 1e18, 0.00001e18);
    }

    function _bounds() private pure returns (PoolTypes.GlobalPoolBounds memory bounds) {
        bounds.minAssets = 2;
        bounds.maxAssets = 16;
        bounds.maxNameBytes = 64;
        bounds.maxSymbolBytes = 16;
        bounds.minInitialShareSupply = 1e18;
        bounds.maxInitialShareSupply = 1e30;
        bounds.minBootstrapDuration = 1 hours;
        bounds.maxBootstrapDuration = 30 days;
    }

    function _input(address feed, address twapPool) private pure returns (PoolTypes.AssetConfigInput memory input) {
        input.chainlinkFeed = feed;
        input.twapPool = twapPool;
        input.twapWindow = 30 minutes;
        input.maxChainlinkStale = 1 hours;
        input.maxOracleDeviationBps = 200;
        input.maxReferenceMoveBps = 500;
    }
}
