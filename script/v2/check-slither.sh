#!/usr/bin/env bash
set -euo pipefail

report_dir="$(mktemp -d "${TMPDIR:-/tmp}/demeter-v2-slither.XXXXXX")"
output="$report_dir/report.json"
filters='lib|test|script|src/core/DemeterFactory.sol|src/core/DemeterRouter.sol|src/core/DemeterVault.sol|src/core/ProtocolAddressProvider.sol|src/modules|src/libraries/Constants.sol|src/libraries/DataTypes.sol|src/libraries/Errors.sol|src/libraries/FlashAccounting.sol|src/libraries/TransientLock.sol|src/libraries/VaultMath.sol|src/libraries/VaultStorage.sol|src/interfaces/core|src/interfaces/modules|src/interfaces/external/IAaveV3.sol|src/interfaces/external/ISequencerOracle.sol|src/interfaces/external/IUniswapV3.sol|src/interfaces/external/IWETH.sol'

command -v slither >/dev/null || {
  echo "slither is required for the V2 static-analysis gate" >&2
  exit 1
}

slither . \
  --exclude-dependencies \
  --filter-paths "$filters" \
  --fail-high \
  --json "$output"

echo "V2 Slither report: $output"
