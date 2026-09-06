#!/usr/bin/env bash
set -euo pipefail

v2_paths=(
  src/core/AssetRegistry.sol
  src/core/AuctionRebalance.sol
  src/core/DemeterBasketRouter.sol
  src/core/DemeterManager.sol
  src/core/DemeterShare.sol
  src/core/IndexPolicy.sol
  src/interfaces/IAssetRegistry.sol
  src/interfaces/IAuctionRebalance.sol
  src/interfaces/IDemeterBasketRouter.sol
  src/interfaces/IDemeterManager.sol
  src/interfaces/IDemeterShare.sol
  src/interfaces/IIndexPolicy.sol
  src/interfaces/ITwapOracle.sol
  src/interfaces/external/IChainlinkAggregator.sol
  src/interfaces/external/IUniswapV3Pool.sol
  src/libraries/AuctionMath.sol
  src/libraries/OracleGuard.sol
  src/libraries/PoolId.sol
  src/libraries/ProportionalMath.sol
  src/libraries/V2Errors.sol
  src/libraries/V2Validation.sol
  src/libraries/uniswap/TickMath.sol
  src/libraries/uniswap/V3OracleMath.sol
  src/oracle/UniswapV3TwapOracle.sol
  src/types/PoolTypes.sol
  src/types/RebalanceTypes.sol
  test/v2
  script/v2
)

forge fmt --check "${v2_paths[@]}"
