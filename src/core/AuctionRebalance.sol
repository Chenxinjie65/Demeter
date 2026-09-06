// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IAuctionRebalance} from "src/interfaces/IAuctionRebalance.sol";
import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {ITwapOracle} from "src/interfaces/ITwapOracle.sol";
import {AuctionMath} from "src/libraries/AuctionMath.sol";
import {OracleGuard} from "src/libraries/OracleGuard.sol";
import {ProportionalMath} from "src/libraries/ProportionalMath.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";

/**
 * @title AuctionRebalance
 * @notice Permissionless bounded rebalance plans and direct Dutch-auction bids.
 * @custom:security-contact security@demeter.protocol
 */
contract AuctionRebalance is IAuctionRebalance, ReentrancyGuardTransient {
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    IDemeterManager public immutable manager;
    IIndexPolicy public immutable policy;
    IAssetRegistry public immutable registry;
    ITwapOracle public immutable twapOracle;

    bool public paused;
    mapping(bytes32 poolId => RebalanceTypes.RebalancePlan plan) private _plans;
    mapping(bytes32 poolId => RebalanceTypes.Auction auction) private _auctions;
    mapping(bytes32 poolId => uint64 nonce) private _nextPlanNonce;
    mapping(bytes32 poolId => uint64 nonce) private _nextAuctionNonce;
    mapping(bytes32 poolId => uint64 timestamp) private _lastPlanAt;
    mapping(bytes32 poolId => uint64 version) private _lastPlannedPolicyVersion;

    error AuctionRebalance__Unauthorized(address caller);

    constructor(address manager_, address policy_, address registry_, address twapOracle_) {
        _validateDependency(manager_, "manager");
        _validateDependency(policy_, "policy");
        _validateDependency(registry_, "registry");
        _validateDependency(twapOracle_, "twapOracle");
        manager = IDemeterManager(manager_);
        policy = IIndexPolicy(policy_);
        registry = IAssetRegistry(registry_);
        twapOracle = ITwapOracle(twapOracle_);
    }

    /*//////////////////////////////////////////////////////////////
                          USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAuctionRebalance
    function startPlan(bytes32 poolId) external nonReentrant returns (uint64 planNonce) {
        _requireNotPaused();
        _requireManagerIdle(poolId);
        if (_isActive(_plans[poolId].state)) revert V2Errors.V2Errors__PlanAlreadyActive(poolId);
        if (!policy.isPolicyActive(poolId)) revert V2Errors.V2Errors__PolicyNotActive(0, block.timestamp);

        RebalanceTypes.PolicyVersion memory activePolicy = policy.activePolicy(poolId);
        uint64 lastPlan = _lastPlanAt[poolId];
        if (lastPlan != 0 && block.timestamp < uint256(lastPlan) + activePolicy.minPlanInterval) {
            revert V2Errors.V2Errors__InvalidTime("minPlanInterval", block.timestamp);
        }

        address[] memory assets = manager.getPoolAssets(poolId);
        uint256 supply = IERC20(manager.poolShare(poolId)).totalSupply();
        uint256[] memory prices = new uint256[](assets.length);
        uint256[] memory targets = new uint256[](assets.length);
        uint256[] memory current = new uint256[](assets.length);
        uint256[] memory deltaValues = new uint256[](assets.length);
        uint64[] memory configVersions = new uint64[](assets.length);
        uint256 portfolioValueWad;

        for (uint256 i; i < assets.length; ++i) {
            OracleGuard.ValidatedPrice memory validated =
                OracleGuard.validatedPrice(registry, twapOracle, assets[i], activePolicy.maxOracleDeviationBps);
            prices[i] = validated.chainlinkUsdWad;
            configVersions[i] = validated.assetConfigVersion;
            current[i] = manager.reserveOf(poolId, assets[i]);
            PoolTypes.AssetConfig memory assetConfig = registry.getAssetConfig(assets[i]);
            portfolioValueWad += ProportionalMath.valueWad(current[i], prices[i], assetConfig.decimals);
        }
        if (portfolioValueWad == 0) revert V2Errors.V2Errors__NoRebalanceNeeded(poolId);

        uint256 totalAbsoluteDeltaValueWad;
        uint256 driftBps;
        for (uint256 i; i < assets.length; ++i) {
            PoolTypes.AssetConfig memory assetConfig = registry.getAssetConfig(assets[i]);
            uint256 currentValue = ProportionalMath.valueWad(current[i], prices[i], assetConfig.decimals);
            uint256 actualWeight = Math.mulDiv(currentValue, BPS, portfolioValueWad);
            driftBps += actualWeight > activePolicy.weightsBps[i]
                ? actualWeight - activePolicy.weightsBps[i]
                : activePolicy.weightsBps[i] - actualWeight;

            uint256 desiredTarget = ProportionalMath.targetRawAmount(
                portfolioValueWad, activePolicy.weightsBps[i], prices[i], assetConfig.decimals
            );
            targets[i] = desiredTarget;
            uint256 deltaRaw = current[i] > desiredTarget ? current[i] - desiredTarget : desiredTarget - current[i];
            deltaValues[i] = ProportionalMath.valueWadUp(deltaRaw, prices[i], assetConfig.decimals);
            totalAbsoluteDeltaValueWad += deltaValues[i];
        }
        driftBps /= 2;
        bool calendarDue =
            block.timestamp >= activePolicy.epoch && _lastPlannedPolicyVersion[poolId] < activePolicy.version;
        if (!calendarDue && driftBps < activePolicy.triggerBps) {
            revert V2Errors.V2Errors__RebalanceNotEligible(poolId, driftBps);
        }
        if (totalAbsoluteDeltaValueWad == 0) revert V2Errors.V2Errors__NoRebalanceNeeded(poolId);

        uint256 desiredTurnoverWad = totalAbsoluteDeltaValueWad / 2;
        uint256 maximumTurnoverWad =
            Math.mulDiv(portfolioValueWad, activePolicy.maxTurnoverBps, BPS, Math.Rounding.Floor);
        uint256 maximumAssetDeltaWad =
            Math.mulDiv(portfolioValueWad, activePolicy.maxAssetAdjustmentBps, BPS, Math.Rounding.Floor);
        uint256 scaleWad = WAD;
        if (desiredTurnoverWad > maximumTurnoverWad) {
            scaleWad = Math.mulDiv(maximumTurnoverWad, WAD, desiredTurnoverWad, Math.Rounding.Floor);
        }
        for (uint256 i; i < targets.length; ++i) {
            if (deltaValues[i] > maximumAssetDeltaWad) {
                scaleWad =
                    Math.min(scaleWad, Math.mulDiv(maximumAssetDeltaWad, WAD, deltaValues[i], Math.Rounding.Floor));
            }
        }

        uint256 plannedSellValueWad;
        uint256 plannedBuyValueWad;
        for (uint256 i; i < targets.length; ++i) {
            uint256 desiredDelta = current[i] > targets[i] ? current[i] - targets[i] : targets[i] - current[i];
            uint256 scaledDelta = Math.mulDiv(desiredDelta, scaleWad, WAD, Math.Rounding.Floor);
            targets[i] = current[i] > targets[i] ? current[i] - scaledDelta : current[i] + scaledDelta;
            PoolTypes.AssetConfig memory assetConfig = registry.getAssetConfig(assets[i]);
            uint256 scaledValue = ProportionalMath.valueWad(scaledDelta, prices[i], assetConfig.decimals);
            if (current[i] > targets[i]) plannedSellValueWad += scaledValue;
            else plannedBuyValueWad += scaledValue;
        }
        uint256 turnoverBudgetWad = Math.min(maximumTurnoverWad, Math.min(plannedSellValueWad, plannedBuyValueWad));
        if (turnoverBudgetWad == 0) revert V2Errors.V2Errors__NoRebalanceNeeded(poolId);

        RebalanceTypes.RebalancePlan storage stored = _plans[poolId];
        planNonce = ++_nextPlanNonce[poolId];
        stored.nonce = planNonce;
        stored.policyVersion = activePolicy.version;
        stored.createdAt = uint64(block.timestamp);
        stored.expiresAt = uint64(block.timestamp + activePolicy.planDuration);
        stored.referenceValueWad = portfolioValueWad;
        stored.referenceShareSupply = supply;
        stored.turnoverBudgetWad = turnoverBudgetWad;
        stored.turnoverConsumedWad = 0;
        stored.policyConfigVersion = policy.getGlobalBounds().configVersion;
        stored.policyFamilyVersion = policy.familyVersion(activePolicy.policyFamilyId);
        stored.oracleConfigVersion = registry.oracleConfigVersion();
        stored.state = RebalanceTypes.RebalanceState.PLANNED;
        delete stored.targetRawAmounts;
        delete stored.referencePricesWad;
        delete stored.configVersions;
        for (uint256 i; i < targets.length; ++i) {
            stored.targetRawAmounts.push(targets[i]);
            stored.referencePricesWad.push(prices[i]);
            stored.configVersions.push(configVersions[i]);
        }
        _lastPlanAt[poolId] = uint64(block.timestamp);
        _lastPlannedPolicyVersion[poolId] = activePolicy.version;
        emit PlanStarted(
            poolId, planNonce, activePolicy.version, portfolioValueWad, turnoverBudgetWad, stored.expiresAt
        );
    }

    /// @inheritdoc IAuctionRebalance
    function openAuction(bytes32 poolId, address sellToken, address buyToken)
        external
        nonReentrant
        returns (uint64 auctionNonce)
    {
        _requireNotPaused();
        RebalanceTypes.RebalancePlan storage plan = _requirePlanned(poolId);
        _requirePlanValid(poolId, plan);
        if (!manager.validatePoolForAuction(poolId, sellToken, buyToken)) {
            revert V2Errors.V2Errors__InvalidConfig("auctionPair");
        }

        (uint256 sellIndex, uint256 buyIndex) = _assetIndexes(poolId, sellToken, buyToken);
        uint256 supply = IERC20(manager.poolShare(poolId)).totalSupply();
        uint256 sellTarget =
            Math.mulDiv(plan.targetRawAmounts[sellIndex], supply, plan.referenceShareSupply, Math.Rounding.Floor);
        uint256 buyTarget =
            Math.mulDiv(plan.targetRawAmounts[buyIndex], supply, plan.referenceShareSupply, Math.Rounding.Floor);
        uint256 sellReserve = manager.reserveOf(poolId, sellToken);
        uint256 buyReserve = manager.reserveOf(poolId, buyToken);
        if (sellReserve <= sellTarget) revert V2Errors.V2Errors__NoSurplus(sellToken);
        if (buyReserve >= buyTarget) revert V2Errors.V2Errors__NoDeficit(buyToken);

        RebalanceTypes.PolicyVersion memory activePolicy = policy.policy(poolId, plan.policyVersion);
        if (block.timestamp + activePolicy.auctionDuration > plan.expiresAt) {
            revert V2Errors.V2Errors__InvalidTime("auctionPastPlan", plan.expiresAt);
        }
        _validateAuctionOracles(plan, activePolicy, sellIndex, buyIndex, sellToken, buyToken);
        uint256 referencePairPrice =
            AuctionMath.pairPriceWad(plan.referencePricesWad[sellIndex], plan.referencePricesWad[buyIndex]);
        PoolTypes.AssetConfig memory sellConfig = registry.getAssetConfig(sellToken);
        uint256 sellLimit =
            Math.min(sellReserve - sellTarget, _turnoverCapacityRaw(plan, sellIndex, sellConfig.decimals));
        if (sellLimit == 0) revert V2Errors.V2Errors__NoTurnoverCapacity(poolId);
        auctionNonce = ++_nextAuctionNonce[poolId];
        _auctions[poolId] = RebalanceTypes.Auction({
            nonce: auctionNonce,
            planNonce: plan.nonce,
            sellToken: sellToken,
            buyToken: buyToken,
            sellLimit: sellLimit,
            buyLimit: buyTarget - buyReserve,
            startPriceWad: AuctionMath.startPrice(referencePairPrice, activePolicy.startPremiumBps),
            endPriceWad: AuctionMath.endPrice(referencePairPrice, activePolicy.maxDiscountBps),
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + activePolicy.auctionDuration),
            sellFilled: 0,
            buyReceived: 0,
            active: true
        });
        plan.state = RebalanceTypes.RebalanceState.AUCTION_ACTIVE;
        RebalanceTypes.Auction storage opened = _auctions[poolId];
        emit AuctionOpened(
            poolId,
            auctionNonce,
            sellToken,
            buyToken,
            opened.sellLimit,
            opened.buyLimit,
            opened.startPriceWad,
            opened.endPriceWad,
            opened.startTime,
            opened.endTime
        );
    }

    /// @inheritdoc IAuctionRebalance
    function bid(RebalanceTypes.BidParams calldata params) external nonReentrant returns (uint256 buyAmount) {
        if (params.receiver == address(0)) revert V2Errors.V2Errors__InvalidRecipient(address(0));
        RebalanceTypes.RebalancePlan storage plan = _plans[params.poolId];
        uint256 turnover;
        uint16 destinationBps;
        (buyAmount, turnover, destinationBps) = _quoteBid(params.poolId, params.auctionNonce, params.sellAmount);
        if (buyAmount > params.maxBuyAmount) {
            revert V2Errors.V2Errors__PriceTooLow(params.maxBuyAmount, buyAmount);
        }
        RebalanceTypes.Auction storage active = _auctions[params.poolId];
        manager.settleAuctionBid(
            params.poolId,
            active.nonce,
            active.sellToken,
            active.buyToken,
            params.sellAmount,
            buyAmount,
            msg.sender,
            params.receiver
        );
        if (!(active.active && plan.state == RebalanceTypes.RebalanceState.AUCTION_ACTIVE)) {
            revert V2Errors.V2Errors__AuctionNotActive(params.poolId, params.auctionNonce);
        }
        // _quoteBid proves each increment is bounded by the frozen lot and budget.
        unchecked {
            active.sellFilled += params.sellAmount;
            active.buyReceived += buyAmount;
            plan.turnoverConsumedWad += turnover;
        }
        if (_destinationReached(params.poolId, plan, destinationBps)) {
            active.active = false;
            plan.state = RebalanceTypes.RebalanceState.SETTLED;
            emit PlanFinalized(params.poolId, plan.nonce, "destination");
        } else if (plan.turnoverConsumedWad >= plan.turnoverBudgetWad) {
            active.active = false;
            plan.state = RebalanceTypes.RebalanceState.SETTLED;
            emit PlanFinalized(params.poolId, plan.nonce, "turnoverBudget");
        } else {
            (uint256 remainingSell, uint256 remainingBuy) = _liveAuctionCapacity(params.poolId, plan, active);
            if (remainingSell == 0 || remainingBuy == 0) {
                active.active = false;
                plan.state = RebalanceTypes.RebalanceState.PLANNED;
            }
        }
        emit AuctionBid(params.poolId, active.nonce, msg.sender, params.sellAmount, buyAmount, plan.turnoverConsumedWad);
    }

    /// @inheritdoc IAuctionRebalance
    function quoteBid(bytes32 poolId, uint64 auctionNonce, uint256 sellAmount)
        external
        view
        returns (uint256 buyAmount)
    {
        (buyAmount,,) = _quoteBid(poolId, auctionNonce, sellAmount);
    }

    /// @inheritdoc IAuctionRebalance
    // This path only mutates auction lifecycle state and makes no external call.
    function expireAuction(bytes32 poolId) external {
        RebalanceTypes.Auction storage active = _auctions[poolId];
        if (!active.active) revert V2Errors.V2Errors__AuctionNotActive(poolId, active.nonce);
        RebalanceTypes.RebalancePlan storage plan = _plans[poolId];
        if (!(plan.state == RebalanceTypes.RebalanceState.AUCTION_ACTIVE && active.planNonce == plan.nonce)) {
            active.active = false;
            emit AuctionCancelled(poolId, active.nonce, "stale");
            return;
        }
        if (block.timestamp <= active.endTime) {
            revert V2Errors.V2Errors__AuctionExpired(active.endTime, block.timestamp);
        }
        active.active = false;
        plan.state = block.timestamp > plan.expiresAt
            ? RebalanceTypes.RebalanceState.EXPIRED
            : RebalanceTypes.RebalanceState.PLANNED;
        emit AuctionCancelled(poolId, active.nonce, "expired");
    }

    /// @inheritdoc IAuctionRebalance
    function invalidatePlan(bytes32 poolId) external {
        _requireManagerIdle(poolId);
        RebalanceTypes.RebalancePlan storage plan = _plans[poolId];
        if (!_isActive(plan.state)) revert V2Errors.V2Errors__PlanInvalid(poolId);
        if (_isPlanValid(poolId, plan)) revert V2Errors.V2Errors__PlanStillValid(poolId);
        _auctions[poolId].active = false;
        plan.state = block.timestamp > plan.expiresAt
            ? RebalanceTypes.RebalanceState.EXPIRED
            : RebalanceTypes.RebalanceState.CANCELLED;
        emit PlanInvalidated(poolId, plan.nonce, "configuration");
    }

    /// @inheritdoc IAuctionRebalance
    function finalizePlan(bytes32 poolId) external {
        RebalanceTypes.RebalancePlan storage plan = _requirePlanned(poolId);
        _requirePlanValid(poolId, plan);
        RebalanceTypes.PolicyVersion memory activePolicy = policy.policy(poolId, plan.policyVersion);
        bytes32 reason;
        if (_destinationReached(poolId, plan, activePolicy.destinationBps)) {
            reason = "destination";
        } else if (plan.turnoverConsumedWad >= plan.turnoverBudgetWad) {
            reason = "turnoverBudget";
        } else if (!_hasRawSurplusAndDeficit(poolId, plan)) {
            reason = "noExecutablePair";
        } else {
            revert V2Errors.V2Errors__PlanStillValid(poolId);
        }
        plan.state = RebalanceTypes.RebalanceState.SETTLED;
        emit PlanFinalized(poolId, plan.nonce, reason);
    }

    /// @inheritdoc IAuctionRebalance
    // Guardian cancellation only writes local state; token-moving paths remain guarded.
    function cancelPlan(bytes32 poolId) external {
        _requireManagerIdle(poolId);
        _requireGuardian();
        RebalanceTypes.RebalancePlan storage plan = _plans[poolId];
        if (!_isActive(plan.state)) revert V2Errors.V2Errors__PlanInvalid(poolId);
        _auctions[poolId].active = false;
        plan.state = RebalanceTypes.RebalanceState.CANCELLED;
        emit PlanInvalidated(poolId, plan.nonce, "guardian");
    }

    /// @inheritdoc IAuctionRebalance
    function setPaused(bool paused_) external {
        bool timelockCaller = msg.sender == registry.timelock();
        if ((!paused_ && !timelockCaller) || (paused_ && msg.sender != registry.guardian() && !timelockCaller)) {
            revert AuctionRebalance__Unauthorized(msg.sender);
        }
        paused = paused_;
        if (paused_) emit Paused(msg.sender);
        else emit Unpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAuctionRebalance
    function getPlan(bytes32 poolId) external view returns (RebalanceTypes.RebalancePlan memory plan) {
        plan = _plans[poolId];
    }

    /// @inheritdoc IAuctionRebalance
    function getAuction(bytes32 poolId) external view returns (RebalanceTypes.Auction memory auction) {
        auction = _auctions[poolId];
    }

    /// @inheritdoc IAuctionRebalance
    function currentPrice(bytes32 poolId) public view returns (uint256 priceWad) {
        RebalanceTypes.Auction storage active = _auctions[poolId];
        priceWad = AuctionMath.currentPrice(
            active.startPriceWad, active.endPriceWad, active.startTime, active.endTime, block.timestamp
        );
    }

    /// @inheritdoc IAuctionRebalance
    function liveAuctionCapacity(bytes32 poolId) external view returns (uint256 sellAvailable, uint256 buyAvailable) {
        RebalanceTypes.Auction storage active = _auctions[poolId];
        if (!active.active) revert V2Errors.V2Errors__AuctionNotActive(poolId, active.nonce);
        RebalanceTypes.RebalancePlan storage plan = _plans[poolId];
        if (!(plan.state == RebalanceTypes.RebalanceState.AUCTION_ACTIVE && active.planNonce == plan.nonce)) {
            revert V2Errors.V2Errors__AuctionNotActive(poolId, active.nonce);
        }
        return _liveAuctionCapacity(poolId, _plans[poolId], active);
    }

    /// @inheritdoc IAuctionRebalance
    function isPoolLocked(bytes32 poolId) external view returns (bool) {
        RebalanceTypes.RebalancePlan storage plan = _plans[poolId];
        return _isActive(plan.state);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _requirePlanned(bytes32 poolId) internal view returns (RebalanceTypes.RebalancePlan storage plan) {
        plan = _plans[poolId];
        if (plan.state != RebalanceTypes.RebalanceState.PLANNED) {
            revert V2Errors.V2Errors__InvalidState(uint8(plan.state));
        }
        if (block.timestamp > plan.expiresAt) {
            revert V2Errors.V2Errors__PlanExpired(plan.expiresAt, block.timestamp);
        }
    }

    function _quoteBid(bytes32 poolId, uint64 auctionNonce, uint256 sellAmount)
        internal
        view
        returns (uint256 buyAmount, uint256 turnover, uint16 destinationBps)
    {
        _requireNotPaused();
        RebalanceTypes.RebalancePlan storage plan = _plans[poolId];
        _requirePlanValid(poolId, plan);
        RebalanceTypes.Auction storage active = _auctions[poolId];
        if (
            active.nonce != auctionNonce || active.planNonce != plan.nonce
                || !(active.active && plan.state == RebalanceTypes.RebalanceState.AUCTION_ACTIVE)
        ) {
            revert V2Errors.V2Errors__AuctionNotActive(poolId, auctionNonce);
        }
        if (block.timestamp > active.endTime) {
            revert V2Errors.V2Errors__AuctionExpired(active.endTime, block.timestamp);
        }

        (uint256 sellIndex, uint256 buyIndex) = _assetIndexes(poolId, active.sellToken, active.buyToken);
        RebalanceTypes.PolicyVersion memory activePolicy = policy.policy(poolId, plan.policyVersion);
        destinationBps = activePolicy.destinationBps;
        _validateAuctionOracles(plan, activePolicy, sellIndex, buyIndex, active.sellToken, active.buyToken);
        PoolTypes.AssetConfig memory sellConfig = registry.getAssetConfig(active.sellToken);
        PoolTypes.AssetConfig memory buyConfig = registry.getAssetConfig(active.buyToken);
        uint256 maxSellAmount;
        uint256 buyAvailable;
        (maxSellAmount, buyAvailable) = _liveAuctionCapacity(poolId, plan, active);
        uint256 priceWad = currentPrice(poolId);
        maxSellAmount = Math.min(
            maxSellAmount, AuctionMath.maxSellRaw(buyAvailable, priceWad, sellConfig.decimals, buyConfig.decimals)
        );
        if (sellAmount > maxSellAmount || sellAmount == 0) {
            revert V2Errors.V2Errors__BidTooLarge(sellAmount, maxSellAmount);
        }
        buyAmount = AuctionMath.paymentRaw(sellAmount, priceWad, sellConfig.decimals, buyConfig.decimals);
        turnover = ProportionalMath.valueWadUp(sellAmount, plan.referencePricesWad[sellIndex], sellConfig.decimals);
        if (plan.turnoverConsumedWad + turnover > plan.turnoverBudgetWad) {
            revert V2Errors.V2Errors__BidTooLarge(plan.turnoverConsumedWad + turnover, plan.turnoverBudgetWad);
        }
    }

    function _requirePlanValid(bytes32 poolId, RebalanceTypes.RebalancePlan storage plan) internal view {
        if (!_isPlanValid(poolId, plan)) revert V2Errors.V2Errors__PlanInvalid(poolId);
    }

    function _isPlanValid(bytes32 poolId, RebalanceTypes.RebalancePlan storage plan) internal view returns (bool) {
        if (!_isActive(plan.state) || block.timestamp > plan.expiresAt) return false;
        if (!policy.isPolicyActive(poolId)) return false;
        RebalanceTypes.PolicyVersion memory activePolicy = policy.activePolicy(poolId);
        if (activePolicy.version != plan.policyVersion) {
            return false;
        }
        if (policy.getGlobalBounds().configVersion != plan.policyConfigVersion) return false;
        if (policy.familyVersion(activePolicy.policyFamilyId) != plan.policyFamilyVersion) return false;
        if (registry.oracleConfigVersion() != plan.oracleConfigVersion) return false;
        address[] memory assets = manager.getPoolAssets(poolId);
        if (assets.length != plan.configVersions.length) return false;
        for (uint256 i; i < assets.length; ++i) {
            if (!registry.isAssetEnabled(assets[i])) return false;
            if (registry.assetConfigVersion(assets[i]) != plan.configVersions[i]) return false;
        }
        return true;
    }

    function _liveAuctionCapacity(
        bytes32 poolId,
        RebalanceTypes.RebalancePlan storage plan,
        RebalanceTypes.Auction storage active
    ) internal view returns (uint256 sellAvailable, uint256 buyAvailable) {
        (uint256 sellIndex, uint256 buyIndex) = _assetIndexes(poolId, active.sellToken, active.buyToken);
        uint256 supply = IERC20(manager.poolShare(poolId)).totalSupply();
        uint256 sellTarget =
            Math.mulDiv(plan.targetRawAmounts[sellIndex], supply, plan.referenceShareSupply, Math.Rounding.Floor);
        uint256 buyTarget =
            Math.mulDiv(plan.targetRawAmounts[buyIndex], supply, plan.referenceShareSupply, Math.Rounding.Floor);
        uint256 sellReserve = manager.reserveOf(poolId, active.sellToken);
        uint256 buyReserve = manager.reserveOf(poolId, active.buyToken);
        uint256 liveSellSurplus = sellReserve > sellTarget ? sellReserve - sellTarget : 0;
        uint256 liveBuyDeficit = buyTarget > buyReserve ? buyTarget - buyReserve : 0;
        sellAvailable = Math.min(active.sellLimit - active.sellFilled, liveSellSurplus);
        buyAvailable = Math.min(active.buyLimit - active.buyReceived, liveBuyDeficit);
        PoolTypes.AssetConfig memory sellConfig = registry.getAssetConfig(active.sellToken);
        sellAvailable = Math.min(sellAvailable, _turnoverCapacityRaw(plan, sellIndex, sellConfig.decimals));
    }

    function _turnoverCapacityRaw(RebalanceTypes.RebalancePlan storage plan, uint256 sellIndex, uint8 sellDecimals)
        internal
        view
        returns (uint256)
    {
        if (plan.turnoverConsumedWad >= plan.turnoverBudgetWad) return 0;
        return Math.mulDiv(
            plan.turnoverBudgetWad - plan.turnoverConsumedWad,
            10 ** uint256(sellDecimals),
            plan.referencePricesWad[sellIndex],
            Math.Rounding.Floor
        );
    }

    function _hasRawSurplusAndDeficit(bytes32 poolId, RebalanceTypes.RebalancePlan storage plan)
        internal
        view
        returns (bool)
    {
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256 supply = IERC20(manager.poolShare(poolId)).totalSupply();
        bool hasSurplus;
        bool hasDeficit;
        for (uint256 i; i < assets.length; ++i) {
            uint256 target =
                Math.mulDiv(plan.targetRawAmounts[i], supply, plan.referenceShareSupply, Math.Rounding.Floor);
            uint256 reserve = manager.reserveOf(poolId, assets[i]);
            if (reserve > target) {
                PoolTypes.AssetConfig memory config = registry.getAssetConfig(assets[i]);
                if (_turnoverCapacityRaw(plan, i, config.decimals) != 0) hasSurplus = true;
            } else if (reserve < target) {
                hasDeficit = true;
            }
            if (hasSurplus && hasDeficit) return true;
        }
        return false;
    }

    function _referenceMoveLimit(uint16 policyLimit, uint16 assetLimit) internal pure returns (uint16) {
        return policyLimit < assetLimit ? policyLimit : assetLimit;
    }

    function _validateAuctionOracles(
        RebalanceTypes.RebalancePlan storage plan,
        RebalanceTypes.PolicyVersion memory activePolicy,
        uint256 sellIndex,
        uint256 buyIndex,
        address sellToken,
        address buyToken
    ) internal view {
        OracleGuard.ValidatedPrice memory sellPrice =
            OracleGuard.validatedPrice(registry, twapOracle, sellToken, activePolicy.maxOracleDeviationBps);
        OracleGuard.ValidatedPrice memory buyPrice =
            OracleGuard.validatedPrice(registry, twapOracle, buyToken, activePolicy.maxOracleDeviationBps);
        PoolTypes.AssetConfig memory sellConfig = registry.getAssetConfig(sellToken);
        PoolTypes.AssetConfig memory buyConfig = registry.getAssetConfig(buyToken);
        uint16 moveLimit = _referenceMoveLimit(
            _referenceMoveLimit(activePolicy.maxReferenceMoveBps, sellConfig.maxReferenceMoveBps),
            buyConfig.maxReferenceMoveBps
        );
        uint16 deviationLimit = _referenceMoveLimit(
            _referenceMoveLimit(activePolicy.maxOracleDeviationBps, sellConfig.maxOracleDeviationBps),
            buyConfig.maxOracleDeviationBps
        );
        OracleGuard.validateSourceDivergence(
            AuctionMath.pairPriceWad(sellPrice.chainlinkUsdWad, buyPrice.chainlinkUsdWad),
            AuctionMath.pairPriceWad(sellPrice.twapUsdWad, buyPrice.twapUsdWad),
            deviationLimit
        );
        OracleGuard.validateReferenceMove(plan.referencePricesWad[sellIndex], sellPrice.chainlinkUsdWad, moveLimit);
        OracleGuard.validateReferenceMove(plan.referencePricesWad[buyIndex], buyPrice.chainlinkUsdWad, moveLimit);
        OracleGuard.validateReferenceMove(
            AuctionMath.pairPriceWad(plan.referencePricesWad[sellIndex], plan.referencePricesWad[buyIndex]),
            AuctionMath.pairPriceWad(sellPrice.chainlinkUsdWad, buyPrice.chainlinkUsdWad),
            moveLimit
        );
    }

    function _destinationReached(bytes32 poolId, RebalanceTypes.RebalancePlan storage plan, uint16 destinationBps)
        internal
        view
        returns (bool)
    {
        address[] memory assets = manager.getPoolAssets(poolId);
        uint256 totalValue;
        uint256[] memory values = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            PoolTypes.AssetConfig memory config = registry.getAssetConfig(assets[i]);
            values[i] = ProportionalMath.valueWad(
                manager.reserveOf(poolId, assets[i]), plan.referencePricesWad[i], config.decimals
            );
            totalValue += values[i];
        }
        if (totalValue == 0) return false;
        RebalanceTypes.PolicyVersion memory activePolicy = policy.policy(poolId, plan.policyVersion);
        uint256 drift;
        for (uint256 i; i < values.length; ++i) {
            uint256 weight = Math.mulDiv(values[i], BPS, totalValue);
            drift += weight > activePolicy.weightsBps[i]
                ? weight - activePolicy.weightsBps[i]
                : activePolicy.weightsBps[i] - weight;
        }
        return drift / 2 <= destinationBps;
    }

    function _assetIndexes(bytes32 poolId, address first, address second)
        internal
        view
        returns (uint256 firstIndex, uint256 secondIndex)
    {
        address[] memory assets = manager.getPoolAssets(poolId);
        bool firstFound;
        bool secondFound;
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == first) {
                firstIndex = i;
                firstFound = true;
            } else if (assets[i] == second) {
                secondIndex = i;
                secondFound = true;
            }
        }
        if (!firstFound) revert V2Errors.V2Errors__TokenNotInPool(first);
        if (!secondFound) revert V2Errors.V2Errors__TokenNotInPool(second);
    }

    function _isActive(RebalanceTypes.RebalanceState state) internal pure returns (bool) {
        return state > RebalanceTypes.RebalanceState.NONE && state < RebalanceTypes.RebalanceState.SETTLED;
    }

    function _requireNotPaused() internal view {
        if (paused) revert V2Errors.V2Errors__Paused();
    }

    function _requireManagerIdle(bytes32 poolId) private view {
        if (!manager.isPoolActive(poolId)) revert V2Errors.V2Errors__PoolLocked(poolId);
    }

    function _requireGuardian() internal view {
        if (msg.sender != registry.guardian()) revert AuctionRebalance__Unauthorized(msg.sender);
    }

    function _validateDependency(address target, bytes32 field) internal view {
        if (target == address(0) || target.code.length == 0) revert V2Errors.V2Errors__InvalidConfig(field);
    }
}
