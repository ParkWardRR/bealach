#!/usr/bin/env bash
# Run Bealach's local CI inside a Linux container.
#
# The checks themselves need no Linux — ci/check.sh runs fine on macOS — but a
# Linux container keeps the environment reproducible and catches host-specific
# assumptions. On macOS the Docker engine is OrbStack (https://orbstack.dev);
# any working `docker` CLI is fine elsewhere.
#
#   ci/linux.sh              build the image if needed, then run every check
#   ci/linux.sh --rebuild    force a fresh image build
#   ci/linux.sh links        run one check inside the container
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DOCKER="${DOCKER:-docker}"
IMAGE="${BEALACH_CI_IMAGE:-bealach-ci:local}"

if ! command -v "$DOCKER" >/dev/null 2>&1; then
  echo "linux-ci: '$DOCKER' not found." >&2
  echo "On macOS install OrbStack (https://orbstack.dev); it provides docker." >&2
  exit 1
fi

BUILD_FLAGS=""
if [ "${1:-}" = "--rebuild" ]; then
  shift
  BUILD_FLAGS="--no-cache"
fi

# shellcheck disable=SC2086 # $BUILD_FLAGS is intentionally word-split
"$DOCKER" build $BUILD_FLAGS -t "$IMAGE" ci
exec "$DOCKER" run --rm -v "$ROOT":/work -w /work "$IMAGE" ci/check.sh "$@"
