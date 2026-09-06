// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../src/interfaces/modules/IPriceOracle.sol";

/**
 * @title MockPriceOracle
 * @notice Configurable IPriceOracle mock for unit testing.
 * @dev Prices are set via `setPrice`. Any asset without a configured price will revert.
 */
contract MockPriceOracle is IPriceOracle {
    mapping(address => uint256) private _prices;
    bool public shouldRevert;

    // -------------------------------------------------------------------------
    // Test helpers
    // -------------------------------------------------------------------------

    function setPrice(address asset, uint256 price) external {
        _prices[asset] = price;
    }

    /// @notice Causes getPrice to revert on the next call when set to true.
    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    // -------------------------------------------------------------------------
    // IPriceOracle
    // -------------------------------------------------------------------------

    function getPrice(address asset) external view override returns (uint256 price) {
        if (shouldRevert) revert("MockPriceOracle: forced revert");
        price = _prices[asset];
        require(price != 0, "MockPriceOracle: price not set");
    }

    function getPrices(address[] calldata assets) external view override returns (uint256[] memory prices) {
        prices = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ) {
            prices[i] = _prices[assets[i]];
            unchecked { i++; }
        }
    }

    function isPriceValid(address asset) external view override returns (bool) {
        return _prices[asset] != 0 && !shouldRevert;
    }

    function getSourceOfAsset(address) external pure override returns (address) {
        return address(0);
    }

    // Admin stubs (no-ops in mock).
    function setAssetSource(address, address) external override {}
    function setAssetSources(address[] calldata, address[] calldata) external override {}
    function setMaxStaleTime(uint256) external override {}
    function setSequencerConfig(address, uint256) external override {}
}
