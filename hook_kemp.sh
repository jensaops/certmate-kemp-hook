#!/usr/bin/env bash
# =============================================================================
# hook_kemp.sh — CertMate deploy hook for Kemp LoadMaster
#
# Triggered by CertMate after a certificate is issued or renewed.
# Reads a YAML config to determine which Kemp appliances to push to based on
# domain mapping. On first upload binds the certificate to configured Virtual
# Services. On renewal, replace=1 causes Kemp to automatically update all
# existing VS bindings — no explicit rebind needed.
#
# CertMate environment variables:
#   CERTMATE_DOMAIN         Primary domain (e.g. example.com or *.example.com)
#   CERTMATE_CERT_PATH      Path to cert.pem
#   CERTMATE_KEY_PATH       Path to privkey.pem
#   CERTMATE_FULLCHAIN_PATH Path to fullchain.pem
#   CERTMATE_EVENT          Event type: issued | renewed | expired
#
# Config file (default: /etc/certmate/kemp.yml):
#   Override with KEMP_CONFIG env var.
#
# Credentials (per-host .env files, default dir: /etc/certmate/kemp.d/):
#   Override dir with KEMP_ENV_DIR env var.
#   Each file named <hostname>.env exports KEMP_USER + KEMP_PASS
#   or KEMP_APIKEY for API key authentication.
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
: "${CERTMATE_CERT_PATH:?CERTMATE_CERT_PATH is not set}"
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

for f in "$CERTMATE_CERT_PATH" "$CERTMATE_KEY_PATH" "$CERTMATE_FULLCHAIN_PATH"; do
  [ -s "$f" ] || { fail "Required file is missing or empty: $f"; exit 1; }
done

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------

[ -f "$CONFIG_FILE" ] || { fail "Config file not found: $CONFIG_FILE"; exit 1; }
command -v yq >/dev/null 2>&1 || { fail "yq v4+ is required but not found in PATH"; exit 1; }
command -v curl >/dev/null 2>&1 || { fail "curl is required but not found in PATH"; exit 1; }

# -----------------------------------------------------------------------------
# Build combined PEM (key + fullchain) — Kemp expects both in one file
# -----------------------------------------------------------------------------

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

BUNDLE="$tmpd/bundle.pem"
cat "$CERTMATE_KEY_PATH" "$CERTMATE_FULLCHAIN_PATH" > "$BUNDLE"
log "Built combined PEM bundle for $CERTMATE_DOMAIN"

# -----------------------------------------------------------------------------
# Certificate alias derived from domain name
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
# Domain matching — support exact and wildcard patterns
# -----------------------------------------------------------------------------

match_domain() {
  local pattern="$1" domain="$2"
  case "$pattern" in
    \*.*)
      local base="${pattern#\*.}"
      case "$domain" in
        *".$base"|"$base") return 0 ;;
      esac
      ;;
    *)
      [ "$pattern" = "$domain" ] && return 0
      ;;
  esac
  return 1
}

# -----------------------------------------------------------------------------
# Credential resolution — basic auth or API key
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

# Returns query string suffix for API key auth, or empty for basic auth
kemp_auth_qs() {
  [ -n "${KEMP_APIKEY:-}" ] && printf '&apikey=%s' "$KEMP_APIKEY" || printf ''
}

# Returns curl flags for basic auth, or empty for API key auth
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

kemp_get() {
  local url="$1" path="$2"
  local auth_qs auth_flags
  auth_qs="$(kemp_auth_qs)"
  auth_flags="$(kemp_auth_flags)"
  # shellcheck disable=SC2086
  curl -sk $auth_flags \
    --max-time "$CURL_TIMEOUT" \
    --connect-timeout "$CURL_CONNECT" \
    "${url%/}${path}${auth_qs}"
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
  kemp_get "$url" "/access/delcert?cert=${alias}" >/dev/null 2>&1 || true
}

kemp_listcert_has() {
  local url="$1" alias="$2"
  kemp_get "$url" "/access/listcert" | grep -q "$alias"
}

