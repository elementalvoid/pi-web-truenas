#!/usr/bin/env bash
# Build the pi-web image for the TrueNAS app.
#
#   ./build.sh                 # CACHE_BUST from mise.toml, so rebuilds are cached but
#                              # automatically re-run after you edit the toolchain.
#                              # PI_WEB_VERSION is resolved from npm, so a new pi-web
#                              # release re-runs just that layer.
#   ./build.sh --refresh       # force a fresh CACHE_BUST (pick up newer `latest` tools)
#   ./build.sh --no-cache      # extra args are passed straight to `docker build`
#
# Overrides: IMAGE=tag (default pi-web-truenas:latest), DOCKER="docker --config /etc/docker".
# An explicit --build-arg PI_WEB_VERSION=... skips the npm lookup.
set -euo pipefail
cd "$(dirname "$0")"

image=${IMAGE:-pi-web-truenas:latest}
docker_cmd=${DOCKER:-docker}

bust="mise.toml-$(sha256sum mise.toml | cut -c1-16)"
if [ "${1:-}" = "--refresh" ]; then
  shift
  bust="refresh-$(date -u +%Y%m%dT%H%M%SZ)"
fi

# Resolve the current pi-web release so a new one rebuilds only its own layer: the
# Dockerfile's pi-web RUN reads PI_WEB_VERSION, so a changed value is a cache miss while
# the toolchain layer stays cached. Offline, or given an explicit --build-arg above, this
# stays empty and the Dockerfile default `latest` applies.
pi_web_version=""
pi_web_args=()
if [[ " $* " != *"--build-arg PI_WEB_VERSION"* ]]; then
  pi_web_version=$(curl -fsS --max-time 20 https://registry.npmjs.org/@jmfederico/pi-web 2>/dev/null \
    | grep -oE '"dist-tags":\{"latest":"[^"]+"' | head -1 | cut -d'"' -f6) || true
  if [ -n "$pi_web_version" ]; then
    pi_web_args=(--build-arg "PI_WEB_VERSION=$pi_web_version")
  else
    echo "==> warning: could not resolve the latest pi-web release; using the ARG default" >&2
  fi
fi

echo "==> building $image (CACHE_BUST=$bust${pi_web_version:+, PI_WEB_VERSION=$pi_web_version})"
"$docker_cmd" build --build-arg "CACHE_BUST=$bust" "${pi_web_args[@]}" -t "$image" "$@" .

echo
echo "==> $image  $("$docker_cmd" image inspect "$image" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1073741824}')"
echo "==> now use Redeploy in the TrueNAS app UI (never Update/pull: this image has no registry)"
