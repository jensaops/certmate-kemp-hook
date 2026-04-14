#!/usr/bin/env bash
# =============================================================================
# hook_kemp.sh — CertMate deploy hook for Kemp LoadMaster
#
# Triggered by CertMate after a certificate is issued or renewed.
# Reads a YAML/JSON config file to determine which Kemp appliances to push to,
# resolves credentials from per-host .env files, and uploads the certificate.
#
# Environment variables provided by CertMate:
#   CERTMATE_DOMAIN         Primary domain (e.g. example.com)
#   CERTMATE_CERT_PATH      Path to cert.pem
#   CERTMATE_KEY_PATH       Path to privkey.pem
#   CERTMATE_FULLCHAIN_PATH Path to fullchain.pem
#   CERTMATE_EVENT          Event type: issued | renewed | expired
#
# Config file (default: /etc/certmate/kemp.yml):
#   Set KEMP_CONFIG env var to override the path.
#
# Config format — see kemp.yml.example at the bottom of this file.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths and constants
# -----------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
CONFIG_FILE="${KEMP_CONFIG:-/etc/certmate/kemp.yml}"
ENV_DIR="${KEMP_ENV_DIR:-/etc/certmate/kemp.d}"   # directory of per-host .env files
KEMP_MODE="${KEMP_MODE:-replace}"                  # new | replace

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

# Only act on issue/renewal events
case "$CERTMATE_EVENT" in
  issued|renewed) ;;
  *)
    log "Event '$CERTMATE_EVENT' does not require Kemp deployment — exiting."
    exit 0
    ;;
esac

# -----------------------------------------------------------------------------
# Validate input files
# -----------------------------------------------------------------------------

for f in "$CERTMATE_CERT_PATH" "$CERTMATE_KEY_PATH" "$CERTMATE_FULLCHAIN_PATH"; do
  [ -s "$f" ] || { fail "Required file is missing or empty: $f"; exit 1; }
done

# -----------------------------------------------------------------------------
# Config file
# -----------------------------------------------------------------------------

[ -f "$CONFIG_FILE" ] || { fail "Config file not found: $CONFIG_FILE"; exit 1; }

# Requires yq (https://github.com/mikefarah/yq) v4+
command -v yq >/dev/null 2>&1 || { fail "yq is required but not found in PATH"; exit 1; }

kemps_n="$(yq '. | length' "$CONFIG_FILE" 2>/dev/null || echo 0)"
if [ "$kemps_n" -eq 0 ]; then
  log "No Kemp entries found in $CONFIG_FILE — nothing to do."
  exit 0
fi

# -----------------------------------------------------------------------------
# Build combined PEM (key + fullchain) that Kemp expects
# -----------------------------------------------------------------------------

tmpd="$(mktemp -d)"
trap 'rm -rf "$tmpd"' EXIT

BUNDLE="$tmpd/bundle.pem"
cat "$CERTMATE_KEY_PATH" "$CERTMATE_FULLCHAIN_PATH" > "$BUNDLE"
log "Built combined PEM bundle for $CERTMATE_DOMAIN"

# -----------------------------------------------------------------------------
# Derive a safe certificate alias from the domain name
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
# Kemp API helpers
# -----------------------------------------------------------------------------

kemp_resp_ok() {
  printf '%s' "$1" | grep -qiE 'code="ok"|<Success>'
}

kemp_listcert_has() {
  local url="$1" user="$2" pass="$3" alias="$4"
  curl -sk -u "$user:$pass" "${url%/}/access/listcert" | grep -q "$alias"
}

kemp_addcert() {
  # url user pass alias pem_path replace(0|1) → 0 on success
  local url="$1" user="$2" pass="$3" alias="$4" pem="$5" replace="$6"
  local tmp code body
  tmp="$(mktemp)"
  code="$(
    curl -ksu "$user:$pass" \
      -H 'Content-Type: text/plain' \
      --data-binary "@${pem}" \
      --write-out "%{http_code}" \
      --output "$tmp" \
      "${url%/}/access/addcert?cert=${alias}&replace=${replace}"
  )"
  body="$(tr -d '\r' < "$tmp")"; rm -f "$tmp"
  if [ "$code" = "200" ] && kemp_resp_ok "$body"; then
    return 0
  fi
  printf 'HTTP %s :: %s\n' "$code" "$(printf '%s' "$body" | tr -d '\n' | cut -c1-400)" >&2
  return 1
}

