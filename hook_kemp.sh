#!/usr/bin/env bash
# =============================================================================
# hook_kemp.sh — CertMate deploy hook for Kemp LoadMaster
#
# Uploads all CertMate certificates to one or more Kemp LoadMaster appliances
# after issuance or renewal.
#
# - New cert:     uploaded with replace=0
# - Existing cert: uploaded with replace=1 (Kemp auto-updates VS bindings)
# - VS binding is a manual step in the Kemp UI after first upload
#
# CertMate environment variables (set automatically):
#   CERTMATE_DOMAIN         Primary domain (e.g. example.com)
#   CERTMATE_KEY_PATH       Path to privkey.pem
#   CERTMATE_FULLCHAIN_PATH Path to fullchain.pem
#   CERTMATE_EVENT          Event type: issued | renewed
#
# Config file (default: /etc/certmate/kemp.yml):
#   Override with KEMP_CONFIG=/path/to/kemp.yml
#
# Credentials (per-host .env files, default: /etc/certmate/kemp.d/):
#   Override dir with KEMP_ENV_DIR=/path/to/dir
#   File named <hostname>.env containing:
#     KEMP_USER=admin
#     KEMP_PASS=secret
#   or:
#     KEMP_APIKEY=your-api-key
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${KEMP_CONFIG:-/etc/certmate/kemp.yml}"
ENV_DIR="${KEMP_ENV_DIR:-/etc/certmate/kemp.d}"
CURL_TIMEOUT="${KEMP_CURL_TIMEOUT:-30}"
CURL_CONNECT="${KEMP_CURL_CONNECT_TIMEOUT:-10}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------

log()  { printf '%s [%s] INFO  %s\n'  "$(date -Iseconds)" "$SCRIPT_NAME" "$*"; }
warn() { printf '%s [%s] WARN  %s\n'  "$(date -Iseconds)" "$SCRIPT_NAME" "$*" >&2; }
fail() { printf '%s [%s] ERROR %s\n'  "$(date -Iseconds)" "$SCRIPT_NAME" "$*" >&2; }

# -----------------------------------------------------------------------------
# Validate CertMate environment
# -----------------------------------------------------------------------------

: "${CERTMATE_DOMAIN:?CERTMATE_DOMAIN is not set}"
: "${CERTMATE_KEY_PATH:?CERTMATE_KEY_PATH is not set}"
: "${CERTMATE_FULLCHAIN_PATH:?CERTMATE_FULLCHAIN_PATH is not set}"
: "${CERTMATE_EVENT:?CERTMATE_EVENT is not set}"

log "Event=$CERTMATE_EVENT domain=$CERTMATE_DOMAIN"

case "$CERTMATE_EVENT" in
  issued|renewed) ;;
  *)
    log "Event '$CERTMATE_EVENT' does not require Kemp deployment — exiting."
    exit 0
    ;;
esac

for f in "$CERTMATE_KEY_PATH" "$CERTMATE_FULLCHAIN_PATH"; do
  [ -s "$f" ] || { fail "Required file is missing or empty: $f"; exit 1; }
done

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------

[ -f "$CONFIG_FILE" ] || { fail "Config file not found: $CONFIG_FILE"; exit 1; }
command -v yq   >/dev/null 2>&1 || { fail "yq v4+ is required but not found in PATH"; exit 1; }
command -v curl >/dev/null 2>&1 || { fail "curl is required but not found in PATH"; exit 1; }

kemps_n="$(yq '. | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
if [ "$kemps_n" -eq 0 ]; then
  log "No Kemp entries in $CONFIG_FILE — nothing to do."
  exit 0
fi

# -----------------------------------------------------------------------------
# Build combined PEM (privkey + fullchain) — Kemp expects both in one file
# -----------------------------------------------------------------------------

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

BUNDLE="$tmpd/bundle.pem"
cat "$CERTMATE_KEY_PATH" "$CERTMATE_FULLCHAIN_PATH" > "$BUNDLE"
log "Built combined PEM bundle for $CERTMATE_DOMAIN"

# -----------------------------------------------------------------------------
# Certificate alias — derived from domain name (dots replaced by dashes)
# -----------------------------------------------------------------------------

cert_alias="$(
  printf '%s' "$CERTMATE_DOMAIN" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -e 's/[^a-z0-9.-]/-/g' \
        -e 's/\./-/g' \
        -e 's/-\{2,\}/-/g' \
        -e 's/^-//' \
        -e 's/-$//'
)"
log "Certificate alias: $cert_alias"

# -----------------------------------------------------------------------------
# Credential resolution
# Per-host .env files named after the Kemp hostname:
#   /etc/certmate/kemp.d/<hostname>.env
# -----------------------------------------------------------------------------

load_host_env() {
  local url="$1"
  local host
  host="$(printf '%s' "$url" | sed -E 's#^https?://([^/:]+).*#\1#')"
  local env_file="${ENV_DIR}/${host}.env"
  unset KEMP_USER KEMP_PASS KEMP_APIKEY
  if [ -f "$env_file" ]; then
    # shellcheck source=/dev/null
    . "$env_file"
    log "Loaded credentials from $env_file"
  else
    warn "No .env file found for host '$host' (expected $env_file)"
  fi
}

# Query string suffix for API key auth, empty for basic auth
kemp_auth_qs() {
  [ -n "${KEMP_APIKEY:-}" ] && printf '&apikey=%s' "$KEMP_APIKEY" || printf ''
}

