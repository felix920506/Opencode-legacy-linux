#!/bin/sh
# Smoke-test a built bundle. Meant to run inside a legacy glibc Linux container
# (CentOS 6/7, Amazon Linux 2, Ubuntu 18.04, Debian 10, ...) to prove the
# bundle is self-contained and independent of the host libc.
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

# Some minimal base images (notably Amazon Linux 2) ship without tar and/or
# gzip, which are needed to unpack the bundle. Install any that are missing,
# best-effort, with whatever package manager is present.
ensure_archive_tools() {
  command -v tar >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1 && return 0
  echo ">> tar/gzip not found; installing via the distro package manager"
  pkgs="tar gzip"
  if command -v microdnf >/dev/null 2>&1; then microdnf install -y $pkgs >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then dnf install -y $pkgs >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then yum install -y $pkgs >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then apt-get update >/dev/null 2>&1 && apt-get install -y $pkgs >/dev/null 2>&1 || true
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache $pkgs >/dev/null 2>&1 || true
  fi
  command -v tar >/dev/null 2>&1 || fail "tar is required but is not available"
  command -v gzip >/dev/null 2>&1 || fail "gzip is required but is not available"
}

# Bound a command's runtime if `timeout` is available; otherwise run as-is.
# The bash /dev/tcp reader below can block if the server keeps the socket open,
# so this is what guarantees the test never hangs.
run_bounded() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 15 "$@"
  else
    "$@"
  fi
}

# Portable HTTP GET, printed to stdout. Base images vary wildly in what they
# ship (RPM distros have curl; Ubuntu/Debian have neither curl nor wget), so
# fall back through curl -> wget -> a bash /dev/tcp request. The bash reader
# streams the full response (headers + body) before the socket may go idle, so
# callers get the body even if the connection is then killed by the timeout;
# they only look for a token, so the extra headers are harmless.
http_get() {
  _url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 15 "$_url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=15 "$_url"
  elif command -v bash >/dev/null 2>&1; then
    run_bounded bash -c '
      u="$1"; rest="${u#http://}"; hostport="${rest%%/*}"
      case "$rest" in */*) path="/${rest#*/}" ;; *) path="/" ;; esac
      host="${hostport%%:*}"; port="${hostport#*:}"
      [ "$port" = "$hostport" ] && port=80
      exec 3<>"/dev/tcp/$host/$port" || exit 1
      printf "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n" "$path" "$host" >&3
      cat <&3
    ' _ "$_url"
  else
    fail "no HTTP client available (curl, wget, or bash)"
  fi
}

tarball="$(ls "$OUT_DIR"/opencode-*-centos7-bundle.tar.gz 2>/dev/null | head -n1 || true)"
[ -n "$tarball" ] || fail "No bundle tarball found in $OUT_DIR"

echo ">> Host libc (should be glibc, no musl):"
ldd --version 2>&1 | head -n1 || true

ensure_archive_tools

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

# Tolerate a nonzero exit (e.g. the bash fallback being killed after streaming
# the response); correctness is judged by the body content, not the exit code.
cfg="$(http_get "$url/config" || true)"
printf '%s' "$cfg" | grep -q 'opencode' || fail "/config response looked wrong: $cfg"
echo "   -> GET /config OK"

doc="$(http_get "$url/doc" || true)"
printf '%s' "$doc" | grep -q '"openapi"' || fail "/doc did not return an OpenAPI document"
echo "   -> GET /doc OK (OpenAPI)"

# Clean shutdown check.
kill "$spid" 2>/dev/null || true
wait "$spid" 2>/dev/null || true
trap - EXIT INT TERM

echo ">> OK: opencode runs and serves its API"
