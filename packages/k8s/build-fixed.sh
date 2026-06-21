#!/usr/bin/env bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PACKAGE_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/offline_build_lib.sh"
copy_payload_files() {
  local package_dir="$1"
  local payload_dir="$2"
  mkdir -p "$payload_dir/images"
  cp "$package_dir/install.sh" "$payload_dir/install.sh"
  chmod +x "$payload_dir/install.sh"
  cp -a "$package_dir/manifests" "$payload_dir/"
  cp "$package_dir/images/image.json" "$payload_dir/images/image.json"
}
make_run_package "$PACKAGE_DIR" "k8s" "$REPO_ROOT" "$@"
