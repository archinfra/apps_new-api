#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-help}"; shift || true
INSTALL_DIR="${INSTALL_DIR:-/opt/new-api}"
REGISTRY="${REGISTRY:-}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_PASS="${REGISTRY_PASS:-}"
SKIP_IMAGE_PREPARE=false
YES=false
DANGER_DELETE_DATA=false
APP_PORT="${APP_PORT:-3000}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-new-api-change-me}"
REDIS_PASSWORD="${REDIS_PASSWORD:-new-api-change-me}"
SESSION_SECRET="${SESSION_SECRET:-change-me-please}"
TZ_VALUE="${TZ:-Asia/Shanghai}"
NEW_API_LOCAL=""
NEW_API_TARGET=""
REDIS_LOCAL=""
REDIS_TARGET=""
POSTGRES_LOCAL=""
POSTGRES_TARGET=""

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }
usage() {
  cat <<'USAGE'
New-API Compose offline installer

Usage:
  ./new-api-compose-installer-amd64.run install [options]
  ./new-api-compose-installer-amd64.run status [options]
  ./new-api-compose-installer-amd64.run uninstall [options]

Options:
  --install-dir DIR
  --registry PREFIX
  --registry-user USER
  --registry-pass PASS
  --skip-image-prepare
  --app-port PORT
  --postgres-password PASS
  --redis-password PASS
  --session-secret SECRET
  --tz TZ
  --danger-delete-data
  -y, --yes
USAGE
}
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
      --registry) REGISTRY="${2:-}"; shift 2 ;;
      --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
      --registry-pass) REGISTRY_PASS="${2:-}"; shift 2 ;;
      --skip-image-prepare) SKIP_IMAGE_PREPARE=true; shift ;;
      --app-port) APP_PORT="${2:-}"; shift 2 ;;
      --postgres-password) POSTGRES_PASSWORD="${2:-}"; shift 2 ;;
      --redis-password) REDIS_PASSWORD="${2:-}"; shift 2 ;;
      --session-secret) SESSION_SECRET="${2:-}"; shift 2 ;;
      --tz) TZ_VALUE="${2:-}"; shift 2 ;;
      --danger-delete-data) DANGER_DELETE_DATA=true; shift ;;
      -y|--yes) YES=true; shift ;;
      -h|--help) ACTION=help; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}
