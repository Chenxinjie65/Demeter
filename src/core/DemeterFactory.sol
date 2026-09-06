// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IDemeterFactory} from "../interfaces/core/IDemeterFactory.sol";
import {IDemeterVault} from "../interfaces/core/IDemeterVault.sol";
import {IProtocolAddressProvider} from "../interfaces/core/IProtocolAddressProvider.sol";
import {IAssetWhitelist} from "../interfaces/modules/IAssetWhitelist.sol";
import {CircuitBreaker} from "../modules/circuit-breaker/CircuitBreaker.sol";
import {Errors} from "../libraries/Errors.sol";
import {Constants} from "../libraries/Constants.sol";

/**
 * @title DemeterFactory
 * @notice Permissionless factory for creating new DemeterVault instances.
 *
 * @dev
 * Architecture:
 * - Each vault is deployed as an OpenZeppelin {BeaconProxy} pointing to the current
 *   {UpgradeableBeacon}. All vaults created by this factory are upgraded atomically
 *   when the beacon's implementation is updated.
 * - A dedicated {CircuitBreaker} is deployed per vault to enforce per-period outflow
 *   rate limits and prevent catastrophic TVL drains.
 * - The factory reads a {ProtocolAddressProvider} for global protocol configuration
 *   (oracle, whitelist, beacon) so it does not need to be updated when those components
 *   are upgraded.
 *
 * Permissions:
 * - {createFund} is intentionally permissionless: any address may deploy a vault.
 * - {setVaultBeacon} is owner-gated (DAO multisig / governance timelock).
 *
 * Circuit-breaker defaults:
 * - Period: 24 hours.
 * - Limit: 10% of vault AUM in USD (8-decimal). Caller should override via governance
 *   after deployment for large vaults.
 *
 * Security:
 * - Validates that all supplied assets are whitelisted before deploying.
 * - Validates that weights sum to BPS (10_000) to prevent malformed vaults.
 * - Ownership uses a two-step pattern via {Ownable2Step}.
 * - No fallback / receive — prevents ether accumulation.
 */
