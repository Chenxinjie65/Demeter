// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {RebalanceTypes} from "src/types/RebalanceTypes.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {ITwapOracle} from "src/interfaces/ITwapOracle.sol";

/**
 * @title IAuctionRebalance
 * @notice Public plan, auction, and direct-bid interface.
 * @custom:security-contact security@demeter.protocol
 */
interface IAuctionRebalance {
    event PlanStarted(
        bytes32 indexed poolId,
        uint64 indexed planNonce,
        uint64 policyVersion,
        uint256 referenceValueWad,
        uint256 turnoverBudgetWad,
        uint64 expiresAt
    );
    event AuctionOpened(
        bytes32 indexed poolId,
        uint64 indexed auctionNonce,
        address sellToken,
        address buyToken,
        uint256 sellLimit,
        uint256 buyLimit,
        uint256 startPriceWad,
        uint256 endPriceWad,
        uint64 startTime,
        uint64 endTime
    );
    event AuctionBid(
        bytes32 indexed poolId,
        uint64 indexed auctionNonce,
        address indexed bidder,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 turnoverConsumedWad
    );
    event AuctionCancelled(bytes32 indexed poolId, uint64 indexed auctionNonce, bytes32 reason);
    event PlanInvalidated(bytes32 indexed poolId, uint64 indexed planNonce, bytes32 reason);
    event PlanFinalized(bytes32 indexed poolId, uint64 indexed planNonce, bytes32 reason);
    event Paused(address indexed guardian);
    event Unpaused(address indexed caller);

    /// @notice Start an eligible plan from current reserves and validated oracle prices.
    function startPlan(bytes32 poolId) external returns (uint64 planNonce);

    /// @notice Open one surplus-to-deficit Dutch auction for a planned pool.
    function openAuction(bytes32 poolId, address sellToken, address buyToken) external returns (uint64 auctionNonce);

    /// @notice Execute a direct bid using native token amounts and a maximum payment.
    function bid(RebalanceTypes.BidParams calldata params) external returns (uint256 buyAmount);

    /// @notice Return the exact payment for a valid same-block bid amount.
    /// @param poolId Pool whose auction is queried.
    /// @param auctionNonce Active auction nonce.
    /// @param sellAmount Native-unit amount of the surplus token to sell.
    /// @return buyAmount Native-unit payment required from the bidder, rounded up.
    function quoteBid(bytes32 poolId, uint64 auctionNonce, uint256 sellAmount)
        external
        view
        returns (uint256 buyAmount);

    /// @notice Cancel an active plan as the guardian; this moves no tokens.
    function cancelPlan(bytes32 poolId) external;

    /// @notice Return the full stored plan, including raw targets and version pins.
    function getPlan(bytes32 poolId) external view returns (RebalanceTypes.RebalancePlan memory plan);

    /// @notice Return the full stored auction and fill counters.
    function getAuction(bytes32 poolId) external view returns (RebalanceTypes.Auction memory auction);

    /// @notice Return the current bounded Dutch-curve price in WAD quote units.
    function currentPrice(bytes32 poolId) external view returns (uint256 priceWad);

    /// @notice Return remaining live sell and buy capacity in native units.
    function liveAuctionCapacity(bytes32 poolId) external view returns (uint256 sellAvailable, uint256 buyAvailable);

    /// @notice Return whether a plan lifecycle state currently locks the pool.
    function isPoolLocked(bytes32 poolId) external view returns (bool);

    /// @notice Invalidate a plan whose pinned configuration or validity has expired.
    function invalidatePlan(bytes32 poolId) external;

    /// @notice Mark a plan settled when its destination, budget, or executable work is complete.
    function finalizePlan(bytes32 poolId) external;

    /// @notice Explicitly clean up an ended auction and release its lifecycle lock.
    function expireAuction(bytes32 poolId) external;

    /// @notice Pause or unpause non-redemption auction paths; only guardian/timelock may call.
    function setPaused(bool paused_) external;

    function paused() external view returns (bool);

    function manager() external view returns (IDemeterManager);

    function policy() external view returns (IIndexPolicy);

    function registry() external view returns (IAssetRegistry);

    function twapOracle() external view returns (ITwapOracle);
}
