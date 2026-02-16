// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ProtocolAddressProvider} from "../../src/core/ProtocolAddressProvider.sol";
import {IProtocolAddressProvider} from "../../src/interfaces/core/IProtocolAddressProvider.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/**
 * @title ProtocolAddressProviderTest
 * @notice Tests all functionality of the ProtocolAddressProvider contract
 */
contract ProtocolAddressProviderTest is Test {
    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    ProtocolAddressProvider public addressProvider;
    
    address public owner = address(0x1);
    address public newOwner = address(0x2);
    address public nonOwner = address(0x3);
    
    address public oracle = address(0x10);
    address public whitelist = address(0x20);
    address public factory = address(0x30);
    address public vaultBeacon = address(0x40);
    address public guardian = address(0x50);
    address public riskAdmin = address(0x60);
    address public treasury = address(0x70);

    // -------------------------------------------------------------------------
    // Setup
    // -------------------------------------------------------------------------

    function setUp() public {
        vm.prank(owner);
        addressProvider = new ProtocolAddressProvider(owner);
    }

    // -------------------------------------------------------------------------
    // Constructor Tests
    // -------------------------------------------------------------------------

    function test_Constructor_SetsOwner() public {
        assertEq(addressProvider.owner(), owner);
    }

    function test_Constructor_SetsAddressProviderToSelf() public {
        // Constructor should automatically set KEY_ADDRESS_PROVIDER to the contract itself
        // Note: Since _addresses is private, we verify through events
        // or other indirect means
        vm.expectEmit(true, false, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.KEY_ADDRESS_PROVIDER(),
            address(0),
            address(addressProvider)
        );
        
        vm.prank(owner);
        new ProtocolAddressProvider(owner);
    }

    function test_Constructor_RevertsIfOwnerIsZero() public {
        // OpenZeppelin's Ownable uses OwnableInvalidOwner error
        vm.expectRevert();
        new ProtocolAddressProvider(address(0));
    }

    // -------------------------------------------------------------------------
    // View Function Tests - Initial Values
    // -------------------------------------------------------------------------

    function test_GetPriceOracle_ReturnsZeroInitially() public {
        assertEq(addressProvider.getPriceOracle(), address(0));
    }

    function test_GetAssetWhitelist_ReturnsZeroInitially() public {
        assertEq(addressProvider.getAssetWhitelist(), address(0));
    }

    function test_GetFactory_ReturnsZeroInitially() public {
        assertEq(addressProvider.getFactory(), address(0));
    }

    function test_GetVaultBeacon_ReturnsZeroInitially() public {
        assertEq(addressProvider.getVaultBeacon(), address(0));
    }

    function test_GetGuardian_ReturnsZeroInitially() public {
        assertEq(addressProvider.getGuardian(), address(0));
    }

    function test_GetRiskAdmin_ReturnsZeroInitially() public {
        assertEq(addressProvider.getRiskAdmin(), address(0));
    }

    function test_GetTreasury_ReturnsZeroInitially() public {
        assertEq(addressProvider.getTreasury(), address(0));
    }

    // -------------------------------------------------------------------------
    // setPriceOracle Tests
    // -------------------------------------------------------------------------

    function test_SetPriceOracle_Success() public {
        vm.prank(owner);
        addressProvider.setPriceOracle(oracle);
        
        assertEq(addressProvider.getPriceOracle(), oracle);
    }

    function test_SetPriceOracle_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.KEY_ORACLE(),
            address(0),
            oracle
        );
        
        vm.prank(owner);
        addressProvider.setPriceOracle(oracle);
    }

    function test_SetPriceOracle_UpdatesExistingAddress() public {
        address newOracle = address(0x11);
        
        vm.prank(owner);
        addressProvider.setPriceOracle(oracle);
        
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.KEY_ORACLE(),
            oracle,
            newOracle
        );
        
        vm.prank(owner);
        addressProvider.setPriceOracle(newOracle);
        
        assertEq(addressProvider.getPriceOracle(), newOracle);
    }

    function test_SetPriceOracle_RevertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(nonOwner);
        addressProvider.setPriceOracle(oracle);
    }

    function test_SetPriceOracle_RevertsIfZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, addressProvider.KEY_ORACLE()));
        vm.prank(owner);
        addressProvider.setPriceOracle(address(0));
    }

    // -------------------------------------------------------------------------
    // setAssetWhitelist Tests
    // -------------------------------------------------------------------------

    function test_SetAssetWhitelist_Success() public {
        vm.prank(owner);
        addressProvider.setAssetWhitelist(whitelist);
        
        assertEq(addressProvider.getAssetWhitelist(), whitelist);
    }

    function test_SetAssetWhitelist_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.KEY_WHITELIST(),
            address(0),
            whitelist
        );
        
        vm.prank(owner);
        addressProvider.setAssetWhitelist(whitelist);
    }

    function test_SetAssetWhitelist_RevertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(nonOwner);
        addressProvider.setAssetWhitelist(whitelist);
    }

    function test_SetAssetWhitelist_RevertsIfZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, addressProvider.KEY_WHITELIST()));
        vm.prank(owner);
        addressProvider.setAssetWhitelist(address(0));
    }

    // -------------------------------------------------------------------------
    // setFactory Tests
    // -------------------------------------------------------------------------

    function test_SetFactory_Success() public {
        vm.prank(owner);
        addressProvider.setFactory(factory);
        
        assertEq(addressProvider.getFactory(), factory);
    }

    function test_SetFactory_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.KEY_FACTORY(),
            address(0),
            factory
        );
        
        vm.prank(owner);
        addressProvider.setFactory(factory);
    }

    function test_SetFactory_RevertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(nonOwner);
        addressProvider.setFactory(factory);
    }

    function test_SetFactory_RevertsIfZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, addressProvider.KEY_FACTORY()));
        vm.prank(owner);
        addressProvider.setFactory(address(0));
    }

    // -------------------------------------------------------------------------
    // setVaultBeacon Tests
    // -------------------------------------------------------------------------

    function test_SetVaultBeacon_Success() public {
        vm.prank(owner);
        addressProvider.setVaultBeacon(vaultBeacon);
        
        assertEq(addressProvider.getVaultBeacon(), vaultBeacon);
    }

    function test_SetVaultBeacon_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.KEY_VAULT_BEACON(),
            address(0),
            vaultBeacon
        );
        
        vm.prank(owner);
        addressProvider.setVaultBeacon(vaultBeacon);
    }

    function test_SetVaultBeacon_RevertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(nonOwner);
        addressProvider.setVaultBeacon(vaultBeacon);
    }

    function test_SetVaultBeacon_RevertsIfZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, addressProvider.KEY_VAULT_BEACON()));
        vm.prank(owner);
        addressProvider.setVaultBeacon(address(0));
    }

    // -------------------------------------------------------------------------
    // setGuardian Tests
    // -------------------------------------------------------------------------

    function test_SetGuardian_Success() public {
        vm.prank(owner);
        addressProvider.setGuardian(guardian);
        
        assertEq(addressProvider.getGuardian(), guardian);
    }

    function test_SetGuardian_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.ROLE_GUARDIAN(),
            address(0),
            guardian
        );
        
        vm.prank(owner);
        addressProvider.setGuardian(guardian);
    }

    function test_SetGuardian_RevertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(nonOwner);
        addressProvider.setGuardian(guardian);
    }

    function test_SetGuardian_RevertsIfZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, addressProvider.ROLE_GUARDIAN()));
        vm.prank(owner);
        addressProvider.setGuardian(address(0));
    }

    // -------------------------------------------------------------------------
    // setRiskAdmin Tests
    // -------------------------------------------------------------------------

    function test_SetRiskAdmin_Success() public {
        vm.prank(owner);
        addressProvider.setRiskAdmin(riskAdmin);
        
        assertEq(addressProvider.getRiskAdmin(), riskAdmin);
    }

    function test_SetRiskAdmin_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.ROLE_RISK_ADMIN(),
            address(0),
            riskAdmin
        );
        
        vm.prank(owner);
        addressProvider.setRiskAdmin(riskAdmin);
    }

    function test_SetRiskAdmin_RevertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(nonOwner);
        addressProvider.setRiskAdmin(riskAdmin);
    }

    function test_SetRiskAdmin_RevertsIfZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, addressProvider.ROLE_RISK_ADMIN()));
        vm.prank(owner);
        addressProvider.setRiskAdmin(address(0));
    }

    // -------------------------------------------------------------------------
    // setTreasury Tests
    // -------------------------------------------------------------------------

    function test_SetTreasury_Success() public {
        vm.prank(owner);
        addressProvider.setTreasury(treasury);
        
        assertEq(addressProvider.getTreasury(), treasury);
    }

    function test_SetTreasury_EmitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.ROLE_TREASURY(),
            address(0),
            treasury
        );
        
        vm.prank(owner);
        addressProvider.setTreasury(treasury);
    }

    function test_SetTreasury_RevertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(nonOwner);
        addressProvider.setTreasury(treasury);
    }

    function test_SetTreasury_RevertsIfZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, addressProvider.ROLE_TREASURY()));
        vm.prank(owner);
        addressProvider.setTreasury(address(0));
    }

    // -------------------------------------------------------------------------
    // Constants Tests
    // -------------------------------------------------------------------------

    function test_Constants_AreCorrect() public {
        // Verify that constant values are correct
        assertEq(
            addressProvider.KEY_ADDRESS_PROVIDER(),
            keccak256("KEY_ADDRESS_PROVIDER")
        );
        assertEq(
            addressProvider.KEY_ORACLE(),
            keccak256("KEY_ORACLE")
        );
        assertEq(
            addressProvider.KEY_WHITELIST(),
            keccak256("KEY_WHITELIST")
        );
        assertEq(
            addressProvider.KEY_FACTORY(),
            keccak256("KEY_FACTORY")
        );
        assertEq(
            addressProvider.KEY_VAULT_BEACON(),
            keccak256("KEY_VAULT_BEACON")
        );
        assertEq(
            addressProvider.ROLE_GUARDIAN(),
            keccak256("ROLE_GUARDIAN")
        );
        assertEq(
            addressProvider.ROLE_RISK_ADMIN(),
            keccak256("ROLE_RISK_ADMIN")
        );
        assertEq(
            addressProvider.ROLE_TREASURY(),
            keccak256("ROLE_TREASURY")
        );
    }

    // -------------------------------------------------------------------------
    // Integration Tests - Set All Addresses
    // -------------------------------------------------------------------------

    function test_SetAllAddresses_Success() public {
        vm.startPrank(owner);
        addressProvider.setPriceOracle(oracle);
        addressProvider.setAssetWhitelist(whitelist);
        addressProvider.setFactory(factory);
        addressProvider.setVaultBeacon(vaultBeacon);
        addressProvider.setGuardian(guardian);
        addressProvider.setRiskAdmin(riskAdmin);
        addressProvider.setTreasury(treasury);
        vm.stopPrank();

        assertEq(addressProvider.getPriceOracle(), oracle);
        assertEq(addressProvider.getAssetWhitelist(), whitelist);
        assertEq(addressProvider.getFactory(), factory);
        assertEq(addressProvider.getVaultBeacon(), vaultBeacon);
        assertEq(addressProvider.getGuardian(), guardian);
        assertEq(addressProvider.getRiskAdmin(), riskAdmin);
        assertEq(addressProvider.getTreasury(), treasury);
    }

    // -------------------------------------------------------------------------
    // Ownable2Step Tests
    // -------------------------------------------------------------------------

    function test_Ownable2Step_TransferOwnership() public {
        // Step 1: Initiate transfer
        vm.prank(owner);
        addressProvider.transferOwnership(newOwner);
        
        // At this point, newOwner is not yet the owner
        assertEq(addressProvider.owner(), owner);
        assertEq(addressProvider.pendingOwner(), newOwner);
        
        // Step 2: New owner accepts
        vm.prank(newOwner);
        addressProvider.acceptOwnership();
        
        assertEq(addressProvider.owner(), newOwner);
    }

    function test_Ownable2Step_OnlyPendingOwnerCanAccept() public {
        vm.prank(owner);
        addressProvider.transferOwnership(newOwner);
        
        // Non-pending owner cannot accept
        vm.expectRevert();
        vm.prank(nonOwner);
        addressProvider.acceptOwnership();
    }

    function test_Ownable2Step_NewOwnerCanSetAddresses() public {
        // Transfer ownership
        vm.prank(owner);
        addressProvider.transferOwnership(newOwner);
        
        vm.prank(newOwner);
        addressProvider.acceptOwnership();
        
        // New owner can set addresses
        vm.prank(newOwner);
        addressProvider.setPriceOracle(oracle);
        
        assertEq(addressProvider.getPriceOracle(), oracle);
    }

    function test_Ownable2Step_OldOwnerCannotSetAfterTransfer() public {
        // Transfer ownership
        vm.prank(owner);
        addressProvider.transferOwnership(newOwner);
        
        vm.prank(newOwner);
        addressProvider.acceptOwnership();
        
        // Old owner can no longer set addresses
        vm.expectRevert();
        vm.prank(owner);
        addressProvider.setPriceOracle(oracle);
    }

    // -------------------------------------------------------------------------
    // Edge Case Tests
    // -------------------------------------------------------------------------

    function test_SetSameAddress_EmitsEventWithSameOldAndNew() public {
        vm.prank(owner);
        addressProvider.setPriceOracle(oracle);
        
        // Set to the same address again
        vm.expectEmit(true, true, false, false);
        emit IProtocolAddressProvider.AddressSet(
            addressProvider.KEY_ORACLE(),
            oracle,
            oracle
        );
        
        vm.prank(owner);
        addressProvider.setPriceOracle(oracle);
    }

    function test_MultipleUpdates_PreservesOtherAddresses() public {
        // Set multiple addresses
        vm.startPrank(owner);
        addressProvider.setPriceOracle(oracle);
        addressProvider.setAssetWhitelist(whitelist);
        addressProvider.setFactory(factory);
        vm.stopPrank();
        
        // Update one of them
        vm.prank(owner);
        address newOracle = address(0x11);
        addressProvider.setPriceOracle(newOracle);
        
        // Other addresses should remain unchanged
        assertEq(addressProvider.getPriceOracle(), newOracle);
        assertEq(addressProvider.getAssetWhitelist(), whitelist);
        assertEq(addressProvider.getFactory(), factory);
    }
}