kemp_delcert() {
  # Best-effort purge of a tombstoned alias
  local url="$1" user="$2" pass="$3" alias="$4"
  curl -ksu "$user:$pass" "${url%/}/access/delcert?cert=${alias}" >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Per-host credential resolution
# Per-host .env files live in $ENV_DIR and are named after the hostname,
# e.g. /etc/certmate/kemp.d/kemp1.example.com.env
# Each file exports KEMP_USER and KEMP_PASS (and optionally KEMP_MODE).
# -----------------------------------------------------------------------------

load_host_env() {
  local url="$1"
  local host
  host="$(printf '%s' "$url" | sed -E 's#^https?://([^/:]+).*#\1#')"
  local env_file="${ENV_DIR}/${host}.env"
  # Unset any previously loaded per-host creds before loading new ones
  unset KEMP_USER KEMP_PASS
  if [ -f "$env_file" ]; then
    # shellcheck source=/dev/null
    . "$env_file"
    log "Loaded credentials from $env_file"
  else
    warn "No .env file found for host '$host' (expected $env_file)"
  fi
}

# -----------------------------------------------------------------------------
# Main loop — iterate over Kemp entries in config
# -----------------------------------------------------------------------------

errors=0

case "$KEMP_MODE" in
  new|replace) ;;
  *) fail "KEMP_MODE must be 'new' or 'replace' (got '$KEMP_MODE')"; exit 1 ;;
esac

for k in $(seq 0 $((kemps_n - 1))); do
  url="$(yq -r ".[$k].url" "$CONFIG_FILE")"

  # Load per-host credentials
  load_host_env "$url"

  # Allow config-level credential override (optional)
  user_override="$(yq -r ".[$k].user // \"\"" "$CONFIG_FILE")"
  pass_override="$(yq -r ".[$k].pass // \"\"" "$CONFIG_FILE")"
  u="${user_override:-${KEMP_USER:-}}"
  p="${pass_override:-${KEMP_PASS:-}}"

  if [ -z "$u" ] || [ -z "$p" ]; then
    fail "Credentials missing for $url — skipping"
    errors=$((errors + 1))
    continue
  fi

  # Allow per-entry alias override (optional; defaults to domain-derived alias)
  alias_override="$(yq -r ".[$k].cert_alias // \"\"" "$CONFIG_FILE")"
  alias="${alias_override:-$cert_alias}"

  log "Processing Kemp at $url (alias '$alias', mode=$KEMP_MODE)"

  exists=false
  kemp_listcert_has "$url" "$u" "$p" "$alias" && exists=true

  case "$KEMP_MODE" in
    new)
      if $exists; then
        log "Alias '$alias' already exists at $url — skipping (new-only mode)"
        continue
      fi
      log "Uploading (new) '$alias' to $url"
      if ! out="$(kemp_addcert "$url" "$u" "$p" "$alias" "$BUNDLE" 0 2>&1)"; then
        if printf '%s' "$out" | grep -qi 'Identifier has been deleted'; then
          log "Tombstoned alias detected — purging and retrying"
          kemp_delcert "$url" "$u" "$p" "$alias"
          sleep 1
          kemp_addcert "$url" "$u" "$p" "$alias" "$BUNDLE" 0 \
            || { fail "addcert(new) retry failed for '$alias' at $url :: $out"; errors=$((errors + 1)); continue; }
        else
          fail "addcert(new) failed for '$alias' at $url :: $out"
          errors=$((errors + 1)); continue
        fi
      fi
      ;;

    replace)
      if $exists; then
        log "Replacing '$alias' at $url"
        if ! out="$(kemp_addcert "$url" "$u" "$p" "$alias" "$BUNDLE" 1 2>&1)"; then
          if printf '%s' "$out" | grep -qi 'Identifier has been deleted'; then
            log "Tombstoned alias detected — purging and retrying as new"
            kemp_delcert "$url" "$u" "$p" "$alias"
            sleep 1
            kemp_addcert "$url" "$u" "$p" "$alias" "$BUNDLE" 0 \
              || { fail "replace→new failed for '$alias' at $url :: $out"; errors=$((errors + 1)); continue; }
          else
            fail "replace failed for '$alias' at $url :: $out"
            errors=$((errors + 1)); continue
          fi
        fi
      else
        log "Alias '$alias' not found at $url — creating as new (replace-mode)"
        out="$(kemp_addcert "$url" "$u" "$p" "$alias" "$BUNDLE" 0 2>&1)" \
          || { fail "create(new) in replace-mode failed for '$alias' at $url :: $out"; errors=$((errors + 1)); continue; }
      fi
      ;;
  esac

  # Verify upload succeeded
  if kemp_listcert_has "$url" "$u" "$p" "$alias"; then
    log "Upload OK — '$alias' is visible in /access/listcert at $url"
  else
    fail "Alias '$alias' not visible in /access/listcert at $url after upload"
    errors=$((errors + 1))
  fi

done

if [ "$errors" -gt 0 ]; then
  fail "$errors error(s) occurred during Kemp deployment"
  exit 1
fi

log "All Kemp deployments completed successfully for $CERTMATE_DOMAIN"
exit 0
