#!/usr/bin/env bash
set -euo pipefail
DIR="$(dirname "$0")"
bash "$DIR/build-fixed.sh" "$@"
