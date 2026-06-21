#!/usr/bin/env bash
set -euo pipefail

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
usage_common() {
  cat <<'USAGE'
Usage: bash build.sh --arch amd64|arm64 [options]

Options:
  --arch ARCH             Target architecture: amd64 or arm64. Required.
  --source-dir DIR        Existing new-api source directory. If omitted, SOURCE_REPO is cloned.
  --source-repo URL       Source git repository. Default: https://github.com/QuantumNous/new-api.git
  --source-ref REF        Source branch/tag/commit. Default: main
  --version VERSION       Package/image version. Default: source ref + UTC timestamp.
  --image-prefix PREFIX   Local image prefix. Default: new-api-offline
  --keep-work             Keep temporary .work directory for debugging.
  -h, --help              Show this help.

Environment overrides:
  SOURCE_REPO, SOURCE_REF, IMAGE_VERSION, IMAGE_PREFIX
USAGE
}
parse_common_args() {
  ARCH="${ARCH:-}"
  SOURCE_DIR="${SOURCE_DIR:-}"
  SOURCE_REPO="${SOURCE_REPO:-https://github.com/QuantumNous/new-api.git}"
  SOURCE_REF="${SOURCE_REF:-main}"
  IMAGE_VERSION="${IMAGE_VERSION:-}"
  IMAGE_PREFIX="${IMAGE_PREFIX:-new-api-offline}"
  KEEP_WORK="${KEEP_WORK:-false}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --arch) ARCH="${2:-}"; shift 2 ;;
      --source-dir) SOURCE_DIR="${2:-}"; shift 2 ;;
      --source-repo) SOURCE_REPO="${2:-}"; shift 2 ;;
      --source-ref) SOURCE_REF="${2:-}"; shift 2 ;;
      --version) IMAGE_VERSION="${2:-}"; shift 2 ;;
      --image-prefix) IMAGE_PREFIX="${2:-}"; shift 2 ;;
      --keep-work) KEEP_WORK=true; shift ;;
      -h|--help) usage_common; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [[ -n "$ARCH" ]] || die "--arch is required"
  [[ "$ARCH" == "amd64" || "$ARCH" == "arm64" ]] || die "--arch must be amd64 or arm64"
  if [[ -z "$IMAGE_VERSION" ]]; then
    local safe_ref
    safe_ref="$(printf '%s' "$SOURCE_REF" | tr '/:@ ' '----' | tr -cd 'A-Za-z0-9_.-')"
    IMAGE_VERSION="${safe_ref:-main}-$(date -u '+%Y%m%d%H%M%S')"
  fi
}
prepare_source() {
  local work_dir="$1"
  if [[ -n "$SOURCE_DIR" ]]; then
    [[ -d "$SOURCE_DIR" ]] || die "--source-dir not found: $SOURCE_DIR"
    SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
    log "using source dir: $SOURCE_DIR"
    return
  fi
  need_cmd git
  SOURCE_DIR="$work_dir/source"
  log "cloning source: $SOURCE_REPO ref=$SOURCE_REF"
  git clone --depth 1 --branch "$SOURCE_REF" "$SOURCE_REPO" "$SOURCE_DIR" 2>/dev/null || {
    log "shallow branch clone failed; trying generic clone + checkout"
    git clone --depth 1 "$SOURCE_REPO" "$SOURCE_DIR"
    git -C "$SOURCE_DIR" fetch --depth 1 origin "$SOURCE_REF" || true
    git -C "$SOURCE_DIR" checkout "$SOURCE_REF"
  }
}
build_and_save_images() {
  local work_dir="$1"
  local payload_dir="$2"
  local package_name="$3"
  need_cmd docker
  mkdir -p "$payload_dir/images"

  APP_LOCAL_REF="${IMAGE_PREFIX}/new-api:${IMAGE_VERSION}-${ARCH}"
  REDIS_LOCAL_REF="redis:7.4-alpine"
  POSTGRES_LOCAL_REF="postgres:15-bookworm"

  log "building new-api image: $APP_LOCAL_REF platform=linux/$ARCH"
  docker buildx build --platform "linux/$ARCH" --load -t "$APP_LOCAL_REF" "$SOURCE_DIR"

  log "pulling dependency images for linux/$ARCH"
  docker pull --platform "linux/$ARCH" "$REDIS_LOCAL_REF"
  docker pull --platform "linux/$ARCH" "$POSTGRES_LOCAL_REF"

  cat > "$payload_dir/images/image-index.tsv" <<EOF_INDEX
component\tlocal_ref\ttarget_ref
new-api\t${APP_LOCAL_REF}\tnew-api:${IMAGE_VERSION}-${ARCH}
redis\t${REDIS_LOCAL_REF}\tredis:7.4-alpine
postgres\t${POSTGRES_LOCAL_REF}\tpostgres:15-bookworm
EOF_INDEX

  log "saving images to payload/images/images.tar"
  docker save -o "$payload_dir/images/images.tar" "$APP_LOCAL_REF" "$REDIS_LOCAL_REF" "$POSTGRES_LOCAL_REF"

  cat > "$payload_dir/images/build-info.env" <<EOF_INFO
PACKAGE_NAME=${package_name}
ARCH=${ARCH}
IMAGE_VERSION=${IMAGE_VERSION}
SOURCE_REPO=${SOURCE_REPO}
SOURCE_REF=${SOURCE_REF}
BUILD_TIME_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF_INFO
}
copy_payload_files() {
  local package_dir="$1"
  local payload_dir="$2"
  mkdir -p "$payload_dir"
  cp "$package_dir/install.sh" "$payload_dir/install.sh"
  chmod +x "$payload_dir/install.sh"
  if [[ -d "$package_dir/templates" ]]; then cp -a "$package_dir/templates" "$payload_dir/"; fi
  if [[ -d "$package_dir/manifests" ]]; then cp -a "$package_dir/manifests" "$payload_dir/"; fi
  cp "$package_dir/images/image.json" "$payload_dir/images/image.json"
}
write_launcher() {
  local out_file="$1"
  cat > "$out_file" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

payload_offset() {
  awk '
    BEGIN { pos = 0 }
    /^__PAYLOAD_BELOW__$/ { print pos + length($0) + 1; exit 0 }
    { pos += length($0) + 1 }
  ' "$0"
}

tmp_dir="$(mktemp -d /tmp/new-api-run.XXXXXX)"
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

offset="$(payload_offset)"
if [[ -z "$offset" || "$offset" == "0" ]]; then
  echo "payload marker not found" >&2
  exit 1
fi

tail -c +"$((offset + 1))" "$0" | tar -xzf - -C "$tmp_dir"
exec bash "$tmp_dir/install.sh" "$@"
exit 0
__PAYLOAD_BELOW__
LAUNCHER
}
make_run_package() {
  local package_dir="$1"
  local package_name="$2"
  local repo_root="$3"
  shift 3
  parse_common_args "$@"
  need_cmd tar
  need_cmd gzip
  need_cmd sha256sum
  need_cmd jq
  jq empty "$package_dir/images/image.json"

  local work_dir="$package_dir/.work/${package_name}-${ARCH}"
  local payload_dir="$work_dir/payload"
  local dist_dir="$package_dir/dist"
  rm -rf "$work_dir"
  mkdir -p "$payload_dir" "$dist_dir"

  prepare_source "$work_dir"
  copy_payload_files "$package_dir" "$payload_dir"
  build_and_save_images "$work_dir" "$payload_dir" "$package_name"

  (cd "$payload_dir" && tar -czf "$work_dir/payload.tar.gz" .)

  local out_name="new-api-${package_name}-installer-${ARCH}.run"
  local out_file="$dist_dir/$out_name"
  write_launcher "$out_file"
  cat "$work_dir/payload.tar.gz" >> "$out_file"
  chmod +x "$out_file"
  (cd "$dist_dir" && sha256sum "$out_name" > "$out_name.sha256")
  log "created: $out_file"
  log "created: $out_file.sha256"

  if [[ "$KEEP_WORK" != "true" ]]; then rm -rf "$work_dir"; else log "kept work dir: $work_dir"; fi
}
