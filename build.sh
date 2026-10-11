#!/usr/bin/env bash
# Build the pi-web image for the TrueNAS app.
#
#   ./build.sh                 # CACHE_BUST from mise.toml, so rebuilds are cached but
#                              # automatically re-run after you edit the toolchain
#   ./build.sh --refresh       # force a fresh CACHE_BUST (pick up newer `latest` tools)
#   ./build.sh --no-cache      # extra args are passed straight to `docker build`
#
# Overrides: IMAGE=tag (default pi-web-truenas:latest), DOCKER="docker --config /etc/docker".
set -euo pipefail
cd "$(dirname "$0")"

image=${IMAGE:-pi-web-truenas:latest}
docker_cmd=${DOCKER:-docker}

bust="mise.toml-$(sha256sum mise.toml | cut -c1-16)"
if [ "${1:-}" = "--refresh" ]; then
  shift
  bust="refresh-$(date -u +%Y%m%dT%H%M%SZ)"
fi

echo "==> building $image (CACHE_BUST=$bust)"
"$docker_cmd" build --build-arg "CACHE_BUST=$bust" -t "$image" "$@" .

echo
echo "==> $image  $("$docker_cmd" image inspect "$image" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1073741824}')"
echo "==> now use Redeploy in the TrueNAS app UI (never Update/pull: this image has no registry)"
