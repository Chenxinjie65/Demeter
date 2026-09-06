// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";

/**
 * @title IDemeterManager
 * @notice Singleton custody, proportional claim, and auction settlement API.
 * @custom:security-contact security@demeter.protocol
 */
interface IDemeterManager {
    event PoolCreated(bytes32 indexed poolId, address indexed creator, address indexed share);
    event PoolBootstrapped(bytes32 indexed poolId, uint256 initialShareSupply);
    event Issued(bytes32 indexed poolId, address indexed caller, address indexed receiver, uint256 shares);
    event Redeemed(bytes32 indexed poolId, address indexed caller, address indexed receiver, uint256 shares);
    event AuctionAuthoritySet(address indexed authority);
    event IndexPolicySet(address indexed policy);
    event PoolClosed(bytes32 indexed poolId, address indexed owner);
    event PoolBootstrapExpired(bytes32 indexed poolId);

    /// @notice Create a permissionless pool from enabled, sorted assets and deploy its ERC-20 share.
    /// @dev Seed amounts and share supply use native token units and raw 18-decimal share units.
    function createPool(PoolTypes.CreatePoolParams calldata params) external returns (bytes32 poolId, address share);

    /// @notice Pull the committed seed basket from the recorded bootstrapper and mint initial shares.
    function bootstrap(bytes32 poolId) external;

    /// @notice Permanently expire an unbootstrapped pool after its bootstrap deadline.
    function expireBootstrap(bytes32 poolId) external;

    /// @notice Issue proportional shares, rounding each required input up.
    /// @param params Pool ID, 18-decimal share amount, receiver, deadline, and per-asset max inputs.
    function issue(PoolTypes.IssueParams calldata params) external returns (uint256[] memory amountsIn);

    /// @notice Redeem proportional shares, rounding each output down; full redemption closes the pool.
    /// @param params Pool ID, share owner, 18-decimal share amount, receiver, deadline, and per-asset minimums.
    function redeem(PoolTypes.RedeemParams calldata params) external returns (uint256[] memory amountsOut);

    /// @notice Settle one validated auction bid; callable only by the configured auction module.
    /// @dev Amounts use native token units and must satisfy the auction's current price and capacity.
    function settleAuctionBid(
        bytes32 poolId,
        uint64 auctionNonce,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        address bidder,
        address receiver
    ) external;

    /// @notice Set the auction module once, before any pool exists.
    function setAuctionRebalance(address authority) external;

    /// @notice Set the index-policy module once, before any pool exists.
    function setIndexPolicy(address policy) external;

    /// @notice Return the creator recorded for a pool.
    function poolCreator(bytes32 poolId) external view returns (address);

    /// @notice Return the ERC-20 share address for a pool.
    function poolShare(bytes32 poolId) external view returns (address);

    /// @notice Return the immutable, strictly sorted asset list for a pool.
    function getPoolAssets(bytes32 poolId) external view returns (address[] memory);

    /// @notice Return pool configuration and lifecycle flags.
    function getPoolConfig(bytes32 poolId) external view returns (PoolTypes.PoolConfig memory);

    /// @notice Return committed bootstrap seed amounts in pool asset order.
    function getSeedAmounts(bytes32 poolId) external view returns (uint256[] memory amounts);

    /// @notice Return a pool's recorded reserve in native token units.
    function reserveOf(bytes32 poolId, address asset) external view returns (uint256);

    /// @notice Return the aggregate recorded reserve for an asset across all pools.
    function accountedReserve(address asset) external view returns (uint256);

    /// @notice Return the one-time configured auction authority.
    function auctionRebalance() external view returns (address);

    /// @notice Return the one-time configured policy authority.
    function indexPolicy() external view returns (address);

    /// @notice Return the Manager's actual token balance for an asset.
    function tokenBalance(address asset) external view returns (uint256);

    /// @notice True for a live pool only while no Manager asset operation is executing.
    function isPoolActive(bytes32 poolId) external view returns (bool);

    /// @notice Exposes the Manager's transient operation guard to fixed protocol modules.
    function isOperationActive() external view returns (bool);

    /// @notice Return whether a pool has reached its terminal closed state.
    function isPoolClosed(bytes32 poolId) external view returns (bool);

    /// @notice Quote proportional issue inputs, rounded up per asset.
    function quoteIssue(bytes32 poolId, uint256 sharesOut) external view returns (uint256[] memory amountsIn);

    /// @notice Quote proportional redemption outputs, rounded down per asset.
    function quoteRedeem(bytes32 poolId, uint256 sharesIn) external view returns (uint256[] memory amountsOut);

    /// @notice Validate that an asset pair belongs to a live pool and is enabled.
    function validatePoolForAuction(bytes32 poolId, address sellToken, address buyToken)
        external
        view
        returns (bool valid);

    /// @notice Derive a creator-bound pool ID from immutable pool key fields.
    function derivePoolId(address creator, address[] calldata assets, bytes32 policyFamilyId, bytes32 creatorSalt)
        external
        view
        returns (bytes32 poolId);

    /// @notice Return the immutable asset registry dependency.
    function registry() external view returns (IAssetRegistry);

    /// @notice Return the governance timelock shared with the registry.
    function timelock() external view returns (address);
}