# VS list is cached per URL to avoid redundant API calls when binding multiple VSes
_VS_LIST_CACHE=""
_VS_LIST_CACHE_URL=""

kemp_vs_list() {
  local url="$1"
  if [ "$_VS_LIST_CACHE_URL" != "$url" ]; then
    _VS_LIST_CACHE="$(kemp_get "$url" "/access/listvs" | tr -d '\r')"
    _VS_LIST_CACHE_URL="$url"
  fi
  printf '%s' "$_VS_LIST_CACHE"
}

kemp_resolve_vs_index() {
  local url="$1" handle="$2"
  case "$handle" in
    index:*)
      local idx="${handle#index:}"
      case "$idx" in (''|*[!0-9]*) return 1 ;; esac
      printf '%s' "$idx"; return 0
      ;;
  esac

  local ip="" port="" nickname=""
  case "$handle" in
    *:*) ip="${handle%%:*}"; port="${handle##*:}" ;;
    *)
      if printf '%s' "$handle" | grep -Eq '^[0-9.]+$'; then
        ip="$handle"; port="443"
      else
        nickname="$handle"
      fi
      ;;
  esac

  local body
  body="$(kemp_vs_list "$url")"

  awk -v want_ip="$ip" -v want_port="$port" -v want_name="$nickname" '
    BEGIN { RS="</VS>"; FS="\n"; lname=tolower(want_name) }
    {
      rec=$0; idx=""; a=""; p=""; n=""
      if (match(rec, /<Index>[^<]+<\/Index>/))        { s=substr(rec,RSTART,RLENGTH); gsub(/.*<Index>|<\/Index>.*/,"",s); idx=s }
      if (match(rec, /<VSAddress>[^<]+<\/VSAddress>/)) { s=substr(rec,RSTART,RLENGTH); gsub(/.*<VSAddress>|<\/VSAddress>.*/,"",s); a=s }
      if (match(rec, /<VSPort>[^<]+<\/VSPort>/))       { s=substr(rec,RSTART,RLENGTH); gsub(/.*<VSPort>|<\/VSPort>.*/,"",s); p=s }
      if (match(rec, /<NickName>[^<]*<\/NickName>/))   { s=substr(rec,RSTART,RLENGTH); gsub(/.*<NickName>|<\/NickName>.*/,"",s); n=s }
      if (lname != "" && tolower(n) == lname && idx != "") { print idx; exit }
      if (want_ip != "" && a == want_ip && p == want_port && idx != "") { print idx; exit }
    }
  ' <<EOF
$body
EOF
}

kemp_bind_vs() {
  local url="$1" vs_handle="$2" alias="$3"
  local vs_index
  vs_index="$(kemp_resolve_vs_index "$url" "$vs_handle")" || {
    fail "Could not resolve VS '$vs_handle' at $url (use NickName, IP[:PORT], or index:N)"
    return 1
  }
  log "Binding VS '$vs_handle' (index $vs_index) to cert '$alias' at $url"
  local resp
  resp="$(kemp_get "$url" "/access/modvs?vs=${vs_index}&cert=${alias}")"
  if kemp_resp_ok "$resp"; then
    log "VS '$vs_handle' (index $vs_index) now uses cert '$alias'"
    return 0
  fi
  warn "VS bind failed for '$vs_handle' (index $vs_index) :: $(printf '%s' "$resp" | tr -d '\n' | cut -c1-300)"
  return 1
}

# -----------------------------------------------------------------------------
# Deploy to one Kemp entry — runs in subshell for parallel execution
# -----------------------------------------------------------------------------

