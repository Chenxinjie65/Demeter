// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IDemeterShare} from "src/interfaces/IDemeterShare.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";

/**
 * @title DemeterShare
 * @notice The transferable ERC-20 claim token for one Demeter pool.
 * @dev
 * The token has no underlying-token custody and no upgrade path. Its manager
 * is fixed at deployment time. Keeping mint and burn behind this narrow
 * boundary prevents a pool's share supply from being changed by any other
 * protocol module.
 */
contract DemeterShare is ERC20, IDemeterShare {
    /// @dev The pool this share token represents.
    bytes32 private immutable _poolId;

    /// @dev The sole account permitted to mint and burn.
    address private immutable _manager;

    /**
     * @notice Deploy a pool share token.
     * @param name_ ERC-20 display name.
     * @param symbol_ ERC-20 display symbol.
     * @param poolId_ Immutable pool identifier.
     * @param manager_ Sole minting and burning authority.
     */
    constructor(string memory name_, string memory symbol_, bytes32 poolId_, address manager_) ERC20(name_, symbol_) {
        if (manager_ == address(0)) revert V2Errors.V2Errors__ZeroAddress("manager");
        _poolId = poolId_;
        _manager = manager_;
    }

    /// @inheritdoc IDemeterShare
    function poolId() external view returns (bytes32) {
        return _poolId;
    }

    /// @inheritdoc IDemeterShare
    function manager() external view returns (address) {
        return _manager;
    }

    /**
     * @notice Mint shares for a manager-authorized operation.
     * @param to Recipient of the newly issued shares.
     * @param amount Number of shares to mint.
     */
    function mint(address to, uint256 amount) external {
        _onlyManager();
        _mint(to, amount);
    }

    /**
     * @notice Burn shares for a manager-authorized redemption.
     * @param from Account whose shares are burned.
     * @param amount Number of shares to burn.
     */
    function burnFrom(address from, address operator, uint256 amount) external {
        _onlyManager();
        if (operator != from) _spendAllowance(from, operator, amount);
        _burn(from, amount);
    }

    function _onlyManager() internal view {
        if (msg.sender != _manager) revert V2Errors.V2Errors__Unauthorized(msg.sender);
    }
}
