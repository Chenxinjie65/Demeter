// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";

/**
 * @title AuctionMath
 * @notice Full-precision price and native-unit payment math for V2 auctions.
 * @custom:security-contact security@demeter.protocol
 */
library AuctionMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    /// @notice Pair price in quote-token WAD per base-token WAD, rounded down.
    function pairPriceWad(uint256 baseUsdPriceWad, uint256 quoteUsdPriceWad) internal pure returns (uint256) {
        if (baseUsdPriceWad == 0) revert V2Errors.V2Errors__InvalidConfig("basePrice");
        if (quoteUsdPriceWad == 0) revert V2Errors.V2Errors__InvalidConfig("quotePrice");
        return Math.mulDiv(baseUsdPriceWad, WAD, quoteUsdPriceWad, Math.Rounding.Floor);
    }

    function startPrice(uint256 referencePriceWad, uint16 premiumBps) internal pure returns (uint256) {
        if (premiumBps > BPS) revert V2Errors.V2Errors__InvalidBps("premiumBps", premiumBps);
        return Math.mulDiv(referencePriceWad, BPS + premiumBps, BPS, Math.Rounding.Ceil);
    }

    function endPrice(uint256 referencePriceWad, uint16 discountBps) internal pure returns (uint256) {
        if (discountBps >= BPS) revert V2Errors.V2Errors__InvalidBps("discountBps", discountBps);
        return Math.mulDiv(referencePriceWad, BPS - discountBps, BPS, Math.Rounding.Ceil);
    }

    /// @notice Linear current auction price, rounded up so the fund never receives less than the curve.
    function currentPrice(
        uint256 startPriceWad,
        uint256 endPriceWad,
        uint64 startTime,
        uint64 endTime,
        uint256 timestamp
    ) internal pure returns (uint256) {
        if (endTime <= startTime) revert V2Errors.V2Errors__InvalidTime("auctionWindow", endTime);
        if (startPriceWad < endPriceWad) revert V2Errors.V2Errors__InvalidConfig("auctionPrices");
        if (timestamp <= startTime) return startPriceWad;
        if (timestamp >= endTime) return endPriceWad;

        uint256 elapsed = timestamp - startTime;
        uint256 duration = endTime - startTime;
        uint256 decay = Math.mulDiv(startPriceWad - endPriceWad, elapsed, duration, Math.Rounding.Floor);
        return startPriceWad - decay;
    }

    /// @notice Native quote-token payment for raw base-token amount, rounded up in favor of the fund.
    function paymentRaw(uint256 sellRaw, uint256 pairPriceWad_, uint8 sellDecimals, uint8 buyDecimals)
        internal
        pure
        returns (uint256)
    {
        uint256 quoteWad = Math.mulDiv(sellRaw, pairPriceWad_, 10 ** uint256(sellDecimals), Math.Rounding.Ceil);
        if (buyDecimals >= 18) {
            uint256 factor = 10 ** uint256(buyDecimals - 18);
            if (quoteWad > type(uint256).max / factor) revert V2Errors.V2Errors__MathOverflow("buyRaw");
            return quoteWad * factor;
        }
        return _ceilDiv(quoteWad, 10 ** uint256(18 - buyDecimals));
    }

    /// @notice Conservative maximum raw sell amount payable by a raw buy-token budget.
    function maxSellRaw(uint256 maxBuyRaw, uint256 pairPriceWad_, uint8 sellDecimals, uint8 buyDecimals)
        internal
        pure
        returns (uint256)
    {
        if (pairPriceWad_ == 0) revert V2Errors.V2Errors__InvalidConfig("pairPrice");
        uint256 buyWad = Math.mulDiv(maxBuyRaw, WAD, 10 ** uint256(buyDecimals), Math.Rounding.Floor);
        uint256 sellWad = Math.mulDiv(buyWad, WAD, pairPriceWad_, Math.Rounding.Floor);
        if (sellDecimals >= 18) {
            uint256 factor = 10 ** uint256(sellDecimals - 18);
            if (sellWad > type(uint256).max / factor) return type(uint256).max;
            return sellWad * factor;
        }
        return sellWad / 10 ** uint256(18 - sellDecimals);
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        if (numerator == 0) return 0;
        uint256 quotient = numerator / denominator;
        return numerator % denominator == 0 ? quotient : quotient + 1;
    }
}
