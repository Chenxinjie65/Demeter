// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IProtocolAddressProvider
 * @notice Global registry of core contracts and privileged roles for the Demeter protocol.
 *
 * @dev
 * Inspired by Aave's PoolAddressesProvider, but simplified and adapted for Demeter:
 * - Stores core contract addresses and selected privileged roles in a single mapping.
 * - Exposes typed getters/setters for well-known keys.
 */
interface IProtocolAddressProvider {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when a generic address is updated in the registry.
     * @param id Identifier key (e.g. KEY_ORACLE, ROLE_DAO).
     * @param oldAddress Previous address associated with the key.
     * @param newAddress New address associated with the key.
     */
    event AddressSet(bytes32 indexed id, address indexed oldAddress, address indexed newAddress);

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @notice Returns the configured price oracle address.
    function getPriceOracle() external view returns (address);

    /// @notice Returns the configured asset whitelist address.
    function getAssetWhitelist() external view returns (address);

    /// @notice Returns the configured factory address.
    function getFactory() external view returns (address);

    /// @notice Returns the configured Demeter vault beacon address.
    function getVaultBeacon() external view returns (address);

    /// @notice Returns the guardian role address.
    function getGuardian() external view returns (address);

    /// @notice Returns the risk admin role address.
    function getRiskAdmin() external view returns (address);

    /// @notice Returns the treasury role address.
    function getTreasury() external view returns (address);

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    function setPriceOracle(address newOracle) external;

    function setAssetWhitelist(address newWhitelist) external;

    function setFactory(address newFactory) external;

    function setVaultBeacon(address newBeacon) external;

    function setGuardian(address newGuardian) external;

    function setRiskAdmin(address newRiskAdmin) external;

    function setTreasury(address newTreasury) external;
}