#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# One process per test_*.py module, never one process for the whole suite.
# A daemon thread, an open socket or a reused fd number left behind by an
# earlier module can then neither break a later module's test nor let a
# shared-process flake hide a real failure (SuperMox#11).
# Scratch logs live under build/, never /tmp.
log_dir="build/test-python"
rm -rf "$log_dir"
mkdir -p "$log_dir"

fail=0
total=0
modules=0

for f in tests/py/test_*.py; do
  module="${f#tests/py/}"
  module="${module%.py}"
  log="$log_dir/$module.log"
  started=$SECONDS
  if PYTHONPATH=src:tests/py python3 -m unittest "$module" >"$log" 2>&1; then
    status=ok
  else
    status=fail
    fail=1
  fi
  ran=$(grep -Eo '^Ran [0-9]+ test' "$log" | grep -Eo '[0-9]+' || true)
  ran=${ran:-0}
  total=$((total + ran))
  modules=$((modules + 1))
  printf '%-6s %s (%s tests, %ss)\n' "$status" "$module" "$ran" "$((SECONDS - started))"
  if [ "$status" = fail ]; then
    cat "$log"
  fi
done

if [ "$modules" -eq 0 ]; then
  echo "FAIL: no tests/py/test_*.py modules found"
  exit 1
fi

echo "Ran $total tests in ${SECONDS}s across $modules processes"
exit "$fail"
