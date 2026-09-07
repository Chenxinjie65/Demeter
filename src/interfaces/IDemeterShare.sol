// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IDemeterShare
 * @notice ERC-20 claim token interface for one Demeter pool.
 * @custom:security-contact https://github.com/Chenxinjie65/Demeter/security/advisories/new
 */
interface IDemeterShare is IERC20 {
    /// @notice Return the immutable pool ID represented by this share token.
    function poolId() external view returns (bytes32);

    /// @notice Return the immutable Manager authorized to mint and burn shares.
    function manager() external view returns (address);

    /// @notice Mint shares; callable only by the immutable Manager.
    /// @param to Account receiving the newly issued shares.
    /// @param amount Raw 18-decimal share amount to mint.
    function mint(address to, uint256 amount) external;

    /// @notice Burn owner shares using an owner allowance or Manager authority.
    /// @param owner Account whose shares are destroyed.
    /// @param operator Caller authorized by the owner allowance, or the Manager.
    /// @param amount Raw 18-decimal share amount to burn.
    function burnFrom(address owner, address operator, uint256 amount) external;
}
