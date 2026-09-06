// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDemeterFactory
 * @notice Interface for the Demeter fund factory.
 *
 * @dev
 * - Responsible for deploying new DemeterVault instances (Beacon proxies).
 * - Reads global configuration from the ProtocolAddressProvider.
 * - Itself is immutable; upgrades are performed either via Beacon upgrades or by
 *   deploying a new factory and updating the AddressProvider.
 */
interface IDemeterFactory {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a new Demeter vault is created.
     * @param vault Address of the newly deployed vault proxy.
     * @param manager Manager address configured for the fund.
     * @param assets Underlying portfolio assets.
     * @param weights Target portfolio weights in basis points.
     * @param name ERC-20 name of the share token.
     * @param symbol ERC-20 symbol of the share token.
     */
    event FundCreated(
        address indexed vault,
        address indexed manager,
        address[] assets,
        uint256[] weights,
        string name,
        string symbol
    );

    /**
     * @notice Emitted when the beacon used for new vault deployments is updated.
     * @param oldBeacon Previous beacon address.
     * @param newBeacon New beacon address.
     */
    event VaultBeaconUpdated(address indexed oldBeacon, address indexed newBeacon);

    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /**
     * @notice Parameters required to create a new Demeter fund.
     */
    struct CreateFundParams {
        address manager;
        address[] assets;
        uint256[] weights; // Basis points; SHOULD sum to 10_000.
        string name;
        string symbol;
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /**
     * @notice Returns the current beacon used to deploy new vault proxies.
     */
    function vaultBeacon() external view returns (address);

    /**
     * @notice Returns the global ProtocolAddressProvider used by this factory.
     */
    function addressProvider() external view returns (address);

    // -------------------------------------------------------------------------
    // Management functions
    // -------------------------------------------------------------------------

    /**
     * @notice Updates the beacon address used for newly created vaults.
     * @dev
     * - Existing vaults will continue to use the beacon they were deployed with.
     * - This function is meant to be governance / timelock controlled.
     *
     * @param newBeacon Address of the new UpgradeableBeacon contract.
     */
    function setVaultBeacon(address newBeacon) external;

    // -------------------------------------------------------------------------
    // Fund creation
    // -------------------------------------------------------------------------

    /**
     * @notice Creates a new Demeter fund (vault) as a Beacon proxy.
     * @dev
     * - Implementations SHOULD:
     *   - Validate assets are whitelisted.
     *   - Validate weights length and sum.
     *   - Initialize the vault with the provided parameters.
     *
     * @param params Struct containing manager, assets, weights, name and symbol.
     * @return vault Address of the newly created vault proxy.
     */
    function createFund(CreateFundParams calldata params) external returns (address vault);
}


