// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAddressProvider} from "../../src/core/ProtocolAddressProvider.sol";
import {AssetWhitelist} from "../../src/modules/governance/AssetWhitelist.sol";
import {IProtocolAddressProvider} from "../../src/interfaces/core/IProtocolAddressProvider.sol";

/**
 * @title TestFixtures
 * @notice Test helper contract providing common test setup and utility functions
 */
contract TestFixtures is Test {
    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    ProtocolAddressProvider public addressProvider;
    AssetWhitelist public assetWhitelist;

    address public owner = address(0x1);
    address public riskAdmin = address(0x2);
    address public guardian = address(0x3);
    address public treasury = address(0x4);

    // -------------------------------------------------------------------------
    // Setup Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Sets up a basic ProtocolAddressProvider
     */
    function setUpAddressProvider() public {
        vm.prank(owner);
        addressProvider = new ProtocolAddressProvider(owner);
    }

    /**
     * @notice Sets up a complete test environment (including all roles)
     */
    function setUpFullEnvironment() public {
        setUpAddressProvider();
        
        vm.startPrank(owner);
        addressProvider.setRiskAdmin(riskAdmin);
        addressProvider.setGuardian(guardian);
        addressProvider.setTreasury(treasury);
        vm.stopPrank();
    }

    /**
     * @notice Sets up AssetWhitelist and registers it with AddressProvider
     */
    function setUpAssetWhitelist() public {
        if (address(addressProvider) == address(0)) {
            setUpFullEnvironment();
        }

        assetWhitelist = new AssetWhitelist(address(addressProvider));
        
        vm.prank(owner);
        addressProvider.setAssetWhitelist(address(assetWhitelist));
    }

    // -------------------------------------------------------------------------
    // Helper Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Creates a random asset address from a name
     */
    function makeAsset(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }

    /**
     * @notice Creates multiple asset addresses
     */
    function makeAssets(uint256 count) public pure returns (address[] memory) {
        address[] memory assets = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            assets[i] = address(uint160(uint256(keccak256(abi.encodePacked("asset", i)))));
        }
        return assets;
    }
}

