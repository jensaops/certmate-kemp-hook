# hook_kemp.sh — CertMate Deploy Hook for Kemp LoadMaster

A deploy hook for [CertMate](https://github.com/fabriziosalmi/certmate) that automatically uploads SSL/TLS certificates to one or more [Kemp LoadMaster](https://kemptechnologies.com/) appliances after issuance or renewal.

---

## Features

- Deploys to multiple Kemp appliances in a single run
- Per-host credentials via `.env` files — no plaintext passwords in config
- Handles tombstoned certificate aliases (Kemp "Identifier has been deleted" edge case)
- Supports `new` and `replace` upload modes
- Per-entry certificate alias override
- Exits non-zero on any failure so CertMate can log deployment errors

---

## Requirements

- `bash`
- `curl`
- `yq` v4+ (`apt install yq` or https://github.com/mikefarah/yq)
- Network access to the Kemp REST API (default port 443)

---

## Installation

```bash
# Copy the hook script
cp hook_kemp.sh /etc/certmate/hooks/hook_kemp.sh
chmod +x /etc/certmate/hooks/hook_kemp.sh

# Create config and credentials directories
mkdir -p /etc/certmate/kemp.d

# Create config file
cp kemp.yml.example /etc/certmate/kemp.yml

# Create per-host credentials
cp kemp.d/kemp1.example.com.env.example /etc/certmate/kemp.d/kemp1.example.com.env
chmod 600 /etc/certmate/kemp.d/kemp1.example.com.env
```

Then register the hook in CertMate under **Settings → Deploy Hooks**:

```
/etc/certmate/hooks/hook_kemp.sh
```

---

## Configuration

### Config file

Default path: `/etc/certmate/kemp.yml`  
Override with: `KEMP_CONFIG=/path/to/kemp.yml`

```yaml
# One entry per Kemp appliance
- url: https://kemp1.example.com

- url: https://kemp2.example.com
  cert_alias: example-com-prod   # optional alias override
```

| Field | Required | Description |
|---|---|---|
| `url` | Yes | Base URL of the Kemp REST API |
| `cert_alias` | No | Override the auto-derived alias (default: domain name with dots replaced by dashes) |
| `user` | No | Inline username — prefer `.env` files |
| `pass` | No | Inline password — prefer `.env` files |

### Per-host credentials

Credentials are resolved from `.env` files named after the Kemp hostname:

```
/etc/certmate/kemp.d/<hostname>.env
```

Example for `kemp1.example.com`:

```bash
# /etc/certmate/kemp.d/kemp1.example.com.env
KEMP_USER=admin
KEMP_PASS=your-password-here

# Optional: override upload mode for this host (new | replace)
# KEMP_MODE=replace
```

**Credential resolution order:**
1. Inline `user`/`pass` fields in `kemp.yml` (least preferred)
2. Per-host `.env` file in `$KEMP_ENV_DIR` (recommended)

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `KEMP_CONFIG` | `/etc/certmate/kemp.yml` | Path to the config file |
| `KEMP_ENV_DIR` | `/etc/certmate/kemp.d` | Directory containing per-host `.env` files |
| `KEMP_MODE` | `replace` | Upload mode: `new` or `replace` |

### CertMate variables (set automatically)

| Variable | Description |
|---|---|
| `CERTMATE_DOMAIN` | Primary domain name |
| `CERTMATE_CERT_PATH` | Path to `cert.pem` |
| `CERTMATE_KEY_PATH` | Path to `privkey.pem` |
| `CERTMATE_FULLCHAIN_PATH` | Path to `fullchain.pem` |
| `CERTMATE_EVENT` | Event type: `issued` or `renewed` |

---

## Upload Modes

### `replace` (default)

- If the alias exists on Kemp: replaces it (`replace=1`)
- If the alias does not exist: creates it as new (`replace=0`)
- Recommended for ongoing certificate management

### `new`

- Only uploads if the alias does not already exist
- Skips silently if the alias is already present
- Useful for initial provisioning scripts

---

## Certificate Alias

The certificate alias is derived from the domain name by replacing dots with dashes:

```
example.com        →  example-com
*.example.com      →  -example-com
sub.example.com    →  sub-example-com
```

Override per Kemp entry using `cert_alias` in `kemp.yml`.

---

## Tombstoned Alias Handling

Kemp can return `"Identifier has been deleted"` for aliases that exist in a deleted state. The hook detects this, purges the tombstoned alias with `/access/delcert`, waits 1 second, and retries the upload automatically.

---

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All deployments succeeded |
| `>0` | One or more deployments failed (count equals the number of errors) |

CertMate records a failed deploy hook when the script exits non-zero.

---

## Troubleshooting

**`yq: command not found`**  
Install yq v4: `apt install yq` or download from https://github.com/mikefarah/yq/releases

**`Credentials missing for https://kemp1.example.com`**  
Check that `/etc/certmate/kemp.d/kemp1.example.com.env` exists and contains `KEMP_USER` and `KEMP_PASS`. The filename must match the hostname in the URL exactly.

**`alias not visible in /access/listcert after upload`**  
The Kemp API accepted the upload but the certificate isn't appearing in the list. This can happen if the PEM format is invalid. Verify the combined PEM is well-formed:
```bash
openssl x509 -in /docker/certmate/certificates/<domain>/cert.pem -noout -subject
```

**`HTTP 401`**  
Wrong credentials. Verify username and password against the Kemp web UI.

**`HTTP 403`**  
The API user does not have sufficient permissions. Ensure the user has certificate management rights in Kemp.

---

## Related

- [CertMate](https://github.com/fabriziosalmi/certmate) — SSL Certificate Management System
- [Kemp LoadMaster REST API](https://kemptechnologies.com/documentation/) — API reference
