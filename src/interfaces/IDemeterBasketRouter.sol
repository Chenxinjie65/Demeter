// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";

/**
 * @title IDemeterBasketRouter
 * @notice Stateless convenience wrappers for direct in-kind issue and redeem.
 * @custom:security-contact security@demeter.protocol
 */
interface IDemeterBasketRouter {
    event BasketIssued(bytes32 indexed poolId, address indexed payer, address indexed receiver, uint256 sharesOut);
    event BasketRedeemed(bytes32 indexed poolId, address indexed owner, address indexed receiver, uint256 sharesIn);

    error DemeterBasketRouter__InvalidManager(address manager);
    error DemeterBasketRouter__InvalidOwner(address caller, address owner);
    error DemeterBasketRouter__AmountInAboveMaximum(address asset, uint256 requiredAmount, uint256 maximumAmount);
    error DemeterBasketRouter__AmountOutBelowMinimum(address asset, uint256 actualAmount, uint256 minimumAmount);
    error DemeterBasketRouter__QuoteMismatch(address asset, uint256 quotedAmount, uint256 executedAmount);
    error DemeterBasketRouter__ResidualBalance(address asset, uint256 balance);
    error DemeterBasketRouter__ResidualAllowance(address asset, uint256 allowance);

    /// @notice Return the immutable Manager used by this stateless router.
    function manager() external view returns (IDemeterManager);

    /**
     * @notice Issue shares by supplying the exact proportional basket.
     * @dev Basket assets are pulled from the caller and never from the manager.
     */
    function issue(PoolTypes.IssueParams calldata params) external returns (uint256[] memory amountsIn);

    /**
     * @notice Redeem caller-owned shares for the proportional basket.
     * @dev The caller must approve this router to spend the share token. Basket
     * assets are transferred directly from the manager to `params.receiver`.
     */
    function redeem(PoolTypes.RedeemParams calldata params) external returns (uint256[] memory amountsOut);
}
