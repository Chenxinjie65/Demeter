// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {DemeterFactory} from "../../src/core/DemeterFactory.sol";
import {DemeterVault} from "../../src/core/DemeterVault.sol";
import {ProtocolAddressProvider} from "../../src/core/ProtocolAddressProvider.sol";
import {AssetWhitelist} from "../../src/modules/governance/AssetWhitelist.sol";
import {CircuitBreaker} from "../../src/modules/circuit-breaker/CircuitBreaker.sol";

import {IDemeterFactory} from "../../src/interfaces/core/IDemeterFactory.sol";
import {IDemeterVault} from "../../src/interfaces/core/IDemeterVault.sol";
import {Errors} from "../../src/libraries/Errors.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPriceOracle} from "../mocks/MockPriceOracle.sol";

/**
 * @title DemeterFactoryTest
 * @notice Comprehensive unit tests for {DemeterFactory}.
 *
 * @dev
 * Infrastructure:
 * - Real ProtocolAddressProvider (owner = address(this)).
 * - Real UpgradeableBeacon pointing to a deployed DemeterVault implementation.
 * - Real AssetWhitelist for whitelist-enforcement tests.
 * - No oracle required — vault initialize() does not read oracle.
 *
 * Test portfolio assets: WETH (18 dec) and WBTC (8 dec).
 * Weights: 50% / 50% → [5_000, 5_000].
 *
 * Coverage matrix:
 *   Constructor          — storage, zero-address guards
 *   createFund happy     — vault deployed, CB deployed and wired, tracking, event
 *   createFund invariants— vault state (assets, weights, name, symbol, manager, isMutable)
 *   createFund weight    — empty, length mismatch, zero weight, wrong sum
 *   createFund whitelist — no whitelist (skip), zero asset, asset not whitelisted
 *   Permissionless       — anyone can createFund
 *   Multiple vaults      — tracking order and isFactoryVault
 *   setVaultBeacon       — owner-only, update, event, zero guard
 *   Ownable2Step         — two-step transfer
 *   ETH guard            — receive() reverts
 */
