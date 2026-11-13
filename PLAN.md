# Plan: pi-web as a TrueNAS custom app (locally built image, mise toolchain)

## Goal

Run [jmfederico/pi-web](https://github.com/jmfederico/pi-web) on this TrueNAS box as a
custom app, from a **locally built** image (no registry). The image is a **general-purpose
dev/test container**: mise-managed toolchain via shims, the tools in `mise.toml`, and
runtime tool installs / `mise self-update` that survive the container being recreated.

Deliverables in this repo: `Dockerfile`, `image/pi-web-entrypoint`, `mise.toml`,
`compose.yaml` (paste-ready TrueNAS custom-app YAML), `build.sh`, `README.md`,
`.dockerignore`, `.gitignore`. I build nothing here and start nothing — build/deploy is
yours.

Decisions locked in: state at `/mnt/skinner/apps-pi-web:/data` (you create it), **no code
mounts**, `mise.toml` tool list unchanged, Node at 26.11.1, **non-slim base**, extra
`openssh-client`/`rsync`/`file`/`zip`/`zstd`/`patch`.

## Base image: Debian vs Ubuntu (measured on this box)

| | `debian:bookworm` (12) | **`debian:trixie` (13)** | `ubuntu:24.04` LTS | `ubuntu:26.04` LTS |
| --- | --- | --- | --- | --- |
| compressed | 111 MB | 114 MB | 75 MB | 96 MB |
| glibc | 2.36 | 2.41 | 2.39 | 2.43 |
| packages in base | 88 | 78 | 92 | 87 |
| man / doc / locale data | **7 / 9 / 20 MB** | **kept** | 0 / 1 / 0 MB | 0 / 1 / 0 MB |
| available packages | 63.6k | 68.9k | **87.5k** | 78.9k |
| gcc / python3 | 12 / 3.11 | 14 / 3.13 | 13 / 3.12 | 15 / 3.14 |
| `docker.io` (CLI) | 20.10 | 26.1 | **29.1** | 29.1 |
| support horizon | oldstable (security-only) | stable, ~2028 + LTS | 2029 + ESM | 2031 + ESM |

Findings that matter more than the usual "slim vs full" folklore:

- **Debian's `bookworm` and `bookworm-slim` have byte-identical package sets** (88 each,
  `diff`-verified). Non-slim only differs by keeping man pages/docs/translations (~38 MB).
  Likewise **Ubuntu's release images are already doc-stripped** (`/usr/share/man` is
  empty), so "non-slim" is effectively a *Debian-only* choice: pick Debian non-slim if you
  want offline man pages/docs at all (add `man-db` and they are readable; on Ubuntu the
  files are not there to read).
- **No base gives you free tools.** gcc, python3, git, curl, less, rsync, ripgrep, tini,
  libatomic1 are absent from every one of them, so the apt list below is needed either
  way. Our list was `apt-get install -s`-verified to resolve on trixie, ubuntu:24.04 and
  ubuntu:26.04 with zero missing packages.
- **bookworm is now oldstable** (security-only updates). It was only ever the base of my
  first probe; it should not be the shipped base.
- **Alpine/musl is the one to avoid** — mise's prebuilt Node/Python/Bun/Go artifacts are
  glibc builds, so musl means corepack/gcompat workarounds forever.

**Recommended base: `debian:trixie` (non-slim)** — it is the only base that actually gives
the non-slim property you asked for, it is the current stable, and it matches the TrueNAS
host family (TrueNAS SCALE is Debian-based) while staying vendor-neutral (no ESM or
phased-update tooling in the container). glibc 2.41 / gcc 14 / python 3.13 are modern
enough that mise supplies nothing you'd miss.

**Alternative: `ubuntu:24.04` LTS** if you'd rather have the bigger package pool, the
longer support window, vendor `.deb` repos (Docker/Google/Microsoft/HashiCorp target
Ubuntu first) and the much newer `docker.io` CLI. Cost: no man pages/docs offline, plus
phased updates. `ubuntu:26.04` LTS is the same tradeoff with a fresher system toolchain
(gcc 15 / python 3.14) at six months old. Switching is a one-word `FROM` change — the apt
list and every other line are identical (both were probed).

