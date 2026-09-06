// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import {DemeterShare} from "src/core/DemeterShare.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IAuctionRebalance} from "src/interfaces/IAuctionRebalance.sol";
import {IDemeterManager} from "src/interfaces/IDemeterManager.sol";
import {IDemeterShare} from "src/interfaces/IDemeterShare.sol";
import {IIndexPolicy} from "src/interfaces/IIndexPolicy.sol";
import {AuctionMath} from "src/libraries/AuctionMath.sol";
import {PoolId} from "src/libraries/PoolId.sol";
import {ProportionalMath} from "src/libraries/ProportionalMath.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {V2Validation} from "src/libraries/V2Validation.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";
import {RebalanceTypes} from "src/types/RebalanceTypes.sol";

/**
 * @title DemeterManager
 * @notice Singleton custody and proportional reserve ledger for Demeter V2.
 * @dev The contract never prices issue or redeem through an oracle and never
 * grants token approvals to external venues.
 * @custom:security-contact security@demeter.protocol
 */
contract DemeterManager is IDemeterManager, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IAssetRegistry public immutable registry;
    address public immutable timelock;

    address public override auctionRebalance;
    address public override indexPolicy;

    uint256 private _poolCount;
    mapping(bytes32 poolId => PoolTypes.PoolConfig config) private _poolConfigs;
    mapping(bytes32 poolId => address[] assets) private _poolAssets;
    mapping(bytes32 poolId => uint256[] amounts) private _seedAmounts;
    mapping(bytes32 poolId => mapping(address asset => uint256 amount)) private _reserves;
    mapping(bytes32 poolId => mapping(address asset => uint256 indexPlusOne)) private _assetIndexPlusOne;
    mapping(address asset => uint256 amount) public override accountedReserve;

    error DemeterManager__Unauthorized(address caller);
    error DemeterManager__AlreadyConfigured(bytes32 field);
    error DemeterManager__ConfigurationLocked();
    error DemeterManager__DuplicatePool(bytes32 poolId);
    error DemeterManager__Slippage(address asset, uint256 limit, uint256 actual);
    error DemeterManager__InsufficientReserve(address asset, uint256 requested, uint256 available);

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert DemeterManager__Unauthorized(msg.sender);
        _;
    }

    constructor(address registry_, address timelock_) {
        if (registry_ == address(0)) revert V2Errors.V2Errors__ZeroAddress("registry");
        if (timelock_ == address(0)) revert V2Errors.V2Errors__ZeroAddress("timelock");
        if (registry_.code.length == 0) revert V2Errors.V2Errors__InvalidConfig("registry");
        registry = IAssetRegistry(registry_);
        if (registry.timelock() != timelock_) revert V2Errors.V2Errors__InvalidConfig("timelockMismatch");
        timelock = timelock_;
    }

    /*//////////////////////////////////////////////////////////////
                         CONFIGURATION FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDemeterManager
    function setAuctionRebalance(address authority) external onlyTimelock {
        if (_poolCount != 0) revert DemeterManager__ConfigurationLocked();
        if (auctionRebalance != address(0)) revert DemeterManager__AlreadyConfigured("auctionRebalance");
        if (authority == address(0) || authority.code.length == 0) {
            revert V2Errors.V2Errors__InvalidAuctionAuthority(authority);
        }
        IAuctionRebalance candidate = IAuctionRebalance(authority);
        if (
            address(candidate.manager()) != address(this) || address(candidate.policy()) != indexPolicy
                || address(candidate.registry()) != address(registry) || address(candidate.twapOracle()).code.length == 0
        ) revert V2Errors.V2Errors__InvalidAuctionAuthority(authority);
        auctionRebalance = authority;
        emit AuctionAuthoritySet(authority);
    }

    /// @inheritdoc IDemeterManager
    function setIndexPolicy(address policy) external onlyTimelock {
        if (_poolCount != 0) revert DemeterManager__ConfigurationLocked();
        if (indexPolicy != address(0)) revert DemeterManager__AlreadyConfigured("indexPolicy");
        if (policy == address(0) || policy.code.length == 0) revert V2Errors.V2Errors__InvalidConfig("policy");
        IIndexPolicy candidate = IIndexPolicy(policy);
        if (address(candidate.manager()) != address(this) || candidate.timelock() != timelock) {
            revert V2Errors.V2Errors__InvalidConfig("policyLinks");
        }
        indexPolicy = policy;
        emit IndexPolicySet(policy);
    }

    /*//////////////////////////////////////////////////////////////
                           POOL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDemeterManager
    function createPool(PoolTypes.CreatePoolParams calldata params)
        external
        nonReentrant
        returns (bytes32 poolId, address share)
    {
        if (auctionRebalance == address(0)) revert V2Errors.V2Errors__AuctionAuthorityNotSet();
        if (indexPolicy == address(0)) revert V2Errors.V2Errors__IndexPolicyNotSet();
        V2Validation.validateAssetList(params.assets);

        PoolTypes.GlobalPoolBounds memory bounds = registry.getGlobalPoolBounds();
        if (params.assets.length < bounds.minAssets || params.assets.length > bounds.maxAssets) {
            revert V2Errors.V2Errors__InvalidConfig("assetCount");
        }
        if (bytes(params.name).length == 0 || bytes(params.name).length > bounds.maxNameBytes) {
            revert V2Errors.V2Errors__InvalidMetadata("name");
        }
        if (bytes(params.symbol).length == 0 || bytes(params.symbol).length > bounds.maxSymbolBytes) {
            revert V2Errors.V2Errors__InvalidMetadata("symbol");
        }
        if (params.bootstrapper == address(0)) revert V2Errors.V2Errors__InvalidBootstrapper(address(0));
        if (params.initialShareRecipient == address(0)) revert V2Errors.V2Errors__InvalidRecipient(address(0));
        if (params.initialPolicyHash == bytes32(0)) revert V2Errors.V2Errors__InitialPolicyRequired(bytes32(0));
        if (params.policyFamilyId == bytes32(0)) {
            revert V2Errors.V2Errors__InvalidPolicyFamily(params.policyFamilyId);
        }
        if (
            params.initialShareSupply < bounds.minInitialShareSupply
                || params.initialShareSupply > bounds.maxInitialShareSupply
        ) revert V2Errors.V2Errors__InvalidInitialSupply(params.initialShareSupply);
        if (params.seedAmounts.length != params.assets.length) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(params.assets.length, params.seedAmounts.length);
        }
        uint256 bootstrapDuration =
            params.bootstrapDeadline > block.timestamp ? params.bootstrapDeadline - block.timestamp : 0;
        if (bootstrapDuration < bounds.minBootstrapDuration || bootstrapDuration > bounds.maxBootstrapDuration) {
            revert V2Errors.V2Errors__InvalidTime("bootstrapDeadline", params.bootstrapDeadline);
        }

        for (uint256 i; i < params.assets.length; ++i) {
            if (!registry.isAssetEnabled(params.assets[i])) revert V2Errors.V2Errors__AssetNotEnabled(params.assets[i]);
            if (params.seedAmounts[i] == 0) {
                revert V2Errors.V2Errors__InvalidBootstrapAmount(i, params.seedAmounts[i]);
            }
        }

        poolId = PoolId.derive(
            block.chainid, address(this), msg.sender, params.assets, params.policyFamilyId, params.creatorSalt
        );
        if (_poolConfigs[poolId].creator != address(0)) revert DemeterManager__DuplicatePool(poolId);

        IIndexPolicy(indexPolicy).validatePoolCreation(
            poolId, msg.sender, params.kind, params.policyFamilyId, params.assets.length
        );

        share = address(new DemeterShare{salt: poolId}(params.name, params.symbol, poolId, address(this)));
        bytes32 seedHash = keccak256(
            abi.encode(
                params.assets,
                params.seedAmounts,
                params.initialShareSupply,
                params.initialShareRecipient,
                params.bootstrapper,
                params.bootstrapDeadline,
                params.initialPolicyHash
            )
        );
        _poolConfigs[poolId] = PoolTypes.PoolConfig({
            creator: msg.sender,
            share: share,
            bootstrapper: params.bootstrapper,
            policyFamilyId: params.policyFamilyId,
            kind: params.kind,
            createdAt: uint64(block.timestamp),
            bootstrapDeadline: params.bootstrapDeadline,
            bootstrapped: false,
            closed: false,
            initialShareRecipient: params.initialShareRecipient,
            initialShareSupply: params.initialShareSupply,
            seedHash: seedHash,
            initialPolicyHash: params.initialPolicyHash,
            bootstrapExpired: false
        });
        for (uint256 i; i < params.assets.length; ++i) {
            _poolAssets[poolId].push(params.assets[i]);
            _seedAmounts[poolId].push(params.seedAmounts[i]);
            _assetIndexPlusOne[poolId][params.assets[i]] = i + 1;
        }
        unchecked {
            ++_poolCount;
        }
        emit PoolCreated(poolId, msg.sender, share);
    }

    /// @inheritdoc IDemeterManager
    function bootstrap(bytes32 poolId) external nonReentrant {
        PoolTypes.PoolConfig storage config = _requirePool(poolId);
        if (msg.sender != config.bootstrapper) {
            revert V2Errors.V2Errors__UnauthorizedBootstrapper(msg.sender, config.bootstrapper);
        }
        if (config.bootstrapped) revert V2Errors.V2Errors__PoolAlreadyBootstrapped(poolId);
        if (config.bootstrapExpired || block.timestamp > config.bootstrapDeadline) {
            revert V2Errors.V2Errors__BootstrapExpired(config.bootstrapDeadline, block.timestamp);
        }
        IIndexPolicy policy = IIndexPolicy(indexPolicy);
        if (!policy.isPolicyActive(poolId)) revert V2Errors.V2Errors__InitialPolicyRequired(poolId);
        RebalanceTypes.PolicyVersion memory activePolicy = policy.activePolicy(poolId);
        if (activePolicy.version != 1) {
            revert V2Errors.V2Errors__PolicyVersionMismatch(1, activePolicy.version);
        }
        if (activePolicy.policyHash != config.initialPolicyHash) {
            revert V2Errors.V2Errors__InitialPolicyHashMismatch(config.initialPolicyHash, activePolicy.policyHash);
        }

        address[] storage assets = _poolAssets[poolId];
        uint256[] storage seeds = _seedAmounts[poolId];
        for (uint256 i; i < assets.length; ++i) {
            if (!registry.isAssetEnabled(assets[i])) revert V2Errors.V2Errors__AssetNotEnabled(assets[i]);
        }
        for (uint256 i; i < assets.length; ++i) {
            _pullExact(assets[i], config.bootstrapper, seeds[i]);
            _reserves[poolId][assets[i]] = seeds[i];
            accountedReserve[assets[i]] += seeds[i];
        }
        config.bootstrapped = true;
        DemeterShare(config.share).mint(config.initialShareRecipient, config.initialShareSupply);
        emit PoolBootstrapped(poolId, config.initialShareSupply);
    }

    /// @inheritdoc IDemeterManager
    function expireBootstrap(bytes32 poolId) external {
        PoolTypes.PoolConfig storage config = _requirePool(poolId);
        if (config.bootstrapped) revert V2Errors.V2Errors__PoolAlreadyBootstrapped(poolId);
        if (block.timestamp <= config.bootstrapDeadline) {
            revert V2Errors.V2Errors__BootstrapNotReady(config.bootstrapDeadline, block.timestamp);
        }
        config.bootstrapExpired = true;
        emit PoolBootstrapExpired(poolId);
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDemeterManager
    function issue(PoolTypes.IssueParams calldata params) external nonReentrant returns (uint256[] memory amountsIn) {
        _checkDeadline(params.deadline);
        if (params.receiver == address(0)) revert V2Errors.V2Errors__InvalidRecipient(address(0));
        if (IAuctionRebalance(auctionRebalance).paused()) revert V2Errors.V2Errors__Paused();
        PoolTypes.PoolConfig storage config = _requireActivePool(params.poolId);
        if (_isLocked(params.poolId)) revert V2Errors.V2Errors__PoolLocked(params.poolId);
        if (!IIndexPolicy(indexPolicy).isPolicyActive(params.poolId)) {
            revert V2Errors.V2Errors__PolicyNotActive(0, block.timestamp);
        }

        amountsIn = _quoteIssue(params.poolId, params.sharesOut, config.share);
        if (params.maxAmountsIn.length != amountsIn.length) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(amountsIn.length, params.maxAmountsIn.length);
        }
        address[] storage assets = _poolAssets[params.poolId];
        for (uint256 i; i < assets.length; ++i) {
            if (!registry.isAssetEnabled(assets[i])) revert V2Errors.V2Errors__AssetNotEnabled(assets[i]);
            if (amountsIn[i] == 0) revert V2Errors.V2Errors__ZeroOutput(params.poolId);
            if (amountsIn[i] > params.maxAmountsIn[i]) {
                revert DemeterManager__Slippage(assets[i], params.maxAmountsIn[i], amountsIn[i]);
            }
            _pullExact(assets[i], msg.sender, amountsIn[i]);
            _reserves[params.poolId][assets[i]] += amountsIn[i];
            accountedReserve[assets[i]] += amountsIn[i];
        }
        DemeterShare(config.share).mint(params.receiver, params.sharesOut);
        emit Issued(params.poolId, msg.sender, params.receiver, params.sharesOut);
    }

    /// @inheritdoc IDemeterManager
    function redeem(PoolTypes.RedeemParams calldata params)
        external
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        _checkDeadline(params.deadline);
        if (params.owner == address(0)) revert V2Errors.V2Errors__ZeroAddress("owner");
        if (params.receiver == address(0) || params.receiver == address(this)) {
            revert V2Errors.V2Errors__InvalidRecipient(params.receiver);
        }
        PoolTypes.PoolConfig storage config = _requireActivePool(params.poolId);
        IDemeterShare share = IDemeterShare(config.share);
        uint256 supply = share.totalSupply();
        if (params.sharesIn == 0 || params.sharesIn > supply) {
            revert V2Errors.V2Errors__InvalidShareAmount(params.sharesIn);
        }
        bool fullRedemption = params.sharesIn == supply;
        if (fullRedemption && _isLocked(params.poolId)) revert V2Errors.V2Errors__PoolLocked(params.poolId);

        amountsOut = _quoteRedeem(params.poolId, params.sharesIn, supply, fullRedemption);
        if (params.minAmountsOut.length != amountsOut.length) {
            revert V2Errors.V2Errors__ArrayLengthMismatch(amountsOut.length, params.minAmountsOut.length);
        }
        address[] storage assets = _poolAssets[params.poolId];
        for (uint256 i; i < assets.length; ++i) {
            if (amountsOut[i] < params.minAmountsOut[i]) {
                revert DemeterManager__Slippage(assets[i], params.minAmountsOut[i], amountsOut[i]);
            }
            _reserves[params.poolId][assets[i]] -= amountsOut[i];
            accountedReserve[assets[i]] -= amountsOut[i];
        }
        DemeterShare(config.share).burnFrom(params.owner, msg.sender, params.sharesIn);
        for (uint256 i; i < assets.length; ++i) {
            _pushExact(assets[i], params.receiver, amountsOut[i]);
        }
        if (fullRedemption) {
            config.closed = true;
            emit PoolClosed(params.poolId, params.owner);
        }
        emit Redeemed(params.poolId, msg.sender, params.receiver, params.sharesIn);
    }

    /*//////////////////////////////////////////////////////////////
                         AUCTION SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDemeterManager
    function settleAuctionBid(
        bytes32 poolId,
        uint64 auctionNonce,
        address sellToken,
        address buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        address bidder,
        address receiver
    ) external nonReentrant {
        if (msg.sender != auctionRebalance) revert DemeterManager__Unauthorized(msg.sender);
        if (bidder == address(0)) revert V2Errors.V2Errors__ZeroAddress("bidder");
        if (receiver == address(0) || receiver == address(this)) {
            revert V2Errors.V2Errors__InvalidRecipient(receiver);
        }
        _requireActivePool(poolId);
        if (sellToken == buyToken || _assetIndexPlusOne[poolId][sellToken] == 0) {
            revert V2Errors.V2Errors__TokenNotInPool(sellToken);
        }
        if (_assetIndexPlusOne[poolId][buyToken] == 0) revert V2Errors.V2Errors__TokenNotInPool(buyToken);
        if (!registry.isAssetEnabled(sellToken)) revert V2Errors.V2Errors__AssetNotEnabled(sellToken);
        if (!registry.isAssetEnabled(buyToken)) revert V2Errors.V2Errors__AssetNotEnabled(buyToken);
        if (sellAmount == 0 || buyAmount == 0) revert V2Errors.V2Errors__ZeroOutput(poolId);

        RebalanceTypes.Auction memory active = IAuctionRebalance(auctionRebalance).getAuction(poolId);
        RebalanceTypes.RebalancePlan memory currentPlan = IAuctionRebalance(auctionRebalance).getPlan(poolId);
        if (
            !active.active || active.nonce != auctionNonce || active.sellToken != sellToken
                || active.buyToken != buyToken || active.planNonce != currentPlan.nonce
                || currentPlan.state != RebalanceTypes.RebalanceState.AUCTION_ACTIVE
        ) revert V2Errors.V2Errors__AuctionNotActive(poolId, auctionNonce);
        if (block.timestamp > active.endTime) revert V2Errors.V2Errors__AuctionExpired(active.endTime, block.timestamp);
        uint256 sellAvailable = active.sellLimit - active.sellFilled;
        if (sellAmount > sellAvailable) revert V2Errors.V2Errors__BidTooLarge(sellAmount, sellAvailable);
        uint256 buyAvailable = active.buyLimit - active.buyReceived;
        if (buyAmount > buyAvailable) revert V2Errors.V2Errors__BidTooLarge(buyAmount, buyAvailable);
        (uint256 liveSellAvailable, uint256 liveBuyAvailable) =
            IAuctionRebalance(auctionRebalance).liveAuctionCapacity(poolId);
        if (sellAmount > liveSellAvailable) {
            revert V2Errors.V2Errors__BidTooLarge(sellAmount, liveSellAvailable);
        }
        if (buyAmount > liveBuyAvailable) {
            revert V2Errors.V2Errors__BidTooLarge(buyAmount, liveBuyAvailable);
        }
        uint256 reserve = _reserves[poolId][sellToken];
        if (sellAmount > reserve) revert DemeterManager__InsufficientReserve(sellToken, sellAmount, reserve);

        PoolTypes.AssetConfig memory sellConfig = registry.getAssetConfig(sellToken);
        PoolTypes.AssetConfig memory buyConfig = registry.getAssetConfig(buyToken);
        uint256 currentPriceWad = IAuctionRebalance(auctionRebalance).currentPrice(poolId);
        uint256 requiredBuy =
            AuctionMath.paymentRaw(sellAmount, currentPriceWad, sellConfig.decimals, buyConfig.decimals);
        if (buyAmount < requiredBuy) revert V2Errors.V2Errors__PriceTooLow(buyAmount, requiredBuy);

        _pullExact(buyToken, bidder, buyAmount);
        _reserves[poolId][buyToken] += buyAmount;
        accountedReserve[buyToken] += buyAmount;
        _reserves[poolId][sellToken] -= sellAmount;
        accountedReserve[sellToken] -= sellAmount;
        _pushExact(sellToken, receiver, sellAmount);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDemeterManager
    function poolCreator(bytes32 poolId) external view returns (address) {
        return _poolConfigs[poolId].creator;
    }

    /// @inheritdoc IDemeterManager
    function poolShare(bytes32 poolId) external view returns (address) {
        return _poolConfigs[poolId].share;
    }

    /// @inheritdoc IDemeterManager
    function getPoolAssets(bytes32 poolId) external view returns (address[] memory) {
        return _poolAssets[poolId];
    }

    /// @inheritdoc IDemeterManager
    function getPoolConfig(bytes32 poolId) external view returns (PoolTypes.PoolConfig memory) {
        return _poolConfigs[poolId];
    }

    /// @inheritdoc IDemeterManager
    function getSeedAmounts(bytes32 poolId) external view returns (uint256[] memory amounts) {
        return _seedAmounts[poolId];
    }

    /// @inheritdoc IDemeterManager
    function reserveOf(bytes32 poolId, address asset) external view returns (uint256) {
        return _reserves[poolId][asset];
    }

    /// @inheritdoc IDemeterManager
    function tokenBalance(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @inheritdoc IDemeterManager
    function isPoolActive(bytes32 poolId) external view returns (bool) {
        PoolTypes.PoolConfig storage config = _poolConfigs[poolId];
        return !_reentrancyGuardEntered() && config.bootstrapped && !config.closed;
    }

    /// @inheritdoc IDemeterManager
    function isOperationActive() external view returns (bool) {
        return _reentrancyGuardEntered();
    }

    /// @inheritdoc IDemeterManager
    function isPoolClosed(bytes32 poolId) external view returns (bool) {
        return _poolConfigs[poolId].closed;
    }

    /// @inheritdoc IDemeterManager
    function quoteIssue(bytes32 poolId, uint256 sharesOut) external view returns (uint256[] memory amountsIn) {
        PoolTypes.PoolConfig storage config = _requireActivePool(poolId);
        amountsIn = _quoteIssue(poolId, sharesOut, config.share);
    }

    /// @inheritdoc IDemeterManager
    function quoteRedeem(bytes32 poolId, uint256 sharesIn) external view returns (uint256[] memory amountsOut) {
        PoolTypes.PoolConfig storage config = _requireActivePool(poolId);
        uint256 supply = IERC20(config.share).totalSupply();
        if (sharesIn == 0 || sharesIn > supply) revert V2Errors.V2Errors__InvalidShareAmount(sharesIn);
        amountsOut = _quoteRedeem(poolId, sharesIn, supply, sharesIn == supply);
    }

    /// @inheritdoc IDemeterManager
    function validatePoolForAuction(bytes32 poolId, address sellToken, address buyToken)
        external
        view
        returns (bool valid)
    {
        PoolTypes.PoolConfig storage config = _poolConfigs[poolId];
        valid = config.bootstrapped && !config.closed && sellToken != buyToken
            && _assetIndexPlusOne[poolId][sellToken] != 0 && _assetIndexPlusOne[poolId][buyToken] != 0
            && registry.isAssetEnabled(sellToken) && registry.isAssetEnabled(buyToken);
    }

    /// @inheritdoc IDemeterManager
    function derivePoolId(address creator, address[] calldata assets, bytes32 policyFamilyId, bytes32 creatorSalt)
        external
        view
        returns (bytes32 poolId)
    {
        poolId = PoolId.derive(block.chainid, address(this), creator, assets, policyFamilyId, creatorSalt);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _quoteIssue(bytes32 poolId, uint256 sharesOut, address share)
        internal
        view
        returns (uint256[] memory amountsIn)
    {
        uint256 supply = IERC20(share).totalSupply();
        amountsIn = new uint256[](_poolAssets[poolId].length);
        for (uint256 i; i < amountsIn.length; ++i) {
            amountsIn[i] = ProportionalMath.amountIn(_reserves[poolId][_poolAssets[poolId][i]], sharesOut, supply);
        }
    }

    function _quoteRedeem(bytes32 poolId, uint256 sharesIn, uint256 supply, bool fullRedemption)
        internal
        view
        returns (uint256[] memory amountsOut)
    {
        amountsOut = new uint256[](_poolAssets[poolId].length);
        for (uint256 i; i < amountsOut.length; ++i) {
            uint256 reserve = _reserves[poolId][_poolAssets[poolId][i]];
            amountsOut[i] = fullRedemption ? reserve : ProportionalMath.amountOut(reserve, sharesIn, supply);
        }
    }

    function _requirePool(bytes32 poolId) internal view returns (PoolTypes.PoolConfig storage config) {
        config = _poolConfigs[poolId];
        if (config.creator == address(0)) revert V2Errors.V2Errors__PoolNotFound(poolId);
    }

    function _requireActivePool(bytes32 poolId) internal view returns (PoolTypes.PoolConfig storage config) {
        config = _requirePool(poolId);
        if (!config.bootstrapped) revert V2Errors.V2Errors__PoolNotBootstrapped(poolId);
        if (config.closed) revert V2Errors.V2Errors__PoolClosed(poolId);
    }

    function _isLocked(bytes32 poolId) internal view returns (bool) {
        return IAuctionRebalance(auctionRebalance).isPoolLocked(poolId);
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert V2Errors.V2Errors__DeadlineExpired(deadline, block.timestamp);
    }

    function _pullExact(address asset, address from, uint256 amount) internal {
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - beforeBalance;
        if (received != amount) revert V2Errors.V2Errors__ExactTransferMismatch(asset, amount, received);
    }

    function _pushExact(address asset, address to, uint256 amount) internal {
        if (amount == 0) return;
        IERC20 token = IERC20(asset);
        uint256 managerBefore = token.balanceOf(address(this));
        uint256 receiverBefore = token.balanceOf(to);
        token.safeTransfer(to, amount);
        uint256 managerDecrease = managerBefore - token.balanceOf(address(this));
        uint256 receiverIncrease = token.balanceOf(to) - receiverBefore;
        if (managerDecrease != amount || receiverIncrease != amount) {
            revert V2Errors.V2Errors__ExactTransferMismatch(asset, amount, receiverIncrease);
        }
        if (token.balanceOf(address(this)) < accountedReserve[asset]) {
            revert V2Errors.V2Errors__InsufficientBalance(
                asset, address(this), accountedReserve[asset], token.balanceOf(address(this))
            );
        }
    }
}
