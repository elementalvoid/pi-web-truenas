# syntax=docker/dockerfile:1.7
# pi-web for TrueNAS custom apps, with a mise-managed general-purpose dev/test toolchain.
# Upstream's own Docker setup expects a plain Docker host (host-profile detection,
# docker.sock, /home+/srv+/opt mounts, hostexec, its own `docker compose up`), which is
# useless inside a TrueNAS app — middleware owns compose and passes `-p ix-<app>`.
FROM debian:trixie

ARG MISE_VERSION=2026.10.7
ARG PI_WEB_VERSION=latest
ARG PI_CODING_AGENT_VERSION=latest
ARG PLAYWRIGHT_VERSION=1.64.0
ARG CACHE_BUST=local

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# MISE_DATA_DIR sits on the persistent volume so runtime tool installs, shims and
# `mise self-update` persist. The image's own toolchain lives in the mise system dir
# (/usr/local/share/mise) and is found automatically, at lower precedence than /data/mise.
# No MISE_CONFIG_DIR / MISE_GLOBAL_CONFIG_FILE on purpose: the image toolchain is the
# *system* config (/etc/mise/config.toml), while the global config stays at
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
    PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
    MISE_DATA_DIR=/data/mise \
    MISE_CACHE_DIR=/mise/cache \
    MISE_TRUSTED_CONFIG_PATHS=/etc/mise \
    MISE_YES=1 \
    MISE_INSTALL_PATH=/usr/local/libexec/mise/mise \
    CARGO_HOME=/usr/local/share/cargo \
    RUSTUP_HOME=/usr/local/share/rustup \
    PATH=/usr/local/share/mise/shims:/data/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Standard tools for an agent/dev container. build-essential plus python (from mise) are
# what node-pty's node-gyp fallback needs; libatomic1 is required by Node 26's official
# build on Debian.
# The GTK4/WebKitGTK 6 dev packages (with pkg-config) are the native build deps for
# webkit-based GUI shells (e.g. Tauri 2 on Linux), so `cargo build` works in the image.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl git git-lfs less tini procps ripgrep unzip xz-utils \
    zip zstd patch file rsync openssh-client build-essential libatomic1 \
    pkg-config libgtk-4-dev libwebkitgtk-6.0-dev libjavascriptcoregtk-6.0-dev \
  && rm -rf /var/lib/apt/lists/*

# mise itself. The real binary stays in libexec: /usr/local/bin/mise is a symlink to the
# /data copy, created further down.
RUN mkdir -p "$(dirname "$MISE_INSTALL_PATH")" \
  && curl -fsSL https://mise.run | MISE_VERSION="$MISE_VERSION" sh

# Image toolchain: mise system installs + system shims. Always present, fresh volume
# included. Build-time mise calls must use $MISE_INSTALL_PATH: /usr/local/bin/mise does not
# exist yet, and is a dangling symlink from the moment it does.
COPY mise.toml /etc/mise/config.toml
RUN set -eux; \
  echo "mise toolchain cache bust: ${CACHE_BUST}"; \
  "$MISE_INSTALL_PATH" trust /etc/mise/config.toml; \
  "$MISE_INSTALL_PATH" install --system; \
  "$MISE_INSTALL_PATH" reshim --system; \
  "$MISE_INSTALL_PATH" --version

# pi-web from npm via mise's Node. Globals land in /usr/local/bin, on the plain PATH.
# pi-web declares the Pi SDK (@earendil-works/pi-coding-agent) as an *optional* peer, which
# npm does not install: without it piRuntime.js cannot find a host Pi and sessiond refuses
# to start. Install it explicitly (it is the `pi` command) in the same global tree.
# The checks are build-time guards: node-pty's native module, and pi-web's own runtime
# selection of the SDK we just installed.
RUN set -eux; \
  echo "pi-web build cache bust: ${CACHE_BUST}"; \
  extra=""; \
  if [ "$(npm --version | cut -d. -f1)" -ge 12 ]; then extra="--allow-scripts=node-pty"; fi; \
  npm install -g --prefix /usr/local --omit=dev --include=peer --no-audit --no-fund \
    ${extra} "@jmfederico/pi-web@${PI_WEB_VERSION}" \
    "@earendil-works/pi-coding-agent@${PI_CODING_AGENT_VERSION}"; \
  cd /usr/local/lib/node_modules/@jmfederico/pi-web; \
  node -e "require('node-pty')"; \
  node -e "import('./dist/piRuntime.js').then(m => m.selectPiRuntimePackageDir()).then(d => console.log('pi sdk:', d))"; \
  /usr/local/bin/pi --version; \
  npm cache clean --force

# Playwright + Chromium, system-wide, so the agent's shells can drive a real browser.
# Browsers live in /opt (image content), not /data: a volume mounted at runtime would
# shadow anything baked into /data. Cost: a runtime `playwright install` of a *different*
# version lands in /opt too and is lost on container recreation — the baked version is the
# one that survives. `install-deps` apt-installs Chromium's shared libraries and needs a
# distro-aware package list: 1.64.0 has a debian13 table, 1.49.1 stops at debian12.
# Everything installs under /usr/local, like pi-web, so bare `playwright` resolves on PATH.
RUN set -eux; \
  echo "playwright cache bust: ${PLAYWRIGHT_VERSION}"; \
  npm install -g --prefix /usr/local --no-audit --no-fund "playwright@${PLAYWRIGHT_VERSION}"; \
  playwright install-deps chromium; \
  playwright install chromium; \
  chrome=$(node -p "require('/usr/local/lib/node_modules/playwright').chromium.executablePath()"); \
  "$chrome" --headless --no-sandbox --disable-gpu --dump-dom about:blank > /dev/null; \
  echo "chromium ok: $chrome"; \
  npm cache clean --force; \
  rm -rf /var/lib/apt/lists/*

# pi-web spawns login shells for terminals, and Debian's /etc/profile rewrites PATH, which
# would drop the shim dirs. Put them back so terminals resolve the same tools agents do.
RUN printf '%s\n' \
  '# mise shims for login shells (pi-web terminals).' \
  'for d in /usr/local/share/mise/shims /data/mise/shims; do' \
  '  case ":$PATH:" in *:"$d":*) ;; *) PATH="$d:$PATH" ;; esac' \
  'done; export PATH' \
  > /etc/profile.d/10-mise-shims.sh

# The `mise` on PATH is a symlink to the persistent copy: shims resolve through it with
# argv[0] intact, and `mise self-update` replaces the file at its canonicalized path, i.e.
# the one on /data. This is why it must not be a wrapper script, and why it comes last.
RUN ln -s /data/mise/mise /usr/local/bin/mise

COPY image/pi-web-entrypoint /usr/local/bin/pi-web-entrypoint
RUN chmod 0755 /usr/local/bin/pi-web-entrypoint

WORKDIR /workspace
EXPOSE 8504
ENTRYPOINT ["tini", "--", "/usr/local/bin/pi-web-entrypoint"]
CMD ["pi-web-server"]
