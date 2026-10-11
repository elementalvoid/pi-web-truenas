# Plan: pi-web as a TrueNAS custom app (locally built image, mise toolchain)

## Goal

Run [jmfederico/pi-web](https://github.com/jmfederico/pi-web) on this TrueNAS box as a
custom app, from a **locally built** image (no registry). The image carries **mise, used
via shims**, plus the standard tools from `mise.toml`. Runtime tool installs and
`mise self-update` must survive the container being recreated.

Deliverables in this repo: `Dockerfile`, `image/pi-web-entrypoint`, `mise.toml`,
`compose.yaml` (paste-ready TrueNAS custom-app YAML), `README.md`, `.dockerignore`,
`.gitignore`. I build nothing here and start nothing — build/deploy is yours.

Answers locked in: state at `/mnt/skinner/apps-pi-web:/data` (you create it), **no code
mounts**, `mise.toml` tool list unchanged, Node bumped to the newest version that works.

## What I verified

In the upstream repo and this box:

- **pi-web needs two processes.** Bins: `pi-web` (CLI), `pi-web-server` (web/API),
  `pi-web-sessiond` (agent runtime owner). `pi-web-server` does not spawn sessiond, so we
  run two services sharing `/data`, like upstream.
- **Node floor is `>=22.19.0`**, declared by pi-web *and* all three peers
  (`@earendil-works/pi-{ai,agent-core,coding-agent}@1.1.0`), with **no upper bound**.
  npm latest is `@jmfederico/pi-web@1.202610.1`.
- **Upstream's Docker setup is not reusable here.** It targets a plain Docker host
  (host-profile detection, `docker.sock`, `/home`+`/srv`+`/opt` mounts, `hostexec`
  namespace bridge, its own `docker compose up`). TrueNAS middleware owns compose and
  passes `-p ix-<app>`. We reuse its env-var layout, healthchecks and tini, not its files.
- **Locally tagged images work**: custom-app create/redeploy runs `compose up` only, no
  pull. Only the explicit pull-images/upgrade flow pulls, and that would fail for a
  local-only tag → use **Redeploy**, not the Update button.
- **The `mise.toml` comments are dsh leftovers** (Node/amaro note, `/root`-volume
  reasoning) and are junk here. The tool list is good; only the `node` pin changes.

Verified by building throwaway probe images from `debian:bookworm-slim` and running them
with a fresh volume mounted at `/data` (probes deleted afterwards):

| Check | Result |
| --- | --- |
| `mise install --system` (image toolchain) | works, **no `MISE_EXPERIMENTAL` needed** |
| Fresh volume: `node`, `jq`, `rustc` via shims | resolve from the system install, no user data present |
| `mise self-update` target | replaced `/data/mise/mise`; image copy untouched |
| self-update after `docker rm` + recreate on same volume | version persisted |
| Runtime `mise use -g shellcheck@0.11.0` | installed to `/data`, config written to `/data/config/mise/config.toml`, shim in `/data/mise/shims`, and all three survived recreate |
| `rustc` with `HOME=/data/home` and `/data` mounted | works **only** with `CARGO_HOME`/`RUSTUP_HOME` redirected (see below) |
| Node 26.11.1 on `bookworm-slim` | needs `libatomic1` |
| `node-pty` build (node-gyp) | OK on **both** 24.21.0 and 26.11.1 once `python3` + build tools are present |

### Gotchas found (these shaped the design)

1. **A wrapper script breaks shims.** My first idea — `/usr/local/bin/mise` as a shell
   wrapper that `exec`s the `/data` copy — made runtime-created shims point at the wrapper,
   and the wrapper's `exec` **loses `argv[0]`**, so mise could not tell which tool a shim
   was for. Symptom: `shellcheck --version` printed *mise's* version. Fixed by making
   `/usr/local/bin/mise` a **symlink** to `/data/mise/mise`: symlink chains preserve
   `argv[0]`, and self-update canonicalizes to the `/data` file. A wrapper is now only
   needed for the seed step, which moved into the entrypoint.
2. **`MISE_CONFIG_DIR` hijacks the global config.** With it set, the global config *is*
   `/etc/mise/config.toml`, so a runtime `mise use -g` writes into the image layer and is
   lost on recreate. Leaving it unset keeps the image toolchain in the **system** config
   (`/etc/mise/config.toml`, path independent of `MISE_CONFIG_DIR` — verified) while the
   **global** config lands at `$XDG_CONFIG_HOME/mise/config.toml` =
   `/data/config/mise/config.toml`, which persists.
3. **rustup-backed rust installs into `$HOME`,** which is `/data/home` → a symlinked
   toolchain that dangles on a fresh volume. `CARGO_HOME=/usr/local/share/cargo` +
   `RUSTUP_HOME=/usr/local/share/rustup` keep it in the image (verified working).
4. **Node 26 needs `libatomic1`** (Node 24 does not). Pi-web's floors allow 26.
5. **node-gyp needs `python3`** — satisfied by mise's Python, but the toolchain layer must
   run *before* the npm layer.
6. `COPY` preserves host file modes, so the entrypoint needs an explicit `chmod 0755`
   (caught by the probe failing to start).

## Key decisions

1. **Own thin Dockerfile on `debian:bookworm-slim`** rather than vendoring upstream's
   openSUSE Dockerfile + installer + `hostexec` (~700 lines) that TrueNAS makes useless.
2. **Two-tier mise** (the mise-documented "shared/system installs" pattern, which is
   exactly the devcontainer-with-home-mount case):
   - **Image tier**: `mise.toml` baked as the *system* config `/etc/mise/config.toml`,
     installed with `mise install --system` into `/usr/local/share/mise/installs`, with
     `mise reshim --system` shims in `/usr/local/share/mise/shims`. Always present, even
     on a fresh volume; invisible-not-lost under the `/data` mount.
   - **Runtime tier**: `MISE_DATA_DIR=/data/mise` → runtime installs, shims, plugins and
     state persist. Runtime installs **take precedence** over system ones (verified).
3. **mise provides Node** (official distro build, so the bundled TypeScript type-stripper
   is present — `stripTypeScriptTypes` confirmed as a function), and pi-web is installed
   with mise's npm into `/usr/local` (`--prefix /usr/local`) so `pi-web-server`,
   `pi-web-sessiond`, `pi-web` and a symlinked `pi` are on the default `PATH`, independent
   of mise.
4. **`node = "26.11.1"`** — the newest release that works (verified run + `node-pty`
   build). Requires `libatomic1`. `24.21.0` is the conservative fallback if you'd rather
   match upstream's tested Node 22 line.
5. **Entrypoint seeds the persistent binary**, creating `/data` subdirs and
   `/data/mise/mise` on first start (atomic temp+`mv`, so sessiond/web can't race), with a
   fallback symlink to the image copy if `/data` is unusable — degraded, never missing.
6. **Run as root**, like your `dsh` example: pi-web is not a sandbox, it's LAN-only, and
   root avoids ownership fights on the bind mount. No `pi-web` account.
7. **bash/Debian login-shell note:** terminals get login shells and Debian's
   `/etc/profile` rewrites `PATH`; `/etc/profile.d/10-mise-shims.sh` re-adds the shim
   dirs so terminals and agent processes agree.
8. **Compose has no `build:`, no `container_name`, no `name:`**, one `/data` bind mount.

## Files

### `mise.toml` (only the node pin changes)

```toml
# Toolchain baked into the image at build time (system config /etc/mise/config.toml).
# Runtime additions live in /data/mise and take precedence over these.
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

```dockerfile
# syntax=docker/dockerfile:1.7
# pi-web for TrueNAS custom apps. Upstream's own Docker setup expects a plain Docker
# host (host mounts, docker.sock, hostexec) and is deliberately not reused.
FROM debian:bookworm-slim

ARG MISE_VERSION=2026.10.7
ARG PI_WEB_VERSION=latest
ARG CACHE_BUST=local

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# MISE_DATA_DIR sits on the persistent volume, so runtime tool installs and shims
# persist. The image's toolchain lives in the system dir (/usr/local/share/mise) and is
# found automatically, with lower precedence than anything under /data/mise.
# No MISE_CONFIG_DIR / MISE_GLOBAL_CONFIG_FILE: the image toolchain is the *system*
# config (/etc/mise/config.toml) and the global config stays at
# $XDG_CONFIG_HOME/mise/config.toml = /data/config/mise/config.toml, so runtime
# `mise use -g` persists too.
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

# build-essential + libatomic1: gcc/python for node-pty's node-gyp fallback, and
# libatomic for Node 26's official build on bookworm.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl git git-lfs less tini procps ripgrep unzip xz-utils \
    build-essential libatomic1 \
  && rm -rf /var/lib/apt/lists/*

# mise itself. The real binary stays in libexec: /usr/local/bin/mise is a symlink to the
# /data copy, created further down.
RUN mkdir -p "$(dirname "$MISE_INSTALL_PATH")" \
  && curl -fsSL https://mise.run | MISE_VERSION="$MISE_VERSION" sh

# Image toolchain: system installs + system shims (always present, fresh volume included).
COPY mise.toml /etc/mise/config.toml
RUN set -eux; \
  echo "mise toolchain cache bust: ${CACHE_BUST}"; \
  mise trust /etc/mise/config.toml; \
  mise install --system; \
  mise reshim --system; \
  mise --version

# pi-web from npm, using mise's Node (globals land in /usr/local/bin, plain PATH).
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
# back so terminals resolve the same tools agents do.
RUN printf '%s\n' \
  '# mise shims for login shells (pi-web terminals).' \
  'for d in /usr/local/share/mise/shims /data/mise/shims; do' \
  '  case ":$PATH:" in *:"$d":*) ;; *) PATH="$d:$PATH" ;; esac' \
  'done; export PATH' \
  > /etc/profile.d/10-mise-shims.sh

# `mise` on PATH is a symlink to the copy on the persistent volume: shims resolve
# through it with argv[0] intact, and `mise self-update` replaces the file at its
# canonicalized path, i.e. the one on /data. Dangling until the entrypoint seeds it, so
# this must come after every build-time mise/npm step.
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

### `README.md`

Runbook: build command, the `docker --config /etc/docker` fallback, paste/deploy steps,
first-run setup, rebuild/redeploy, and the two-tier toolchain model — what lives where
(`/etc/mise/config.toml` image toolchain, `/data/mise` runtime installs + binary,
`/data/config/mise/config.toml` runtime `use -g` pins), how to change the image toolchain
(edit `mise.toml`, rebuild with a new `CACHE_BUST`), and the security note.

### `.dockerignore` / `.gitignore`

`compose.yaml`, `*.md`, `.git`, `.DS_Store` out of the build context; `data/`, `*.log`
ignored by git.

## Deploy flow (yours)

1. `mkdir -p /mnt/skinner/apps-pi-web`
2. `docker build --build-arg CACHE_BUST=$(date +%s) -t pi-web-truenas:latest .`
   (first build installs the whole mise toolchain: several minutes, multi-GB image)
3. Apps → Discover → **Custom App** → Install via YAML → paste `compose.yaml`
4. Portal on `:8504`; add a project under `/data`; configure a provider key in
   Settings → Models.

## Post-build smoke test (run these against the real image)

```sh
T=$(mktemp -d)                              # NOT /tmp: noexec on this box
mkdir -p "$T/data"
docker run -d --name pi-web-smoke -v "$T/data:/data" pi-web-truenas:latest sleep infinity
docker exec pi-web-smoke bash -lc 'mise --version; node --version; rustc --version; \
  jq --version; which node; mise config ls; pi-web --help >/dev/null && echo pi-web-ok'
docker exec pi-web-smoke mise use -g shellcheck@0.11.0   # runtime install...
docker rm -f pi-web-smoke
docker run -d --name pi-web-smoke -v "$T/data:/data" pi-web-truenas:latest sleep infinity
docker exec pi-web-smoke bash -lc 'shellcheck --version; mise --version'  # ...persisted?
docker rm -f pi-web-smoke && rm -rf "$T"
```

Plus one real `mise self-update` and re-create, since that is the property you asked for.

## Risks / things to know

- **Node 26 is newer than upstream's tested line** (their Dockerfile defaults to Node 22).
  It runs and `node-pty` builds (verified), but if anything misbehaves, `24.21.0` is a
  one-line change; keep `libatomic1` installed either way (harmless).
- **`latest` tool versions** mean the toolchain layer only rebuilds when the Docker cache
  is busted — that is what `CACHE_BUST` is for. Pin more versions in `mise.toml` for fully
  reproducible rebuilds.
- **Cargo's registry cache is image-level** (`CARGO_HOME=/usr/local/share/cargo`), so crate
  downloads are re-fetched after a recreate. Moving `CARGO_HOME` to `/data/cargo` in the
  compose env is safe (keep `RUSTUP_HOME` in the image) if you'd rather have a warm cache.
- **Don't use the app's Update/pull path**; it would pull `pi-web-truenas:latest` from a
  registry that doesn't exist. Rebuild + Redeploy.
- **Root + no auth is intentional** for a trusted LAN. Don't forward the port to the
  internet.
- **First start copies ~160 MB** (the mise binary) into `/data/mise`. One time.
- **`pathAccess.allowedPaths`** in `/data/config/pi-web/config.json` (or Settings →
  General) is only needed to browse roots outside the workspace.
- The Dockerfile itself is not yet built against real pi-web; the probe verified the mise
  layer and native-module build, not the pi-web npm layer end to end. The
  `node -e "require('node-pty')"` assert and the smoke test above cover that.

## Answer recap / still open

- 1 ✅ `/mnt/skinner/apps-pi-web:/data` (you create it).
- 2 ✅ No code mounts; projects live under `/data` (noted in the app notes).
- 3 ✅ `mise.toml` tool list unchanged, comments cleaned.
- 4 ✅ `node = "26.11.1"` (newest; verified). Say so if you prefer `24.21.0`.

Nothing blocking: say go and I'll write the six files and commit them.
