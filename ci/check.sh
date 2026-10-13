#!/usr/bin/env bash
# Bealach local CI — runs every check on this machine. No hosted CI.
#
#   ci/check.sh              run everything
#   ci/check.sh links        run one check by name
#
# Linux is never required: the same script runs on macOS and Linux. When a
# reproducible Linux environment is wanted anyway, use ci/linux.sh (OrbStack).
#
# Compatible with bash 3.2 (macOS /bin/bash) and up.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CAIRN_CONTRACTS="${CAIRN_CONTRACTS:-$ROOT/contracts}"
export CAIRN_CONTRACTS

PASS=""
FAIL=""
SKIP=""

note() { printf '%s\n' "$*"; }

run() {
  name="$1"
  shift
  note ""
  note "==> $name"
  if "$@"; then
    PASS="$PASS $name"
  else
    FAIL="$FAIL $name"
  fi
}

skip() {
  note ""
  note "==> $1"
  note "skipped: $2"
  SKIP="$SKIP $1"
}

check_links() {
  python3 "$ROOT/ci/links.py"
}

# CI is local-only by design (no paid GitHub features). Keep it that way.
check_local_ci_policy() {
  if [ -d "$ROOT/.github/workflows" ] && [ -n "$(ls -A "$ROOT/.github/workflows" 2>/dev/null)" ]; then
    note "GitHub Actions workflows found under .github/workflows/."
    note "Bealach CI is local-only by design — see ci/README.md."
    return 1
  fi
  note "local-ci policy: ok (no GitHub Actions workflows)"
}

check_tools_go() {
  command -v go >/dev/null 2>&1 || { note "go not installed"; return 1; }
  (cd "$ROOT/tools" && go test ./blevectors ./contractcheck ./enginelang)
}

check_harvest_rust() {
  command -v cargo >/dev/null 2>&1 || { note "cargo not installed"; return 1; }
  cargo test --quiet --locked \
    --manifest-path "$ROOT/harvest/firmware/tools/enginegen/Cargo.toml"
}

check_firmware_host() {
  (cd "$ROOT/firmware/test/host" && make clean && make)
}

check_ios() {
  command -v swift >/dev/null 2>&1 || return 2
  (cd "$ROOT/ios" && swift build && swift test)
}

maybe_ios() {
  check_ios
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS="$PASS ios"
  elif [ "$rc" -eq 2 ]; then
    skip "ios" "swift not on PATH (macOS only)"
  else
    FAIL="$FAIL ios"
  fi
}

check_mermaid() {
  command -v mmdc >/dev/null 2>&1 || return 2
  mkdir -p "$ROOT/build/ci"
  sed -n '/^```mermaid$/,/^```$/p' "$ROOT/README.md" \
    | sed '1d;$d' > "$ROOT/build/ci/arch.mmd"
  mmdc -i "$ROOT/build/ci/arch.mmd" -o "$ROOT/build/ci/arch.svg" >/dev/null
  note "mermaid: ok (README diagram renders)"
}

maybe_mermaid() {
  check_mermaid
  rc=$?
  if [ "$rc" -eq 0 ]; then
    PASS="$PASS mermaid"
  elif [ "$rc" -eq 2 ]; then
    skip "mermaid" "mmdc not on PATH (npm i -g @mermaid-js/mermaid-cli to enable)"
  else
    FAIL="$FAIL mermaid"
  fi
}

ONLY="${1:-}"

if [ -z "$ONLY" ] || [ "$ONLY" = "links" ]; then run "links" check_links; fi
if [ -z "$ONLY" ] || [ "$ONLY" = "local-ci-policy" ]; then run "local-ci-policy" check_local_ci_policy; fi
if [ -z "$ONLY" ] || [ "$ONLY" = "tools-go" ]; then run "tools-go" check_tools_go; fi
if [ -z "$ONLY" ] || [ "$ONLY" = "harvest-rust" ]; then run "harvest-rust" check_harvest_rust; fi
if [ -z "$ONLY" ] || [ "$ONLY" = "firmware-host" ]; then run "firmware-host" check_firmware_host; fi
if [ -z "$ONLY" ] || [ "$ONLY" = "ios" ]; then maybe_ios; fi
if [ -z "$ONLY" ]; then maybe_mermaid; fi

note ""
note "----------------------------------------"
note "passed:${PASS:- none}"
[ -n "$SKIP" ] && note "skipped:$SKIP"
if [ -n "$FAIL" ]; then
  note "FAILED:$FAIL"
  exit 1
fi
note "local CI: all checks passed"