Ubuntu pros: package breadth, support longevity, ecosystem docs, newest distro toolchain,
smaller base image. Debian pros: real non-slim docs, host-family parity, vendor neutrality,
better reproducibility (`snapshot.debian.org`), and no Ubuntu-specific apt behaviour.

## Verified

Both candidate bases were probed as **full images** (throwaway probes, since deleted),
each with the real `mise.toml`, the real `npm install` of pi-web, the real entrypoint, and
the real two-service shape:

| Check | `debian:trixie` | `ubuntu:24.04` |
| --- | --- | --- |
| build (full 16-tool mise toolchain + pi-web) | 2m15s cached / ~6m cold | ~6m cold |
| image size | 3.93 GB | 3.81 GB |
| `mise install --system` + `reshim --system` | ok | ok (no `MISE_EXPERIMENTAL` needed) |
| `node-pty` native build (build-time assert) | ok | ok |
| sessiond: socket `/data/pi-web/sessiond.sock` | ok | ok |
| web: `/api/pi-web/runtime` returns web+sessiond available | ok | ok |
| UI `/` | HTTP 200 | HTTP 200 |
| login-shell PATH resolves all 18 tools | ok, no MISSING | ok, no MISSING |
| runtime `mise use -g shellcheck@0.11.0` → `/data/config/mise/config.toml` | ok | ok |
| `mise self-update` → persists across recreating both containers | ok | ok |
| app still serving after recreate | HTTP 200 | HTTP 200 |

