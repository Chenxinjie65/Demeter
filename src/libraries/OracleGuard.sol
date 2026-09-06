// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {ITwapOracle} from "src/interfaces/ITwapOracle.sol";
import {IChainlinkAggregator} from "src/interfaces/external/IChainlinkAggregator.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";
import {PoolTypes} from "src/types/PoolTypes.sol";

/**
 * @title OracleGuard
 * @notice Chainlink + common-quote TWAP validation for plans and bids.
 * @custom:security-contact security@demeter.protocol
 */
library OracleGuard {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    struct ValidatedPrice {
        uint256 chainlinkUsdWad;
        uint256 twapUsdWad;
        uint64 assetConfigVersion;
        uint64 oracleConfigVersion;
    }

    function validatedPrice(
        IAssetRegistry registry,
        ITwapOracle twapOracle,
        address asset,
        uint16 policyMaxDeviationBps
    ) internal view returns (ValidatedPrice memory result) {
        if (!registry.isAssetEnabled(asset)) revert V2Errors.V2Errors__AssetNotEnabled(asset);
        _checkSequencer(registry);

        PoolTypes.AssetConfig memory config = registry.getAssetConfig(asset);
        address commonQuote = registry.twapQuoteAsset();
        PoolTypes.AssetConfig memory quoteConfig = registry.getAssetConfig(commonQuote);
        if (!quoteConfig.enabled) revert V2Errors.V2Errors__AssetNotEnabled(commonQuote);

        result.chainlinkUsdWad = _chainlinkPrice(config);
        uint256 quoteUsdWad = asset == commonQuote ? result.chainlinkUsdWad : _chainlinkPrice(quoteConfig);
        if (asset == commonQuote) {
            result.twapUsdWad = result.chainlinkUsdWad;
        } else {
            uint256 oneToken = 10 ** uint256(config.decimals);
            uint256 quoteRaw = twapOracle.quote(config.twapPool, asset, commonQuote, oneToken, config.twapWindow);
            uint256 commonQuotePerAssetWad = Math.mulDiv(quoteRaw, WAD, 10 ** uint256(quoteConfig.decimals));
            result.twapUsdWad = Math.mulDiv(commonQuotePerAssetWad, quoteUsdWad, WAD);
        }

        uint16 maxDeviation =
            config.maxOracleDeviationBps < policyMaxDeviationBps ? config.maxOracleDeviationBps : policyMaxDeviationBps;
        validateSourceDivergence(result.chainlinkUsdWad, result.twapUsdWad, maxDeviation);

        result.assetConfigVersion = config.configVersion;
        result.oracleConfigVersion = registry.oracleConfigVersion();
    }

    function validateSourceDivergence(uint256 primaryPriceWad, uint256 secondaryPriceWad, uint16 maxDeviationBps)
        internal
        pure
    {
        if (primaryPriceWad == 0 || secondaryPriceWad == 0) {
            revert V2Errors.V2Errors__OracleUnsafe("zeroSource");
        }
        uint256 difference = primaryPriceWad > secondaryPriceWad
            ? primaryPriceWad - secondaryPriceWad
            : secondaryPriceWad - primaryPriceWad;
        uint256 deviationBps = Math.mulDiv(difference, BPS, primaryPriceWad, Math.Rounding.Ceil);
        if (deviationBps > maxDeviationBps) revert V2Errors.V2Errors__OracleUnsafe("sourceDivergence");
    }

    function validateReferenceMove(uint256 referencePriceWad, uint256 currentPriceWad, uint16 maxMoveBps)
        internal
        pure
    {
        if (referencePriceWad == 0 || currentPriceWad == 0) {
            revert V2Errors.V2Errors__OracleUnsafe("zeroReference");
        }
        uint256 difference = referencePriceWad > currentPriceWad
            ? referencePriceWad - currentPriceWad
            : currentPriceWad - referencePriceWad;
        uint256 movementBps = Math.mulDiv(difference, BPS, referencePriceWad, Math.Rounding.Ceil);
        if (movementBps > maxMoveBps) revert V2Errors.V2Errors__OracleUnsafe("referenceMove");
    }

    function _chainlinkPrice(PoolTypes.AssetConfig memory config) private view returns (uint256 priceWad) {
        IChainlinkAggregator feed = IChainlinkAggregator(config.chainlinkFeed);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert V2Errors.V2Errors__OracleUnsafe("chainlinkAnswer");
        if (updatedAt == 0 || updatedAt > block.timestamp) revert V2Errors.V2Errors__OracleUnsafe("chainlinkTime");
        if (roundId == 0 || answeredInRound < roundId) revert V2Errors.V2Errors__OracleUnsafe("chainlinkRound");
        if (block.timestamp - updatedAt > config.maxChainlinkStale) {
            revert V2Errors.V2Errors__OracleUnsafe("chainlinkStale");
        }

        uint8 decimals = feed.decimals();
        uint256 raw = uint256(answer);
        priceWad =
            decimals <= 18 ? Math.mulDiv(raw, 10 ** uint256(18 - decimals), 1) : raw / 10 ** uint256(decimals - 18);
        if (priceWad == 0) revert V2Errors.V2Errors__OracleUnsafe("normalizedPrice");
    }

    function _checkSequencer(IAssetRegistry registry) private view {
        address feedAddress = registry.sequencerUptimeFeed();
        if (feedAddress == address(0)) return;
        (, int256 answer, uint256 startedAt,,) = IChainlinkAggregator(feedAddress).latestRoundData();
        if (answer != 0) revert V2Errors.V2Errors__OracleUnsafe("sequencerDown");
        if (startedAt == 0 || startedAt > block.timestamp) {
            revert V2Errors.V2Errors__OracleUnsafe("sequencerTime");
        }
        if (block.timestamp - startedAt <= registry.sequencerGracePeriod()) {
            revert V2Errors.V2Errors__OracleUnsafe("sequencerGrace");
        }
    }
}
