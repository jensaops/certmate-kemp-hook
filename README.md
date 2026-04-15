# hook_kemp.sh — CertMate Deploy Hook for Kemp LoadMaster

A deploy hook for [CertMate](https://github.com/fabriziosalmi/certmate) that automatically uploads SSL/TLS certificates to one or more [Kemp LoadMaster](https://kemptechnologies.com/) appliances after issuance or renewal.

---

## How It Works

- **New certificate** — uploaded to Kemp with `replace=0`. Bind it to a Virtual Service manually in the Kemp UI once.
- **Renewed certificate** — uploaded with `replace=1`. Kemp automatically updates all existing VS bindings using that alias. No manual steps needed.
- **All certificates** — every cert issued or renewed by CertMate is uploaded to every Kemp listed in the config. No domain filtering required.

---

## Requirements

- `bash`
- `curl`
- `yq` v4+ (`apt install yq` or https://github.com/mikefarah/yq)
- Network access to the Kemp REST API (default port 443)

If running CertMate in Docker, add `yq` to your Dockerfile (see [Docker Setup](#docker-setup)).

---

## Installation

```bash
# Copy the hook script
cp hook_kemp.sh /etc/certmate/hook_kemp.sh
chmod +x /etc/certmate/hook_kemp.sh

# Create config file
cp kemp.yml.example /etc/certmate/kemp.yml
# Edit kemp.yml and set your Kemp URL
```

Then register the hook in CertMate under **Settings → Deploy Hooks**:

```
/etc/certmate/hook_kemp.sh
```

---

## Configuration

### Config file

Default path: `/etc/certmate/kemp.yml`
Override with: `KEMP_CONFIG=/path/to/kemp.yml`

```yaml
# Minimal — one Kemp, all certs
- url: https://kemp1.example.com

# Multiple Kemps — all get every cert
- url: https://kemp1.example.com
- url: https://kemp2.example.com

# With alias override
- url: https://kemp1.example.com
  cert_alias: my-custom-alias
```

| Field | Required | Description |
|---|---|---|
| `url` | Yes | Base URL of the Kemp REST API |
| `cert_alias` | No | Override the auto-derived alias (default: domain with dots replaced by dashes, e.g. `test3-primeoperator-com`) |

---

### Credentials

Credentials can be provided in two ways:

**Option 1 — Environment variables** (simplest, recommended for single Kemp):

```bash
# In docker-compose.yml or .env
KEMP_USER=admin
KEMP_PASS=yourpassword

# Or API key auth
KEMP_APIKEY=your-api-key
```

**Option 2 — Per-host .env files** (recommended for multiple Kemps with different credentials):

Files are named after the Kemp hostname and placed in `$KEMP_ENV_DIR` (default: `/etc/certmate/kemp.d/`):

```bash
# /etc/certmate/kemp.d/kemp1.example.com.env
KEMP_USER=admin
KEMP_PASS=yourpassword
```

```bash
# Or API key auth
KEMP_APIKEY=your-api-key
```

```bash
chmod 600 /etc/certmate/kemp.d/kemp1.example.com.env
```

Credential resolution order:
1. Per-host `.env` file (loaded first, overrides environment)
2. Environment variables (`KEMP_USER`/`KEMP_PASS` or `KEMP_APIKEY`)

---

## Docker Setup

Add `yq` to the runtime stage of your Dockerfile (`curl` is typically already present):

```dockerfile
RUN apt-get update && \
    apt-get install -y curl tini && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" \
         -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq
```

Add a volume mount for the hook config in `docker-compose.yml`:

```yaml
volumes:
  - ./kemp:/etc/certmate
```

Host directory structure:

```
/docker/certmate/kemp/
├── hook_kemp.sh
├── kemp.yml
└── kemp.d/                  # optional, only needed for multiple Kemps
    └── kemp1.example.com.env
```

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `KEMP_CONFIG` | `/etc/certmate/kemp.yml` | Path to the config file |
| `KEMP_ENV_DIR` | `/etc/certmate/kemp.d` | Directory for per-host `.env` credential files |
| `KEMP_USER` | — | Kemp username (basic auth) |
| `KEMP_PASS` | — | Kemp password (basic auth) |
| `KEMP_APIKEY` | — | Kemp API key (alternative to basic auth) |
| `KEMP_CURL_TIMEOUT` | `30` | Per-request timeout in seconds |
| `KEMP_CURL_CONNECT_TIMEOUT` | `10` | Connection timeout in seconds |

### CertMate variables (set automatically)

| Variable | Description |
|---|---|
| `CERTMATE_DOMAIN` | Primary domain name |
| `CERTMATE_CERT_PATH` | Path to `cert.pem` |
| `CERTMATE_KEY_PATH` | Path to `privkey.pem` |
| `CERTMATE_FULLCHAIN_PATH` | Path to `fullchain.pem` |
| `CERTMATE_EVENT` | Event type: `issued` or `renewed` |

---

## Certificate Alias

The alias is derived from the domain name by replacing dots with dashes:

```
test3.primeoperator.com   →  test3-primeoperator-com
*.primeoperator.com       →  -primeoperator-com
```

Override per Kemp entry using `cert_alias` in `kemp.yml`.

---

## VS Binding

VS binding is a **manual one-time step** after the first upload:

1. Certificate is uploaded to Kemp automatically on first issuance
2. Log in to the Kemp UI and bind the certificate alias to your Virtual Service(s)
3. On all future renewals, `replace=1` causes Kemp to automatically update all existing VS bindings — no further manual steps needed

---

## Tombstoned Alias Handling

Kemp can return `"Identifier has been deleted"` for aliases that exist in a deleted state. The hook detects this, purges the tombstoned alias with `/access/delcert`, waits 1 second, and retries the upload automatically.

---

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | All deployments succeeded |
| `>0` | One or more deployments failed |

CertMate records a failed deploy hook when the script exits non-zero.

---

## Troubleshooting

**`yq: command not found`**
Install yq v4 in your Dockerfile or via `apt install yq`. See [Docker Setup](#docker-setup).

**`Credentials missing for https://kemp1.example.com`**
Set `KEMP_USER` and `KEMP_PASS` (or `KEMP_APIKEY`) as environment variables, or create a per-host `.env` file at `/etc/certmate/kemp.d/kemp1.example.com.env`.

**`HTTP 401`**
Wrong credentials. Verify against the Kemp web UI.

**`HTTP 403`**
The API user lacks certificate management permissions. Check the user's role in Kemp.

**Cert uploads but VS not updated on renewal**
The alias in Kemp must exactly match the alias the hook uses. Check the hook log for the derived alias and verify it matches what's configured in the Kemp VS.

---

## Related

- [CertMate](https://github.com/fabriziosalmi/certmate) — SSL Certificate Management System
- [Kemp LoadMaster REST API](https://kemptechnologies.com/documentation/) — API reference
- [yq](https://github.com/mikefarah/yq) — YAML processor
