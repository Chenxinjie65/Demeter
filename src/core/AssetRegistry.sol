// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IChainlinkAggregator} from "src/interfaces/external/IChainlinkAggregator.sol";
import {IUniswapV3Pool} from "src/interfaces/external/IUniswapV3Pool.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";

/**
 * @title AssetRegistry
 * @notice Timelock-controlled asset admission and global pool safety bounds.
 * @dev Token behavior is governance-attested at admission and rechecked through
 * exact balance deltas at runtime. This contract never holds user assets.
 * @custom:security-contact security@demeter.protocol
 */
contract AssetRegistry is IAssetRegistry {
    uint16 private constant MAX_ASSETS_HARD_CAP = 32;
    uint16 private constant MAX_METADATA_BYTES_HARD_CAP = 128;
    uint64 private constant MAX_BOOTSTRAP_DURATION_HARD_CAP = 365 days;
    uint8 private constant MAX_TOKEN_DECIMALS = 36;
    uint8 private constant MAX_FEED_DECIMALS = 36;
    uint32 private constant MIN_TWAP_WINDOW_HARD_CAP = 5 minutes;
    uint32 private constant MAX_TWAP_WINDOW_HARD_CAP = 7 days;
    uint32 private constant MAX_CHAINLINK_STALE_HARD_CAP = 7 days;
    uint32 private constant MIN_SEQUENCER_GRACE_HARD_CAP = 1 minutes;
    uint32 private constant MAX_SEQUENCER_GRACE_HARD_CAP = 1 days;
    uint256 private constant BPS = 10_000;

    address public immutable override timelock;
    address public immutable override twapQuoteAsset;
    address public override guardian;
    address public override sequencerUptimeFeed;
    uint32 public override sequencerGracePeriod;
    uint64 public override oracleConfigVersion;

    mapping(address asset => PoolTypes.AssetConfig config) private _assetConfigs;
    PoolTypes.GlobalPoolBounds private _globalPoolBounds;
    bytes32 private _globalBoundsHash;

    error AssetRegistry__Unauthorized(address caller);
    error AssetRegistry__ZeroAddress(bytes32 field);
    error AssetRegistry__InvalidCode(address target);
    error AssetRegistry__InvalidDecimals(address target, uint256 decimals);
    error AssetRegistry__DecimalsChanged(address asset, uint8 expected, uint8 actual);
    error AssetRegistry__InvalidBps(bytes32 field, uint256 value);
    error AssetRegistry__InvalidWindow(bytes32 field, uint256 value);
    error AssetRegistry__InvalidPool(address pool, address asset, address quoteAsset);
    error AssetRegistry__AssetNotConfigured(address asset);
    error AssetRegistry__InvalidBounds(bytes32 field, uint256 value);

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert AssetRegistry__Unauthorized(msg.sender);
        _;
    }

    constructor(
        address timelock_,
        address guardian_,
        address twapQuoteAsset_,
        PoolTypes.GlobalPoolBounds memory bounds_
    ) {
        _validateAddress(timelock_, "timelock");
        if (timelock_.code.length == 0) revert AssetRegistry__InvalidCode(timelock_);
        _validateAddress(guardian_, "guardian");
        _validateContract(twapQuoteAsset_);

        timelock = timelock_;
        guardian = guardian_;
        twapQuoteAsset = twapQuoteAsset_;
        _setGlobalPoolBounds(bounds_);
    }

    /*//////////////////////////////////////////////////////////////
                         GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetRegistry
    function configureAsset(address asset, PoolTypes.AssetConfigInput calldata input) external onlyTimelock {
        _validateContract(asset);
        _validateContract(input.chainlinkFeed);
        if (input.twapWindow < MIN_TWAP_WINDOW_HARD_CAP || input.twapWindow > MAX_TWAP_WINDOW_HARD_CAP) {
            revert AssetRegistry__InvalidWindow("twapWindow", input.twapWindow);
        }
        if (input.maxChainlinkStale == 0 || input.maxChainlinkStale > MAX_CHAINLINK_STALE_HARD_CAP) {
            revert AssetRegistry__InvalidWindow("maxChainlinkStale", input.maxChainlinkStale);
        }
        _validateBps("maxOracleDeviationBps", input.maxOracleDeviationBps);
        _validateBps("maxReferenceMoveBps", input.maxReferenceMoveBps);

        uint8 tokenDecimals = IERC20Metadata(asset).decimals();
        if (tokenDecimals > MAX_TOKEN_DECIMALS) {
            revert AssetRegistry__InvalidDecimals(asset, tokenDecimals);
        }

        uint8 feedDecimals = IChainlinkAggregator(input.chainlinkFeed).decimals();
        if (feedDecimals > MAX_FEED_DECIMALS) {
            revert AssetRegistry__InvalidDecimals(input.chainlinkFeed, feedDecimals);
        }

        if (asset == twapQuoteAsset) {
            if (input.twapPool != address(0)) {
                revert AssetRegistry__InvalidPool(input.twapPool, asset, twapQuoteAsset);
            }
        } else {
            if (!_assetConfigs[twapQuoteAsset].enabled) {
                revert AssetRegistry__AssetNotConfigured(twapQuoteAsset);
            }
            _validateContract(input.twapPool);
            address token0 = IUniswapV3Pool(input.twapPool).token0();
            address token1 = IUniswapV3Pool(input.twapPool).token1();
            bool matches =
                (token0 == asset && token1 == twapQuoteAsset) || (token1 == asset && token0 == twapQuoteAsset);
            if (!matches) revert AssetRegistry__InvalidPool(input.twapPool, asset, twapQuoteAsset);
        }

        PoolTypes.AssetConfig storage current = _assetConfigs[asset];
        if (current.configVersion != 0 && current.decimals != tokenDecimals) {
            revert AssetRegistry__DecimalsChanged(asset, current.decimals, tokenDecimals);
        }

        uint64 nextVersion = current.configVersion + 1;
        _assetConfigs[asset] = PoolTypes.AssetConfig({
            enabled: true,
            decimals: tokenDecimals,
            chainlinkFeed: input.chainlinkFeed,
            twapPool: input.twapPool,
            twapQuoteAsset: twapQuoteAsset,
            twapWindow: input.twapWindow,
            maxChainlinkStale: input.maxChainlinkStale,
            maxOracleDeviationBps: input.maxOracleDeviationBps,
            maxReferenceMoveBps: input.maxReferenceMoveBps,
            configVersion: nextVersion
        });

        unchecked {
            ++oracleConfigVersion;
        }

        emit AssetConfigured(asset, nextVersion, true);
    }

    /// @inheritdoc IAssetRegistry
    function disableAsset(address asset) external onlyTimelock {
        PoolTypes.AssetConfig storage config = _assetConfigs[asset];
        if (config.configVersion == 0) revert AssetRegistry__AssetNotConfigured(asset);
        config.enabled = false;
        unchecked {
            ++config.configVersion;
            ++oracleConfigVersion;
        }
        emit AssetConfigured(asset, config.configVersion, false);
    }

    /// @inheritdoc IAssetRegistry
    function setGuardian(address newGuardian) external onlyTimelock {
        _validateAddress(newGuardian, "guardian");
        address oldGuardian = guardian;
        guardian = newGuardian;
        emit GuardianUpdated(oldGuardian, newGuardian);
    }

    /// @inheritdoc IAssetRegistry
    function setGlobalPoolBounds(PoolTypes.GlobalPoolBounds calldata bounds) external onlyTimelock {
        _setGlobalPoolBounds(bounds);
    }

    /// @inheritdoc IAssetRegistry
    function setSequencerConfig(address feed, uint32 gracePeriod) external onlyTimelock {
        if (feed != address(0)) _validateContract(feed);
        if (
            (feed == address(0)) != (gracePeriod == 0)
                || (
                    feed != address(0)
                        && (gracePeriod < MIN_SEQUENCER_GRACE_HARD_CAP || gracePeriod > MAX_SEQUENCER_GRACE_HARD_CAP)
                )
        ) {
            revert AssetRegistry__InvalidWindow("sequencerGracePeriod", gracePeriod);
        }
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriod;
        unchecked {
            ++oracleConfigVersion;
        }
        emit SequencerConfigUpdated(feed, gracePeriod, oracleConfigVersion);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAssetRegistry
    function isAssetEnabled(address asset) external view returns (bool) {
        return _assetConfigs[asset].enabled;
    }

    /// @inheritdoc IAssetRegistry
    function getAssetConfig(address asset) external view returns (PoolTypes.AssetConfig memory) {
        return _assetConfigs[asset];
    }

    /// @inheritdoc IAssetRegistry
    function assetConfigVersion(address asset) external view returns (uint64) {
        return _assetConfigs[asset].configVersion;
    }

    /// @inheritdoc IAssetRegistry
    function globalBounds() external view returns (bytes32 boundsHash) {
        boundsHash = _globalBoundsHash;
    }

    /// @inheritdoc IAssetRegistry
    function getGlobalPoolBounds() external view returns (PoolTypes.GlobalPoolBounds memory bounds) {
        bounds = _globalPoolBounds;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setGlobalPoolBounds(PoolTypes.GlobalPoolBounds memory bounds) internal {
        if (bounds.minAssets < 2 || bounds.minAssets > bounds.maxAssets) {
            revert AssetRegistry__InvalidBounds("minAssets", bounds.minAssets);
        }
        if (bounds.maxAssets > MAX_ASSETS_HARD_CAP) {
            revert AssetRegistry__InvalidBounds("maxAssets", bounds.maxAssets);
        }
        if (bounds.maxNameBytes == 0 || bounds.maxNameBytes > MAX_METADATA_BYTES_HARD_CAP) {
            revert AssetRegistry__InvalidBounds("maxNameBytes", bounds.maxNameBytes);
        }
        if (bounds.maxSymbolBytes == 0 || bounds.maxSymbolBytes > MAX_METADATA_BYTES_HARD_CAP) {
            revert AssetRegistry__InvalidBounds("maxSymbolBytes", bounds.maxSymbolBytes);
        }
        if (bounds.minInitialShareSupply == 0 || bounds.minInitialShareSupply > bounds.maxInitialShareSupply) {
            revert AssetRegistry__InvalidBounds("initialShareSupply", bounds.minInitialShareSupply);
        }
        if (
            bounds.minBootstrapDuration == 0 || bounds.minBootstrapDuration > bounds.maxBootstrapDuration
                || bounds.maxBootstrapDuration > MAX_BOOTSTRAP_DURATION_HARD_CAP
        ) {
            revert AssetRegistry__InvalidBounds("bootstrapDuration", bounds.maxBootstrapDuration);
        }

        uint64 nextVersion = _globalPoolBounds.configVersion + 1;
        bounds.configVersion = nextVersion;
        _globalPoolBounds = bounds;
        _globalBoundsHash = keccak256(abi.encode(bounds));
        emit GlobalBoundsUpdated(_globalBoundsHash);
    }

    function _validateBps(bytes32 field, uint256 value) internal pure {
        if (value > BPS) revert AssetRegistry__InvalidBps(field, value);
    }

    function _validateAddress(address target, bytes32 field) internal pure {
        if (target == address(0)) revert AssetRegistry__ZeroAddress(field);
    }

    function _validateContract(address target) internal view {
        if (target == address(0)) revert AssetRegistry__ZeroAddress("contract");
        if (target.code.length == 0) revert AssetRegistry__InvalidCode(target);
    }
}