confirm() { [[ "$YES" == "true" ]] && return 0; read -r -p "$1 [y/N] " ans; [[ "$ans" == y || "$ans" == Y ]]; }
script_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
trim_slash() { printf '%s' "$1" | sed 's#/*$##'; }
trim_ws() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
compose_cmd() { if docker compose version >/dev/null 2>&1; then echo "docker compose"; elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; else die "missing docker compose"; fi; }
target_for() {
  local target_ref="$1"
  local local_ref="$2"
  [[ -n "$target_ref" ]] || target_ref="$local_ref"
  if [[ -n "$REGISTRY" ]]; then printf '%s/%s' "$(trim_slash "$REGISTRY")" "$target_ref"; else printf '%s' "$local_ref"; fi
}
validate_image_map() {
  local f="$1"
  local missing=""
  [[ -n "$NEW_API_LOCAL" && -n "$NEW_API_TARGET" ]] || missing="${missing} new-api"
  [[ -n "$REDIS_LOCAL" && -n "$REDIS_TARGET" ]] || missing="${missing} redis"
  [[ -n "$POSTGRES_LOCAL" && -n "$POSTGRES_TARGET" ]] || missing="${missing} postgres"
  if [[ -n "$missing" ]]; then
    printf '[ERROR] invalid image index: %s\n' "$f" >&2
    printf '[ERROR] missing component(s):%s\n' "$missing" >&2
    printf '[ERROR] first lines of image-index.tsv:\n' >&2
    sed -n '1,20p' "$f" >&2 || true
    exit 1
  fi
}
load_image_map() {
  local f="$(script_dir)/images/image-index.tsv"
  local line component local_ref target_ref _extra
  NEW_API_LOCAL=""; NEW_API_TARGET=""; REDIS_LOCAL=""; REDIS_TARGET=""; POSTGRES_LOCAL=""; POSTGRES_TARGET=""
  [[ -f "$f" ]] || die "missing image index: $f"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$(trim_ws "$line")" ]] && continue
    [[ "$(trim_ws "$line")" == \#* ]] && continue
    line="${line//\\t/$'\t'}"
    IFS=$'\t' read -r component local_ref target_ref _extra <<< "$line"
    component="$(trim_ws "${component:-}")"
    local_ref="$(trim_ws "${local_ref:-}")"
    target_ref="$(trim_ws "${target_ref:-}")"
    [[ "$component" == "component" ]] && continue
    case "$component" in
      new-api) NEW_API_LOCAL="$local_ref"; NEW_API_TARGET="$(target_for "$target_ref" "$local_ref")" ;;
      redis) REDIS_LOCAL="$local_ref"; REDIS_TARGET="$(target_for "$target_ref" "$local_ref")" ;;
      postgres) POSTGRES_LOCAL="$local_ref"; POSTGRES_TARGET="$(target_for "$target_ref" "$local_ref")" ;;
    esac
  done < "$f"
  validate_image_map "$f"
}
prepare_images() {
  [[ "$SKIP_IMAGE_PREPARE" == true ]] && { log "skip image prepare"; return; }
  need_cmd docker
  local tar_file="$(script_dir)/images/images.tar"
  [[ -f "$tar_file" ]] || die "missing images tar: $tar_file"
  docker load -i "$tar_file"
  if [[ -n "$REGISTRY" ]]; then
    if [[ -n "$REGISTRY_USER" || -n "$REGISTRY_PASS" ]]; then
      [[ -n "$REGISTRY_USER" && -n "$REGISTRY_PASS" ]] || die "registry user/pass must be provided together"
      printf '%s' "$REGISTRY_PASS" | docker login "$(trim_slash "$REGISTRY")" -u "$REGISTRY_USER" --password-stdin
    fi
    for pair in "$NEW_API_LOCAL $NEW_API_TARGET" "$REDIS_LOCAL $REDIS_TARGET" "$POSTGRES_LOCAL $POSTGRES_TARGET"; do
      src="${pair%% *}"; dst="${pair#* }"; docker tag "$src" "$dst"; docker push "$dst"
    done
  fi
}
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&]/\\&/g'; }
render_compose() {
  mkdir -p "$INSTALL_DIR/data" "$INSTALL_DIR/logs"
  sed \
    -e "s#__NEW_API_IMAGE__#$(sed_escape "$NEW_API_TARGET")#g" \
    -e "s#__REDIS_IMAGE__#$(sed_escape "$REDIS_TARGET")#g" \
    -e "s#__POSTGRES_IMAGE__#$(sed_escape "$POSTGRES_TARGET")#g" \
    "$(script_dir)/templates/docker-compose.yml" > "$INSTALL_DIR/docker-compose.yml"
  cat > "$INSTALL_DIR/.env" <<EOF_ENV
APP_PORT=${APP_PORT}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
SESSION_SECRET=${SESSION_SECRET}
TZ=${TZ_VALUE}
EOF_ENV
  chmod 600 "$INSTALL_DIR/.env"
}
do_install() {
  need_cmd docker; load_image_map
  echo "Install dir: $INSTALL_DIR"
  echo "New-API image: $NEW_API_TARGET"
  echo "Redis image: $REDIS_TARGET"
  echo "Postgres image: $POSTGRES_TARGET"
  confirm "Continue?" || die "cancelled"
  prepare_images
  render_compose
  dc="$(compose_cmd)"
  (cd "$INSTALL_DIR" && $dc up -d)
  log "done: http://127.0.0.1:${APP_PORT}"
}
do_status() { load_image_map; printf 'new-api=%s\nredis=%s\npostgres=%s\n' "$NEW_API_TARGET" "$REDIS_TARGET" "$POSTGRES_TARGET"; [[ -f "$INSTALL_DIR/docker-compose.yml" ]] && (cd "$INSTALL_DIR" && $(compose_cmd) ps) || true; }
do_uninstall() { [[ -f "$INSTALL_DIR/docker-compose.yml" ]] || die "compose file not found"; confirm "Stop New-API compose stack?" || die "cancelled"; if [[ "$DANGER_DELETE_DATA" == true ]]; then (cd "$INSTALL_DIR" && $(compose_cmd) down -v); rm -rf "$INSTALL_DIR/data" "$INSTALL_DIR/logs"; else (cd "$INSTALL_DIR" && $(compose_cmd) down); fi; }

parse_args "$@"
case "$ACTION" in
  install) do_install ;;
  status) do_status ;;
  uninstall) do_uninstall ;;
  print-images) load_image_map; printf '%s\n%s\n%s\n' "$NEW_API_TARGET" "$REDIS_TARGET" "$POSTGRES_TARGET" ;;
  help|--help|-h) usage ;;
  *) usage; die "unknown action: $ACTION" ;;
esac
