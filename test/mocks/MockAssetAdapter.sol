// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAssetAdapter} from "../../src/interfaces/modules/IAssetAdapter.sol";

/**
 * @title MockAssetAdapter
 * @notice IAssetAdapter mock that simulates Aave-style yield strategies.
 *
 * @dev
 * - Tracks deposited balances in a mapping.
 * - Supports configurable revert injection to simulate Aave 100% utilization DoS.
 * - `deposit`: pulls tokens from caller, records balance.
 * - `withdraw`: sends tokens to recipient, decrements balance.
 * - `getBalance`: returns recorded balance (can be forced to revert).
 */
contract MockAssetAdapter is IAssetAdapter {
    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /// @notice Causes withdraw() to revert when true (simulates Aave DoS).
    bool public shouldRevertWithdraw;
    /// @notice Causes getBalance() to revert when true.
    bool public shouldRevertGetBalance;

    // asset => vault => balance (underlying token units)
    mapping(address => mapping(address => uint256)) private _balances;

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setRevertWithdraw(bool revert_) external {
        shouldRevertWithdraw = revert_;
    }

    function setRevertGetBalance(bool revert_) external {
        shouldRevertGetBalance = revert_;
    }

    // -------------------------------------------------------------------------
    // IAssetAdapter
    // -------------------------------------------------------------------------

    function deposit(address asset, uint256 amount) external override returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        _balances[asset][msg.sender] += amount;
        return amount;
    }

    function withdraw(address asset, uint256 amount, address recipient) external override returns (uint256) {
        if (shouldRevertWithdraw) revert("MockAssetAdapter: withdrawal failed (Aave DoS)");
        _balances[asset][msg.sender] -= amount;
        IERC20(asset).transfer(recipient, amount);
        return amount;
    }

    function getBalance(address asset, address owner) external view override returns (uint256) {
        if (shouldRevertGetBalance) revert("MockAssetAdapter: getBalance failed");
        return _balances[asset][owner];
    }

    function claimRewards(address) external pure override returns (address, uint256) {
        return (address(0), 0);
    }
}
