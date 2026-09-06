#!/usr/bin/env bash
set -euo pipefail

check_size() {
  local contract="$1"
  local maximum="$2"
  local bytecode
  local size
  bytecode="$(forge inspect "$contract" deployedBytecode)"
  size=$(( (${#bytecode} - 2) / 2 ))
  echo "$contract runtime size: $size bytes (limit: $maximum)"
  if (( size > maximum )); then
    echo "$contract exceeds the configured runtime-size gate" >&2
    exit 1
  fi
}

check_size AssetRegistry 6000
check_size DemeterManager 22000
check_size IndexPolicy 14000
check_size AuctionRebalance 23500
check_size DemeterBasketRouter 6000
