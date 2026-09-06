// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockV2UniswapPool {
    address public immutable token0;
    address public immutable token1;
    int24 public meanTick;
    int56 public rawDelta;
    bool public useRawDelta;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setMeanTick(int24 tick) external {
        meanTick = tick;
        useRawDelta = false;
    }

    function setRawDelta(int56 delta) external {
        rawDelta = delta;
        useRawDelta = true;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        if (secondsAgos.length == 2) {
            tickCumulatives[1] = useRawDelta ? rawDelta : int56(meanTick) * int56(uint56(secondsAgos[0]));
        }
    }
}
