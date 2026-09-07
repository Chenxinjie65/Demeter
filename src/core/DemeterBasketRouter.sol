// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IDemeterBasketRouter} from "src/interfaces/IDemeterBasketRouter.sol";
import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";

/**
 * @title DemeterBasketRouter
 * @notice Stateless direct in-kind issue and redeem convenience layer.
 * @dev
 * This contract has no administrator, DEX integration, generic call surface,
 * permit path, ETH path, or access to auction settlement. It holds basket
 * assets only between a caller transfer and the same transaction's manager
 * issue call. Every manager allowance is exact and cleared after use.
 *
 * Unsolicited balances are refunded to the current caller at the start of its
 * route. They are never incorporated into an issue or treated as custody.
 * @custom:security-contact https://github.com/Chenxinjie65/Demeter/security/advisories/new
 */
contract DemeterBasketRouter is IDemeterBasketRouter, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IDemeterManager public immutable override manager;

    constructor(address manager_) {
        if (manager_ == address(0) || manager_.code.length == 0) {
            revert DemeterBasketRouter__InvalidManager(manager_);
        }
        manager = IDemeterManager(manager_);
    }

    /// @inheritdoc IDemeterBasketRouter
    function issue(PoolTypes.IssueParams calldata params) external nonReentrant returns (uint256[] memory amountsIn) {
        _checkDeadline(params.deadline);
        _checkReceiver(params.receiver);

        address[] memory assets = manager.getPoolAssets(params.poolId);
        uint256[] memory quotedAmounts = manager.quoteIssue(params.poolId, params.sharesOut);
        uint256 assetCount = assets.length;
        if (quotedAmounts.length != assetCount) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(assetCount, quotedAmounts.length);
        }
        if (params.maxAmountsIn.length != assetCount) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(assetCount, params.maxAmountsIn.length);
        }

        for (uint256 i; i < assetCount; ++i) {
            uint256 amount = quotedAmounts[i];
            if (amount > params.maxAmountsIn[i]) {
                revert DemeterBasketRouter__AmountInAboveMaximum(assets[i], amount, params.maxAmountsIn[i]);
            }
        }

        for (uint256 i; i < assetCount; ++i) {
            IERC20 token = IERC20(assets[i]);
            _refundUnsolicited(token, msg.sender);
            _pullExact(token, msg.sender, quotedAmounts[i]);
            token.forceApprove(address(manager), quotedAmounts[i]);
        }

        amountsIn = manager.issue(params);
        if (amountsIn.length != assetCount) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(assetCount, amountsIn.length);
        }
        for (uint256 i; i < assetCount; ++i) {
            if (amountsIn[i] != quotedAmounts[i]) {
                revert DemeterBasketRouter__QuoteMismatch(assets[i], quotedAmounts[i], amountsIn[i]);
            }
            IERC20 token = IERC20(assets[i]);
            token.forceApprove(address(manager), 0);
            _requireClean(token);
        }

        emit BasketIssued(params.poolId, msg.sender, params.receiver, params.sharesOut);
    }

    /// @inheritdoc IDemeterBasketRouter
    function redeem(PoolTypes.RedeemParams calldata params)
        external
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        _checkDeadline(params.deadline);
        _checkReceiver(params.receiver);
        if (params.owner != msg.sender) {
            revert DemeterBasketRouter__InvalidOwner(msg.sender, params.owner);
        }

        address[] memory assets = manager.getPoolAssets(params.poolId);
        uint256[] memory quotedAmounts = manager.quoteRedeem(params.poolId, params.sharesIn);
        uint256 assetCount = assets.length;
        if (quotedAmounts.length != assetCount) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(assetCount, quotedAmounts.length);
        }
        if (params.minAmountsOut.length != assetCount) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(assetCount, params.minAmountsOut.length);
        }

        for (uint256 i; i < assetCount; ++i) {
            if (quotedAmounts[i] < params.minAmountsOut[i]) {
                revert DemeterBasketRouter__AmountOutBelowMinimum(assets[i], quotedAmounts[i], params.minAmountsOut[i]);
            }
            _refundUnsolicited(IERC20(assets[i]), msg.sender);
        }

        address share = manager.poolShare(params.poolId);
        uint256 shareAllowance = IERC20(share).allowance(msg.sender, address(this));
        if (shareAllowance < params.sharesIn) {
            revert V2Errors.V2Errors__InsufficientAllowance(
                share, msg.sender, address(this), params.sharesIn, shareAllowance
            );
        }

        uint256[] memory receiverBalancesBefore = new uint256[](assetCount);
        for (uint256 i; i < assetCount; ++i) {
            receiverBalancesBefore[i] = IERC20(assets[i]).balanceOf(params.receiver);
        }

        amountsOut = manager.redeem(params);
        if (amountsOut.length != assetCount) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(assetCount, amountsOut.length);
        }
        for (uint256 i; i < assetCount; ++i) {
            if (amountsOut[i] != quotedAmounts[i]) {
                revert DemeterBasketRouter__QuoteMismatch(assets[i], quotedAmounts[i], amountsOut[i]);
            }
            IERC20 token = IERC20(assets[i]);
            uint256 received = token.balanceOf(params.receiver) - receiverBalancesBefore[i];
            if (received != amountsOut[i]) {
                revert V2Errors.V2Errors__ExactTransferMismatch(assets[i], amountsOut[i], received);
            }
            _requireClean(token);
        }

        emit BasketRedeemed(params.poolId, msg.sender, params.receiver, params.sharesIn);
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) {
            revert V2Errors.V2Errors__DeadlineExpired(deadline, block.timestamp);
        }
    }

    function _checkReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this)) {
            revert V2Errors.V2Errors__InvalidRecipient(receiver);
        }
    }

    function _pullExact(IERC20 token, address from, uint256 amount) private {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - balanceBefore;
        if (received != amount) {
            revert V2Errors.V2Errors__ExactTransferMismatch(address(token), amount, received);
        }
    }

    function _requireClean(IERC20 token) private view {
        uint256 balance = token.balanceOf(address(this));
        if (balance != 0) revert DemeterBasketRouter__ResidualBalance(address(token), balance);
        uint256 allowance = token.allowance(address(this), address(manager));
        if (allowance != 0) {
            revert DemeterBasketRouter__ResidualAllowance(address(token), allowance);
        }
    }

    function _refundUnsolicited(IERC20 token, address receiver) private {
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) return;
        uint256 receiverBefore = token.balanceOf(receiver);
        token.safeTransfer(receiver, balance);
        uint256 received = token.balanceOf(receiver) - receiverBefore;
        if (received != balance || token.balanceOf(address(this)) != 0) {
            revert V2Errors.V2Errors__ExactTransferMismatch(address(token), balance, received);
        }
    }
}
