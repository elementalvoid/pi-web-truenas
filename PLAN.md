# Plan: pi-web as a TrueNAS custom app (locally built image, mise toolchain)

## Goal

Run [jmfederico/pi-web](https://github.com/jmfederico/pi-web) on this TrueNAS box as a
custom app, from a **locally built** image (no registry). The image must carry **mise
(used via shims)** plus a suite of standard dev tools so agents inside pi-web sessions
have a usable toolchain.

Deliverables in this repo: `Dockerfile`, `mise.toml`, `compose.yaml` (the paste-ready
TrueNAS custom-app YAML), `README.md`, `.dockerignore`, `.gitignore`. No app is started
here — build/deploy is yours.

## What I verified

- **Upstream Docker setup exists but is not a drop-in.** `docker/Dockerfile` is openSUSE
  Tumbleweed based and the installer (`docker/install.sh`) is designed for a plain Linux
  or macOS Docker host: it detects a host profile, mounts `/var/run/docker.sock`, mounts
  `/`, `/home`, `/srv`, `/opt`, drops in a `hostexec` namespace bridge, writes
  `compose.override.yml`, and runs its own `docker compose up`. None of that fits a
  TrueNAS app (middleware owns compose, `-p ix-<appname>`, and would create a second
  stack). We reuse its *ideas* (env vars, healthchecks, path parity, tini), not the files.
- **pi-web needs two processes.** `package.json` bins: `pi-web` (CLI), `pi-web-server`
  (web/API), `pi-web-sessiond` (agent runtime owner). `pi-web-server` does not spawn
  sessiond. Upstream runs them as two containers sharing `/data`; we do the same.
- **Node requirement**: `engines.node >= 22.19.0`. Latest npm version is
  `@jmfederico/pi-web@1.202610.1`; peers `@earendil-works/pi-{ai,agent-core,coding-agent} ^1.0.0`,
  which npm resolves itself with `--include=peer` (as upstream does).
- **Local images are fine for custom apps.** Install/redeploy path is `docker compose up`
  only (`compose_action(..., 'up')`); there is no `pull` on custom-app create or redeploy.
  `pull` only happens via the explicit "pull images"/upgrade flow, which would fail for a
  locally tagged image → don't use the UI Update button; redeploy instead. (I did check
  this in the middleware; I stopped reading the rest as you asked.)
- **mise facts used** (from current mise docs): `MISE_INSTALL_PATH` for the install script,
  `MISE_VERSION` to pin, `MISE_DATA_DIR`/`MISE_CONFIG_DIR`/`MISE_SHIMS_DIR`,
  `MISE_GLOBAL_CONFIG_FILE` (global config path), `MISE_TRUSTED_CONFIG_PATHS` +
  `mise trust`, `mise install`, and shims placed on `PATH` (no `activate`, no shell hook
  required for the shell the process is started with).
- **Versions in your `mise.toml` all exist**: node `24.18.0`, bun `1.4.0`,
  neovim `0.12.4`, awscli `2.36.29` (registry checked). All other tool names are valid
  mise backends (`go`, `rust`, `python`, `uv`, `kubectl`, `helm`, `terraform`, `gh`,
  `yq`, `jq`, `fzf`, `shellcheck`).
- **The comments in `mise.toml` are dsh leftovers** (Node/amaro note, `/root` volume
  reasoning) — not applicable here, and the `/etc/mise/config.toml` path they mention is
  the one I actually want for a different reason (image-level, not a runtime volume).
  The tool list itself is good and I'm keeping it.

## Key decisions (and why)

1. **Write our own thin Dockerfile on `debian:bookworm-slim`** instead of vendoring
   upstream's ~700-line openSUSE Dockerfile + installer + `hostexec` + `pi-web-docker`.
   We need none of the host-bridge machinery on TrueNAS. Debian slim keeps the diff small
   and everything in this repo is ours to read.
2. **mise provides Node** (official distro build, so the bundled TypeScript type-stripper
   works, which upstream explicitly cares about), and **pi-web is installed with mise's
   npm into `/usr/local`** (`--prefix /usr/local`), so `pi-web-server`,
   `pi-web-sessiond`, `pi-web` and a symlinked `pi` CLI land on the default `PATH` —
   no dependency on mise shims for the app's own binaries.
3. **`/mise` is image-level** (`MISE_DATA_DIR=/mise`, `MISE_SHIMS_DIR=/mise/shims`,
   config at `/etc/mise/config.toml`). Tools are installed at build time, so nothing
   under `/data` hides them. Consequence: a runtime `mise install` writes to the image
   layer and is lost on container recreate — documented, with `MISE_DATA_DIR=/data/mise`
   as the escape hatch if you'd rather have runtime installs persist.
