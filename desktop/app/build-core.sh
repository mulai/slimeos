#!/usr/bin/env bash
# Builds the Go core (../core) as the Tauri sidecar, named the way Tauri's
# externalBin wants it: src-tauri/binaries/slimeos-desktop-core-<target triple>.
#
#   ./build-core.sh                      this machine's triple
#   ./build-core.sh x86_64-pc-windows-msvc
#   ./build-core.sh universal-apple-darwin   (arm64 + x86_64, for a universal .app)
#
# VERSION (env) is stamped into the core; defaults to tauri.conf.json's version.
set -euo pipefail
cd "$(dirname "$0")"
triple="${1:-$(rustc -vV | sed -n 's/^host: //p')}"
version="${VERSION:-$(sed -n 's/^  "version": "\(.*\)",$/\1/p' src-tauri/tauri.conf.json)}"
out="$PWD/src-tauri/binaries"
mkdir -p "$out"

build() { # goos goarch file
    (cd ../core && CGO_ENABLED=0 GOOS="$1" GOARCH="$2" go build -trimpath \
        -ldflags "-s -w -X main.version=$version" -o "$3" .)
}

case "$triple" in
    universal-apple-darwin)
        build darwin arm64 "$out/core-arm64"
        build darwin amd64 "$out/core-amd64"
        lipo -create -output "$out/slimeos-desktop-core-$triple" "$out/core-arm64" "$out/core-amd64"
        rm "$out/core-arm64" "$out/core-amd64"
        ;;
    aarch64-apple-darwin)      build darwin arm64 "$out/slimeos-desktop-core-$triple" ;;
    x86_64-apple-darwin)       build darwin amd64 "$out/slimeos-desktop-core-$triple" ;;
    x86_64-pc-windows-msvc)    build windows amd64 "$out/slimeos-desktop-core-$triple.exe" ;;
    aarch64-pc-windows-msvc)   build windows arm64 "$out/slimeos-desktop-core-$triple.exe" ;;
    x86_64-unknown-linux-gnu)  build linux amd64 "$out/slimeos-desktop-core-$triple" ;;
    *) echo "unknown target $triple" >&2; exit 1 ;;
esac
echo "built core $version for $triple"
