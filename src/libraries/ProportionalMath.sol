// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V2Errors} from "src/libraries/V2Errors.sol";

/**
 * @title ProportionalMath
 * @notice Full-precision reserve and share calculations for Demeter V2.
 * @custom:security-contact security@demeter.protocol
 */
library ProportionalMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SHARE_WAD = 1e18;

    /// @notice Assets required to mint shares, rounded up in favor of the fund.
    function amountIn(uint256 reserve, uint256 sharesOut, uint256 totalShares) internal pure returns (uint256) {
        if (sharesOut == 0) revert V2Errors.V2Errors__InvalidShareAmount(0);
        if (totalShares == 0) revert V2Errors.V2Errors__InvalidInitialSupply(0);
        return Math.mulDiv(reserve, sharesOut, totalShares, Math.Rounding.Ceil);
    }

    /// @notice Assets returned for burned shares, rounded down in favor of the fund.
    function amountOut(uint256 reserve, uint256 sharesIn, uint256 totalShares) internal pure returns (uint256) {
        if (sharesIn == 0) revert V2Errors.V2Errors__InvalidShareAmount(0);
        if (totalShares == 0) revert V2Errors.V2Errors__InvalidInitialSupply(0);
        return Math.mulDiv(reserve, sharesIn, totalShares, Math.Rounding.Floor);
    }

    /// @notice USD WAD value of a raw token amount, rounded down.
    function valueWad(uint256 rawAmount, uint256 priceWad, uint8 tokenDecimals) internal pure returns (uint256) {
        return Math.mulDiv(rawAmount, priceWad, 10 ** uint256(tokenDecimals), Math.Rounding.Floor);
    }

    /// @notice USD WAD value of a raw token amount, rounded up for risk-limit accounting.
    function valueWadUp(uint256 rawAmount, uint256 priceWad, uint8 tokenDecimals) internal pure returns (uint256) {
        return Math.mulDiv(rawAmount, priceWad, 10 ** uint256(tokenDecimals), Math.Rounding.Ceil);
    }

    /// @notice Raw token target for one asset's weight, rounded down.
    function targetRawAmount(uint256 portfolioValueWad, uint16 weightBps, uint256 priceWad, uint8 tokenDecimals)
        internal
        pure
        returns (uint256)
    {
        if (priceWad == 0) revert V2Errors.V2Errors__InvalidConfig("priceWad");
        if (weightBps == 0 || weightBps > BPS) {
            revert V2Errors.V2Errors__InvalidBps("weightBps", weightBps);
        }

        uint256 weightedValueWad = Math.mulDiv(portfolioValueWad, weightBps, BPS, Math.Rounding.Floor);
        return Math.mulDiv(weightedValueWad, 10 ** uint256(tokenDecimals), priceWad, Math.Rounding.Floor);
    }

    /// @notice Raw target units per 1e18 share units, rounded down.
    function targetUnitsPerShare(uint256 targetRaw, uint256 totalShares) internal pure returns (uint256) {
        if (totalShares == 0) revert V2Errors.V2Errors__InvalidInitialSupply(0);
        return Math.mulDiv(targetRaw, SHARE_WAD, totalShares, Math.Rounding.Floor);
    }

    /// @notice Live raw target from per-share units and live supply, rounded down.
    function liveTargetRaw(uint256 unitsPerShare, uint256 totalShares) internal pure returns (uint256) {
        return Math.mulDiv(unitsPerShare, totalShares, SHARE_WAD, Math.Rounding.Floor);
    }
}