4. **Shims on `PATH` plus one `/etc/profile.d` hook.** pi-web spawns *login* shells for
   terminals, and Debian's `/etc/profile` resets `PATH`, which would drop `/mise/shims`.
   A 1-file hook re-adds it; agents and terminals then resolve the same tools.
5. **Run as root** (like your `dsh` example). pi-web is explicitly not a sandbox and is
   meant for a trusted LAN; root avoids ownership fights on the host bind mount. No
   `pi-web` account like upstream creates.
6. **One app, two services, one `/data` bind mount**, matching upstream's env-var layout
   (`HOME=/data/home`, `XDG_CONFIG_HOME=/data/config`, `PI_WEB_DATA_DIR=/data/pi-web`,
   `PI_CODING_AGENT_DIR=/data/pi-agent`) so upstream docs/agents stay accurate.
7. **Code mounted at identical absolute paths** (`/mnt/skinner/...:/mnt/skinner/...`), so
   a pi-web "project" path is the same inside and outside the container and sessions line
   up with host worktrees. Same trick as upstream's host mounts, without the socket.
8. **No `build:` in the compose file, no `container_name`, no `name:`.** Image is
   prebuilt and tagged locally; the middleware passes `-p ix-<app>`.

## Files

### `mise.toml` (cleanup, not a rewrite)

Drop the dsh comments, add a one-line header saying this is the image toolchain. Keep the
tool list and your pins. Optionally bump node `24.18.0` → `24.21.0` (same lts line) — say
the word and I'll leave it exactly as-is instead. `latest` entries stay `latest`; the
build caches that layer, so a `CACHE_BUST` build arg is how you refresh them.

### `Dockerfile`

```dockerfile
# syntax=docker/dockerfile:1.7
# pi-web for TrueNAS custom apps: mise-managed toolchain + locally built image.
# Upstream's own Docker setup targets a plain Docker host (host mounts, docker.sock,
# hostexec) and is deliberately not reused here.
FROM debian:bookworm-slim

ARG MISE_VERSION=2026.10.7
ARG PI_WEB_VERSION=latest
ARG CACHE_BUST=local

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# mise is image-level so a runtime /data bind mount cannot hide the toolchain.
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
    MISE_DATA_DIR=/mise \
    MISE_CONFIG_DIR=/mise \
    MISE_CACHE_DIR=/mise/cache \
    MISE_SHIMS_DIR=/mise/shims \
    MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml \
    MISE_TRUSTED_CONFIG_PATHS=/etc/mise \
    MISE_YES=1 \
    MISE_INSTALL_PATH=/usr/local/bin/mise \
    PATH=/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl git git-lfs less tini procps ripgrep unzip xz-utils \
    build-essential \
  && rm -rf /var/lib/apt/lists/*

# mise itself; shims land in $MISE_SHIMS_DIR which is already on PATH.
RUN curl -fsSL https://mise.run | MISE_VERSION="$MISE_VERSION" sh

# Toolchain last-pinned-by: CACHE_BUST. Bump it to refresh `latest` tools.
COPY mise.toml /etc/mise/config.toml
RUN set -eux; \
  echo "mise toolchain cache bust: ${CACHE_BUST}"; \
  mise trust /etc/mise/config.toml; \
  mise install; \
  mise reshim

# pi-web via mise's npm, globals in /usr/local/bin (plain PATH, not a shim).
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

# pi-web spawns login shells for terminals; Debian's /etc/profile resets PATH.
RUN printf '%s\n' \
  '# mise shims for login shells (pi-web terminals).' \
  'case ":$PATH:" in *:/mise/shims:*) ;; *) PATH="/mise/shims:$PATH"; export PATH ;; esac' \
  > /etc/profile.d/10-mise-shims.sh

WORKDIR /workspace
EXPOSE 8504
ENTRYPOINT ["tini", "--"]
CMD ["pi-web-server"]
```

Notes: `npm --allow-scripts` only exists on npm 12, hence the guard (on npm 11 install
scripts run anyway). The `require('node-pty')` line is the build-time check that the
native module actually built — pi-web terminals need it and it is the one thing that
silently ships broken. If Node 24.18's npm turns out to be 12, the guard handles it; if
node-pty still fails to build we'll see it at build time, not in the browser.

### `compose.yaml` (paste-ready TrueNAS custom app)

Path placeholders: `/mnt/skinner/apps-pi-web` for persistent state, and the code root to
mount for agent workspaces. **Confirm these two paths before I write the file.**

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

