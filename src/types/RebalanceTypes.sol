// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title RebalanceTypes
 * @notice Policy, plan, and auction data structures for Demeter V2.
 * @custom:security-contact https://github.com/Chenxinjie65/Demeter/security/advisories/new
 */
library RebalanceTypes {
    /// @notice Lifecycle of a policy-driven rebalance.
    enum RebalanceState {
        NONE,
        PLANNED,
        AUCTION_ACTIVE,
        SETTLED,
        EXPIRED,
        CANCELLED
    }

    /// @notice Policy inputs submitted by a pool creator.
    struct PolicyParams {
        uint16[] weightsBps;
        uint64 epoch;
        uint64 effectiveAt;
        uint32 minPlanInterval;
        uint32 planDuration;
        uint16 triggerBps;
        uint16 destinationBps;
        uint16 maxTurnoverBps;
        uint16 maxAssetAdjustmentBps;
        uint16 startPremiumBps;
        uint16 maxDiscountBps;
        uint32 auctionDuration;
        uint16 maxOracleDeviationBps;
        uint16 maxReferenceMoveBps;
        bytes32 policyFamilyId;
    }

    /// @notice Protocol-wide limits applied to every creator-submitted policy.
    struct GlobalPolicyBounds {
        uint16 minAssets;
        uint16 maxAssets;
        uint16 minWeightBps;
        uint16 maxWeightBps;
        uint32 minPolicyDelay;
        uint32 maxPolicyDelay;
        uint32 minPlanInterval;
        uint32 maxPlanDuration;
        uint16 maxTurnoverBps;
        uint16 maxAssetAdjustmentBps;
        uint16 maxStartPremiumBps;
        uint16 maxDiscountBps;
        uint32 minAuctionDuration;
        uint32 maxAuctionDuration;
        uint16 maxOracleDeviationBps;
        uint16 maxReferenceMoveBps;
        uint64 configVersion;
    }

    /// @notice Append-only policy version stored by IndexPolicy.
    struct PolicyVersion {
        uint64 version;
        bytes32 policyHash;
        uint64 epoch;
        uint64 effectiveAt;
        uint32 minPlanInterval;
        uint32 planDuration;
        uint16 triggerBps;
        uint16 destinationBps;
        uint16 maxTurnoverBps;
        uint16 maxAssetAdjustmentBps;
        uint16 startPremiumBps;
        uint16 maxDiscountBps;
        uint32 auctionDuration;
        uint16 maxOracleDeviationBps;
        uint16 maxReferenceMoveBps;
        uint16[] weightsBps;
        bytes32 policyFamilyId;
        uint64 configVersion;
        uint64 familyVersion;
    }

    /// @notice A price snapshot used to form a rebalance plan.
    struct PriceSnapshot {
        uint256[] chainlinkPricesWad;
        uint256[] twapPricesWad;
        uint64 capturedAt;
        uint64[] configVersions;
        uint64 oracleConfigVersion;
    }

    /// @notice A fixed risk envelope for one pool rebalance.
    struct RebalancePlan {
        uint64 nonce;
        uint64 policyVersion;
        uint64 createdAt;
        uint64 expiresAt;
        uint256 referenceValueWad;
        uint256 referenceShareSupply;
        uint256[] targetRawAmounts;
        uint256[] referencePricesWad;
        uint256 turnoverBudgetWad;
        uint256 turnoverConsumedWad;
        uint64[] configVersions;
        uint64 policyConfigVersion;
        uint64 policyFamilyVersion;
        uint64 oracleConfigVersion;
        RebalanceState state;
    }

    /// @notice One surplus-to-deficit auction.
    struct Auction {
        uint64 nonce;
        uint64 planNonce;
        address sellToken;
        address buyToken;
        uint256 sellLimit;
        uint256 buyLimit;
        uint256 startPriceWad;
        uint256 endPriceWad;
        uint64 startTime;
        uint64 endTime;
        uint256 sellFilled;
        uint256 buyReceived;
        bool active;
    }

    /// @notice User inputs for a direct auction bid.
    struct BidParams {
        bytes32 poolId;
        uint64 auctionNonce;
        uint256 sellAmount;
        uint256 maxBuyAmount;
        address receiver;
    }
}
