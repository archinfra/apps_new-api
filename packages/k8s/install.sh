#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-help}"; shift || true
NAMESPACE="${NAMESPACE:-new-api}"
REGISTRY="${REGISTRY:-}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_PASS="${REGISTRY_PASS:-}"
SKIP_IMAGE_PREPARE=false
YES=false
DANGER_DELETE_DATA=false
SERVICE_TYPE="${SERVICE_TYPE:-NodePort}"
NODE_PORT="${NODE_PORT:-30080}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-new-api-change-me}"
REDIS_PASSWORD="${REDIS_PASSWORD:-new-api-change-me}"
SESSION_SECRET="${SESSION_SECRET:-change-me-please}"
TZ_VALUE="${TZ:-Asia/Shanghai}"
POSTGRES_STORAGE_SIZE="${POSTGRES_STORAGE_SIZE:-10Gi}"
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
New-API Kubernetes offline installer

Usage:
  ./new-api-k8s-installer-amd64.run install [options]
  ./new-api-k8s-installer-amd64.run status [options]
  ./new-api-k8s-installer-amd64.run uninstall [options]

Options:
  -n, --namespace NS
  --registry PREFIX
  --registry-user USER
  --registry-pass PASS
  --skip-image-prepare
  --service-type TYPE
  --node-port PORT
  --postgres-password PASS
  --redis-password PASS
  --session-secret SECRET
  --postgres-storage-size SIZE
  --tz TZ
  --danger-delete-data
  -y, --yes
