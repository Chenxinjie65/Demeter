// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPriceOracle
 * @notice Unified price oracle interface for Demeter protocol.
 *
 * @dev
 * Implementations are expected to wrap external data sources such as
 * Chainlink or Pyth and normalize their outputs.
 *
 * Requirements:
 * - Must perform staleness checks (e.g. `updatedAt`).
 * - Should be aware of L2 sequencer status where applicable.
 * - All prices are denominated in USD with 8 decimals.
 */
interface IPriceOracle {
    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /**
     * @notice Emitted when the price source for an asset is updated.
     * @param asset Asset address.
     * @param source Address of the price source (e.g. Chainlink aggregator).
     */
    event AssetSourceUpdated(address indexed asset, address indexed source);

    /**
     * @notice Emitted when the maximum allowed staleness time is updated.
     * @param oldValue Previous max stale time value.
     * @param newValue New max stale time value.
     */
    event MaxStaleTimeSet(uint256 oldValue, uint256 newValue);

    /**
     * @notice Emitted when the sequencer configuration is updated.
     * @param feed Address of the sequencer uptime feed.
     * @param gracePeriod Grace period in seconds after sequencer recovery.
     */
    event SequencerConfigSet(address indexed feed, uint256 gracePeriod);

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------
    /**
     * @notice Returns the latest price for a given asset, denominated in USD.
     * @dev
     * - Implementations SHOULD revert if the price is stale or invalid.
     * - All prices are returned with 8 decimals (standard for USD price feeds).
     * - For ChainlinkOracle implementation:
     *   - Reverts if no feed is configured for the asset.
     *   - Reverts if price is stale or invalid.
     *   - Reverts if sequencer is down (if sequencer checks are enabled).
     *   - Performs validation checks including:
     *     * Sequencer health check (if configured)
     *     * Feed existence check
     *     * Price validity check (must be positive)
     *     * Round staleness check (answeredInRound >= roundId)
     *     * Time staleness check (if maxStaleTime > 0)
     *   - Price is normalized to 8 decimals regardless of the feed's native decimals.
     *
     * @param asset Asset whose price is being queried.
     * @return price Latest price in USD, scaled to 8 decimals.
     */
    function getPrice(address asset) external view returns (uint256 price);

    /**
     * @notice Batch version of {getPrice} for gas-efficient multi-asset queries.
     * @dev
     * - For ChainlinkOracle implementation:
     *   - Reverts if any feed is invalid or stale.
     *   - More gas-efficient than calling {getPrice} multiple times.
     *   - Each price in the batch undergoes the same validation as {getPrice}.
     *   - All prices are normalized to 8 decimals.
     *
     * @param assets Array of asset addresses.
     * @return prices Array of prices in USD, each scaled to 8 decimals.
     */
    function getPrices(address[] calldata assets) external view returns (uint256[] memory prices);

    /**
     * @notice Returns whether the price feed for a given asset is currently considered valid.
     * @dev
     * - This is a non-reverting health check that can be used for risk management.
     * - For ChainlinkOracle implementation:
     *   - Returns false if the feed is not configured, stale, or sequencer is down.
     *   - Uses try-catch to prevent reverts, making it safe for external calls.
     *   - Wraps {getPrice} in a try-catch block to handle all error cases gracefully.
     *
     * @param asset Asset address.
     * @return isValid True if the feed is healthy and within configured freshness bounds.
     */
    function isPriceValid(address asset) external view returns (bool isValid);

    /**
     * @notice Returns the address of the price source for an asset.
     * @dev
     * - For ChainlinkOracle implementation:
     *   - Returns the Chainlink AggregatorV3 contract address for the asset.
     *   - Returns address(0) if no feed is configured for the asset.
     *
     * @param asset Asset address.
     * @return source The address of the price source (e.g. Chainlink aggregator), or address(0) if not set.
     */
    function getSourceOfAsset(address asset) external view returns (address source);

    // -------------------------------------------------------------------------
    // Admin functions
    // -------------------------------------------------------------------------

    /**
     * @notice Sets the Chainlink aggregator feed for an asset.
     * @dev
     * - Only callable by the RiskAdmin role.
     * - Setting `source = address(0)` effectively disables the feed.
     * - The aggregator must implement AggregatorV2V3Interface.
     * - Emits {AssetSourceUpdated} event.
     *
     * @param asset Asset address (e.g. WETH, WBTC).
     * @param source Address of the Chainlink AggregatorV2V3 price feed contract.
     */
    function setAssetSource(address asset, address source) external;

    /**
     * @notice Sets or replaces price sources for multiple assets.
     * @dev
     * - Only callable by the RiskAdmin role.
     * - Arrays must have the same length.
     * - Setting `source = address(0)` effectively disables the feed for that asset.
     * - Emits {AssetSourceUpdated} event for each asset.
     *
     * @param assets Array of asset addresses.
     * @param sources Array of Chainlink AggregatorV2V3 price feed contract addresses.
     */
    function setAssetSources(address[] calldata assets, address[] calldata sources) external;

    /**
     * @notice Updates the maximum allowed staleness for price data.
     * @dev
     * - Only callable by the RiskAdmin role.
     * - Setting to 0 disables staleness checks (not recommended for production).
     * - Typical values: 3600 (1 hour) to 86400 (24 hours) depending on feed update frequency.
     * - Emits {MaxStaleTimeSet} event.
     *
     * @param newMaxStaleTime New staleness threshold in seconds.
     */
    function setMaxStaleTime(uint256 newMaxStaleTime) external;

    /**
     * @notice Configures the optional L2 sequencer uptime feed and grace period.
     * @dev
     * - Only callable by the RiskAdmin role.
     * - If `feed` is the zero address, sequencer checks are disabled (for L1 or when not needed).
     * - The sequencer feed must implement ISequencerOracle interface.
     * - Grace period prevents using stale prices immediately after sequencer recovery.
     * - Emits {SequencerConfigSet} event.
     *
     * @param feed Address of the sequencer uptime feed (e.g. Chainlink L2 Sequencer Uptime Feed).
     * @param gracePeriodSeconds Grace period in seconds after sequencer comes back up.
     */
    function setSequencerConfig(address feed, uint256 gracePeriodSeconds) external;
}


