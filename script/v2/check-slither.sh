#!/usr/bin/env bash
set -euo pipefail

report_dir="$(mktemp -d "${TMPDIR:-/tmp}/demeter-v2-slither.XXXXXX")"
output="$report_dir/report.json"
filters='lib|test|script'

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
