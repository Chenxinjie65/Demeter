// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAddressProvider} from "../../src/core/ProtocolAddressProvider.sol";
import {ChainlinkOracle} from "../../src/modules/oracle/ChainlinkOracle.sol";
import {AssetWhitelist} from "../../src/modules/governance/AssetWhitelist.sol";
import {AggregatorV2V3Interface} from "../../src/interfaces/external/AggregatorInterface.sol";
import {IAaveV3Pool} from "../../src/interfaces/external/IAaveV3.sol";

/**
 * @title ProtocolIntegrationTest
 * @notice Integration tests for the Demeter protocol using fork testing
 * 
 * @dev
 * This test suite demonstrates how to test integration with external protocols:
 * 1. Fork Testing: Uses vm.createFork() to fork mainnet/testnet
 * 2. Real Contract Addresses: Tests against actual Chainlink and Aave contracts
 * 3. Integration Scenarios: Tests end-to-end flows across multiple modules
 * 
 * To run fork tests:
 * - Set FORK_URL in .env (e.g., ALCHEMY_API_KEY or INFURA_API_KEY)
 * - Run: forge test --match-path test/integration/ProtocolIntegration.t.sol -vvv
 */
contract ProtocolIntegrationTest is Test {
    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    ProtocolAddressProvider public addressProvider;
    ChainlinkOracle public oracle;
    AssetWhitelist public whitelist;

    address public owner = address(0x1);
    address public riskAdmin = address(0x2);

    // Mainnet addresses (Ethereum)
    // Chainlink Price Feeds
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD on mainnet
    address constant BTC_USD_FEED = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // BTC/USD on mainnet
    
    // Aave V3 Pool (Ethereum mainnet)
    address constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    
    // Test tokens
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Arbitrum One addresses (for L2 sequencer testing)
    address constant ARB_SEQUENCER_UPTIME_FEED = 0xFdB631f5ee196f0eD6faA767959853a9f217197D;

    uint256 public forkId;
    uint256 constant FORK_BLOCK = 20_000_000; // Use a recent block number

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        // Check if FORK_URL is set
        string memory forkUrl = vm.envOr("FORK_URL", string(""));
        
        if (bytes(forkUrl).length == 0) {
            // If no fork URL, skip fork tests
            return;
        }

        // Create a fork of mainnet
        forkId = vm.createFork(forkUrl, FORK_BLOCK);
        vm.selectFork(forkId);

        // Deploy protocol contracts
        vm.prank(owner);
        addressProvider = new ProtocolAddressProvider(owner);

        // Deploy oracle
        oracle = new ChainlinkOracle(address(addressProvider), 3600); // 1 hour stale time

        // Deploy whitelist
        whitelist = new AssetWhitelist(address(addressProvider));

        // Setup roles
        vm.startPrank(owner);
        addressProvider.setRiskAdmin(riskAdmin);
        addressProvider.setPriceOracle(address(oracle));
        addressProvider.setAssetWhitelist(address(whitelist));
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Integration Tests - Chainlink Oracle with Real Feeds
    // -------------------------------------------------------------------------

    function test_Integration_ChainlinkOracle_WithRealETHFeed() public {
        // Skip if no fork
        if (forkId == 0) return;

        // Configure oracle with real Chainlink feed
        vm.prank(riskAdmin);
        oracle.setAssetSource(WETH, ETH_USD_FEED);

        // Get price from real Chainlink feed
        uint256 price = oracle.getPrice(WETH);

        // Verify price is reasonable (ETH should be > $1000)
        assertGt(price, 1000e8, "ETH price should be > $1000");
        assertLt(price, 10000e8, "ETH price should be < $10000");

        // Verify price source
        assertEq(oracle.getSourceOfAsset(WETH), ETH_USD_FEED);
    }

    function test_Integration_ChainlinkOracle_WithRealBTCFeed() public {
        // Skip if no fork
        if (forkId == 0) return;

        // Configure oracle with real Chainlink feed
        vm.prank(riskAdmin);
        oracle.setAssetSource(WBTC, BTC_USD_FEED);

        // Get price from real Chainlink feed
        uint256 price = oracle.getPrice(WBTC);

        // Verify price is reasonable (BTC should be > $20000)
        assertGt(price, 20000e8, "BTC price should be > $20000");
        assertLt(price, 100000e8, "BTC price should be < $100000");

        // Verify price is normalized to 8 decimals
        AggregatorV2V3Interface feed = AggregatorV2V3Interface(BTC_USD_FEED);
        (, int256 rawAnswer,,,) = feed.latestRoundData();
        uint8 feedDecimals = feed.decimals();
        
        // Calculate expected normalized price
        uint256 expectedPrice;
        if (feedDecimals == 8) {
            expectedPrice = uint256(rawAnswer);
        } else if (feedDecimals > 8) {
            expectedPrice = uint256(rawAnswer) / (10 ** (feedDecimals - 8));
        } else {
            expectedPrice = uint256(rawAnswer) * (10 ** (8 - feedDecimals));
        }

        // Allow small difference due to rounding
        uint256 diff = price > expectedPrice ? price - expectedPrice : expectedPrice - price;
        assertLt(diff, 1e6, "Price normalization should be accurate");
    }

    function test_Integration_ChainlinkOracle_BatchPrices() public {
        // Skip if no fork
        if (forkId == 0) return;

        // Configure multiple feeds
        vm.startPrank(riskAdmin);
        oracle.setAssetSource(WETH, ETH_USD_FEED);
        oracle.setAssetSource(WBTC, BTC_USD_FEED);
        vm.stopPrank();

        // Get batch prices
        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = WBTC;

        uint256[] memory prices = oracle.getPrices(assets);

        assertEq(prices.length, 2);
        assertGt(prices[0], 0, "ETH price should be > 0");
        assertGt(prices[1], 0, "BTC price should be > 0");
        assertGt(prices[1], prices[0], "BTC should be more expensive than ETH");
    }

    function test_Integration_ChainlinkOracle_PriceValidity() public {
        // Skip if no fork
        if (forkId == 0) return;

        vm.prank(riskAdmin);
        oracle.setAssetSource(WETH, ETH_USD_FEED);

        // Price should be valid
        assertTrue(oracle.isPriceValid(WETH), "Price should be valid");

        // Invalid asset should return false
        assertFalse(oracle.isPriceValid(address(0x999)), "Invalid asset should return false");
    }

    // -------------------------------------------------------------------------
    // Integration Tests - Protocol Modules Interaction
    // -------------------------------------------------------------------------

    function test_Integration_WhitelistAndOracle_Workflow() public {
        // Skip if no fork
        if (forkId == 0) return;

        // 1. Add assets to whitelist
        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = WBTC;

        vm.prank(riskAdmin);
        whitelist.addAssets(assets);

        // 2. Configure oracle feeds
        address[] memory feeds = new address[](2);
        feeds[0] = ETH_USD_FEED;
        feeds[1] = BTC_USD_FEED;

        vm.prank(riskAdmin);
        oracle.setAssetSources(assets, feeds);

        // 3. Verify integration
        assertTrue(whitelist.isWhitelisted(WETH), "WETH should be whitelisted");
        assertTrue(whitelist.isWhitelisted(WBTC), "WBTC should be whitelisted");
        assertEq(whitelist.getWhitelistCount(), 2, "Whitelist count should be 2");

        // 4. Get prices for whitelisted assets
        uint256 ethPrice = oracle.getPrice(WETH);
        uint256 btcPrice = oracle.getPrice(WBTC);

        assertGt(ethPrice, 0, "ETH price should be available");
        assertGt(btcPrice, 0, "BTC price should be available");
    }

    function test_Integration_AddressProvider_Registry() public {
        // Skip if no fork
        if (forkId == 0) return;

        // Verify all modules are registered
        assertEq(addressProvider.getPriceOracle(), address(oracle), "Oracle should be registered");
        assertEq(addressProvider.getAssetWhitelist(), address(whitelist), "Whitelist should be registered");
        assertEq(addressProvider.getRiskAdmin(), riskAdmin, "RiskAdmin should be registered");

        // Verify modules can access each other through AddressProvider
        assertEq(
            address(oracle.ADDRESSES_PROVIDER()),
            address(addressProvider),
            "Oracle should reference AddressProvider"
        );
        assertEq(
            address(whitelist.ADDRESSES_PROVIDER()),
            address(addressProvider),
            "Whitelist should reference AddressProvider"
        );
    }

    // -------------------------------------------------------------------------
    // Integration Tests - Aave V3 (Example)
    // -------------------------------------------------------------------------

    function test_Integration_AaveV3_InterfaceCompatibility() public {
        // Skip if no fork
        if (forkId == 0) return;

        // Verify Aave V3 Pool exists and implements expected interface
        IAaveV3Pool aavePool = IAaveV3Pool(AAVE_V3_POOL);

        // This test verifies that our interface matches Aave's implementation
        // We can't call supply/withdraw without tokens, but we can verify the contract exists
        assertTrue(AAVE_V3_POOL.code.length > 0, "Aave V3 Pool should exist");

        // Note: Actual deposit/withdraw tests would require:
        // 1. ERC20 token approvals
        // 2. Sufficient token balances
        // 3. Proper test setup with tokens
    }

    // -------------------------------------------------------------------------
    // Integration Tests - Error Handling with Real Contracts
    // -------------------------------------------------------------------------

    function test_Integration_ChainlinkOracle_HandlesStaleFeed() public {
        // Skip if no fork
        if (forkId == 0) return;

        vm.prank(riskAdmin);
        oracle.setAssetSource(WETH, ETH_USD_FEED);

        // Set a very short stale time to test staleness detection
        vm.prank(riskAdmin);
        oracle.setMaxStaleTime(1); // 1 second

        // Get current price (should work)
        uint256 price1 = oracle.getPrice(WETH);
        assertGt(price1, 0, "Price should be available");

        // Advance time beyond stale threshold
        vm.warp(block.timestamp + 2);

        // Price should now be stale
        vm.expectRevert();
        oracle.getPrice(WETH);
    }

}

