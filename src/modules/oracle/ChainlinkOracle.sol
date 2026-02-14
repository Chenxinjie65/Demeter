// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../interfaces/modules/IPriceOracle.sol";
import {IProtocolAddressProvider} from "../../interfaces/core/IProtocolAddressProvider.sol";
import {AggregatorV2V3Interface} from "../../interfaces/external/AggregatorInterface.sol";
import {ISequencerOracle} from "../../interfaces/external/ISequencerOracle.sol";
import {Errors} from "../../libraries/Errors.sol";

/**
 * @title ChainlinkOracle
 * @notice Chainlink-based implementation of the IPriceOracle interface.
 *
 * @dev
 * This contract wraps Chainlink AggregatorV2V3 price feeds and provides a unified interface
 * for querying asset prices in USD. It supports:
 * - Asset-to-feed mapping for USD-denominated price feeds
 * - Staleness checks to ensure price freshness
 * - Optional L2 sequencer health checks (for L2 networks like Arbitrum, Optimism)
 * - Batch price queries for gas efficiency
 * - Automatic normalization of prices to 8 decimals regardless of feed decimals
 *
 * SECURITY NOTES:
 * - Only the RiskAdmin role (from ProtocolAddressProvider) can configure feeds and risk parameters.
 * - Price feeds should be carefully validated before being set to prevent oracle manipulation.
 * - The sequencer grace period helps prevent stale prices immediately after sequencer recovery.
 * - All prices are normalized to 8 decimals (standard USD format).
 */
contract ChainlinkOracle is IPriceOracle {
    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Protocol address provider contract.
    IProtocolAddressProvider public immutable ADDRESSES_PROVIDER;

    /// @notice Mapping from asset address to Chainlink aggregator.
    mapping(address => address) private _feeds;

    /// @notice Maximum allowed price age in seconds (staleness threshold).
    uint256 public maxStaleTime;

    /// @notice Optional L2 sequencer uptime feed (zero address if not used).
    address public sequencerUptimeFeed;

    /// @notice Grace period after sequencer comes back up, in seconds.
    uint256 public sequencerGracePeriod;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    /**
     * @param addressesProvider_ Protocol address provider contract address.
     * @param maxStaleTime_ Maximum allowed age of a price update in seconds.
     */
    constructor(address addressesProvider_, uint256 maxStaleTime_) {
        if (addressesProvider_ == address(0)) revert Errors.AddressesProviderIsZero();
        ADDRESSES_PROVIDER = IProtocolAddressProvider(addressesProvider_);
        maxStaleTime = maxStaleTime_;
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    /**
     * @dev Modifier to check that the caller is the RiskAdmin.
     */
    modifier onlyRiskAdmin() {
        if (msg.sender != ADDRESSES_PROVIDER.getRiskAdmin()) revert Errors.CallerNotRiskAdmin();
        _;
    }

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /// @inheritdoc IPriceOracle
    function setAssetSource(address asset, address source) external override onlyRiskAdmin {
        _feeds[asset] = source;
        emit IPriceOracle.AssetSourceUpdated(asset, source);
    }

    /// @inheritdoc IPriceOracle
    function setAssetSources(address[] calldata assets, address[] calldata sources) external override onlyRiskAdmin {
        if (assets.length != sources.length) revert Errors.ArraysLengthMismatch();
        for (uint256 i = 0; i < assets.length; i++) {
            _feeds[assets[i]] = sources[i];
            emit IPriceOracle.AssetSourceUpdated(assets[i], sources[i]);
        }
    }

    /// @inheritdoc IPriceOracle
    function setMaxStaleTime(uint256 newMaxStaleTime) external override onlyRiskAdmin {
        uint256 old = maxStaleTime;
        maxStaleTime = newMaxStaleTime;
        emit IPriceOracle.MaxStaleTimeSet(old, newMaxStaleTime);
    }

    /// @inheritdoc IPriceOracle
    function setSequencerConfig(address feed, uint256 gracePeriodSeconds) external override onlyRiskAdmin {
        sequencerUptimeFeed = feed;
        sequencerGracePeriod = gracePeriodSeconds;
        emit IPriceOracle.SequencerConfigSet(feed, gracePeriodSeconds);
    }

    // -------------------------------------------------------------------------
    // IPriceOracle implementation
    // -------------------------------------------------------------------------

    /// @inheritdoc IPriceOracle
    function getPrice(address asset) external view override returns (uint256 price) {
        price = _getPrice(asset);
    }

    /// @inheritdoc IPriceOracle
    function getPrices(address[] calldata assets) external view override returns (uint256[] memory prices) {
        uint256 len = assets.length;
        prices = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            prices[i] = _getPrice(assets[i]);
        }
    }

    /// @inheritdoc IPriceOracle
    function isPriceValid(address asset) external view override returns (bool isValid) {
        try this.getPrice(asset) returns (uint256 /*price*/) {
            return true;
        } catch {
            return false;
        }
    }

    /// @inheritdoc IPriceOracle
    function getSourceOfAsset(address asset) external view override returns (address source) {
        return _feeds[asset];
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /**
     * @dev Internal function that returns price normalized to 8 decimals.
     * Performs all validation checks including sequencer health, feed existence,
     * price validity, round staleness, and time staleness.
     * @param asset Asset address.
     * @return price Price normalized to 8 decimals.
     */
    function _getPrice(address asset) internal view returns (uint256 price) {
        _checkSequencer();

        address aggregator = _feeds[asset];
        if (aggregator == address(0)) revert Errors.FeedNotSet();

        AggregatorV2V3Interface feed = AggregatorV2V3Interface(aggregator);
        (
            uint80 roundId,
            int256 answer,
            /* uint256 startedAt */,
            uint256 updatedAtFeed,
            uint80 answeredInRound
        ) = feed.latestRoundData();

        if (answer <= 0) revert Errors.InvalidAnswer();
        if (answeredInRound < roundId) revert Errors.StaleRound();

        if (maxStaleTime != 0) {
            if (block.timestamp - updatedAtFeed > maxStaleTime) revert Errors.PriceStale();
        }

        uint8 feedDecimals = feed.decimals();
        uint256 rawPrice = uint256(answer);

        // Normalize price to 8 decimals
        if (feedDecimals == 8) {
            price = rawPrice;
        } else if (feedDecimals > 8) {
            // Scale down: divide by 10^(feedDecimals - 8)
            price = rawPrice / (10 ** (feedDecimals - 8));
        } else {
            // Scale up: multiply by 10^(8 - feedDecimals)
            price = rawPrice * (10 ** (8 - feedDecimals));
        }
    }

    /**
     * @dev Checks the L2 sequencer status if a sequencer feed is configured.
     * On L2 networks, if the sequencer is down, price feeds may return stale data.
     * Applies a grace period after sequencer recovery to ensure prices are fresh.
     */
    function _checkSequencer() internal view {
        if (sequencerUptimeFeed == address(0)) {
            return;
        }

        ISequencerOracle feed = ISequencerOracle(sequencerUptimeFeed);
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
            
        ) = feed.latestRoundData();

        if (answer != 0) revert Errors.SequencerDown();

        if (sequencerGracePeriod != 0) {
            if (block.timestamp - updatedAt <= sequencerGracePeriod) revert Errors.GracePeriodNotOver();
        }
    }

}