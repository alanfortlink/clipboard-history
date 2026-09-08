#!/bin/bash
# Run all plugin logic tests. Requires node and python3.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
python3 -m unittest discover -s tests -p 'test_capture.py'
exec node --test 'tests/*.mjs'
