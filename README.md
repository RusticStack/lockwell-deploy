# Lockwell deployment

Run **Lockwell**, a single-node, S3-compatible object store, on your own infrastructure.

Lockwell runs as **one container** (or one binary) backed by **one data directory**: the S3 API, the native JSON API,
the embedded metadata engine, and always-on at-rest encryption, all in one process. There is **no external database,
message broker, or cache** to run alongside it.

This repository contains everything you need to **deploy and operate** a Lockwell node: a `Dockerfile` and
`docker-compose.yml` that assemble a thin runtime image from the official prebuilt binary, an `.env` template, the
production config, and reverse-proxy examples. **No source is compiled**: the image build only downloads the
checksum-verified static binary. Prebuilt binaries for **Linux** (`amd64`, `arm64`) and **Windows** (`amd64`, `arm64`)
are attached to each [release](https://github.com/RusticStack/lockwell-deploy/releases).

- **Documentation:** <https://lockwell.rusticstack.com>

---

## Contents

| Path | Purpose |
| --- | --- |
| `docker-compose.yml` | Single-node deployment that builds the runtime image from the binary. |
| `Dockerfile` | Wraps the official prebuilt binary in a slim base. Compiles no source. |
| `docker-entrypoint.sh` | First-boot bootstrap (root tenant + access key + admin user; idempotent). |
| `.env.example` | Copy to `.env`; sets initial credentials, ports, and the release version. |
| `examples/lockwell.production.toml` | The production config, baked in and mountable for live tuning. |
| `examples/Caddyfile` | TLS-terminating reverse proxy (automatic HTTPS). |
| `examples/nginx.conf` | TLS-terminating reverse proxy (nginx). |

---

## Deploy with Docker (recommended)

You need [Docker](https://docs.docker.com/get-docker/) with the Compose plugin.

```bash
git clone https://github.com/RusticStack/lockwell-deploy.git
cd lockwell-deploy
cp .env.example .env
```

Edit `.env` and set the initial S3 credentials. The container **fails fast** if they are left at their `CHANGE_ME_*`
placeholders, so there is never a default credential:

```ini
LOCKWELL_ROOT_ACCESS_KEY_ID=lockwell-admin
LOCKWELL_ROOT_SECRET_KEY=change-me-to-a-long-random-secret-min-16-chars
LOCKWELL_ROOT_TENANT=root

# Optional first admin web-UI login (separate from the S3 key above).
LOCKWELL_ADMIN_USERNAME=admin
LOCKWELL_ADMIN_PASSWORD=change-me-to-a-different-long-random-secret
LOCKWELL_ADMIN_ROLE=owner
```

Generate strong secrets with `openssl rand -hex 32`. Then start it:

```bash
docker compose up -d --build
```

The `--build` step assembles a thin runtime image from the official prebuilt binary. It downloads and checksum-verifies
the released static binary for your architecture and wraps it in a slim Debian base. **No source is compiled.** Compose
then runs an **idempotent first-boot bootstrap** (creates the root tenant, the root S3 access key, and optionally the
first admin user) and starts the daemon. Restarts never clobber your credentials. Verify it is up:

```bash
curl -fsS http://127.0.0.1:9000/health   # always-200 liveness on the public port
curl -fsS http://127.0.0.1:9000/readyz   # deep readiness; pings the metadata engine + storage
docker compose logs -f lockwell
```

### Without Compose: `docker build` + `docker run`

Build the runtime image once (this downloads and verifies the official binary, no source compiled), then run it against a single
named volume that holds all state:

```bash
docker build --build-arg LOCKWELL_VERSION=0.2.1 -t lockwell:0.2.1 .
docker volume create lockwell-data

docker run -d --name lockwell \
  --restart unless-stopped \
  -p 9000:9000 \
  -p 127.0.0.1:9001:9001 \
  -e LOCKWELL_BOOTSTRAP_REQUIRED=true \
  -e LOCKWELL_ROOT_ACCESS_KEY_ID=lockwell-admin \
  -e LOCKWELL_ROOT_SECRET_KEY=change-me-to-a-long-random-secret-min-16-chars \
  -e LOCKWELL_ADMIN_USERNAME=admin \
  -e LOCKWELL_ADMIN_PASSWORD=change-me-to-a-different-long-random-secret \
  -v lockwell-data:/var/lib/lockwell \
  lockwell:0.2.1
```

Run a one-off CLI command against the same volume (the daemon must be stopped first for commands that open the store):

```bash
docker run --rm -v lockwell-data:/var/lib/lockwell lockwell:0.2.1 lockwell --help
```

### Platform-managed deploys (Coolify / Dokploy)

Point Coolify or Dokploy at this repository and attach a domain to port **9000**. They terminate TLS for you. Set the
same `.env` variables as deploy secrets. Keep port **9001** off the public domain (see [The two listeners](#the-two-listeners)).

---

## Deploy without Docker

Prebuilt binaries for **Linux** (`amd64`, `arm64`) and **Windows** (`amd64`, `arm64`) are attached to every
[release](https://github.com/RusticStack/lockwell-deploy/releases). They are static and have no runtime dependencies (no
libc to match, no external database). Each archive contains:

- `lockwelld` (`lockwelld.exe` on Windows): the server (S3 API + native API + admin UI + metrics).
- `lockwell` (`lockwell.exe` on Windows): the CLI (tenant/key/admin creation, backup/restore, repair).
- `lockwell.production.toml`: the production config.

### Linux

Download and unpack the archive for your architecture (replace `amd64` with `arm64` on ARM hosts):

```bash
VERSION=0.2.1
curl -fsSLO https://github.com/RusticStack/lockwell-deploy/releases/download/v${VERSION}/lockwell-${VERSION}-linux-amd64.tar.gz
curl -fsSLO https://github.com/RusticStack/lockwell-deploy/releases/download/v${VERSION}/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf lockwell-${VERSION}-linux-amd64.tar.gz
cd lockwell-${VERSION}-linux-amd64
sudo install lockwell lockwelld /usr/local/bin/
```

Create the data directories and the first tenant + access key **before** starting the daemon (the embedded engine takes
an exclusive single-process lock, so bootstrap cannot run while the daemon holds the store open):

```bash
sudo mkdir -p /var/lib/lockwell/blobs /var/lib/lockwell/tmp
sudo install -m 600 lockwell.production.toml /etc/lockwell/lockwell.toml

export LOCKWELL_CONFIG=/etc/lockwell/lockwell.toml

# Create the root tenant + an S3 access key (offline; idempotent).
lockwell tenant-create root --yes
lockwell key-create root --tenant root --read --write --delete --admin \
  --access-key-id lockwell-admin \
  --secret-key change-me-to-a-long-random-secret-min-16-chars

# Optional: first admin web-UI login.
lockwell admin-create admin --password change-me-to-a-different-long-random-secret --role owner
```

Then run the server:

```bash
lockwelld -c /etc/lockwell/lockwell.toml
```

To run it as a managed service, wrap `lockwelld` in a systemd unit (run it as a dedicated non-root user that owns
`/var/lib/lockwell`, and set `Environment=LOCKWELL_CONFIG=/etc/lockwell/lockwell.toml`).

### Windows

Download the `windows` archive for your architecture from the
[release](https://github.com/RusticStack/lockwell-deploy/releases) and expand it (PowerShell):

```powershell
$Version = "0.2.1"
$base = "https://github.com/RusticStack/lockwell-deploy/releases/download/v$Version"
Invoke-WebRequest "$base/lockwell-$Version-windows-amd64.zip" -OutFile "lockwell.zip"
Expand-Archive lockwell.zip -DestinationPath .
Set-Location "lockwell-$Version-windows-amd64"
```

Pick a data directory, then create the first tenant + access key **before** starting the daemon (the embedded engine
takes an exclusive single-process lock):

```powershell
New-Item -ItemType Directory -Force "C:\lockwell\blobs", "C:\lockwell\tmp" | Out-Null
$env:LOCKWELL_CONFIG = "$PWD\lockwell.production.toml"

# Point storage at a Windows path (edit data_dir / temp_dir in lockwell.production.toml
# to C:\lockwell\blobs and C:\lockwell\tmp before first boot).

.\lockwell.exe tenant-create root --yes
.\lockwell.exe key-create root --tenant root --read --write --delete --admin `
  --access-key-id lockwell-admin `
  --secret-key change-me-to-a-long-random-secret-min-16-chars

# Optional: first admin web-UI login.
.\lockwell.exe admin-create admin --password change-me-to-a-different-long-random-secret --role owner
```

Then run the server:

```powershell
.\lockwelld.exe -c .\lockwell.production.toml
```

To run it unattended, register `lockwelld.exe` as a Windows service (for example with
[NSSM](https://nssm.cc/) or `sc.exe create`), set `LOCKWELL_CONFIG` for the service account, and front the public port
with a TLS-terminating reverse proxy as below.

---

## The two listeners

| Port     | Bind (default)        | Surface                                                                                 |
| -------- | --------------------- | --------------------------------------------------------------------------------------- |
| **9000** | published (public)    | S3 API, the native API (`/api/v1`), bearer token mint, signed URLs, `/health` `/readyz` |
| **9001** | `127.0.0.1` (private) | Admin web UI (`/admin`), JSON Admin API (`/admin/api/v1`), Prometheus `/metrics`        |

Put a TLS-terminating reverse proxy in front of port **9000**. **Keep port 9001 private**. `/metrics` is
**unauthenticated**. Reach the admin port over an SSH tunnel or a firewalled private network, and never attach a public
domain to it:

```bash
ssh -L 9001:127.0.0.1:9001 youruser@yourhost
# then open http://localhost:9001/admin and scrape http://localhost:9001/metrics
```

---

## TLS / reverse proxy

The public port binds **plaintext inside the container**. Lockwell does not terminate TLS itself; it expects a reverse
proxy in front of it. This keeps certificate handling out of the daemon and lets you use whatever proxy you already run.

Two object-storage concerns matter at the proxy: raise the body-size limit (large PUTs and multipart parts), and
**stream** the request body rather than buffering it to disk. See [`examples/Caddyfile`](examples/Caddyfile) (automatic
Let's Encrypt, streams by default) and [`examples/nginx.conf`](examples/nginx.conf) (set `client_max_body_size`,
`proxy_request_buffering off`, and forward `Host` / `X-Forwarded-Proto`).

Open only `443` to the internet:

```bash
ufw default deny incoming
ufw allow 22/tcp     # SSH
ufw allow 443/tcp    # HTTPS (reverse proxy)
ufw enable
```

---

## Where the data and master key live

All state (object blobs, the embedded metadata engine, and the auto-generated at-rest **master key**) lives in the
single `lockwell-data` volume mounted at `/var/lib/lockwell` (or your `storage.data_dir` when running without Docker).
The master key is written there during first-boot bootstrap.

> **Back up the master key separately.** Losing the master key makes the encrypted data unrecoverable. A volume snapshot
> alone is not key separation. Copy the key to a different location, or mount it from a secret with
> `LOCKWELL_MASTER_KEY_FILE` so a data-volume loss is recoverable.

---

## Backup and restore

Take an **online** metadata backup from the running daemon (no downtime). The CLI signs an admin-scoped request to the
daemon and writes the metadata to `--out` (object blobs are captured separately via the data volume):

```bash
docker compose exec \
  -e AWS_ACCESS_KEY_ID=lockwell-admin \
  -e AWS_SECRET_ACCESS_KEY=change-me-to-a-long-random-secret-min-16-chars \
  lockwell lockwell metadata-backup \
    --endpoint http://127.0.0.1:9000 \
    --out /var/lib/lockwell/metadata-backup.bin
```

**Restore is offline.** The embedded engine takes an exclusive single-process lock and the restore loads the backup into
a fresh data dir, so stop the daemon first:

```bash
docker compose stop lockwell
# lockwell metadata-restore -c /etc/lockwell/lockwell.toml --from <file> --yes
docker compose start lockwell
```

---

## Updating

Pin `LOCKWELL_VERSION` in `.env` for reproducible deploys. To upgrade, bump it to a new
[release](https://github.com/RusticStack/lockwell-deploy/releases) and rebuild:

```bash
git pull
docker compose up -d --build
```

Compose rebuilds the image from the new binary and reattaches the existing `lockwell-data` volume. The metadata engine
opens **in place**, with no external migration step. Watch the logs and confirm `/readyz` returns 200.

When running without Docker, download the new release archive, replace the binaries, and restart the service.

---

## Sizing

A 1 vCPU, 1 GiB host comfortably runs a small workload. The dominant memory tunable is `[metadata].block_cache_mb` (64
to 128 MiB is a good range with encryption on). Dedup and compression are ON in the shipped config, reducing physical
bytes. Choose a durability tier with `[metadata].sync_interval_ms` and `[storage].relaxed_durability` (STRICT by
default: an acked write survives sudden power loss).

---

## Scope

- **Single-node.** One container (or one binary), one data directory, the embedded engine. There is no built-in
  clustering or multi-node replication. Durability comes from the durability tier plus your own volume snapshots and
  backups.
- **TLS is your proxy's job.** Lockwell binds plaintext behind a reverse proxy; it does not terminate TLS itself.
- **Private by default.** No public/anonymous buckets, no SSE-KMS, no IAM/STS. Credential-free object access is only
  ever via a scoped, time-limited signed URL.

---

## Support and terms

Full product, SDK, and operations documentation lives at <https://lockwell.rusticstack.com>.

The image and binaries published here are distributed as compiled artifacts for self-hosting. They are provided **as is,
without warranty**. This repository contains deployment material only.
