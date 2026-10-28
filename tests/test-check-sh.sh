#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

target="scripts/check.sh"

if [ ! -f "$target" ]; then
  echo "FAIL: $target does not exist"
  exit 1
fi

if ! bash -n "$target"; then
  echo "FAIL: $target is not valid bash syntax"
  exit 1
fi

echo "OK: $target exists and has valid bash syntax"