# Not a sandbox: keep off the internet, LAN/trusted network only.
x-pi-web-volumes: &pi-web-volumes
  - /mnt/skinner/apps-pi-web:/data
  # Mounted at the same absolute path so host and container paths line up.
  - /mnt/skinner/homes/matt/code:/mnt/skinner/homes/matt/code

services:
  sessiond:
    image: *pi-web-image
    command: ["pi-web-sessiond"]
    restart: unless-stopped
    environment: *pi-web-environment
    volumes: *pi-web-volumes
    healthcheck:
      test: ["CMD-SHELL", "test -S /data/pi-web/sessiond.sock"]
      interval: 10s
      timeout: 3s
      retries: 12
      start_period: 10s

  web:
    image: *pi-web-image
    command: ["pi-web-server"]
    restart: unless-stopped
    depends_on:
      sessiond:
        condition: service_healthy
    environment: *pi-web-environment
    volumes: *pi-web-volumes
    ports:
      - "8504:8504"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:8504/api/pi-web/runtime"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 10s

x-action-required: False
x-notes: >-
  **pi-web** — web UI for the Pi coding agent. Sessions run in the `sessiond`
  service and keep running after you close the browser.

  Both services share `/mnt/skinner/apps-pi-web` (Pi config, session history,
  pi-web data) and see your code at its real host path, so projects are added as
  host-absolute paths (for example `/mnt/skinner/homes/matt/code/foo`).

  Authenticate the agent under **Settings → Models** (provider API key), or run
  `pi` in a terminal. No authentication on the web UI: home-network use only.

  The image is built locally; to update, rebuild it and use **Redeploy**, not the
  app Update button (there is no registry to pull from).
x-portals:
  - host: 0.0.0.0
    name: pi-web
    path: /
    port: 8504
    scheme: http
```

### `README.md`

Build-and-deploy runbook: the `docker build` command on the box (including the
`docker --config /etc/docker` fallback if the daemon socket config bites), the paste
steps, first-run setup, how to rebuild/redeploy, where state lives, how to refresh the
mise toolchain (`CACHE_BUST`), how to add a tool (`mise.toml` + rebuild, or a runtime
`mise use` with `MISE_DATA_DIR=/data/mise`), and the security note.

### `.dockerignore` / `.gitignore`

`compose.yaml`, `*.md`, `.git`, `.DS_Store` out of the build context; `data/`, `*.log`
ignored by git.

## Deploy flow (yours to run)

1. On the box: `mkdir -p /mnt/skinner/apps-pi-web` then
   `docker build --build-arg CACHE_BUST=$(date +%s) -t pi-web-truenas:latest .`
   (first build installs the whole mise toolchain: expect several minutes and a
   multi-GB image — see Risks).
2. Apps → Discover → **Custom App** → Install via YAML → paste `compose.yaml`.
3. Open the portal on `:8504`; add a project (host-absolute path) and a workspace.
4. Configure a model provider / API key in Settings → Models.

## Risks / things to know

- **Image size and build time.** `rust`, `go`, `awscli`, `terraform`, `kubectl`, `helm`
  together are large (rough estimate 3–6 GB image, 5–15 min first build). If you don't
  need them in the agent's world, dropping `rust`, `terraform`, `awscli` is the single
  biggest saving — tell me and I'll trim `mise.toml`.
- **`latest` tool versions** mean the toolchain layer is only rebuilt when the Docker
  cache is busted; that is what the `CACHE_BUST` arg is for. Pin more versions in
  `mise.toml` if you want fully reproducible rebuilds.
- **Don't use the app's Update/pull path**; it will try to pull `pi-web-truenas:latest`
  from a registry that doesn't exist. Rebuild + Redeploy.
- **Root + no auth is intentional** for a trusted LAN. Don't forward this port to the
  internet.
- **`pathAccess.allowedPaths`** in `/data/config/pi-web/config.json` (or Settings →
  General) is only needed to browse filesystem roots *outside* the mounted code path.
- I have not run the build; the Dockerfile is unverified until you build it. The
  `node -e "require('node-pty')"` assert is there to fail the build rather than surprise
  you in the browser.

## Open questions before I write the files

1. **State path**: `/mnt/skinner/apps-pi-web:/data` — good, or somewhere else?
2. **Code mounts**: mount all of `/mnt/skinner/homes/matt/code`, or a narrower set of
   repos (or also `/mnt/skinner/homes/matt` for dotfiles/agent config)?
3. **Tool list**: keep all of `mise.toml` as-is, or trim the heavy ones (rust/terraform/
   awscli)?
4. **Node pin**: keep `24.18.0` or bump to `24.21.0`?

Answer 1–4 and I'll write the files and commit them.

## Work log

- Git repo initialized here; existing `mise.toml` committed as the starting point.
