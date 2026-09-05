#!/bin/bash
# Run all plugin logic tests. Requires node.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec node --test 'tests/*.mjs'