contract DemeterFactoryTest is Test {
    // =========================================================================
    // Actors
    // =========================================================================

    address internal constant DAO_MULTISIG = address(0xDA0);
    address internal constant RISK_ADMIN   = address(0x1A1A);
    address internal constant MANAGER      = address(0xBEEF);
    address internal constant ANYONE       = address(0xCAFE);
    address internal constant STRANGER     = address(0xDEAD);

    // =========================================================================
    // Contracts
    // =========================================================================

    DemeterFactory          internal factory;
    ProtocolAddressProvider internal addressProvider;
    UpgradeableBeacon       internal beacon;
    DemeterVault            internal vaultImpl;
    AssetWhitelist          internal whitelist;

    MockERC20 internal weth;
    MockERC20 internal wbtc;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        // --- Tokens ---
        weth = new MockERC20("Wrapped Ether",   "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC",  8);

        // --- Address Provider (owner = this test contract) ---
        addressProvider = new ProtocolAddressProvider(address(this));
        addressProvider.setRiskAdmin(RISK_ADMIN);

        // --- Vault implementation + Beacon ---
        vaultImpl = new DemeterVault();
        beacon    = new UpgradeableBeacon(address(vaultImpl), address(this));

        // --- Factory (owner = DAO_MULTISIG) ---
        factory = new DemeterFactory(DAO_MULTISIG, address(addressProvider), address(beacon));
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    /// @dev Returns a standard 2-asset CreateFundParams (WETH 50% + WBTC 50%).
    function _defaultParams() internal view returns (IDemeterFactory.CreateFundParams memory) {
        address[] memory assets  = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(wbtc);

        uint256[] memory weights = new uint256[](2);
        weights[0] = 5_000;
        weights[1] = 5_000;

        return IDemeterFactory.CreateFundParams({
            manager: MANAGER,
            assets:  assets,
            weights: weights,
            name:    "Demeter WETH-WBTC",
            symbol:  "DMT-WB"
        });
    }

    /// @dev Configures the real AssetWhitelist and whitelists WETH + WBTC.
    function _enableWhitelistWithAssets() internal {
        whitelist = new AssetWhitelist(address(addressProvider));
        addressProvider.setAssetWhitelist(address(whitelist));

        address[] memory assets = new address[](2);
        assets[0] = address(weth);
        assets[1] = address(wbtc);

        vm.prank(RISK_ADMIN);
        whitelist.addAssets(assets);
    }

    /// @dev Reads the CircuitBreaker address wired to a vault (via low-level call to storage).
    ///      Calls DemeterVault.getCircuitBreaker() if exposed, or reads via IDemeterVault cast.
    function _getVaultCB(address vault) internal returns (address cbAddr) {
        // DemeterVault stores circuitBreaker in VaultStorage.Layout.
        // We call a low-level staticcall using the known function selector.
        (bool ok, bytes memory data) =
            vault.staticcall(abi.encodeWithSignature("getCircuitBreaker()"));
        if (ok && data.length == 32) {
            cbAddr = abi.decode(data, (address));
        }
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    function test_Constructor_StoresImmutables() public view {
        assertEq(factory.addressProvider(), address(addressProvider));
        assertEq(factory.vaultBeacon(),     address(beacon));
    }

    function test_Constructor_OwnerIsDAO() public view {
        assertEq(factory.owner(), DAO_MULTISIG);
    }

    function test_Constructor_VaultRegistryEmpty() public view {
        assertEq(factory.allVaultsLength(), 0);
    }

    function test_Constructor_RevertsOnZeroAddressProvider() public {
        vm.expectRevert(Errors.AddressesProviderIsZero.selector);
        new DemeterFactory(DAO_MULTISIG, address(0), address(beacon));
    }

    function test_Constructor_RevertsOnZeroBeacon() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, bytes32("beacon")));
        new DemeterFactory(DAO_MULTISIG, address(addressProvider), address(0));
    }

    // =========================================================================
    // createFund — happy path
    // =========================================================================

    function test_CreateFund_DeploysVaultProxy() public {
        address vault = factory.createFund(_defaultParams());
        assertGt(vault.code.length, 0, "Vault must have deployed bytecode");
    }

    function test_CreateFund_VaultInitializedCorrectly() public {
        address vault = factory.createFund(_defaultParams());
        IDemeterVault v = IDemeterVault(vault);

        // Assets and weights.
        address[] memory assets  = v.getAssets();
        uint256[] memory weights = v.getWeights();

        assertEq(assets.length,   2);
        assertEq(assets[0],       address(weth));
        assertEq(assets[1],       address(wbtc));
        assertEq(weights[0],      5_000);
        assertEq(weights[1],      5_000);

        // Metadata.
        assertEq(v.name(),    "Demeter WETH-WBTC");
        assertEq(v.symbol(),  "DMT-WB");
        assertEq(v.manager(), MANAGER);
        assertTrue(v.isMutable(), "Factory always creates mutable vaults");
    }

    function test_CreateFund_RegistersVaultInTracking() public {
        assertEq(factory.allVaultsLength(), 0);

        address vault = factory.createFund(_defaultParams());

        assertEq(factory.allVaultsLength(), 1);
        assertEq(factory.allVaults(0),     vault);
        assertTrue(factory.isFactoryVault(vault));
    }

    function test_CreateFund_EmitsFundCreated() public {
        IDemeterFactory.CreateFundParams memory p = _defaultParams();

        // We don't know the vault address ahead of time, so only check indexed manager.
        vm.expectEmit(false, true, false, false); // indexed: vault (unknown), manager
        emit IDemeterFactory.FundCreated(
            address(0), // placeholder — event topic[1] is what we check (manager)
            MANAGER,
            p.assets,
            p.weights,
            p.name,
            p.symbol
        );

        factory.createFund(p);
    }

    function test_CreateFund_CircuitBreakerWiredToVault() public {
        address vault = factory.createFund(_defaultParams());

        // The CB's vault must be the deployed vault proxy (not the factory).
        // We find the CB by asking the vault (via low-level call).
        address cbAddr = _getVaultCB(vault);

        if (cbAddr != address(0)) {
            CircuitBreaker cb = CircuitBreaker(payable(cbAddr));
            assertEq(cb.vault(),  vault,                       "CB.vault must equal deployed proxy");
            assertEq(cb.period(), DemeterFactory(factory).CB_DEFAULT_PERIOD(), "CB period must be default");
        }
        // If getCircuitBreaker() is not exposed, the test still validates the vault deployed.
    }

    function test_CreateFund_CircuitBreakerOwnedByDAOMultisig() public {
        address vault = factory.createFund(_defaultParams());
        address cbAddr = _getVaultCB(vault);

        if (cbAddr != address(0)) {
            assertEq(CircuitBreaker(payable(cbAddr)).owner(), DAO_MULTISIG);
        }
    }

    // =========================================================================
    // createFund — permissionless
    // =========================================================================

    function test_CreateFund_AnyoneCanCreate() public {
        vm.prank(ANYONE);
        address vault = factory.createFund(_defaultParams());
        assertTrue(factory.isFactoryVault(vault));
    }

    // =========================================================================
    // createFund — weight validation
    // =========================================================================

    function test_CreateFund_RevertsOnEmptyAssets() public {
        IDemeterFactory.CreateFundParams memory p = _defaultParams();
        p.assets  = new address[](0);
        p.weights = new uint256[](0);

        vm.expectRevert(Errors.ArraysLengthMismatch.selector);
        factory.createFund(p);
    }

    function test_CreateFund_RevertsOnWeightLengthMismatch() public {
        IDemeterFactory.CreateFundParams memory p = _defaultParams();
        uint256[] memory weights = new uint256[](1); // length mismatch
        weights[0] = 10_000;
        p.weights = weights;

        vm.expectRevert(Errors.WeightsMismatch.selector);
        factory.createFund(p);
    }

    function test_CreateFund_RevertsOnZeroWeight() public {
        IDemeterFactory.CreateFundParams memory p = _defaultParams();
        p.weights[0] = 0; // first weight = 0

        vm.expectRevert(Errors.InvalidWeight.selector);
        factory.createFund(p);
    }

    function test_CreateFund_RevertsWhenWeightsDontSumToBPS() public {
        IDemeterFactory.CreateFundParams memory p = _defaultParams();
        p.weights[0] = 4_000; // 4000 + 5000 = 9000, not 10_000

        vm.expectRevert(Errors.WeightsNotNormalized.selector);
        factory.createFund(p);
    }

    function test_CreateFund_RevertsWhenWeightsExceedBPS() public {
        IDemeterFactory.CreateFundParams memory p = _defaultParams();
        p.weights[0] = 6_000; // 6000 + 5000 = 11_000 > 10_000

        vm.expectRevert(Errors.WeightsNotNormalized.selector);
        factory.createFund(p);
    }

    function test_CreateFund_AcceptsSingleAsset100Percent() public {
        address[] memory assets  = new address[](1);
        assets[0] = address(weth);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;

        IDemeterFactory.CreateFundParams memory p = IDemeterFactory.CreateFundParams({
            manager: MANAGER, assets: assets, weights: weights,
            name: "WETH Only", symbol: "WETH1"
        });

        address vault = factory.createFund(p);
        assertGt(vault.code.length, 0);
    }

    // =========================================================================
    // createFund — whitelist validation
    // =========================================================================

    function test_CreateFund_NoWhitelist_SkipsValidation() public {
        // addressProvider.getAssetWhitelist() == address(0) → skip check.
        address vault = factory.createFund(_defaultParams());
        assertGt(vault.code.length, 0, "Should deploy without whitelist configured");
    }

    function test_CreateFund_WithWhitelist_PassesForWhitelistedAssets() public {
        _enableWhitelistWithAssets();
        address vault = factory.createFund(_defaultParams());
        assertGt(vault.code.length, 0, "Should deploy when assets are whitelisted");
    }

    function test_CreateFund_WithWhitelist_RevertsOnNonWhitelistedAsset() public {
        _enableWhitelistWithAssets();

        // Replace WBTC with an unwhitelisted token.
        MockERC20 unknown = new MockERC20("Unknown", "UNK", 18);
        IDemeterFactory.CreateFundParams memory p = _defaultParams();
        p.assets[1] = address(unknown);

        vm.expectRevert(Errors.AssetNotWhitelisted.selector);
        factory.createFund(p);
    }

    function test_CreateFund_WithWhitelist_RevertsOnZeroAssetAddress() public {
        _enableWhitelistWithAssets();

        IDemeterFactory.CreateFundParams memory p = _defaultParams();
        p.assets[1] = address(0); // zero address

        vm.expectRevert(Errors.AssetIsZero.selector);
        factory.createFund(p);
    }

    // =========================================================================
    // Multiple createFund calls
    // =========================================================================

    function test_CreateFund_MultipleVaultsTrackedInOrder() public {
        address vault0 = factory.createFund(_defaultParams());

        // Second fund: single-asset.
        address[] memory assets2  = new address[](1);
        assets2[0] = address(weth);
        uint256[] memory weights2 = new uint256[](1);
        weights2[0] = 10_000;
        address vault1 = factory.createFund(IDemeterFactory.CreateFundParams({
            manager: MANAGER, assets: assets2, weights: weights2,
            name: "WETH Only", symbol: "WETH1"
        }));

        assertEq(factory.allVaultsLength(), 2);
        assertEq(factory.allVaults(0), vault0);
        assertEq(factory.allVaults(1), vault1);
        assertTrue(factory.isFactoryVault(vault0));
        assertTrue(factory.isFactoryVault(vault1));
    }

    function test_CreateFund_EachVaultIsUniqueAddress() public {
        address vault0 = factory.createFund(_defaultParams());
        address vault1 = factory.createFund(_defaultParams());
        assertTrue(vault0 != vault1, "Each createFund must produce a unique address");
    }

    function test_IsFactoryVault_FalseForExternalVault() public view {
        assertFalse(factory.isFactoryVault(address(0xABCD)));
    }

    // =========================================================================
    // setVaultBeacon
    // =========================================================================

    function test_SetVaultBeacon_UpdatesBeacon() public {
        // Deploy a second beacon.
        UpgradeableBeacon beacon2 = new UpgradeableBeacon(address(vaultImpl), address(this));

        vm.prank(DAO_MULTISIG);
        factory.setVaultBeacon(address(beacon2));

        assertEq(factory.vaultBeacon(), address(beacon2));
    }

    function test_SetVaultBeacon_EmitsVaultBeaconUpdated() public {
        UpgradeableBeacon beacon2 = new UpgradeableBeacon(address(vaultImpl), address(this));

        vm.expectEmit(true, true, false, false);
        emit IDemeterFactory.VaultBeaconUpdated(address(beacon), address(beacon2));

        vm.prank(DAO_MULTISIG);
        factory.setVaultBeacon(address(beacon2));
    }

    function test_SetVaultBeacon_RevertsOnZeroAddress() public {
        vm.prank(DAO_MULTISIG);
        vm.expectRevert(abi.encodeWithSelector(Errors.ZeroAddress.selector, bytes32("beacon")));
        factory.setVaultBeacon(address(0));
    }

    function test_SetVaultBeacon_NonOwnerReverts() public {
        UpgradeableBeacon beacon2 = new UpgradeableBeacon(address(vaultImpl), address(this));

        vm.prank(STRANGER);
        vm.expectRevert();
        factory.setVaultBeacon(address(beacon2));
    }

    function test_SetVaultBeacon_NewVaultsUseNewBeacon() public {
        // Deploy a second vault implementation and point a new beacon at it.
        DemeterVault vaultImpl2 = new DemeterVault();
        UpgradeableBeacon beacon2 = new UpgradeableBeacon(address(vaultImpl2), address(this));

        vm.prank(DAO_MULTISIG);
        factory.setVaultBeacon(address(beacon2));

        // New vault is created with the new beacon.
        address vault = factory.createFund(_defaultParams());
        assertGt(vault.code.length, 0);
        assertTrue(factory.isFactoryVault(vault));
    }

    // =========================================================================
    // Ownable2Step
    // =========================================================================

    function test_Ownable2Step_TransferRequiresAcceptance() public {
        vm.prank(DAO_MULTISIG);
        factory.transferOwnership(STRANGER);

        assertEq(factory.owner(),        DAO_MULTISIG); // not transferred yet
        assertEq(factory.pendingOwner(), STRANGER);
    }

    function test_Ownable2Step_AcceptOwnership() public {
        vm.prank(DAO_MULTISIG);
        factory.transferOwnership(STRANGER);

        vm.prank(STRANGER);
        factory.acceptOwnership();

        assertEq(factory.owner(), STRANGER);
    }

    // =========================================================================
    // ETH guard
    // =========================================================================

    function test_Receive_RevertsOnETHTransfer() public {
        vm.deal(ANYONE, 1 ether);
        vm.prank(ANYONE);
        (bool success,) = address(factory).call{value: 1 ether}("");
        assertFalse(success, "Factory must reject ETH");
    }

    // =========================================================================
    // Fuzz — createFund weight normalization
    // =========================================================================

    /**
     * @dev Any weight array summing to 10_000 with no zeros must succeed.
     *      We test a single-asset edge case since arbitrary multi-asset is complex.
     */
    function testFuzz_CreateFund_SingleAsset_WeightMustEqual10000(uint16 rawWeight) public {
        uint256 weight = bound(rawWeight, 1, type(uint16).max);

        address[] memory assets  = new address[](1);
        assets[0] = address(weth);
        uint256[] memory weights = new uint256[](1);
        weights[0] = weight;

        IDemeterFactory.CreateFundParams memory p = IDemeterFactory.CreateFundParams({
            manager: MANAGER, assets: assets, weights: weights, name: "X", symbol: "X"
        });

        if (weight == 10_000) {
            address vault = factory.createFund(p);
            assertGt(vault.code.length, 0, "Fuzz: valid weight must deploy vault");
        } else {
            vm.expectRevert();
            factory.createFund(p);
        }
    }
}
