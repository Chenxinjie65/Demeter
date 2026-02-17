// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AssetWhitelist} from "../../../src/modules/governance/AssetWhitelist.sol";
import {ProtocolAddressProvider} from "../../../src/core/ProtocolAddressProvider.sol";
import {IProtocolAddressProvider} from "../../../src/interfaces/core/IProtocolAddressProvider.sol";
import {IAssetWhitelist} from "../../../src/interfaces/modules/IAssetWhitelist.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {TestFixtures} from "../../fixtures/TestFixtures.sol";

/**
 * @title AssetWhitelistTest
 * @notice Tests all functionality of the AssetWhitelist contract
 */
contract AssetWhitelistTest is TestFixtures {
    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        setUpFullEnvironment();
        setUpAssetWhitelist();
    }

    // -------------------------------------------------------------------------
    // Constructor Tests
    // -------------------------------------------------------------------------

    function test_Constructor_SetsAddressProvider() public {
        AssetWhitelist whitelist = new AssetWhitelist(address(addressProvider));
        assertEq(address(whitelist.ADDRESSES_PROVIDER()), address(addressProvider));
    }

    function test_Constructor_RevertsIfAddressProviderIsZero() public {
        vm.expectRevert(Errors.AddressesProviderIsZero.selector);
        new AssetWhitelist(address(0));
    }

    // -------------------------------------------------------------------------
    // View Function Tests
    // -------------------------------------------------------------------------

    function test_IsWhitelisted_ReturnsFalseForUnlistedAsset() public {
        address asset = makeAsset("USDC");
        assertFalse(assetWhitelist.isWhitelisted(asset));
    }

    function test_GetWhitelistCount_ReturnsZeroInitially() public {
        assertEq(assetWhitelist.getWhitelistCount(), 0);
    }

    // -------------------------------------------------------------------------
    // Add Asset Tests
    // -------------------------------------------------------------------------

    function test_AddAsset_Success() public {
        address asset = makeAsset("USDC");
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);

        assertTrue(assetWhitelist.isWhitelisted(asset));
        assertEq(assetWhitelist.getWhitelistCount(), 1);
    }

    function test_AddAsset_EmitsEvent() public {
        address asset = makeAsset("USDC");
        
        vm.expectEmit(true, false, false, false);
        emit IAssetWhitelist.AssetAdded(asset);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);
    }

    function test_AddAsset_RevertsIfNotRiskAdmin() public {
        address asset = makeAsset("USDC");
        
        vm.expectRevert(Errors.CallerNotRiskAdmin.selector);
        assetWhitelist.addAsset(asset);
    }

    function test_AddAsset_RevertsIfAssetIsZero() public {
        vm.expectRevert(Errors.AssetIsZero.selector);
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(address(0));
    }

    function test_AddAsset_RevertsIfAlreadyWhitelisted() public {
        address asset = makeAsset("USDC");
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);

        vm.expectRevert(Errors.AssetAlreadyWhitelisted.selector);
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);
    }

    // -------------------------------------------------------------------------
    // Remove Asset Tests
    // -------------------------------------------------------------------------

    function test_RemoveAsset_Success() public {
        address asset = makeAsset("USDC");
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);
        
        vm.prank(riskAdmin);
        assetWhitelist.removeAsset(asset);

        assertFalse(assetWhitelist.isWhitelisted(asset));
        assertEq(assetWhitelist.getWhitelistCount(), 0);
    }

    function test_RemoveAsset_EmitsEvent() public {
        address asset = makeAsset("USDC");
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);
        
        vm.expectEmit(true, false, false, false);
        emit IAssetWhitelist.AssetRemoved(asset);
        
        vm.prank(riskAdmin);
        assetWhitelist.removeAsset(asset);
    }

    function test_RemoveAsset_RevertsIfNotRiskAdmin() public {
        address asset = makeAsset("USDC");
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);
        
        vm.expectRevert(Errors.CallerNotRiskAdmin.selector);
        assetWhitelist.removeAsset(asset);
    }

    function test_RemoveAsset_RevertsIfNotWhitelisted() public {
        address asset = makeAsset("USDC");
        
        vm.expectRevert(Errors.AssetNotWhitelisted.selector);
        vm.prank(riskAdmin);
        assetWhitelist.removeAsset(asset);
    }

    // -------------------------------------------------------------------------
    // Batch Add Assets Tests
    // -------------------------------------------------------------------------

    function test_AddAssets_Success() public {
        address[] memory assets = makeAssets(3);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAssets(assets);

        for (uint256 i = 0; i < assets.length; i++) {
            assertTrue(assetWhitelist.isWhitelisted(assets[i]));
        }
        assertEq(assetWhitelist.getWhitelistCount(), 3);
    }

    function test_AddAssets_EmitsEvents() public {
        address[] memory assets = makeAssets(2);
        
        vm.expectEmit(true, false, false, false);
        emit IAssetWhitelist.AssetAdded(assets[0]);
        
        vm.expectEmit(true, false, false, false);
        emit IAssetWhitelist.AssetAdded(assets[1]);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAssets(assets);
    }

    function test_AddAssets_RevertsIfNotRiskAdmin() public {
        address[] memory assets = makeAssets(2);
        
        vm.expectRevert(Errors.CallerNotRiskAdmin.selector);
        assetWhitelist.addAssets(assets);
    }

    function test_AddAssets_RevertsIfAnyAssetIsZero() public {
        address[] memory assets = new address[](2);
        assets[0] = makeAsset("USDC");
        assets[1] = address(0);
        
        vm.expectRevert(Errors.AssetIsZero.selector);
        vm.prank(riskAdmin);
        assetWhitelist.addAssets(assets);
    }

    function test_AddAssets_RevertsIfAnyAssetAlreadyWhitelisted() public {
        address[] memory assets = makeAssets(2);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(assets[0]);
        
        vm.expectRevert(Errors.AssetAlreadyWhitelisted.selector);
        vm.prank(riskAdmin);
        assetWhitelist.addAssets(assets);
    }

    // -------------------------------------------------------------------------
    // Batch Remove Assets Tests
    // -------------------------------------------------------------------------

    function test_RemoveAssets_Success() public {
        address[] memory assets = makeAssets(3);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAssets(assets);
        
        vm.prank(riskAdmin);
        assetWhitelist.removeAssets(assets);

        for (uint256 i = 0; i < assets.length; i++) {
            assertFalse(assetWhitelist.isWhitelisted(assets[i]));
        }
        assertEq(assetWhitelist.getWhitelistCount(), 0);
    }

    function test_RemoveAssets_EmitsEvents() public {
        address[] memory assets = makeAssets(2);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAssets(assets);
        
        vm.expectEmit(true, false, false, false);
        emit IAssetWhitelist.AssetRemoved(assets[0]);
        
        vm.expectEmit(true, false, false, false);
        emit IAssetWhitelist.AssetRemoved(assets[1]);
        
        vm.prank(riskAdmin);
        assetWhitelist.removeAssets(assets);
    }

    function test_RemoveAssets_RevertsIfNotRiskAdmin() public {
        address[] memory assets = makeAssets(2);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAssets(assets);
        
        vm.expectRevert(Errors.CallerNotRiskAdmin.selector);
        assetWhitelist.removeAssets(assets);
    }

    function test_RemoveAssets_RevertsIfAnyAssetNotWhitelisted() public {
        address[] memory assets = makeAssets(2);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(assets[0]);
        
        vm.expectRevert(Errors.AssetNotWhitelisted.selector);
        vm.prank(riskAdmin);
        assetWhitelist.removeAssets(assets);
    }

    // -------------------------------------------------------------------------
    // Edge Cases
    // -------------------------------------------------------------------------

    function test_AddRemoveAdd_Success() public {
        address asset = makeAsset("USDC");
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);
        
        vm.prank(riskAdmin);
        assetWhitelist.removeAsset(asset);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAsset(asset);
        
        assertTrue(assetWhitelist.isWhitelisted(asset));
        assertEq(assetWhitelist.getWhitelistCount(), 1);
    }

    function test_MultipleAssets_CountIsCorrect() public {
        address[] memory assets = makeAssets(10);
        
        vm.prank(riskAdmin);
        assetWhitelist.addAssets(assets);
        
        assertEq(assetWhitelist.getWhitelistCount(), 10);
        
        // Remove half of the assets
        address[] memory toRemove = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            toRemove[i] = assets[i];
        }
        
        vm.prank(riskAdmin);
        assetWhitelist.removeAssets(toRemove);
        
        assertEq(assetWhitelist.getWhitelistCount(), 5);
    }
}

