// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IDemeterShare
 * @notice ERC-20 claim token interface for one Demeter pool.
 * @custom:security-contact security@demeter.protocol
 */
interface IDemeterShare is IERC20 {
    /// @notice Return the immutable pool ID represented by this share token.
    function poolId() external view returns (bytes32);

    /// @notice Return the immutable Manager authorized to mint and burn shares.
    function manager() external view returns (address);

    /// @notice Mint shares; callable only by the immutable Manager.
    function mint(address to, uint256 amount) external;

    /// @notice Burn owner shares using an owner allowance or Manager authority.
    function burnFrom(address owner, address operator, uint256 amount) external;
}
