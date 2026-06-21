#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PACKAGE_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/offline_build_lib.sh"
make_run_package "$PACKAGE_DIR" "k8s" "$REPO_ROOT" "$@"
