#!/bin/sh
# Smoke-test a built bundle. Meant to run inside a CentOS 7 container (glibc,
# no musl) to prove the bundle is self-contained.
#
# Beyond a trivial --version print, this actually starts the opencode HTTP
# server and queries its API. That exercises the real Bun runtime: the event
# loop, config loading, filesystem access, and an HTTP server -- proving the
# bundled musl loader + libstdc++/libgcc are complete enough for opencode to
# genuinely run, not just launch and exit.
#
# Everything is hermetic: HOME/XDG point at a scratch dir, the server binds a
# loopback port, and no network or API key is required.
#
# Environment variables:
#   OUT_DIR  directory containing the built tarball (default: dist)
set -eu

OUT_DIR="${OUT_DIR:-dist}"

fail() { echo "!! $1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required to run this test"

tarball="$(ls "$OUT_DIR"/opencode-*-centos7-bundle.tar.gz 2>/dev/null | head -n1 || true)"
[ -n "$tarball" ] || fail "No bundle tarball found in $OUT_DIR"

echo ">> Host libc (should be glibc, no musl):"
ldd --version 2>&1 | head -n1 || true

work="$(mktemp -d)"
echo ">> Extracting $tarball"
tar -xzf "$tarball" -C "$work"
OC="$work/opencode-bundle/opencode.sh"

# Isolate all opencode state to the scratch dir.
export HOME="$work/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"

# ---------------------------------------------------------------------------
# 1. Version (basic launch)
# ---------------------------------------------------------------------------
echo ">> [1/3] opencode --version"
ver="$("$OC" --version 2>&1)" || fail "opencode --version failed: $ver"
echo "   -> $ver"
printf '%s' "$ver" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' \
  || fail "--version did not print a version string"

# ---------------------------------------------------------------------------
# 2. Start the headless server (real runtime under load)
# ---------------------------------------------------------------------------
echo ">> [2/3] starting headless server"
log="$work/serve.log"
"$OC" serve --port 0 --hostname 127.0.0.1 --print-logs >"$log" 2>&1 &
spid=$!
trap 'kill "$spid" 2>/dev/null || true' EXIT INT TERM

url=""
i=0
while [ "$i" -lt 60 ]; do
  kill -0 "$spid" 2>/dev/null || { echo "--- serve.log ---"; cat "$log"; fail "server exited early"; }
  url="$(sed -nE 's|.*listening on (http://[^ ]+).*|\1|p' "$log" | head -n1)"
  [ -n "$url" ] && break
  i=$((i + 1))
  sleep 0.5
done
[ -n "$url" ] || { echo "--- serve.log ---"; cat "$log"; fail "server did not report a listen URL"; }
echo "   -> listening on $url"

# ---------------------------------------------------------------------------
# 3. Query the API (proves it does real work, not just prints)
# ---------------------------------------------------------------------------
echo ">> [3/3] querying the API"

cfg="$(curl -fsS --max-time 15 "$url/config")" || fail "GET /config failed"
printf '%s' "$cfg" | grep -q 'opencode' || fail "/config response looked wrong: $cfg"
echo "   -> GET /config OK"

doc="$(curl -fsS --max-time 15 "$url/doc")" || fail "GET /doc failed"
printf '%s' "$doc" | grep -q '"openapi"' || fail "/doc did not return an OpenAPI document"
echo "   -> GET /doc OK (OpenAPI)"

# Clean shutdown check.
kill "$spid" 2>/dev/null || true
wait "$spid" 2>/dev/null || true
trap - EXIT INT TERM

echo ">> OK: opencode runs and serves its API on CentOS 7"
