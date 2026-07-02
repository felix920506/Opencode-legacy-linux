#!/bin/sh
# Smoke-test a built bundle. Meant to run inside a CentOS 7 container (glibc,
# no musl) to prove the bundle is self-contained. Extracts the tarball and runs
# opencode through the bundled musl loader.
#
# Environment variables:
#   OUT_DIR  directory containing the built tarball (default: dist)
set -eu

OUT_DIR="${OUT_DIR:-dist}"

tarball="$(ls "$OUT_DIR"/opencode-*-centos7-bundle.tar.gz 2>/dev/null | head -n1 || true)"
if [ -z "$tarball" ]; then
  echo "!! No bundle tarball found in $OUT_DIR" >&2
  exit 1
fi

echo ">> Host libc (should be glibc, no musl):"
ldd --version 2>&1 | head -n1 || true

echo ">> Extracting $tarball"
work="$(mktemp -d)"
tar -xzf "$tarball" -C "$work"

echo ">> Running opencode --version through the bundled loader"
out="$("$work/opencode-bundle/opencode.sh" --version 2>&1)"
status=$?
echo "$out"

if [ $status -ne 0 ]; then
  echo "!! opencode exited with status $status" >&2
  exit 1
fi

# The baseline binary should print a version like "1.17.11". Guard against an
# empty/garbage result even when the exit code is 0.
if ! printf '%s' "$out" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+'; then
  echo "!! Output did not contain a version string" >&2
  exit 1
fi

echo ">> OK: opencode runs on CentOS 7"
