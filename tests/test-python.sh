#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

PYTHONPATH=src python3 -W error::ResourceWarning -m unittest discover -s tests/py -v
