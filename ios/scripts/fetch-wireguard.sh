#!/usr/bin/env bash
# Checks out WireGuardKit (wireguard-apple) at a pinned revision into
# ios/Vendor/wireguard-apple (gitignored), used as a local Swift package.
#
# Its Package.swift declares swift-tools-version 5.3 but uses .macOS(.v12) /
# .iOS(.v15), which need 5.5; current SwiftPM refuses that, so the
# tools-version line is raised to 5.5. WireGuardKitC.h uses u_int32_t and
# friends without <sys/types.h>, which current SDKs' modules reject. The Go
# bridge's Makefile has no GOOS for the simulator, so it would build a macOS
# library there; the simulator is iOS too (cgo's flags make it a simulator one).
set -euo pipefail

REV=2fec12a6e1f6e3460b6ee483aa00ad29cddadab1 # tag 1.0.16-27
DIR="$(cd "$(dirname "$0")/.." && pwd)/Vendor/wireguard-apple"

if [[ ! -d "$DIR/.git" ]]; then
    git clone -q https://git.zx2c4.com/wireguard-apple "$DIR"
fi
git -C "$DIR" fetch -q origin
git -C "$DIR" checkout -q --force "$REV"
sed -i '' 's|^// swift-tools-version:5.3|// swift-tools-version:5.5|' "$DIR/Package.swift"
H="$DIR/Sources/WireGuardKitC/WireGuardKitC.h"
grep -q '^#include <sys/types.h>' "$H" || sed -i '' 's|^#include "key.h"|#include <sys/types.h>\n#include "key.h"|' "$H"
M="$DIR/Sources/WireGuardKitGo/Makefile"
grep -q '^GOOS_iphonesimulator' "$M" || sed -i '' 's|^GOOS_iphoneos := ios$|GOOS_iphoneos := ios\nGOOS_iphonesimulator := ios|' "$M"
head -1 "$DIR/Package.swift"
echo "WireGuardKit at $REV in $DIR"