USAGE
}
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
      --registry) REGISTRY="${2:-}"; shift 2 ;;
      --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
      --registry-pass) REGISTRY_PASS="${2:-}"; shift 2 ;;
      --skip-image-prepare) SKIP_IMAGE_PREPARE=true; shift ;;
      --service-type) SERVICE_TYPE="${2:-}"; shift 2 ;;
      --node-port) NODE_PORT="${2:-}"; shift 2 ;;
      --postgres-password) POSTGRES_PASSWORD="${2:-}"; shift 2 ;;
      --redis-password) REDIS_PASSWORD="${2:-}"; shift 2 ;;
      --session-secret) SESSION_SECRET="${2:-}"; shift 2 ;;
      --postgres-storage-size) POSTGRES_STORAGE_SIZE="${2:-}"; shift 2 ;;
      --tz) TZ_VALUE="${2:-}"; shift 2 ;;
      --danger-delete-data) DANGER_DELETE_DATA=true; shift ;;
      -y|--yes) YES=true; shift ;;
      -h|--help) ACTION=help; shift ;;
      *) die "unknown argument: $1" ;;
    esac
  done
}
confirm() { [[ "$YES" == true ]] && return 0; read -r -p "$1 [y/N] " ans; [[ "$ans" == y || "$ans" == Y ]]; }
script_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" && pwd; }
trim_slash() { printf '%s' "$1" | sed 's#/*$##'; }
trim_ws() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
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
  [[ -n "$REGISTRY" ]] || { log "no registry set; Kubernetes nodes must already have local images"; return; }
  if [[ -n "$REGISTRY_USER" || -n "$REGISTRY_PASS" ]]; then
    [[ -n "$REGISTRY_USER" && -n "$REGISTRY_PASS" ]] || die "registry user/pass must be provided together"
    printf '%s' "$REGISTRY_PASS" | docker login "$(trim_slash "$REGISTRY")" -u "$REGISTRY_USER" --password-stdin
  fi
  for pair in "$NEW_API_LOCAL $NEW_API_TARGET" "$REDIS_LOCAL $REDIS_TARGET" "$POSTGRES_LOCAL $POSTGRES_TARGET"; do
    src="${pair%% *}"; dst="${pair#* }"; docker tag "$src" "$dst"; docker push "$dst"
  done
}
sed_escape() { printf '%s' "$1" | sed -e 's/[\\&]/\\&/g'; }
render_manifest() {
  local out_dir="/tmp/new-api-k8s-rendered-${NAMESPACE}"
  mkdir -p "$out_dir"
  local node_port_line=""
  [[ "$SERVICE_TYPE" == NodePort ]] && node_port_line="    nodePort: ${NODE_PORT}"
  local sql_dsn="postgresql://root:${POSTGRES_PASSWORD}@new-api-postgres:5432/new-api"
  local redis_dsn="redis://:${REDIS_PASSWORD}@new-api-redis:6379"
  sed \
    -e "s#__NAMESPACE__#$(sed_escape "$NAMESPACE")#g" \
    -e "s#__NEW_API_IMAGE__#$(sed_escape "$NEW_API_TARGET")#g" \
    -e "s#__REDIS_IMAGE__#$(sed_escape "$REDIS_TARGET")#g" \
    -e "s#__POSTGRES_IMAGE__#$(sed_escape "$POSTGRES_TARGET")#g" \
    -e "s#__SQL_DSN__#$(sed_escape "$sql_dsn")#g" \
    -e "s#__REDIS_CONN_STRING__#$(sed_escape "$redis_dsn")#g" \
    -e "s#__POSTGRES_PASSWORD__#$(sed_escape "$POSTGRES_PASSWORD")#g" \
    -e "s#__REDIS_PASSWORD__#$(sed_escape "$REDIS_PASSWORD")#g" \
    -e "s#__SESSION_SECRET__#$(sed_escape "$SESSION_SECRET")#g" \
    -e "s#__TZ__#$(sed_escape "$TZ_VALUE")#g" \
    -e "s#__SERVICE_TYPE__#$(sed_escape "$SERVICE_TYPE")#g" \
    -e "s#__NODE_PORT_LINE__#$(sed_escape "$node_port_line")#g" \
    -e "s#__POSTGRES_STORAGE_SIZE__#$(sed_escape "$POSTGRES_STORAGE_SIZE")#g" \
    "$(script_dir)/manifests/new-api.yaml" > "$out_dir/new-api.yaml"
  printf '%s' "$out_dir/new-api.yaml"
}
do_install() {
  need_cmd kubectl; load_image_map
  echo "Namespace: $NAMESPACE"
  echo "New-API image: $NEW_API_TARGET"
  echo "Redis image: $REDIS_TARGET"
  echo "Postgres image: $POSTGRES_TARGET"
  confirm "Continue?" || die "cancelled"
  prepare_images
  manifest="$(render_manifest)"
  kubectl apply -f "$manifest"
  log "done. kubectl get pods,svc,deploy,statefulset,pvc -n $NAMESPACE"
}
do_status() { need_cmd kubectl; load_image_map; printf 'new-api=%s\nredis=%s\npostgres=%s\n' "$NEW_API_TARGET" "$REDIS_TARGET" "$POSTGRES_TARGET"; kubectl get pods,svc,deploy,statefulset,pvc -n "$NAMESPACE" || true; }
do_uninstall() { need_cmd kubectl; load_image_map; manifest="$(render_manifest)"; confirm "Delete New-API Kubernetes resources?" || die "cancelled"; if [[ "$DANGER_DELETE_DATA" == true ]]; then kubectl delete -f "$manifest" --ignore-not-found=true; else kubectl delete deploy/new-api deploy/new-api-redis svc/new-api svc/new-api-redis svc/new-api-postgres secret/new-api-secret statefulset/new-api-postgres -n "$NAMESPACE" --ignore-not-found=true; fi; }

parse_args "$@"
case "$ACTION" in
  install) do_install ;;
  status) do_status ;;
  uninstall) do_uninstall ;;
  print-images) load_image_map; printf '%s\n%s\n%s\n' "$NEW_API_TARGET" "$REDIS_TARGET" "$POSTGRES_TARGET" ;;
  help|--help|-h) usage ;;
  *) usage; die "unknown action: $ACTION" ;;
esac
