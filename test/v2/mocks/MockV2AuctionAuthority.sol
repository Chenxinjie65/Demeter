// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {ITwapOracle} from "src/interfaces/ITwapOracle.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";

contract MockV2AuctionAuthority {
    IDemeterManager public manager;
    IIndexPolicy public policy;
    IAssetRegistry public registry;
    ITwapOracle public twapOracle;
    bool public paused;
    mapping(bytes32 poolId => bool locked) public isPoolLocked;
    mapping(bytes32 poolId => RebalanceTypes.Auction auction) private _auctions;
    mapping(bytes32 poolId => uint256 priceWad) private _prices;

    function configure(address manager_, address policy_, address registry_) external {
        manager = IDemeterManager(manager_);
        policy = IIndexPolicy(policy_);
        registry = IAssetRegistry(registry_);
        twapOracle = ITwapOracle(address(this));
    }

    function setLocked(bytes32 poolId, bool locked) external {
        isPoolLocked[poolId] = locked;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function hasActivePlan(bytes32 poolId) external view returns (bool) {
        return isPoolLocked[poolId];
    }

    function getAuction(bytes32 poolId) external view returns (RebalanceTypes.Auction memory) {
        return _auctions[poolId];
    }

    function currentPrice(bytes32 poolId) external view returns (uint256) {
        return _prices[poolId];
    }

    function liveAuctionCapacity(bytes32 poolId) external view returns (uint256 sellAvailable, uint256 buyAvailable) {
        RebalanceTypes.Auction storage active = _auctions[poolId];
        return (active.sellLimit - active.sellFilled, active.buyLimit - active.buyReceived);
    }

    function setAuction(bytes32 poolId, RebalanceTypes.Auction calldata auction, uint256 priceWad) external {
        _auctions[poolId] = auction;
        _prices[poolId] = priceWad;
        isPoolLocked[poolId] = auction.active;
    }

    function settle(
        IDemeterManager managerInterface,
        bytes32 poolId,
        uint64 auctionNonce,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        address bidder,
        address receiver
    ) external {
        managerInterface.settleAuctionBid(
            poolId, auctionNonce, sellToken, buyToken, sellAmount, buyAmount, bidder, receiver
        );
    }
}