deploy_to_kemp() {
  local k="$1"
  local url alias_override alias vs_n errors=0

  url="$(yq -r ".[$k].url" "$CONFIG_FILE")"
  alias_override="$(yq -r ".[$k].cert_alias // \"\"" "$CONFIG_FILE")"
  alias="${alias_override:-$cert_alias}"

  load_host_env "$url"

  if [ -z "${KEMP_APIKEY:-}" ] && { [ -z "${KEMP_USER:-}" ] || [ -z "${KEMP_PASS:-}" ]; }; then
    fail "Credentials missing for $url"
    return 1
  fi

  log "Deploying '$alias' to $url"

  local exists=false
  kemp_listcert_has "$url" "$alias" && exists=true

  if $exists; then
    # replace=1 — Kemp auto-updates all existing VS bindings
    log "Replacing cert '$alias' at $url"
    local out
    if ! out="$(kemp_addcert "$url" "$alias" "$BUNDLE" 1 2>&1)"; then
      if printf '%s' "$out" | grep -qi 'Identifier has been deleted'; then
        log "Tombstoned alias — purging and retrying"
        kemp_delcert "$url" "$alias"
        sleep 1
        kemp_addcert "$url" "$alias" "$BUNDLE" 0 \
          || { fail "Retry failed for '$alias' at $url :: $out"; return 1; }
      else
        fail "Replace failed for '$alias' at $url :: $out"
        return 1
      fi
    fi
    log "Replace OK — Kemp auto-updates VS bindings for '$alias' at $url"
  else
    # First upload — create new then bind to configured Virtual Services
    log "First upload of '$alias' to $url"
    local out
    out="$(kemp_addcert "$url" "$alias" "$BUNDLE" 0 2>&1)" \
      || { fail "Upload failed for '$alias' at $url :: $out"; return 1; }

    vs_n="$(yq ".[$k].vs_bind | length" "$CONFIG_FILE" 2>/dev/null || echo 0)"
    if [ "$vs_n" -gt 0 ]; then
      for v in $(seq 0 $((vs_n - 1))); do
        local vs
        vs="$(yq -r ".[$k].vs_bind[$v]" "$CONFIG_FILE")"
        kemp_bind_vs "$url" "$vs" "$alias" || errors=$((errors + 1))
      done
    else
      log "No vs_bind configured for $url — skipping VS binding (bind manually or add vs_bind to config)"
    fi
  fi

  [ "$errors" -eq 0 ] && log "Deploy complete for $url" || return 1
}

# -----------------------------------------------------------------------------
# Main — find matching Kemps and deploy in parallel
# -----------------------------------------------------------------------------

kemps_n="$(yq '. | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
if [ "$kemps_n" -eq 0 ]; then
  log "No Kemp entries in $CONFIG_FILE — nothing to do."
  exit 0
fi

# Find Kemps whose domain list matches CERTMATE_DOMAIN
matching=()
for k in $(seq 0 $((kemps_n - 1))); do
  domains_n="$(yq ".[$k].domains | length" "$CONFIG_FILE" 2>/dev/null || echo 0)"
  matched=false
  if [ "$domains_n" -eq 0 ]; then
    matched=true  # No domain filter — deploy to all Kemps
  else
    for d in $(seq 0 $((domains_n - 1))); do
      pattern="$(yq -r ".[$k].domains[$d]" "$CONFIG_FILE")"
      if match_domain "$pattern" "$CERTMATE_DOMAIN"; then
        matched=true
        break
      fi
    done
  fi
  $matched && matching+=("$k")
done

if [ "${#matching[@]}" -eq 0 ]; then
  log "No Kemp entries match domain '$CERTMATE_DOMAIN' — nothing to do."
  exit 0
fi

log "Matched ${#matching[@]} Kemp(s) for '$CERTMATE_DOMAIN'"

# Deploy in parallel — one background subshell per Kemp
tmpout="$tmpd/results"
mkdir -p "$tmpout"
pids=()

for k in "${matching[@]}"; do
  (
    deploy_to_kemp "$k"
    echo $? > "$tmpout/$k.exit"
  ) &
  pids+=($!)
done

# Wait for all and collect exit codes
errors=0
for i in "${!pids[@]}"; do
  wait "${pids[$i]}" || true
  k="${matching[$i]}"
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