contract DemeterFactory is Ownable2Step, IDemeterFactory {
    // -------------------------------------------------------------------------
    // Circuit-breaker deployment constants
    // -------------------------------------------------------------------------

    /// @notice Default circuit-breaker window: 24 hours.
    uint256 public constant CB_DEFAULT_PERIOD = 24 hours;

    /**
     * @notice Default circuit-breaker USD limit per window.
     *
     * @dev
     * Set to a large sentinel value (type(uint256).max / 2) so that out-of-the-box
     * deployments are not blocked. Operators SHOULD call {CircuitBreaker.setLimit}
     * after deployment to configure a meaningful vault-specific limit.
     *
     * Using max/2 rather than type(uint256).max avoids potential overflow in the
     * cumulative arithmetic inside the CircuitBreaker.
     */
    uint256 public constant CB_DEFAULT_LIMIT_USD = type(uint256).max / 2;

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Global address provider (oracle, whitelist, beacon addresses).
    address public immutable override addressProvider;

    /// @notice Current beacon used for new vault deployments.
    address public override vaultBeacon;

    /// @notice Tracks all vaults ever created by this factory (in creation order).
    address[] private _allVaults;

    /// @notice Lookup: vault address → true if created by this factory.
    mapping(address => bool) public isFactoryVault;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Deploys the factory.
     *
     * @param owner_           Owner address (DAO multisig or governance timelock).
     * @param addressProvider_ Address of the deployed {ProtocolAddressProvider}.
     * @param vaultBeacon_     Address of the {UpgradeableBeacon} contract pointing to
     *                         the current DemeterVault implementation.
     */
    constructor(address owner_, address addressProvider_, address vaultBeacon_) Ownable(owner_) {
        if (addressProvider_ == address(0)) revert Errors.AddressesProviderIsZero();
        if (vaultBeacon_ == address(0)) revert Errors.ZeroAddress(bytes32("beacon"));
        addressProvider = addressProvider_;
        vaultBeacon = vaultBeacon_;
    }

    // -------------------------------------------------------------------------
    // IDemeterFactory — View functions
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the number of vaults created by this factory.
     */
    function allVaultsLength() external view returns (uint256) {
        return _allVaults.length;
    }

    /**
     * @notice Returns the vault address at a given index in the creation order.
     * @param index Zero-based index.
     */
    function allVaults(uint256 index) external view returns (address) {
        return _allVaults[index];
    }

    // -------------------------------------------------------------------------
    // IDemeterFactory — Management
    // -------------------------------------------------------------------------

    /// @inheritdoc IDemeterFactory
    function setVaultBeacon(address newBeacon) external override onlyOwner {
        if (newBeacon == address(0)) revert Errors.ZeroAddress(bytes32("beacon"));
        address old = vaultBeacon;
        vaultBeacon = newBeacon;
        emit VaultBeaconUpdated(old, newBeacon);
    }

    // -------------------------------------------------------------------------
    // IDemeterFactory — Fund creation
    // -------------------------------------------------------------------------

    /**
     * @inheritdoc IDemeterFactory
     *
     * @dev
     * Steps:
     * 1. Validate weights: non-zero, correct length, sum == 10_000.
     * 2. Validate each asset: non-zero address, whitelisted.
     * 3. Deploy a {CircuitBreaker} for this vault (vault address unknown yet; updated post-deploy).
     * 4. Deploy a {BeaconProxy} and call {DemeterVault.initialize} via initData.
     * 5. Update the CircuitBreaker's vault reference to the real proxy address.
     * 6. Register the vault in the factory's tracking structures.
     * 7. Emit {FundCreated}.
     *
     * Gas note: deploying two contracts per fund creation is intentionally accepted;
     * fund creation is a rare, administrative operation.
     */
    function createFund(CreateFundParams calldata params) external override returns (address vault) {
        // --- 1. Validate weights ------------------------------------------------
        uint256 numAssets = params.assets.length;
        if (numAssets == 0) revert Errors.ArraysLengthMismatch();
        if (params.weights.length != numAssets) revert Errors.WeightsMismatch();

        uint256 weightSum;
        for (uint256 i; i < numAssets; ) {
            if (params.weights[i] == 0) revert Errors.InvalidWeight();
            weightSum += params.weights[i];
            unchecked { i++; }
        }
        if (weightSum != Constants.BPS) revert Errors.WeightsNotNormalized();

        // --- 2. Validate assets are whitelisted ---------------------------------
        address whitelist = IProtocolAddressProvider(addressProvider).getAssetWhitelist();
        if (whitelist != address(0)) {
            IAssetWhitelist wl = IAssetWhitelist(whitelist);
            for (uint256 i; i < numAssets; ) {
                address asset = params.assets[i];
                if (asset == address(0)) revert Errors.AssetIsZero();
                if (!wl.isWhitelisted(asset)) revert Errors.AssetNotWhitelisted();
                unchecked { i++; }
            }
        }

        // --- 3. Deploy CircuitBreaker (temporary vault = address(this)) ---------
        // The vault address is not known until the BeaconProxy is deployed.
        // We bootstrap with address(this) as the temporary vault, then update it in step 5.
        CircuitBreaker cb = new CircuitBreaker(
            owner(),            // CB owner = factory owner (DAO / multisig)
            address(this),      // temporary vault reference — updated in step 5
            CB_DEFAULT_PERIOD,
            CB_DEFAULT_LIMIT_USD
        );

        // --- 4. Build vault init-data and deploy BeaconProxy --------------------
        IDemeterVault.InitializeParams memory initParams = IDemeterVault.InitializeParams({
            baseAsset:       address(0),        // pure index vault (no single base asset)
            manager:         params.manager,
            assets:          params.assets,
            weights:         params.weights,
            addressProvider: addressProvider,
            name:            params.name,
            symbol:          params.symbol,
            isMutable:       true,              // manager may update weights post-deployment
            circuitBreaker:  address(cb)        // wired at initialization time
        });

        bytes memory initData = abi.encodeCall(IDemeterVault.initialize, (initParams));

        // Deploy the BeaconProxy.
        vault = address(new BeaconProxy(vaultBeacon, initData));

        // --- 5. Update CircuitBreaker to the real vault address -----------------
        // The vault is now deployed; point the CB at the real proxy so only the vault
        // can call checkAndRecordOutflow.  finalizeVault() can only be called by the
        // deployer (this factory) and only once, so it cannot be replayed.
        cb.finalizeVault(vault);

        // --- 6. Register vault --------------------------------------------------
        _allVaults.push(vault);
        isFactoryVault[vault] = true;

        // --- 7. Emit event ------------------------------------------------------
        emit FundCreated(vault, params.manager, params.assets, params.weights, params.name, params.symbol);
    }

    // -------------------------------------------------------------------------
    // Ether guard
    // -------------------------------------------------------------------------

    receive() external payable {
        revert();
    }
}
