# opencode CentOS 7 bundle

Repackages the [opencode](https://github.com/sst/opencode) CLI so it runs on
old Linux distributions such as **CentOS 7**.

## The problem

opencode's Linux "baseline" build (`opencode-linux-x64-baseline-musl.tar.gz`)
is linked against **musl libc**. CentOS 7 ships glibc 2.17 and has no musl, so
the binary won't start there.

## The approach

Assemble a self-contained bundle that carries its own runtime and launches the
binary through the bundled musl loader, so it depends on nothing from the host:

```
opencode-bundle/
  opencode            # the musl baseline binary
  opencode.sh         # launcher (invokes the bundled loader)
  lib/
    ld-musl-x86_64.so.1
    libc.musl-x86_64.so.1 -> ld-musl-x86_64.so.1
    libstdc++.so.6 -> libstdc++.so.6.0.32
    libstdc++.so.6.0.32
    libgcc_s.so.1
```

The launcher runs the binary through the bundled loader with an explicit
library path:

```sh
exec "$DIR/lib/ld-musl-x86_64.so.1" --library-path "$DIR/lib" "$DIR/opencode" "$@"
```

The musl loader and the C++ runtime are taken straight from Alpine (`apk`),
which is where they come from natively.

## Usage

On the target machine:

```sh
tar -xzf opencode-v1.17.11-centos7-bundle.tar.gz
./opencode-bundle/opencode.sh --version
```

## Building

### CI (GitHub Actions)

`.github/workflows/build-bundle.yml` builds the bundle in an Alpine container,
tests it across a matrix of legacy distros, and (on `v*` tag pushes) attaches
the tarball to a GitHub Release. Run it manually from the Actions tab
(**workflow_dispatch**) with an `opencode_version` input, on pushes to `master`,
or by pushing a `v*` tag.

The bundle ships its own musl runtime, so it must run regardless of the host
libc. The test matrix covers a wide glibc range on legacy distros people
realistically still log into and use interactively (old enterprise
workstations, build servers, jump hosts, aging dev boxes):

| Distro | glibc |
|--------|-------|
| CentOS 6 | 2.12 |
| CentOS 7 | 2.17 |
| Ubuntu 16.04 | 2.23 |
| Ubuntu 18.04 | 2.27 |
| Debian 10 (buster) | 2.28 |

### Locally

Requires Docker or Podman:

```sh
# build the bundle (writes dist/opencode-<version>-centos7-bundle.tar.gz)
docker run --rm -e OPENCODE_VERSION=v1.17.11 -e OUT_DIR=/work/dist \
  -v "$PWD:/work" -w /work alpine:3.19 sh /work/scripts/build-bundle.sh

# verify it runs on CentOS 7
docker run --rm -e OUT_DIR=/work/dist \
  -v "$PWD:/work" -w /work centos:7 sh /work/scripts/test-bundle.sh
```

## Layout

| Path | Purpose |
|------|---------|
| `scripts/build-bundle.sh` | Downloads opencode, gathers musl + libstdc++ + libgcc, assembles and tars the bundle. |
| `scripts/test-bundle.sh`  | End-to-end test: checks `--version`, then starts the headless server and queries its `/config` and `/doc` (OpenAPI) endpoints to prove the runtime genuinely works. |
| `.github/workflows/build-bundle.yml` | CI: build → test → release. |
