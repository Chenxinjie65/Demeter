// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {V2Validation} from "src/libraries/V2Validation.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";

/**
 * @title IndexPolicy
 * @notice Creator-published index policies constrained by timelocked global bounds.
 * @dev Governance never approves an individual pool policy. It controls only
 * global risk limits and the set of available policy families.
 * @custom:security-contact https://github.com/Chenxinjie65/Demeter/security/advisories/new
 */
contract IndexPolicy is IIndexPolicy {
    uint256 private constant BPS = 10_000;
    uint16 private constant MAX_ASSETS_HARD_CAP = 32;
    uint32 private constant MAX_DELAY_HARD_CAP = 365 days;
    uint32 private constant MIN_AUCTION_DURATION_HARD = 5 minutes;
    uint32 private constant MIN_POLICY_DELAY_HARD = 5 minutes;
    uint32 private constant MIN_PLAN_INTERVAL_HARD = 5 minutes;
    uint32 private constant MAX_PLAN_DURATION_HARD = 30 days;

    address public immutable timelock;
    IDemeterManager public immutable manager;

    RebalanceTypes.GlobalPolicyBounds private _globalBounds;
    mapping(bytes32 familyId => bool enabled) private _familyEnabled;
    mapping(bytes32 familyId => uint64 version) public override familyVersion;
    mapping(bytes32 poolId => uint64 version) private _activeVersion;
    mapping(bytes32 poolId => uint64 version) private _latestVersion;
    mapping(bytes32 poolId => uint64 version) public override pendingVersion;
    mapping(bytes32 poolId => mapping(uint64 version => RebalanceTypes.PolicyVersion policy)) private _policies;
    mapping(bytes32 poolId => mapping(uint64 version => address creator)) public override policyCreator;

    error IndexPolicy__Unauthorized(address caller);
    error IndexPolicy__ZeroAddress(bytes32 field);
    error IndexPolicy__InvalidBounds(bytes32 field, uint256 value);

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert IndexPolicy__Unauthorized(msg.sender);
        _;
    }

    constructor(address timelock_, address manager_, RebalanceTypes.GlobalPolicyBounds memory bounds_) {
        if (timelock_ == address(0)) revert IndexPolicy__ZeroAddress("timelock");
        if (manager_ == address(0)) revert IndexPolicy__ZeroAddress("manager");
        if (manager_.code.length == 0) revert V2Errors.V2Errors__InvalidConfig("manager");
        timelock = timelock_;
        manager = IDemeterManager(manager_);
        _setGlobalBounds(bounds_);
    }

    /*//////////////////////////////////////////////////////////////
                         GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIndexPolicy
    function setGlobalBounds(RebalanceTypes.GlobalPolicyBounds calldata bounds) external onlyTimelock {
        _setGlobalBounds(bounds);
    }

    /// @inheritdoc IIndexPolicy
    function setPolicyFamily(bytes32 familyId, bool enabled) external onlyTimelock {
        if (familyId == bytes32(0)) revert V2Errors.V2Errors__InvalidPolicyFamily(familyId);
        _familyEnabled[familyId] = enabled;
        unchecked {
            ++familyVersion[familyId];
        }
        emit PolicyFamilyUpdated(familyId, enabled);
    }

    /*//////////////////////////////////////////////////////////////
                          CREATOR FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIndexPolicy
    function publishPolicy(bytes32 poolId, RebalanceTypes.PolicyParams calldata params)
        external
        returns (uint64 version, bytes32 policyHash)
    {
        PoolTypes.PoolConfig memory pool = manager.getPoolConfig(poolId);
        if (pool.creator == address(0)) revert V2Errors.V2Errors__PoolNotFound(poolId);
        if (msg.sender != pool.creator) revert V2Errors.V2Errors__UnauthorizedCreator(msg.sender, pool.creator);
        if (pool.closed) revert V2Errors.V2Errors__PoolClosed(poolId);
        if (params.policyFamilyId != pool.policyFamilyId) {
            revert V2Errors.V2Errors__PolicyFamilyMismatch(pool.policyFamilyId, params.policyFamilyId);
        }
        if (!_familyEnabled[pool.policyFamilyId]) {
            revert V2Errors.V2Errors__PolicyFamilyDisabled(pool.policyFamilyId);
        }
        if (pendingVersion[poolId] != 0) {
            revert V2Errors.V2Errors__PendingPolicyExists(poolId, pendingVersion[poolId]);
        }

        if (pool.kind == PoolTypes.PoolKind.IMMUTABLE_INDEX && _latestVersion[poolId] != 0) {
            revert V2Errors.V2Errors__ImmutablePolicy(poolId);
        }
        version = _latestVersion[poolId] + 1;
        if (version > 1 && _activeVersion[poolId] == 0) {
            revert V2Errors.V2Errors__InitialPolicyRequired(poolId);
        }

        _validatePolicy(poolId, params, version);
        policyHash = _computePolicyHash(poolId, pool.creator, pool.kind, version, _globalBounds.configVersion, params);
        if (version == 1 && policyHash != pool.initialPolicyHash) {
            revert V2Errors.V2Errors__InitialPolicyHashMismatch(pool.initialPolicyHash, policyHash);
        }

        RebalanceTypes.PolicyVersion storage stored = _policies[poolId][version];
        stored.version = version;
        stored.policyHash = policyHash;
        stored.epoch = params.epoch;
        stored.effectiveAt = params.effectiveAt;
        stored.minPlanInterval = params.minPlanInterval;
        stored.planDuration = params.planDuration;
        stored.triggerBps = params.triggerBps;
        stored.destinationBps = params.destinationBps;
        stored.maxTurnoverBps = params.maxTurnoverBps;
        stored.maxAssetAdjustmentBps = params.maxAssetAdjustmentBps;
        stored.startPremiumBps = params.startPremiumBps;
        stored.maxDiscountBps = params.maxDiscountBps;
        stored.auctionDuration = params.auctionDuration;
        stored.maxOracleDeviationBps = params.maxOracleDeviationBps;
        stored.maxReferenceMoveBps = params.maxReferenceMoveBps;
        stored.weightsBps = params.weightsBps;
        stored.policyFamilyId = params.policyFamilyId;
        stored.configVersion = _globalBounds.configVersion;
        stored.familyVersion = familyVersion[params.policyFamilyId];
        policyCreator[poolId][version] = msg.sender;
        pendingVersion[poolId] = version;
        _latestVersion[poolId] = version;

        emit PolicyPublished(poolId, version, msg.sender, policyHash);
    }

    /// @inheritdoc IIndexPolicy
    function activatePolicy(bytes32 poolId) external {
        if (manager.isOperationActive()) revert V2Errors.V2Errors__PoolLocked(poolId);
        uint64 version = pendingVersion[poolId];
        if (version == 0) revert V2Errors.V2Errors__NoPendingPolicy(poolId);
        RebalanceTypes.PolicyVersion storage pending = _policies[poolId][version];
        if (block.timestamp < pending.effectiveAt) {
            revert V2Errors.V2Errors__PolicyNotActive(pending.effectiveAt, block.timestamp);
        }
        if (pending.configVersion != _globalBounds.configVersion) {
            revert V2Errors.V2Errors__ConfigVersionChanged(pending.configVersion, _globalBounds.configVersion);
        }
        uint64 currentFamilyVersion = familyVersion[pending.policyFamilyId];
        if (!_familyEnabled[pending.policyFamilyId] || pending.familyVersion != currentFamilyVersion) {
            revert V2Errors.V2Errors__PolicyFamilyDisabled(pending.policyFamilyId);
        }

        _activeVersion[poolId] = version;
        delete pendingVersion[poolId];
        emit PolicyActivated(poolId, version);
    }

    /// @inheritdoc IIndexPolicy
    function cancelPendingPolicy(bytes32 poolId) external {
        uint64 version = pendingVersion[poolId];
        if (version == 0) revert V2Errors.V2Errors__NoPendingPolicy(poolId);
        RebalanceTypes.PolicyVersion storage pending = _policies[poolId][version];
        address creator = manager.poolCreator(poolId);
        bool stale = pending.configVersion != _globalBounds.configVersion
            || pending.familyVersion != familyVersion[pending.policyFamilyId] || !_familyEnabled[pending.policyFamilyId];
        if (msg.sender != creator && !stale) {
            revert V2Errors.V2Errors__UnauthorizedCreator(msg.sender, creator);
        }
        delete pendingVersion[poolId];
        emit PendingPolicyCancelled(poolId, version, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIndexPolicy
    function activePolicy(bytes32 poolId) external view returns (RebalanceTypes.PolicyVersion memory policy_) {
        policy_ = _policies[poolId][_activeVersion[poolId]];
    }

    /// @inheritdoc IIndexPolicy
    function policy(bytes32 poolId, uint64 version)
        external
        view
        returns (RebalanceTypes.PolicyVersion memory policy_)
    {
        policy_ = _policies[poolId][version];
    }

    /// @inheritdoc IIndexPolicy
    function getGlobalBounds() external view returns (RebalanceTypes.GlobalPolicyBounds memory bounds) {
        bounds = _globalBounds;
    }

    /// @inheritdoc IIndexPolicy
    function isPolicyFamilyEnabled(bytes32 familyId) external view returns (bool) {
        return _familyEnabled[familyId];
    }

    /// @inheritdoc IIndexPolicy
    function isPolicyActive(bytes32 poolId) public view returns (bool) {
        RebalanceTypes.PolicyVersion storage active = _policies[poolId][_activeVersion[poolId]];
        return active.version != 0 && active.effectiveAt <= block.timestamp && _familyEnabled[active.policyFamilyId]
            && _isWithinCurrentBounds(active);
    }

    /// @inheritdoc IIndexPolicy
    function validatePoolCreation(
        bytes32,
        address creator,
        PoolTypes.PoolKind,
        bytes32 policyFamilyId,
        uint256 assetCount
    ) external view {
        if (creator == address(0)) revert V2Errors.V2Errors__ZeroAddress("creator");
        if (!_familyEnabled[policyFamilyId]) revert V2Errors.V2Errors__PolicyFamilyDisabled(policyFamilyId);
        if (assetCount < _globalBounds.minAssets || assetCount > _globalBounds.maxAssets) {
            revert V2Errors.V2Errors__InvalidConfig("assetCount");
        }
    }

    /// @inheritdoc IIndexPolicy
    function initialPolicyHash(bytes32 poolId) external view returns (bytes32 policyHash) {
        policyHash = _policies[poolId][1].policyHash;
    }

    /// @inheritdoc IIndexPolicy
    function computePolicyHash(bytes32 poolId, uint64 version, RebalanceTypes.PolicyParams calldata params)
        external
        view
        returns (bytes32 policyHash)
    {
        PoolTypes.PoolConfig memory pool = manager.getPoolConfig(poolId);
        policyHash = _computePolicyHash(poolId, pool.creator, pool.kind, version, _globalBounds.configVersion, params);
    }

    /// @inheritdoc IIndexPolicy
    function computeInitialPolicyHash(
        bytes32 poolId,
        address creator,
        PoolTypes.PoolKind kind,
        RebalanceTypes.PolicyParams calldata params
    ) external view returns (bytes32 policyHash) {
        policyHash = _computePolicyHash(poolId, creator, kind, 1, _globalBounds.configVersion, params);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setGlobalBounds(RebalanceTypes.GlobalPolicyBounds memory bounds) internal {
        if (bounds.minAssets < 2 || bounds.minAssets > bounds.maxAssets || bounds.maxAssets > MAX_ASSETS_HARD_CAP) {
            revert IndexPolicy__InvalidBounds("assets", bounds.maxAssets);
        }
        if (bounds.minWeightBps == 0 || bounds.minWeightBps > bounds.maxWeightBps || bounds.maxWeightBps > BPS) {
            revert IndexPolicy__InvalidBounds("weights", bounds.maxWeightBps);
        }
        if (
            bounds.minPolicyDelay < MIN_POLICY_DELAY_HARD || bounds.minPolicyDelay > bounds.maxPolicyDelay
                || bounds.maxPolicyDelay > MAX_DELAY_HARD_CAP
        ) revert IndexPolicy__InvalidBounds("policyDelay", bounds.maxPolicyDelay);
        if (
            bounds.minPlanInterval < MIN_PLAN_INTERVAL_HARD || bounds.maxPlanDuration == 0
                || bounds.maxPlanDuration > MAX_PLAN_DURATION_HARD
        ) {
            revert IndexPolicy__InvalidBounds("planTiming", bounds.maxPlanDuration);
        }
        if (
            bounds.maxTurnoverBps == 0 || bounds.maxTurnoverBps > BPS || bounds.maxAssetAdjustmentBps == 0
                || bounds.maxAssetAdjustmentBps > BPS || bounds.maxStartPremiumBps > BPS || bounds.maxDiscountBps >= BPS
                || bounds.maxOracleDeviationBps > BPS || bounds.maxReferenceMoveBps > BPS
        ) revert IndexPolicy__InvalidBounds("bps", BPS);
        if (
            bounds.minAuctionDuration < MIN_AUCTION_DURATION_HARD
                || bounds.minAuctionDuration > bounds.maxAuctionDuration || bounds.maxAuctionDuration > MAX_DELAY_HARD_CAP
        ) revert IndexPolicy__InvalidBounds("auctionDuration", bounds.maxAuctionDuration);

        bounds.configVersion = _globalBounds.configVersion + 1;
        _globalBounds = bounds;
        emit GlobalPolicyBoundsUpdated(keccak256(abi.encode(bounds)));
    }

    function _validatePolicy(bytes32 poolId, RebalanceTypes.PolicyParams calldata params, uint64 version)
        internal
        view
    {
        address[] memory assets = manager.getPoolAssets(poolId);
        V2Validation.validateWeights(params.weightsBps, assets.length);
        V2Validation.validateDestination(params.triggerBps, params.destinationBps);

        uint256 delay = params.effectiveAt > block.timestamp ? params.effectiveAt - block.timestamp : 0;
        if (delay < _globalBounds.minPolicyDelay || delay > _globalBounds.maxPolicyDelay) {
            revert V2Errors.V2Errors__PolicyNotDelayed(params.effectiveAt, block.timestamp);
        }
        if (params.minPlanInterval < _globalBounds.minPlanInterval) {
            revert V2Errors.V2Errors__InvalidTime("minPlanInterval", params.minPlanInterval);
        }
        if (params.planDuration < params.auctionDuration || params.planDuration > _globalBounds.maxPlanDuration) {
            revert V2Errors.V2Errors__InvalidTime("planDuration", params.planDuration);
        }
        if (
            params.maxTurnoverBps == 0 || params.maxTurnoverBps > _globalBounds.maxTurnoverBps
                || params.maxAssetAdjustmentBps == 0 || params.maxAssetAdjustmentBps > _globalBounds.maxAssetAdjustmentBps
                || params.startPremiumBps > _globalBounds.maxStartPremiumBps
                || params.maxDiscountBps > _globalBounds.maxDiscountBps
                || params.maxOracleDeviationBps > _globalBounds.maxOracleDeviationBps
                || params.maxReferenceMoveBps > _globalBounds.maxReferenceMoveBps
        ) revert V2Errors.V2Errors__InvalidConfig("policyBps");
        if (
            params.auctionDuration < _globalBounds.minAuctionDuration
                || params.auctionDuration > _globalBounds.maxAuctionDuration
        ) revert V2Errors.V2Errors__InvalidTime("auctionDuration", params.auctionDuration);

        for (uint256 i; i < params.weightsBps.length; ++i) {
            if (params.weightsBps[i] < _globalBounds.minWeightBps || params.weightsBps[i] > _globalBounds.maxWeightBps)
            {
                revert V2Errors.V2Errors__InvalidBps("weightBps", params.weightsBps[i]);
            }
        }

        if (version > 1) {
            uint64 active = _activeVersion[poolId];
            uint64 previousEpoch = _policies[poolId][active].epoch;
            if (params.epoch <= previousEpoch) revert V2Errors.V2Errors__InvalidEpoch(previousEpoch, params.epoch);
        }
    }

    function _computePolicyHash(
        bytes32 poolId,
        address creator,
        PoolTypes.PoolKind kind,
        uint64 version,
        uint64 configVersion,
        RebalanceTypes.PolicyParams calldata params
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, creator, kind, version, configVersion, params));
    }

    function _isWithinCurrentBounds(RebalanceTypes.PolicyVersion storage stored) internal view returns (bool) {
        uint256 length = stored.weightsBps.length;
        if (length < _globalBounds.minAssets || length > _globalBounds.maxAssets) return false;
        if (stored.triggerBps == 0 || stored.destinationBps >= stored.triggerBps) return false;
        if (stored.minPlanInterval < _globalBounds.minPlanInterval) return false;
        if (stored.planDuration < stored.auctionDuration || stored.planDuration > _globalBounds.maxPlanDuration) {
            return false;
        }
        if (stored.maxTurnoverBps == 0 || stored.maxTurnoverBps > _globalBounds.maxTurnoverBps) return false;
        if (
            stored.maxAssetAdjustmentBps == 0 || stored.maxAssetAdjustmentBps > _globalBounds.maxAssetAdjustmentBps
                || stored.startPremiumBps > _globalBounds.maxStartPremiumBps
                || stored.maxDiscountBps > _globalBounds.maxDiscountBps
                || stored.maxOracleDeviationBps > _globalBounds.maxOracleDeviationBps
                || stored.maxReferenceMoveBps > _globalBounds.maxReferenceMoveBps
        ) return false;
        if (
            stored.auctionDuration < _globalBounds.minAuctionDuration
                || stored.auctionDuration > _globalBounds.maxAuctionDuration
        ) return false;

        uint256 sum;
        for (uint256 i; i < length; ++i) {
            uint256 weight = stored.weightsBps[i];
            if (weight < _globalBounds.minWeightBps || weight > _globalBounds.maxWeightBps) return false;
            sum += weight;
        }
        return sum == BPS;
    }
}
