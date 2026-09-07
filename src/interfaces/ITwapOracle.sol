// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ITwapOracle
 * @notice Stateless external-market TWAP quote interface.
 * @custom:security-contact security@demeter.protocol
 */
interface ITwapOracle {
    /// @notice Quote a base amount through an approved external TWAP pool.
    /// @param pool Uniswap V3 pool address.
    /// @param baseToken Base token in native units.
    /// @param quoteToken Quote token in native units.
    /// @param baseAmount Amount of baseToken to quote.
    /// @param secondsAgo TWAP observation window in seconds.
    /// @return quoteAmount Amount of quoteToken, normalized to its native decimals.
    function quote(address pool, address baseToken, address quoteToken, uint256 baseAmount, uint32 secondsAgo)
        external
        view
        returns (uint256 quoteAmount);
}
