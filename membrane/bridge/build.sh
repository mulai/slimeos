#!/usr/bin/env bash
# Slime OS — build slimeos-bridge static binaries
# Run by hand on the dev machine before committing; the Membrane device
# never runs a Go toolchain, it only downloads the binaries in bin/.
set -euo pipefail
cd "$(dirname "$0")"

TARGETS=(
    "linux amd64"
    "linux arm64"
)

for t in "${TARGETS[@]}"; do
    read -r os arch <<<"$t"
    out="bin/slimeos-bridge-${os}-${arch}"
    echo "Building ${out}..."
    CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" go build -trimpath -ldflags="-s -w" -o "$out" .
done

echo "Done. Binaries are static (CGO_ENABLED=0) — no glibc-version dependency on the target."
