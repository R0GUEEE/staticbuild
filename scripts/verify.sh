#!/bin/sh
# Thin wrapper kept for recipes and muscle memory: scripts/verify.py does the
# work. See that file for the checks and the exit codes.
set -eu
exec python3 "$(cd "$(dirname "$0")" && pwd)/verify.py" "$@"
