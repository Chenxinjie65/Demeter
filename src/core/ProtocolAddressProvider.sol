// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProtocolAddressProvider} from "../interfaces/core/IProtocolAddressProvider.sol";

/**
 * @title ProtocolAddressProvider
 * @notice Main registry of core Demeter protocol contracts and privileged roles.
 *
 * @dev
 * - Inspired by Aave's PoolAddressesProvider, but simplified for this use case.
 * - Deployed once per network and used as a single source of truth for:
 *   - Core contracts (Factory, Oracle, Whitelist, Vault Beacon).
 *   - Global roles (Guardian, Risk Admin, Treasury).
 * - Ownership uses a two-step pattern via {Ownable2Step} to avoid misconfigured transfers.
 */
contract ProtocolAddressProvider is Ownable2Step, IProtocolAddressProvider {
    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Map of registered addresses (identifier => registeredAddress).
    mapping(bytes32 => address) private _addresses;

    // -------------------------------------------------------------------------
    // Identifier constants
    // -------------------------------------------------------------------------

    // Core contract keys ------------------------------------------------------
    bytes32 public constant KEY_ADDRESS_PROVIDER = keccak256("KEY_ADDRESS_PROVIDER");
    bytes32 public constant KEY_ORACLE = keccak256("KEY_ORACLE");
    bytes32 public constant KEY_WHITELIST = keccak256("KEY_WHITELIST");
    bytes32 public constant KEY_FACTORY = keccak256("KEY_FACTORY");
    bytes32 public constant KEY_VAULT_BEACON = keccak256("KEY_VAULT_BEACON");

    // Role keys ---------------------------------------------------------------
    bytes32 public constant ROLE_GUARDIAN = keccak256("ROLE_GUARDIAN");
    bytes32 public constant ROLE_RISK_ADMIN = keccak256("ROLE_RISK_ADMIN");
    bytes32 public constant ROLE_TREASURY = keccak256("ROLE_TREASURY");

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @notice Constructor.
     * @param owner_ Initial owner address (DAO multisig).
     */
    constructor(address owner_) Ownable(owner_) {
        if (owner_ == address(0)) revert InvalidOwner(owner_);
        _setAddress(KEY_ADDRESS_PROVIDER, address(this));
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @inheritdoc IProtocolAddressProvider
    function getPriceOracle() external view override returns (address) {
        return _addresses[KEY_ORACLE];
    }

    /// @inheritdoc IProtocolAddressProvider
    function getAssetWhitelist() external view override returns (address) {
        return _addresses[KEY_WHITELIST];
    }

    /// @inheritdoc IProtocolAddressProvider
    function getFactory() external view override returns (address) {
        return _addresses[KEY_FACTORY];
    }

    /// @inheritdoc IProtocolAddressProvider
    function getVaultBeacon() external view override returns (address) {
        return _addresses[KEY_VAULT_BEACON];
    }

    /// @inheritdoc IProtocolAddressProvider
    function getGuardian() external view override returns (address) {
        return _addresses[ROLE_GUARDIAN];
    }

    /// @inheritdoc IProtocolAddressProvider
    function getRiskAdmin() external view override returns (address) {
        return _addresses[ROLE_RISK_ADMIN];
    }

    /// @inheritdoc IProtocolAddressProvider
    function getTreasury() external view override returns (address) {
        return _addresses[ROLE_TREASURY];
    }

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /// @inheritdoc IProtocolAddressProvider
    function setPriceOracle(address newOracle) external override onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress(KEY_ORACLE);
        _setAddress(KEY_ORACLE, newOracle);
    }

    /// @inheritdoc IProtocolAddressProvider
    function setAssetWhitelist(address newWhitelist) external override onlyOwner {
        if (newWhitelist == address(0)) revert ZeroAddress(KEY_WHITELIST);
        _setAddress(KEY_WHITELIST, newWhitelist);
    }

    /// @inheritdoc IProtocolAddressProvider
    function setFactory(address newFactory) external override onlyOwner {
        if (newFactory == address(0)) revert ZeroAddress(KEY_FACTORY);
        _setAddress(KEY_FACTORY, newFactory);
    }

    /// @inheritdoc IProtocolAddressProvider
    function setVaultBeacon(address newBeacon) external override onlyOwner {
        if (newBeacon == address(0)) revert ZeroAddress(KEY_VAULT_BEACON);
        _setAddress(KEY_VAULT_BEACON, newBeacon);
    }

    /// @inheritdoc IProtocolAddressProvider
    function setGuardian(address newGuardian) external override onlyOwner {
        if (newGuardian == address(0)) revert ZeroAddress(ROLE_GUARDIAN);
        _setAddress(ROLE_GUARDIAN, newGuardian);
    }

    /// @inheritdoc IProtocolAddressProvider
    function setRiskAdmin(address newRiskAdmin) external override onlyOwner {
        if (newRiskAdmin == address(0)) revert ZeroAddress(ROLE_RISK_ADMIN);
        _setAddress(ROLE_RISK_ADMIN, newRiskAdmin);
    }

    /// @inheritdoc IProtocolAddressProvider
    function setTreasury(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress(ROLE_TREASURY);
        _setAddress(ROLE_TREASURY, newTreasury);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @notice Internal function to set an address for the given key.
     * @dev Emits {AddressSet}.
     */
    function _setAddress(bytes32 id, address newAddress) internal {
        address oldAddress = _addresses[id];
        _addresses[id] = newAddress;
        emit AddressSet(id, oldAddress, newAddress);
    }
}