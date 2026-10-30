#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

check_file() {
  local f="$1"
  if ! bash -n "$f"; then
    echo "FAIL: bash -n $f"
    fail=1
  fi
  if ! shellcheck -S warning "$f"; then
    echo "FAIL: shellcheck $f"
    fail=1
  fi
}

lint_sh_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' f; do
    check_file "$f"
  done < <(find "$dir" -type f -name '*.sh' -print0)
}

lint_all_dir() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  while IFS= read -r -d '' f; do
    check_file "$f"
  done < <(find "$dir" -type f -print0)
}

lint_sh_dir scripts
lint_sh_dir tests
lint_all_dir init.d

if [ -d tests ]; then
  while IFS= read -r -d '' t; do
    # A hung test must not stall the gate (and the queue behind it): 10 minutes each.
    if ! timeout 600 bash "$t"; then
      echo "FAIL: test $t"
      fail=1
    fi
  done < <(find tests -type f -name 'test-*.sh' -print0)
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "All checks passed."
