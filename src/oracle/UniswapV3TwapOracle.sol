// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITwapOracle} from "src/interfaces/ITwapOracle.sol";
import {IUniswapV3Pool} from "src/interfaces/external/IUniswapV3Pool.sol";
import {V3OracleMath} from "src/libraries/uniswap/V3OracleMath.sol";

/**
 * @title UniswapV3TwapOracle
 * @notice Stateless Uniswap V3 arithmetic-mean-tick quote adapter.
 * @custom:security-contact security@demeter.protocol
 */
contract UniswapV3TwapOracle is ITwapOracle {
    error UniswapV3TwapOracle__InvalidWindow();
    error UniswapV3TwapOracle__InvalidPool(address pool, address base, address quote);
    error UniswapV3TwapOracle__AmountTooLarge(uint256 amount);
    error UniswapV3TwapOracle__InvalidObservation();

    /// @inheritdoc ITwapOracle
    function quote(address pool, address baseToken, address quoteToken, uint256 baseAmount, uint32 secondsAgo)
        external
        view
        returns (uint256 quoteAmount)
    {
        if (secondsAgo == 0) revert UniswapV3TwapOracle__InvalidWindow();
        if (baseAmount > type(uint128).max) revert UniswapV3TwapOracle__AmountTooLarge(baseAmount);
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();
        bool matches = (token0 == baseToken && token1 == quoteToken) || (token1 == baseToken && token0 == quoteToken);
        if (!matches) revert UniswapV3TwapOracle__InvalidPool(pool, baseToken, quoteToken);

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = secondsAgo;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        if (tickCumulatives.length != 2) revert UniswapV3TwapOracle__InvalidObservation();

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 window = int56(uint56(secondsAgo));
        int56 meanTick56 = delta / window;
        if (meanTick56 < int56(type(int24).min) || meanTick56 > int56(type(int24).max)) {
            revert UniswapV3TwapOracle__InvalidObservation();
        }
        int24 meanTick = int24(meanTick56);
        if (delta < 0 && delta % window != 0) --meanTick;
        quoteAmount = V3OracleMath.quoteAtTick(meanTick, uint128(baseAmount), baseToken, quoteToken);
    }
}