# Curl flags for basic auth, empty for API key auth
kemp_auth_flags() {
  if [ -z "${KEMP_APIKEY:-}" ] && [ -n "${KEMP_USER:-}" ]; then
    printf '%s' "-u ${KEMP_USER}:${KEMP_PASS}"
  fi
}

# -----------------------------------------------------------------------------
# Kemp API helpers
# -----------------------------------------------------------------------------

kemp_resp_ok() {
  printf '%s' "$1" | grep -qiE 'code="ok"|<Success>'
}

kemp_listcert_has() {
  local url="$1" alias="$2"
  local auth_qs auth_flags
  auth_qs="$(kemp_auth_qs)"
  auth_flags="$(kemp_auth_flags)"
  # shellcheck disable=SC2086
  curl -sk $auth_flags \
    --max-time "$CURL_TIMEOUT" \
    --connect-timeout "$CURL_CONNECT" \
    "${url%/}/access/listcert${auth_qs}" | grep -q "$alias"
}

kemp_addcert() {
  local url="$1" alias="$2" pem="$3" replace="$4"
  local auth_qs auth_flags tmp code body
  auth_qs="$(kemp_auth_qs)"
  auth_flags="$(kemp_auth_flags)"
  tmp="$(mktemp)"
  # shellcheck disable=SC2086
  code="$(
    curl -sk $auth_flags \
      --max-time "$CURL_TIMEOUT" \
      --connect-timeout "$CURL_CONNECT" \
      -H 'Content-Type: text/plain' \
      --data-binary "@${pem}" \
      --write-out "%{http_code}" \
      --output "$tmp" \
      "${url%/}/access/addcert?cert=${alias}&replace=${replace}${auth_qs}"
  )"
  body="$(tr -d '\r' < "$tmp")"; rm -f "$tmp"
  if [ "$code" = "200" ] && kemp_resp_ok "$body"; then
    return 0
  fi
  printf 'HTTP %s :: %s\n' "$code" "$(printf '%s' "$body" | tr -d '\n' | cut -c1-400)" >&2
  return 1
}

kemp_delcert() {
  local url="$1" alias="$2"
  local auth_qs auth_flags
  auth_qs="$(kemp_auth_qs)"
  auth_flags="$(kemp_auth_flags)"
  # shellcheck disable=SC2086
  curl -sk $auth_flags \
    --max-time "$CURL_TIMEOUT" \
    --connect-timeout "$CURL_CONNECT" \
    "${url%/}/access/delcert?cert=${alias}${auth_qs}" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Deploy to one Kemp — runs in subshell for parallel execution
# -----------------------------------------------------------------------------

deploy_to_kemp() {
  local k="$1"
  local url alias_override alias

  url="$(yq -r ".[$k].url" "$CONFIG_FILE")"
  alias_override="$(yq -r ".[$k].cert_alias // \"\"" "$CONFIG_FILE")"
  alias="${alias_override:-$cert_alias}"

  load_host_env "$url"

  if [ -z "${KEMP_APIKEY:-}" ] && { [ -z "${KEMP_USER:-}" ] || [ -z "${KEMP_PASS:-}" ]; }; then
    fail "Credentials missing for $url"
    return 1
  fi

  log "Processing Kemp at $url (alias '$alias')"

  local exists=false
  kemp_listcert_has "$url" "$alias" && exists=true

  if $exists; then
    log "Cert '$alias' exists — replacing at $url"
    local out
    if ! out="$(kemp_addcert "$url" "$alias" "$BUNDLE" 1 2>&1)"; then
      if printf '%s' "$out" | grep -qi 'Identifier has been deleted'; then
        log "Tombstoned alias detected — purging and retrying"
        kemp_delcert "$url" "$alias"
        sleep 1
        kemp_addcert "$url" "$alias" "$BUNDLE" 0 \
          || { fail "Retry after tombstone failed for '$alias' at $url :: $out"; return 1; }
      else
        fail "Replace failed for '$alias' at $url :: $out"
        return 1
      fi
    fi
    log "Replace OK — Kemp auto-updates VS bindings for '$alias' at $url"
  else
    log "Cert '$alias' not found — uploading as new to $url"
    local out
    out="$(kemp_addcert "$url" "$alias" "$BUNDLE" 0 2>&1)" \
      || { fail "Upload failed for '$alias' at $url :: $out"; return 1; }
    log "Upload OK — bind '$alias' to a VS manually in the Kemp UI"
  fi

  log "Deploy complete for $url"
}

# -----------------------------------------------------------------------------
# Main — deploy to all Kemps in parallel
# -----------------------------------------------------------------------------

tmpout="$tmpd/results"
mkdir -p "$tmpout"
pids=()

for k in $(seq 0 $((kemps_n - 1))); do
  (
    deploy_to_kemp "$k"
    echo $? > "$tmpout/$k.exit"
  ) &
  pids+=($!)
done

errors=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || true
  k="$i"
  exit_code=0
  [ -f "$tmpout/$k.exit" ] && exit_code="$(cat "$tmpout/$k.exit")"
  [ "$exit_code" -ne 0 ] && errors=$((errors + 1))
done

if [ "$errors" -gt 0 ]; then
  fail "$errors error(s) during Kemp deployment for $CERTMATE_DOMAIN"
  exit 1
fi

log "All Kemp deployments completed successfully for $CERTMATE_DOMAIN"
exit 0
