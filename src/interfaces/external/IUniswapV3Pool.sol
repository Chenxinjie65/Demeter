// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IUniswapV3Pool
 * @notice Minimal Uniswap V3 pool interface required for TWAP observations.
 * @custom:security-contact https://github.com/Chenxinjie65/Demeter/security/advisories/new
 */
interface IUniswapV3Pool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