Also confirmed on both: `node 26.11.1`, `rustc 1.99.0`, `go 1.27.2`, `terraform 1.16.5`,
`aws-cli 2.36.29` (running on mise's Python 3.14) and the `pi` CLI (peer of pi-web).

These probes predate later image changes — the Playwright + Chromium layer, the GTK4/
WebKitGTK dev packages, and the explicit Pi SDK install (`cb2266a`, which fixed `sessiond`
refusing to start without it). Those layers were not re-probed.

Real API response from the probe (web + sessiond healthy, pi 1.1.0):

```json
{"packageName":"@jmfederico/pi-web","components":{"web":{"runtimeVersion":"1.202610.1","piVersion":"1.1.0","available":true},
 "sessiond":{"runtimeVersion":"1.202610.1","piVersion":"1.1.0","available":true,"activeAgentProfile":{"dir":"/data/pi-agent"}}}}
```

### Gotchas found by the probes (each one shaped the design or the Dockerfile)

1. **A wrapper script breaks shims.** With `/usr/local/bin/mise` as a shell wrapper that
   `exec`s the `/data` copy, runtime-created shims pointed at the wrapper, and the wrapper
   loses `argv[0]` — so mise could not tell which tool a shim was for (`shellcheck
   --version` printed *mise's* version). Fix: `/usr/local/bin/mise` is a **symlink** to
   `/data/mise/mise` (symlink chains preserve `argv[0]`, and `self-update` canonicalizes to
   the `/data` file).
2. **`MISE_CONFIG_DIR` hijacks the global config** into the image layer, which silently
   breaks the "runtime installs persist" requirement. Leaving it unset keeps the image
   toolchain in the **system** config `/etc/mise/config.toml` while the **global** config
   lands at `$XDG_CONFIG_HOME/mise/config.toml` = `/data/config/mise/config.toml`.
3. **rustup-backed rust installs into `$HOME`** (`/data/home`) and symlinks the toolchain
   there → dangling on a fresh volume. `CARGO_HOME`/`RUSTUP_HOME` keep it in the image.
4. **`mise` is not on `PATH` during the build** — the binary lives in `libexec` and the
   symlink is created last, so build-time steps must call `"$MISE_INSTALL_PATH"`. (The
   build failed on exactly this; the plan's Dockerfile is fixed.)
5. **Node 26's official build needs `libatomic1`** (Node 24 did not). Kept in the apt list.
6. **node-gyp needs `python3`**, satisfied by mise's Python — so the toolchain layer must
   come before the npm layer.
7. **`COPY` preserves host file modes**, so the entrypoint needs an explicit `chmod 0755`
   (probe failed to start without it).
8. **The `/data` volume must be exec-enabled**: the seeded mise binary is executed from
   `/data/mise/mise`. ZFS datasets on TrueNAS default to `exec=on`, so the app path is
   fine — but a `noexec` mount (like `/tmp` on this box) would break mise and every shim.

## Key decisions

1. **Own thin Dockerfile on `debian:trixie`** rather than vendoring upstream's openSUSE
   Dockerfile + installer + `hostexec` (~700 lines) that TrueNAS makes useless. Upstream's
   setup assumes a plain Docker host: host-profile detection, `docker.sock`, `/home`
   `/srv` `/opt` mounts, its own `docker compose up` — while TrueNAS middleware owns
   compose and passes `-p ix-<app>`.
2. **Two-tier mise** (mise's own documented pattern for devcontainers with a home mount,
   which is exactly our shape):
   - **Image tier**: `mise.toml` baked as the *system* config `/etc/mise/config.toml`,
     installed with `mise install --system` into `/usr/local/share/mise/installs`, shims via
     `mise reshim --system` in `/usr/local/share/mise/shims`. Always present, even on a
     fresh volume; not hidden by the `/data` mount.
   - **Runtime tier**: `MISE_DATA_DIR=/data/mise` holds runtime installs, shims, plugins,
     state and the mise binary. Runtime installs **take precedence** over system ones.
3. **Two services** (sessiond + web) sharing `/data`, exactly like upstream — pi-web's
   `pi-web-server` does not spawn `pi-web-sessiond`. Verified working.
4. **mise provides Node** (official distro build, so `stripTypeScriptTypes` is present) and
   pi-web and the Pi SDK (`@earendil-works/pi-coding-agent`, which provides `pi`) are
   installed with mise's npm into `/usr/local` (`--prefix /usr/local`), so
   `pi-web-server`, `pi-web-sessiond`, `pi-web` and `pi` are on the plain `PATH`,
   independent of mise.
5. **`node = "26.11.1"`** — newest release that works end to end (pi-web and all three
   `@earendil-works/pi-*` peers declare `>=22.19.0` with no upper bound; node-pty builds).
   Fallback if you want upstream's tested line: `24.21.0`.
6. **Entrypoint seeds the persistent binary**: creates `/data` subdirs, copies
   `/data/mise/mise` from the image atomically (temp + `mv`, so sessiond/web cannot race),
   and falls back to symlinking the image copy if `/data` is unusable — degraded, never
   missing.
7. **Run as root**, like your `dsh` example: pi-web is not a sandbox, it is LAN-only, and
   root avoids ownership fights on the bind mount.
8. **Compose has no `build:`, no `container_name`, no `name:`**, one `/data` bind mount.
   Locally tagged images install/redeploy fine; only the explicit pull/upgrade path would
   try a registry, so use **Redeploy**, not the Update button.

## Files

### `mise.toml` (only the node pin changes)

```toml
# Toolchain baked into the image at build time (mise system config /etc/mise/config.toml).
# Anything installed at runtime lands in /data/mise and takes precedence over these.
[tools]
node = "26.11.1"
bun = "1.4.0"
python = "latest"
go = "latest"
gh = "latest"
awscli = "2.36.29"
kubectl = "latest"
helm = "latest"
terraform = "latest"
rust = "latest"
neovim = "0.12.4"
uv = "latest"
fzf = "latest"
yq = "latest"
shellcheck = "latest"
jq = "latest"
```

### `Dockerfile`

Snapshot from the original plan; the repo's `Dockerfile` is authoritative. Later commits
added the Playwright + Chromium layer, `pkg-config` with the GTK4/WebKitGTK 6 dev packages
and `PI_CODING_AGENT_VERSION` for the explicitly installed Pi SDK, and dropped the old
`node_modules/.bin/pi` symlink.

```dockerfile
# syntax=docker/dockerfile:1.7
# pi-web for TrueNAS custom apps, with a mise-managed general-purpose dev/test toolchain.
# Upstream's own Docker setup expects a plain Docker host (host mounts, docker.sock,
# hostexec) and is deliberately not reused.
FROM debian:trixie

ARG MISE_VERSION=2026.10.7
ARG PI_WEB_VERSION=latest
ARG CACHE_BUST=local

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# MISE_DATA_DIR sits on the persistent volume so runtime tool installs, shims and
# `mise self-update` persist. The image's own toolchain lives in the system dir
# (/usr/local/share/mise) and is found automatically, at lower precedence than /data/mise.
# No MISE_CONFIG_DIR / MISE_GLOBAL_CONFIG_FILE on purpose: the image toolchain is the
# *system* config (/etc/mise/config.toml), while the global config stays at
# $XDG_CONFIG_HOME/mise/config.toml = /data/config/mise/config.toml so `mise use -g` persists.
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    SHELL=/bin/bash \
    TERM=xterm-256color \
    HOME=/data/home \
    XDG_CONFIG_HOME=/data/config \
    PI_WEB_HOST=0.0.0.0 \
    PI_WEB_PORT=8504 \
    PI_WEB_DATA_DIR=/data/pi-web \
    PI_WEB_SESSIOND_SOCKET=/data/pi-web/sessiond.sock \
    PI_CODING_AGENT_DIR=/data/pi-agent \
    MISE_DATA_DIR=/data/mise \
    MISE_CACHE_DIR=/mise/cache \
    MISE_TRUSTED_CONFIG_PATHS=/etc/mise \
    MISE_YES=1 \
    MISE_INSTALL_PATH=/usr/local/libexec/mise/mise \
    CARGO_HOME=/usr/local/share/cargo \
    RUSTUP_HOME=/usr/local/share/rustup \
    PATH=/usr/local/share/mise/shims:/data/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Standard tools for an agent/dev container. build-essential + python (from mise) are what
# node-pty's node-gyp fallback needs; libatomic1 is required by Node 26's official build.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl git git-lfs less tini procps ripgrep unzip xz-utils \
    zip zstd patch file rsync openssh-client build-essential libatomic1 \
  && rm -rf /var/lib/apt/lists/*

# mise itself. The real binary stays in libexec: /usr/local/bin/mise is a symlink to the
# /data copy, created further down.
RUN mkdir -p "$(dirname "$MISE_INSTALL_PATH")" \
  && curl -fsSL https://mise.run | MISE_VERSION="$MISE_VERSION" sh

# Image toolchain: system installs + system shims. Always present, fresh volume included.
# Note: build-time mise calls must use $MISE_INSTALL_PATH, because /usr/local/bin/mise does
# not exist yet (and is dangling once it does).
COPY mise.toml /etc/mise/config.toml
RUN set -eux; \
  echo "mise toolchain cache bust: ${CACHE_BUST}"; \
  "$MISE_INSTALL_PATH" trust /etc/mise/config.toml; \
  "$MISE_INSTALL_PATH" install --system; \
  "$MISE_INSTALL_PATH" reshim --system; \
  "$MISE_INSTALL_PATH" --version

# pi-web from npm via mise's Node (globals land in /usr/local/bin, on the plain PATH).
RUN set -eux; \
  echo "pi-web build cache bust: ${CACHE_BUST}"; \
  extra=""; \
  if [ "$(npm --version | cut -d. -f1)" -ge 12 ]; then extra="--allow-scripts=node-pty"; fi; \
  npm install -g --prefix /usr/local --omit=dev --include=peer --no-audit --no-fund \
    ${extra} "@jmfederico/pi-web@${PI_WEB_VERSION}"; \
  pi_bin=/usr/local/lib/node_modules/@jmfederico/pi-web/node_modules/.bin/pi; \
  if [ -x "$pi_bin" ]; then ln -sf "$pi_bin" /usr/local/bin/pi; fi; \
  cd /usr/local/lib/node_modules/@jmfederico/pi-web && node -e "require('node-pty')"; \
  npm cache clean --force

# Login shells (pi-web terminals) get PATH rewritten by /etc/profile; put the shim dirs
# back so terminals resolve the same tools agent processes do.
RUN printf '%s\n' \
  '# mise shims for login shells (pi-web terminals).' \
  'for d in /usr/local/share/mise/shims /data/mise/shims; do' \
  '  case ":$PATH:" in *:"$d":*) ;; *) PATH="$d:$PATH" ;; esac' \
  'done; export PATH' \
  > /etc/profile.d/10-mise-shims.sh

# The `mise` on PATH is a symlink to the persistent copy: shims resolve through it with
# argv[0] intact, and `mise self-update` replaces the file at its canonicalized path, i.e.
# the one on /data. Dangling until the entrypoint seeds it, so this comes last.
RUN ln -s /data/mise/mise /usr/local/bin/mise

COPY image/pi-web-entrypoint /usr/local/bin/pi-web-entrypoint
RUN chmod 0755 /usr/local/bin/pi-web-entrypoint

WORKDIR /workspace
EXPOSE 8504
ENTRYPOINT ["tini", "--", "/usr/local/bin/pi-web-entrypoint"]
CMD ["pi-web-server"]
```

### `image/pi-web-entrypoint`

```sh
#!/bin/sh
# /data is a volume, so it hides the mise binary, shims and toolchain baked into the
# image. Create the runtime directories and seed the persistent mise binary so shims and
# `mise self-update` work from the very first start.
mkdir -p /data/home /data/config /data/pi-web /data/pi-agent 2>/dev/null || true

seed=/usr/local/libexec/mise/mise
bin=/data/mise/mise
link=/usr/local/bin/mise
if [ ! -x "$bin" ]; then
  if mkdir -p /data/mise 2>/dev/null \
     && cp "$seed" "/data/mise/.mise.$$" 2>/dev/null \
     && chmod 0755 "/data/mise/.mise.$$" \
     && mv -f "/data/mise/.mise.$$" "$bin" 2>/dev/null; then
    :
  else
    ln -sf "$seed" "$link"  # volume unusable: keep working, lose persistence
  fi
fi

exec "$@"
```

### `compose.yaml` (paste-ready TrueNAS custom app)

`/mnt/skinner/apps-pi-web` is the one path to have ready. No code mounts, per your answer.

```yaml
x-pi-web-image: &pi-web-image pi-web-truenas:latest

x-pi-web-environment: &pi-web-environment
  HOME: /data/home
  XDG_CONFIG_HOME: /data/config
  PI_WEB_DATA_DIR: /data/pi-web
  PI_WEB_SESSIOND_SOCKET: /data/pi-web/sessiond.sock
  PI_CODING_AGENT_DIR: /data/pi-agent
  PI_WEB_HOST: 0.0.0.0
  PI_WEB_PORT: "8504"

services:
  sessiond:
    image: *pi-web-image
    command: ["pi-web-sessiond"]
    restart: unless-stopped
    environment: *pi-web-environment
    volumes:
      - /mnt/skinner/apps-pi-web:/data
    healthcheck:
      test: ["CMD-SHELL", "test -S /data/pi-web/sessiond.sock"]
      interval: 10s
      timeout: 3s
      retries: 12
      start_period: 60s

  web:
    image: *pi-web-image
    command: ["pi-web-server"]
    restart: unless-stopped
    depends_on:
      sessiond:
        condition: service_healthy
    environment: *pi-web-environment
    volumes:
      - /mnt/skinner/apps-pi-web:/data
    ports:
      - "8504:8504"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8504/api/pi-web/runtime"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 60s

x-action-required: False
x-notes: >-
  **pi-web** — web UI for the Pi coding agent. Sessions run in the `sessiond`
  service and keep running after you close the browser.

  Both services share `/mnt/skinner/apps-pi-web` (Pi config, session history,
  pi-web data, and the mise toolchain installed at runtime). There are no code
  mounts: clone or create repos inside `/data` (for example `/data/repos`) and add
  that path as a project.

  Tools come from mise (`node`, `python`, `go`, `rust`, `uv`, ...). `mise install`
  and `mise self-update` inside the app persist across restarts and redeploys.

  Authenticate the agent under **Settings → Models** (provider API key), or run
  `pi` in a terminal. No authentication on the web UI: home-network use only.

  The image is built locally; to update it, rebuild and use **Redeploy**, not the
  app Update button (there is no registry to pull from).
x-portals:
  - host: 0.0.0.0
    name: pi-web
    path: /
    port: 8504
    scheme: http
```

### `build.sh`

Thin `docker build` wrapper: `CACHE_BUST` from a `mise.toml` hash (or `--refresh`), npm
lookups for `PI_WEB_VERSION` and `PI_CODING_AGENT_VERSION` so those layers rebuild on a
new release, `--build-arg` overrides, and `IMAGE` / `DOCKER` env overrides.

### `README.md`

Runbook: build command, the `docker --config /etc/docker` fallback, paste/deploy steps,
first-run setup, rebuild/redeploy, and the two-tier toolchain model — what lives where
(`/etc/mise/config.toml` image toolchain, `/data/mise` runtime installs + binary,
`/data/config/mise/config.toml` runtime `use -g` pins), how to change the image toolchain
(edit `mise.toml`, rebuild with a new `CACHE_BUST`), why `/data` must be exec-enabled, and
the security note.

### `.dockerignore` / `.gitignore`

`.git`, `.gitignore`, `*.md`, `compose.yaml`, `data/`, `*.log`, `.DS_Store` out of the
build context; `data/`, `*.log`, `.DS_Store` ignored by git.

## Deploy flow (yours)

1. `mkdir -p /mnt/skinner/apps-pi-web`
2. `./build.sh` (wraps `docker build`: derives `CACHE_BUST` from `mise.toml` and resolves
   the pi-web and Pi SDK versions; ~6 minutes cold, ~2 when cached, multi-GB image)
3. Apps → Discover → **Custom App** → Install via YAML → paste `compose.yaml`
4. Portal on `:8504`; add a project under `/data`; configure a provider key in
   Settings → Models.

## Post-build smoke test (mirrors what the probes did)

```sh
docker volume create pi-web-smoke
docker run -d --name pi-web-smoke -v pi-web-smoke:/data -p 18504:8504 pi-web-truenas:latest pi-web-sessiond
sleep 8 && docker exec pi-web-smoke test -S /data/pi-web/sessiond.sock && echo "sessiond ok"
docker run -d --name pi-web-web -v pi-web-smoke:/data -p 18505:8504 pi-web-truenas:latest pi-web-server
sleep 6 && curl -fsS http://127.0.0.1:18505/api/pi-web/runtime && curl -so /dev/null -w '%{http_code}\n' http://127.0.0.1:18505/
docker exec pi-web-web bash -lc 'node --version; pi --version; mise --version; rustc --version'
docker rm -f pi-web-smoke pi-web-web && docker volume rm pi-web-smoke
```

Use a named volume or a ZFS dataset for `/data`, never a `noexec` mount.

## Risks / things to know

- **Image is multi-GB** (exact size is printed by `build.sh`) and the first build takes
  ~6 minutes (rust, go, terraform, awscli, kubectl, helm, Chromium are the bulk). Baking
  fewer tools is the only meaningful way to shrink it.
- **`latest` tool versions** mean the toolchain layer only rebuilds when the Docker cache
  is busted — that is what `CACHE_BUST` is for. Pin more versions for reproducible builds.
- **Cargo's registry cache is image-level** (`CARGO_HOME=/usr/local/share/cargo`), so crate
  downloads are re-fetched after a recreate. Moving `CARGO_HOME` to `/data/cargo` in the
  compose env is safe (keep `RUSTUP_HOME` in the image) if you want a warm cache.
- **Don't use the app's Update/pull path** — it would pull `pi-web-truenas:latest` from a
  registry that doesn't exist. Rebuild + Redeploy.
- **Root + no auth is intentional** for a trusted LAN. Don't forward the port to the
  internet.
- **First start copies ~160 MB** (the mise binary) into `/data/mise`. One time.
- **`pathAccess.allowedPaths`** in `/data/config/pi-web/config.json` (or Settings →
  General) is only needed to browse roots outside the workspace.
- **Node 26 is newer than upstream's tested line** (their Dockerfile defaults to Node 22).
  It is verified here end to end; `24.21.0` is a one-line fallback.
- The probes validated the toolchain, the native module, the services and persistence on
  both bases, but not a real agent session (no model provider configured) and not the
  TrueNAS/paste flow itself.

All of the above is delivered and committed; `README.md` is the runbook.
