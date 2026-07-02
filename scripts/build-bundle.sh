#!/bin/sh
# Build a self-contained "opencode for CentOS 7" bundle.
#
# opencode's Linux baseline build is linked against musl libc. Old distros such
# as CentOS 7 ship glibc and have no musl, so the binary cannot run directly.
# This script assembles a bundle that ships its own musl loader plus the C++
# runtime, and a launcher that invokes the binary through the bundled loader --
# making it independent of whatever libc the host provides.
#
# It is designed to run inside an Alpine container (musl is the native libc
# there, so the loader and libstdc++/libgcc come straight from apk), but works
# anywhere those libraries are present at the expected paths.
#
# Environment variables:
#   OPENCODE_VERSION  opencode release tag to package        (default: v1.17.11)
#   OUT_DIR           directory for the finished tarball      (default: dist)
set -eu

OPENCODE_VERSION="${OPENCODE_VERSION:-v1.17.11}"
OUT_DIR="${OUT_DIR:-dist}"
ASSET="opencode-linux-x64-baseline-musl.tar.gz"
BUNDLE_NAME="opencode-bundle"
BASE_URL="https://github.com/sst/opencode/releases/download"

echo ">> Installing build dependencies (curl, tar, musl, libstdc++, libgcc)"
apk add --no-cache curl tar musl libstdc++ libgcc >/dev/null

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo ">> Downloading opencode ${OPENCODE_VERSION} (${ASSET})"
curl -fL --retry 3 -o "$work/$ASSET" "${BASE_URL}/${OPENCODE_VERSION}/${ASSET}"

echo ">> Extracting release"
mkdir -p "$work/extract"
tar -xzf "$work/$ASSET" -C "$work/extract"

bundle="$work/$BUNDLE_NAME"
mkdir -p "$bundle/lib"

echo ">> Adding opencode binary"
cp "$work/extract/opencode" "$bundle/opencode"
chmod +x "$bundle/opencode"

echo ">> Adding musl loader"
cp -L /lib/ld-musl-x86_64.so.1 "$bundle/lib/ld-musl-x86_64.so.1"
ln -sf ld-musl-x86_64.so.1 "$bundle/lib/libc.musl-x86_64.so.1"

echo ">> Adding libstdc++ and libgcc"
stdcpp_real="$(readlink -f /usr/lib/libstdc++.so.6)"
cp "$stdcpp_real" "$bundle/lib/$(basename "$stdcpp_real")"
ln -sf "$(basename "$stdcpp_real")" "$bundle/lib/libstdc++.so.6"
cp -L /usr/lib/libgcc_s.so.1 "$bundle/lib/libgcc_s.so.1"

echo ">> Writing launcher"
cat > "$bundle/opencode.sh" <<'LAUNCHER'
#!/bin/sh
DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$DIR/lib/ld-musl-x86_64.so.1" --library-path "$DIR/lib" "$DIR/opencode" "$@"
LAUNCHER
chmod +x "$bundle/opencode.sh"

echo ">> Packaging"
mkdir -p "$OUT_DIR"
tarball="opencode-${OPENCODE_VERSION}-centos7-bundle.tar.gz"
tar -czf "$OUT_DIR/$tarball" -C "$work" "$BUNDLE_NAME"

echo ">> Done: $OUT_DIR/$tarball"
ls -la "$OUT_DIR/$tarball"
echo ">> Bundle contents:"
tar -tzf "$OUT_DIR/$tarball"
