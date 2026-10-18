#!/usr/bin/env bash
# Copies FreeRDP and its dependencies from the FreeRDP iOS super-build into
# ios/Vendor/FreeRDP (gitignored), ready for Xcode to link and embed.
#
# The super-build (FreeRDP's client/iOS project, see ios/README.md) leaves
# OpenSSL with absolute install names and FreeRDP pointing at
# /usr/local/lib/libopenh264, so every library is rewritten to load from
# @rpath (the app's Frameworks folder).
#
# Usage: ios/scripts/stage-freerdp.sh [path to the super-build's deps folder]
set -euo pipefail

DEPS="${1:-$HOME/Developer/slimeos-ios/build-ios-device/deps}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Vendor/FreeRDP"
LIBS=(libfreerdp3.3 libfreerdp-client3.3 libwinpr3.3 libcjson.1 liburiparser.1 libssl.4 libcrypto.4 libopenh264.8)

[[ -d "$DEPS/Frameworks" && -d "$DEPS/include" ]] || { echo "no super-build at $DEPS" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
cp -R "$DEPS/include/freerdp3" "$DEPS/include/winpr3" "$OUT/include/"

for n in "${LIBS[@]}"; do
    f="$OUT/lib/$n.dylib"
    cp -L "$DEPS/Frameworks/$n.dylib" "$f"
    chmod u+w "$f"
    install_name_tool -id "@rpath/$n.dylib" "$f" 2>/dev/null
    otool -L "$f" | tail -n +2 | awk '{print $1}' \
        | { grep -v -E '^(/System/|/usr/lib/|@rpath/)' || true; } \
        | while read -r dep; do
            install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null
        done
done

echo "Staged ${#LIBS[@]} libraries in $OUT"
