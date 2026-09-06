// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "@forge-std/Test.sol";

import {AssetRegistry} from "src/core/AssetRegistry.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {MockV2ChainlinkFeed} from "test/v2/mocks/MockV2ChainlinkFeed.sol";
import {MockV2ERC20} from "test/v2/mocks/MockV2ERC20.sol";
import {MockV2UniswapPool} from "test/v2/mocks/MockV2UniswapPool.sol";

contract AssetRegistryTest is Test {
    address private constant TIMELOCK = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);

    AssetRegistry private registry;
    MockV2ERC20 private quote;
    MockV2ERC20 private asset;
    MockV2ChainlinkFeed private quoteFeed;
    MockV2ChainlinkFeed private assetFeed;
    MockV2UniswapPool private pool;

    function setUp() public {
        vm.etch(TIMELOCK, hex"00");
        quote = new MockV2ERC20("USD Coin", "USDC", 6);
        asset = new MockV2ERC20("Wrapped Ether", "WETH", 18);
        quoteFeed = new MockV2ChainlinkFeed(8);
        assetFeed = new MockV2ChainlinkFeed(8);
        pool = new MockV2UniswapPool(address(quote), address(asset));
        registry = new AssetRegistry(TIMELOCK, GUARDIAN, address(quote), _bounds());
    }

    function test_ConstructorRejectsEOATimelock() public {
        address noCode = address(0xCAFE);
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetRegistry__InvalidCode.selector, noCode));
        new AssetRegistry(noCode, GUARDIAN, address(quote), _bounds());
    }

    function test_ConfigureCommonQuoteAndAsset() public {
        vm.startPrank(TIMELOCK);
        registry.configureAsset(address(quote), _input(address(quoteFeed), address(0)));
        registry.configureAsset(address(asset), _input(address(assetFeed), address(pool)));
        vm.stopPrank();

        PoolTypes.AssetConfig memory quoteConfig = registry.getAssetConfig(address(quote));
        PoolTypes.AssetConfig memory assetConfig = registry.getAssetConfig(address(asset));
        assertTrue(quoteConfig.enabled);
        assertTrue(assetConfig.enabled);
        assertEq(assetConfig.decimals, 18);
        assertEq(assetConfig.twapQuoteAsset, address(quote));
        assertEq(assetConfig.configVersion, 1);
    }

    function test_RevertWhen_NonTimelockConfiguresAsset() public {
        vm.expectRevert(abi.encodeWithSelector(AssetRegistry.AssetRegistry__Unauthorized.selector, address(this)));
        registry.configureAsset(address(asset), _input(address(assetFeed), address(pool)));
    }

    function test_RevertWhen_TwapPoolDoesNotMatchCommonQuote() public {
        MockV2ERC20 other = new MockV2ERC20("Other", "OTHER", 18);
        MockV2UniswapPool wrongPool = new MockV2UniswapPool(address(asset), address(other));
        vm.prank(TIMELOCK);
        registry.configureAsset(address(quote), _input(address(quoteFeed), address(0)));
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetRegistry.AssetRegistry__InvalidPool.selector, address(wrongPool), address(asset), address(quote)
            )
        );
        registry.configureAsset(address(asset), _input(address(assetFeed), address(wrongPool)));
    }

    function test_RevertWhen_CommonQuoteIsNotConfiguredFirst() public {
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(AssetRegistry.AssetRegistry__AssetNotConfigured.selector, address(quote))
        );
        registry.configureAsset(address(asset), _input(address(assetFeed), address(pool)));
    }

    function test_RevertWhen_ChainlinkFeedDecimalsExceedHardCap() public {
        MockV2ChainlinkFeed invalidFeed = new MockV2ChainlinkFeed(37);
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(AssetRegistry.AssetRegistry__InvalidDecimals.selector, address(invalidFeed), 37)
        );
        registry.configureAsset(address(quote), _input(address(invalidFeed), address(0)));
    }

    function test_RevertWhen_SequencerFeedHasNoGracePeriod() public {
        MockV2ChainlinkFeed sequencer = new MockV2ChainlinkFeed(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetRegistry.AssetRegistry__InvalidWindow.selector, bytes32("sequencerGracePeriod"), 0
            )
        );
        registry.setSequencerConfig(address(sequencer), 0);
    }

    function test_RevertWhen_OracleWindowsExceedHardBounds() public {
        PoolTypes.AssetConfigInput memory input = _input(address(quoteFeed), address(0));
        input.twapWindow = 5 minutes - 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetRegistry.AssetRegistry__InvalidWindow.selector, bytes32("twapWindow"), input.twapWindow
            )
        );
        registry.configureAsset(address(quote), input);

        input = _input(address(quoteFeed), address(0));
        input.maxChainlinkStale = 7 days + 1;
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetRegistry.AssetRegistry__InvalidWindow.selector,
                bytes32("maxChainlinkStale"),
                input.maxChainlinkStale
            )
        );
        registry.configureAsset(address(quote), input);
    }

    function test_RevertWhen_SequencerGraceIsOutsideHardBounds() public {
        MockV2ChainlinkFeed sequencer = new MockV2ChainlinkFeed(0);
        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetRegistry.AssetRegistry__InvalidWindow.selector, bytes32("sequencerGracePeriod"), 1 minutes - 1
            )
        );
        registry.setSequencerConfig(address(sequencer), 1 minutes - 1);

        vm.prank(TIMELOCK);
        vm.expectRevert(
            abi.encodeWithSelector(
                AssetRegistry.AssetRegistry__InvalidWindow.selector, bytes32("sequencerGracePeriod"), 1 days + 1
            )
        );
        registry.setSequencerConfig(address(sequencer), 1 days + 1);
    }

    function test_DisableIncrementsVersion() public {
        vm.startPrank(TIMELOCK);
        registry.configureAsset(address(quote), _input(address(quoteFeed), address(0)));
        registry.configureAsset(address(asset), _input(address(assetFeed), address(pool)));
        registry.disableAsset(address(asset));
        vm.stopPrank();

        assertFalse(registry.isAssetEnabled(address(asset)));
        assertEq(registry.assetConfigVersion(address(asset)), 2);
    }

    function test_GlobalBoundsVersionIncrements() public {
        PoolTypes.GlobalPoolBounds memory bounds = registry.getGlobalPoolBounds();
        assertEq(bounds.configVersion, 1);
        bounds.maxAssets = 8;
        vm.prank(TIMELOCK);
        registry.setGlobalPoolBounds(bounds);
        assertEq(registry.getGlobalPoolBounds().configVersion, 2);
    }

    function test_GuardianRotationIsTimelockOnly() public {
        address next = address(0xCAFE);
        vm.prank(TIMELOCK);
        registry.setGuardian(next);
        assertEq(registry.guardian(), next);
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
