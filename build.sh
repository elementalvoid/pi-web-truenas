#!/usr/bin/env bash
# Build the pi-web image for the TrueNAS app.
#
#   ./build.sh                 # CACHE_BUST from mise.toml, so rebuilds are cached but
#                              # automatically re-run after you edit the toolchain.
#                              # PI_WEB_VERSION and PI_CODING_AGENT_VERSION are resolved
#                              # from npm, so a new pi-web or Pi SDK release re-runs just
#                              # that layer.
#   ./build.sh --refresh       # force a fresh CACHE_BUST (pick up newer `latest` tools)
#   ./build.sh --no-cache      # extra args are passed straight to `docker build`
#
# Overrides: IMAGE=tag (default pi-web-truenas:latest), DOCKER="docker --config /etc/docker".
# An explicit --build-arg PI_WEB_VERSION=... (or PI_CODING_AGENT_VERSION=...) skips that
# package's npm lookup.
set -euo pipefail
cd "$(dirname "$0")"

image=${IMAGE:-pi-web-truenas:latest}
docker_cmd=${DOCKER:-docker}

bust="mise.toml-$(sha256sum mise.toml | cut -c1-16)"
if [ "${1:-}" = "--refresh" ]; then
  shift
  bust="refresh-$(date -u +%Y%m%dT%H%M%SZ)"
fi

# Resolve the current release of each package the Dockerfile installs so a new one
# rebuilds only its own layer: the matching RUN reads the ARG, so a changed value is a
# cache miss while the toolchain layer stays cached. Offline, or given an explicit
# --build-arg above, a package stays empty and the Dockerfile default `latest` applies.
# pi-web and its Pi SDK peer release independently, so both are resolved.
latest_version() {
  curl -fsS --max-time 20 "https://registry.npmjs.org/$1" 2>/dev/null \
    | grep -oE '"latest":"[^"]+"' | head -1 | cut -d'"' -f4
}

pi_web_args=()
for spec in PI_WEB_VERSION:@jmfederico/pi-web PI_CODING_AGENT_VERSION:@earendil-works/pi-coding-agent; do
  arg=${spec%%:*}
  package=${spec#*:}
  [[ " $* " == *"--build-arg $arg"* ]] && continue
  version=$(latest_version "$package") || true
  if [ -n "$version" ]; then
    pi_web_args+=(--build-arg "$arg=$version")
  else
    echo "==> warning: could not resolve the latest $package release; using the ARG default" >&2
  fi
done

echo "==> building $image (CACHE_BUST=$bust${pi_web_args[*]:+ ${pi_web_args[*]}})"
"$docker_cmd" build --build-arg "CACHE_BUST=$bust" "${pi_web_args[@]}" -t "$image" "$@" .

echo
echo "==> $image  $("$docker_cmd" image inspect "$image" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1073741824}')"
echo "==> now use Redeploy in the TrueNAS app UI (never Update/pull: this image has no registry)"
