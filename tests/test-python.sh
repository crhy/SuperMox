#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# test_manager_websocket runs in its own process: its fake TLS server and the
# client share the test process, and under the full suite one handshake test
# lost its live connection about 1 run in 5 (crhy/SuperMox issue, see
# tests/py/test_manager_websocket.py _EchoServer); alone it has passed every
# run. Every module still runs; none is skipped.
mapfile -t mods < <(find tests/py -maxdepth 1 -name 'test_*.py' ! -name 'test_manager_websocket.py' \
  -printf '%f\n' | sed 's/\.py$//' | LC_ALL=C sort)
PYTHONPATH=src:tests/py python3 -W error::ResourceWarning -m unittest -v "${mods[@]}"
PYTHONPATH=src:tests/py python3 -W error::ResourceWarning -m unittest -v test_manager_websocket
