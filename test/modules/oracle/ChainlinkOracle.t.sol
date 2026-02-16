// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracle} from "../../../src/modules/oracle/ChainlinkOracle.sol";
import {ProtocolAddressProvider} from "../../../src/core/ProtocolAddressProvider.sol";
import {IPriceOracle} from "../../../src/interfaces/modules/IPriceOracle.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {MockChainlinkAggregator} from "../../mocks/MockChainlinkAggregator.sol";
import {MockSequencerOracle} from "../../mocks/MockSequencerOracle.sol";
import {TestFixtures} from "../../fixtures/TestFixtures.sol";

/**
 * @title ChainlinkOracleTest
 * @notice Tests all functionality of the ChainlinkOracle contract
 */
contract ChainlinkOracleTest is TestFixtures {
    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    ChainlinkOracle public oracle;
    MockChainlinkAggregator public mockAggregator;
    MockChainlinkAggregator public mockAggregator18Decimals;
    MockSequencerOracle public mockSequencerOracle;

    address public asset1 = address(0x100);
    address public asset2 = address(0x200);
    address public asset3 = address(0x300);

    uint256 public constant MAX_STALE_TIME = 3600; // 1 hour
    uint256 public constant SEQUENCER_GRACE_PERIOD = 300; // 5 minutes

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        setUpFullEnvironment();

        // Deploy oracle
        oracle = new ChainlinkOracle(address(addressProvider), MAX_STALE_TIME);

        // Deploy mock aggregators
        mockAggregator = new MockChainlinkAggregator(8, "ETH/USD", 1);
        mockAggregator18Decimals = new MockChainlinkAggregator(18, "WBTC/USD", 1);

        // Deploy mock sequencer oracle
        mockSequencerOracle = new MockSequencerOracle();

        // Register oracle in address provider
        vm.prank(owner);
        addressProvider.setPriceOracle(address(oracle));
    }

    // -------------------------------------------------------------------------
    // Constructor Tests
    // -------------------------------------------------------------------------

    function test_Constructor_SetsAddressProvider() public {
        ChainlinkOracle newOracle = new ChainlinkOracle(address(addressProvider), MAX_STALE_TIME);
        assertEq(address(newOracle.ADDRESSES_PROVIDER()), address(addressProvider));
    }

    function test_Constructor_SetsMaxStaleTime() public {
        ChainlinkOracle newOracle = new ChainlinkOracle(address(addressProvider), MAX_STALE_TIME);
        assertEq(newOracle.maxStaleTime(), MAX_STALE_TIME);
    }

    function test_Constructor_RevertsIfAddressProviderIsZero() public {
        vm.expectRevert(Errors.AddressesProviderIsZero.selector);
        new ChainlinkOracle(address(0), MAX_STALE_TIME);
    }

    // -------------------------------------------------------------------------
    // setAssetSource Tests
    // -------------------------------------------------------------------------

    function test_SetAssetSource_Success() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        assertEq(oracle.getSourceOfAsset(asset1), address(mockAggregator));
    }

    function test_SetAssetSource_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IPriceOracle.AssetSourceUpdated(asset1, address(mockAggregator));

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));
    }

    function test_SetAssetSource_RevertsIfNotRiskAdmin() public {
        vm.expectRevert(Errors.CallerNotRiskAdmin.selector);
        oracle.setAssetSource(asset1, address(mockAggregator));
    }

    function test_SetAssetSource_CanSetToZero() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(0));

        assertEq(oracle.getSourceOfAsset(asset1), address(0));
    }

    // -------------------------------------------------------------------------
    // setAssetSources Tests
    // -------------------------------------------------------------------------

    function test_SetAssetSources_Success() public {
        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        address[] memory sources = new address[](2);
        sources[0] = address(mockAggregator);
        sources[1] = address(mockAggregator18Decimals);

        vm.prank(riskAdmin);
        oracle.setAssetSources(assets, sources);

        assertEq(oracle.getSourceOfAsset(asset1), address(mockAggregator));
        assertEq(oracle.getSourceOfAsset(asset2), address(mockAggregator18Decimals));
    }

    function test_SetAssetSources_EmitsEvents() public {
        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        address[] memory sources = new address[](2);
        sources[0] = address(mockAggregator);
        sources[1] = address(mockAggregator18Decimals);

        vm.expectEmit(true, true, false, false);
        emit IPriceOracle.AssetSourceUpdated(asset1, address(mockAggregator));

        vm.expectEmit(true, true, false, false);
        emit IPriceOracle.AssetSourceUpdated(asset2, address(mockAggregator18Decimals));

        vm.prank(riskAdmin);
        oracle.setAssetSources(assets, sources);
    }

    function test_SetAssetSources_RevertsIfArraysLengthMismatch() public {
        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        address[] memory sources = new address[](1);
        sources[0] = address(mockAggregator);

        vm.expectRevert(Errors.ArraysLengthMismatch.selector);
        vm.prank(riskAdmin);
        oracle.setAssetSources(assets, sources);
    }

    function test_SetAssetSources_RevertsIfNotRiskAdmin() public {
        address[] memory assets = new address[](1);
        assets[0] = asset1;

        address[] memory sources = new address[](1);
        sources[0] = address(mockAggregator);

        vm.expectRevert(Errors.CallerNotRiskAdmin.selector);
        oracle.setAssetSources(assets, sources);
    }

    // -------------------------------------------------------------------------
    // setMaxStaleTime Tests
    // -------------------------------------------------------------------------

    function test_SetMaxStaleTime_Success() public {
        uint256 newMaxStaleTime = 7200;

        vm.prank(riskAdmin);
        oracle.setMaxStaleTime(newMaxStaleTime);

        assertEq(oracle.maxStaleTime(), newMaxStaleTime);
    }

    function test_SetMaxStaleTime_EmitsEvent() public {
        uint256 newMaxStaleTime = 7200;

        vm.expectEmit(true, false, false, false);
        emit IPriceOracle.MaxStaleTimeSet(MAX_STALE_TIME, newMaxStaleTime);

        vm.prank(riskAdmin);
        oracle.setMaxStaleTime(newMaxStaleTime);
    }

    function test_SetMaxStaleTime_CanSetToZero() public {
        vm.prank(riskAdmin);
        oracle.setMaxStaleTime(0);

        assertEq(oracle.maxStaleTime(), 0);
    }

    function test_SetMaxStaleTime_RevertsIfNotRiskAdmin() public {
        vm.expectRevert(Errors.CallerNotRiskAdmin.selector);
        oracle.setMaxStaleTime(7200);
    }

    // -------------------------------------------------------------------------
    // setSequencerConfig Tests
    // -------------------------------------------------------------------------

    function test_SetSequencerConfig_Success() public {
        vm.prank(riskAdmin);
        oracle.setSequencerConfig(address(mockSequencerOracle), SEQUENCER_GRACE_PERIOD);

        assertEq(oracle.sequencerUptimeFeed(), address(mockSequencerOracle));
        assertEq(oracle.sequencerGracePeriod(), SEQUENCER_GRACE_PERIOD);
    }

    function test_SetSequencerConfig_EmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IPriceOracle.SequencerConfigSet(address(mockSequencerOracle), SEQUENCER_GRACE_PERIOD);

        vm.prank(riskAdmin);
        oracle.setSequencerConfig(address(mockSequencerOracle), SEQUENCER_GRACE_PERIOD);
    }

    function test_SetSequencerConfig_CanSetToZero() public {
        vm.prank(riskAdmin);
        oracle.setSequencerConfig(address(0), 0);

        assertEq(oracle.sequencerUptimeFeed(), address(0));
        assertEq(oracle.sequencerGracePeriod(), 0);
    }

    function test_SetSequencerConfig_RevertsIfNotRiskAdmin() public {
        vm.expectRevert(Errors.CallerNotRiskAdmin.selector);
        oracle.setSequencerConfig(address(mockSequencerOracle), SEQUENCER_GRACE_PERIOD);
    }

    // -------------------------------------------------------------------------
    // getPrice Tests - Basic Functionality
    // -------------------------------------------------------------------------

    function test_GetPrice_Success_8Decimals() public {
        // Setup
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        int256 price = 2000e8; // $2000 with 8 decimals
        mockAggregator.updateRoundData(price, block.timestamp);

        // Test
        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 2000e8);
    }

    function test_GetPrice_Success_18Decimals() public {
        // Setup
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator18Decimals));

        int256 price = 50000e18; // $50000 with 18 decimals
        mockAggregator18Decimals.updateRoundData(price, block.timestamp);

        // Test - should normalize to 8 decimals
        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 50000e8);
    }

    function test_GetPrice_Success_LessThan8Decimals() public {
        // Create aggregator with 6 decimals
        MockChainlinkAggregator aggregator6Decimals = new MockChainlinkAggregator(6, "USDC/USD", 1);

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(aggregator6Decimals));

        int256 price = 1e6; // $1 with 6 decimals
        aggregator6Decimals.updateRoundData(price, block.timestamp);

        // Test - should normalize to 8 decimals (multiply by 100)
        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 1e8);
    }

    function test_GetPrice_RevertsIfFeedNotSet() public {
        vm.expectRevert(Errors.FeedNotSet.selector);
        oracle.getPrice(asset1);
    }

    function test_GetPrice_RevertsIfAnswerIsZero() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        mockAggregator.updateRoundData(0, block.timestamp);

        vm.expectRevert(Errors.InvalidAnswer.selector);
        oracle.getPrice(asset1);
    }

    function test_GetPrice_RevertsIfAnswerIsNegative() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        mockAggregator.updateRoundData(-100e8, block.timestamp);

        vm.expectRevert(Errors.InvalidAnswer.selector);
        oracle.getPrice(asset1);
    }

    function test_GetPrice_RevertsIfStaleRound() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        mockAggregator.updateRoundDataStale(2000e8, block.timestamp);

        vm.expectRevert(Errors.StaleRound.selector);
        oracle.getPrice(asset1);
    }

    function test_GetPrice_RevertsIfPriceStale() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        // Set price with a fixed past timestamp
        uint256 staleTimestamp = 1000; // Fixed past time
        mockAggregator.updateRoundData(2000e8, staleTimestamp);

        // Advance time to make the price stale
        vm.warp(staleTimestamp + MAX_STALE_TIME + 1);

        vm.expectRevert(Errors.PriceStale.selector);
        oracle.getPrice(asset1);
    }

    function test_GetPrice_Success_WhenMaxStaleTimeIsZero() public {
        // Deploy oracle with maxStaleTime = 0
        ChainlinkOracle oracleNoStaleCheck = new ChainlinkOracle(address(addressProvider), 0);

        vm.prank(riskAdmin);
        oracleNoStaleCheck.setAssetSource(asset1, address(mockAggregator));

        // Set price with current timestamp (not old, since we're not checking staleness)
        mockAggregator.updateRoundData(2000e8, block.timestamp);

        // Should succeed when maxStaleTime is 0
        uint256 result = oracleNoStaleCheck.getPrice(asset1);
        assertEq(result, 2000e8);
    }

    // -------------------------------------------------------------------------
    // getPrice Tests - Sequencer Checks
    // -------------------------------------------------------------------------

    function test_GetPrice_RevertsIfSequencerDown() public {
        // Setup sequencer
        vm.prank(riskAdmin);
        oracle.setSequencerConfig(address(mockSequencerOracle), SEQUENCER_GRACE_PERIOD);

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        // Set sequencer down
        mockSequencerOracle.setSequencerDown(block.timestamp);
        mockAggregator.updateRoundData(2000e8, block.timestamp);

        vm.expectRevert(Errors.SequencerDown.selector);
        oracle.getPrice(asset1);
    }

    function test_GetPrice_Success_WhenSequencerUp() public {
        // Setup sequencer
        vm.prank(riskAdmin);
        oracle.setSequencerConfig(address(mockSequencerOracle), SEQUENCER_GRACE_PERIOD);

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        // Set sequencer up with timestamp in the past (grace period has passed)
        // Use a fixed past time to avoid underflow
        uint256 sequencerUpTime = 1000; // Fixed past time
        mockSequencerOracle.setSequencerUp(sequencerUpTime);
        
        // Advance time to ensure grace period has passed
        vm.warp(sequencerUpTime + SEQUENCER_GRACE_PERIOD + 1);
        mockAggregator.updateRoundData(2000e8, block.timestamp);

        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 2000e8);
    }

    function test_GetPrice_RevertsIfGracePeriodNotOver() public {
        // Setup sequencer
        vm.prank(riskAdmin);
        oracle.setSequencerConfig(address(mockSequencerOracle), SEQUENCER_GRACE_PERIOD);

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        // Sequencer just came back up (within grace period)
        // Set sequencer up time to a fixed past time
        uint256 sequencerUpTime = 1000; // Fixed past time
        mockSequencerOracle.setSequencerUp(sequencerUpTime);
        
        // Advance time but stay within grace period
        vm.warp(sequencerUpTime + SEQUENCER_GRACE_PERIOD - 1);
        mockAggregator.updateRoundData(2000e8, block.timestamp);

        vm.expectRevert(Errors.GracePeriodNotOver.selector);
        oracle.getPrice(asset1);
    }

    function test_GetPrice_Success_WhenGracePeriodIsZero() public {
        // Setup sequencer with grace period = 0
        vm.prank(riskAdmin);
        oracle.setSequencerConfig(address(mockSequencerOracle), 0);

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        // Sequencer just came back up
        mockSequencerOracle.setSequencerUp(block.timestamp);
        mockAggregator.updateRoundData(2000e8, block.timestamp);

        // Should succeed when grace period is 0
        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 2000e8);
    }

    function test_GetPrice_Success_WhenSequencerNotConfigured() public {
        // Don't configure sequencer
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        mockAggregator.updateRoundData(2000e8, block.timestamp);

        // Should succeed without sequencer checks
        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 2000e8);
    }

    // -------------------------------------------------------------------------
    // getPrices Tests
    // -------------------------------------------------------------------------

    function test_GetPrices_Success() public {
        // Setup
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset2, address(mockAggregator18Decimals));

        mockAggregator.updateRoundData(2000e8, block.timestamp);
        mockAggregator18Decimals.updateRoundData(50000e18, block.timestamp);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        uint256[] memory prices = oracle.getPrices(assets);

        assertEq(prices.length, 2);
        assertEq(prices[0], 2000e8);
        assertEq(prices[1], 50000e8);
    }

    function test_GetPrices_RevertsIfAnyFeedNotSet() public {
        // Set feed for asset1 but not asset2
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));
        // asset2 not set

        // Set valid price for asset1
        mockAggregator.updateRoundData(2000e8, block.timestamp);

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        // Should revert when checking asset2 (which has no feed)
        vm.expectRevert(Errors.FeedNotSet.selector);
        oracle.getPrices(assets);
    }

    function test_GetPrices_RevertsIfAnyPriceInvalid() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset2, address(mockAggregator));

        mockAggregator.updateRoundData(2000e8, block.timestamp);
        mockAggregator.updateRoundData(0, block.timestamp); // Invalid price

        address[] memory assets = new address[](2);
        assets[0] = asset1;
        assets[1] = asset2;

        vm.expectRevert(Errors.InvalidAnswer.selector);
        oracle.getPrices(assets);
    }

    // -------------------------------------------------------------------------
    // isPriceValid Tests
    // -------------------------------------------------------------------------

    function test_IsPriceValid_ReturnsTrue_WhenValid() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        mockAggregator.updateRoundData(2000e8, block.timestamp);

        assertTrue(oracle.isPriceValid(asset1));
    }

    function test_IsPriceValid_ReturnsFalse_WhenFeedNotSet() public {
        assertFalse(oracle.isPriceValid(asset1));
    }

    function test_IsPriceValid_ReturnsFalse_WhenPriceInvalid() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        mockAggregator.updateRoundData(0, block.timestamp);

        assertFalse(oracle.isPriceValid(asset1));
    }

    function test_IsPriceValid_ReturnsFalse_WhenPriceStale() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        // Set price with a fixed past timestamp
        uint256 staleTimestamp = 1000; // Fixed past time
        mockAggregator.updateRoundData(2000e8, staleTimestamp);

        // Advance time to make the price stale
        vm.warp(staleTimestamp + MAX_STALE_TIME + 1);

        assertFalse(oracle.isPriceValid(asset1));
    }

    function test_IsPriceValid_ReturnsFalse_WhenSequencerDown() public {
        vm.prank(riskAdmin);
        oracle.setSequencerConfig(address(mockSequencerOracle), SEQUENCER_GRACE_PERIOD);
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        mockSequencerOracle.setSequencerDown(block.timestamp);
        mockAggregator.updateRoundData(2000e8, block.timestamp);

        assertFalse(oracle.isPriceValid(asset1));
    }

    // -------------------------------------------------------------------------
    // getSourceOfAsset Tests
    // -------------------------------------------------------------------------

    function test_GetSourceOfAsset_ReturnsSource() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        assertEq(oracle.getSourceOfAsset(asset1), address(mockAggregator));
    }

    function test_GetSourceOfAsset_ReturnsZero_WhenNotSet() public {
        assertEq(oracle.getSourceOfAsset(asset1), address(0));
    }

    // -------------------------------------------------------------------------
    // Edge Cases
    // -------------------------------------------------------------------------

    function test_GetPrice_HandlesLargePrices() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        int256 largePrice = int256(uint256(type(uint128).max));
        mockAggregator.updateRoundData(largePrice, block.timestamp);

        uint256 result = oracle.getPrice(asset1);
        assertEq(result, uint256(largePrice));
    }

    function test_GetPrice_HandlesSmallPrices() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator));

        int256 smallPrice = 1; // $0.00000001
        mockAggregator.updateRoundData(smallPrice, block.timestamp);

        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 1);
    }

    function test_GetPrice_Normalization_From18To8Decimals() public {
        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(mockAggregator18Decimals));

        // 1e18 with 18 decimals = 1e8 with 8 decimals
        mockAggregator18Decimals.updateRoundData(1e18, block.timestamp);

        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 1e8);
    }

    function test_GetPrice_Normalization_From6To8Decimals() public {
        MockChainlinkAggregator aggregator6Decimals = new MockChainlinkAggregator(6, "USDC/USD", 1);

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(aggregator6Decimals));

        // 1e6 with 6 decimals = 1e8 with 8 decimals (multiply by 100)
        aggregator6Decimals.updateRoundData(1e6, block.timestamp);

        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 1e8);
    }

    function test_GetPrice_Normalization_From10To8Decimals() public {
        MockChainlinkAggregator aggregator10Decimals = new MockChainlinkAggregator(10, "TOKEN/USD", 1);

        vm.prank(riskAdmin);
        oracle.setAssetSource(asset1, address(aggregator10Decimals));

        // 1e10 with 10 decimals = 1e8 with 8 decimals (divide by 100)
        aggregator10Decimals.updateRoundData(1e10, block.timestamp);

        uint256 result = oracle.getPrice(asset1);
        assertEq(result, 1e8);
    }
}

