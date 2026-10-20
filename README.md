# pi-web on TrueNAS (locally built image)

A Docker image that runs [PI WEB](https://pi-web.dev/) — the web UI for the Pi coding
agent — as a TrueNAS custom app. The image is built **locally** (no registry) and doubles
as a general-purpose dev/test container: mise-managed toolchain via shims plus a set of
standard tools.

- Web UI: `http://<truenas>:8504`
- Persistent state: `/mnt/skinner/apps-pi-web` mounted at `/data`
- No authentication. Home/trusted-network use only — never forward this port to the
  internet.

## What is in the image

- `debian:trixie` base plus `git`, `git-lfs`, `openssh-client`, `rsync`, `ripgrep`,
  `jq`*, `less`, `file`, `zip`/`unzip`, `zstd`, `patch`, `procps`, `curl`, `tini`,
  `build-essential`.
- The toolchain from `mise.toml` via **mise** (`node`, `bun`, `python`, `go`, `rust`,
  `gh`, `awscli`, `kubectl`, `helm`, `terraform`, `neovim`, `uv`, `fzf`, `yq`,
  `shellcheck`, `jq`).
- `@jmfederico/pi-web` plus its Pi Coding Agent peer (`pi-web-server`, `pi-web-sessiond`,
  `pi-web`, `pi`).
- (*) `jq` and friends come from mise, not apt, so they are the versions pinned there.

## Build

On the TrueNAS box:

```sh
mkdir -p /mnt/skinner/apps-pi-web          # persistent state, must be exec-enabled
./build.sh
```

`build.sh` tags the image `pi-web-truenas:latest` (the tag `compose.yaml` uses) and
derives `CACHE_BUST` from a hash of `mise.toml`, so:

- unchanged `mise.toml` → layers are cached, a rebuild is seconds;
- edited `mise.toml` → the toolchain and pi-web layers rebuild automatically;
- a new `@jmfederico/pi-web` release → only the pi-web layer re-runs, because `build.sh`
  resolves the current version from npm first (`--build-arg PI_WEB_VERSION=...` overrides
  it; being offline falls back to the Dockerfile's `latest`);
- `./build.sh --refresh` forces a fresh bust, for picking up newer `latest` *toolchain*
  versions, which are not looked up individually;
- extra arguments go to `docker build`, e.g. `./build.sh --no-cache --progress plain`.

Environment overrides: `IMAGE=pi-web-truenas:test ./build.sh`, and
`DOCKER="docker --config /etc/docker" ./build.sh` if the daemon socket is not found by
the default config. First build takes ~5 minutes and produces a ~3.9 GB image (rust, go,
terraform, awscli, kubectl, helm dominate).

## Deploy

TrueNAS UI → **Apps → Discover → Custom App → Install via YAML**, then paste `compose.yaml`.

The app runs two services from the image, sharing one `/data` volume:

| service | command | notes |
| --- | --- | --- |
| `sessiond` | `pi-web-sessiond` | owns agent runtimes; socket at `/data/pi-web/sessiond.sock` |
| `web` | `pi-web-server` | serves the UI/API on port `8504` |

Both are needed: `pi-web-server` does not start the session daemon itself. `web` waits for
`sessiond` to become healthy.

After install: open the portal on `:8504`, add a project (a path under `/data`), pick a
workspace, start a session. Configure a model provider/API key under
**Settings → Models**, or run `pi` in a terminal inside the app.

## Updating

```sh
./build.sh          # or ./build.sh --refresh to force newer `latest` tool versions
```

Then use the app's **Redeploy** action. Do **not** use the app's Update/pull button: the
image is not in any registry, so a pull would fail. Redeploy just recreates containers from
the tag that now points at your new build.

Sessions live in `/data`, so recreating containers keeps history and config. Recreating
`sessiond` does stop active agent runtimes — redeploy while sessions are idle.

## Where things live (toolchain model)

`/data` is the only volume, so make sure it is on a filesystem that allows execution —
the mise binary is run from there. ZFS datasets on TrueNAS default to `exec=on`, which is
fine; a `noexec` mount (like `/tmp` on some systems) would break mise and every shim.

| path | contents | lifetime |
| --- | --- | --- |
| `/etc/mise/config.toml` | image toolchain pin (this repo's `mise.toml`) | image |
| `/usr/local/share/mise` | toolchain installed at build time (`mise install --system`) | image |
| `/data/mise` | runtime tool installs, shims, plugins, and the mise binary | **persists** |
| `/data/config/mise/config.toml` | runtime `mise use -g` pins | **persists** |
| `/data/home` | `HOME`: dotfiles, `~/.ssh`, `~/.pi`, npm/cargo caches | **persists** |
| `/data/pi-web`, `/data/pi-agent` | pi-web state and Pi agent sessions | **persists** |

Tool resolution is two-tier: the image toolchain is always available (even on a fresh
volume), and anything installed at runtime into `/data/mise` **takes precedence** over it.

- Install a tool for a session/project: `mise use -g <tool>@<version>` → persists.
- Prefer `<repo>/mise.toml` inside a workspace; `mise install` there is also persistent
  (installs go to `/data/mise`).
- Change the *image* toolchain: edit `mise.toml`, rebuild with `./build.sh` (the bust
  follows the file), then Redeploy.
- Update mise itself: `mise self-update` — the binary is seeded onto `/data` by the
  entrypoint, so the update survives container recreation (until you change `MISE_VERSION`
  in the Dockerfile and delete `/data/mise/mise`, which resets it to the image pin).

## Security

pi-web is not a sandbox: sessions run as root in the container and can read/write `/data`,
run bash, and use any credentials you place there. There is no login on the UI. Keep it on
a trusted LAN/VPN, or put an authenticated reverse proxy in front of it.

## Troubleshooting

- **`mise: command not found`, missing tools**: check that `/data` is writable and not
  `noexec`; the entrypoint seeds `/data/mise/mise` (falling back to the image copy, without
  persistence, if it cannot).
- **App unhealthy**: `sessiond` needs its socket under `/data/pi-web/`; if an older
  container still owns that directory, stop the app and redeploy.
- **`docker compose` pulls and fails**: don't use the Update/pull path, rebuild + Redeploy.
- **Tools missing in a web terminal but present to agents** (or vice versa): terminals are
  login shells; `/etc/profile.d/10-mise-shims.sh` re-adds the shim dirs. If you change
  `MISE_DATA_DIR` or the shim layout, update that hook.
- **Working on a repo outside `/data`**: there are no host code mounts. Clone into `/data`,
  or add extra bind mounts to the compose file and give pi-web the same absolute path.
  Roots outside a workspace need `pathAccess.allowedPaths` in
  `/data/config/pi-web/config.json` (or Settings → General).

## Files

| file | purpose |
| --- | --- |
| `build.sh` | builds the image with a `mise.toml`-derived `CACHE_BUST` |
| `Dockerfile` | the image: base, standard tools, mise two-tier toolchain, pi-web |
| `mise.toml` | toolchain baked into the image (system config) |
| `image/pi-web-entrypoint` | seeds `/data` and the persistent mise binary, then runs the service |
| `compose.yaml` | paste-ready TrueNAS custom app (sessiond + web) |
| `PLAN.md` | design notes, base-image comparison, and what was verified how |
