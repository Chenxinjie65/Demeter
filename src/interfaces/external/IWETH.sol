// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH
 * @notice Minimal interface for Wrapped Ether (WETH9 / WETH on any EVM chain).
 *
 * @dev
 * The canonical WETH9 contract (Ethereum mainnet: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
 * and its equivalents on other networks expose deposit() and withdraw() for wrapping/unwrapping.
 */
interface IWETH is IERC20 {
    /**
     * @notice Wraps `msg.value` ETH and mints an equal amount of WETH to `msg.sender`.
     */
    function deposit() external payable;

    /**
     * @notice Burns `amount` WETH from `msg.sender` and transfers `amount` ETH back.
     * @param amount Amount of WETH to unwrap.
     */
    function withdraw(uint256 amount) external;
}
