#!/usr/bin/env bash
# Builds FreeRDP and its dependencies for iOS (Release) with FreeRDP's own
# super-build (client/iOS), for the device or the simulator. Then
# stage-freerdp.sh packages both into Vendor/FreeRDP.
#
# Usage: ios/scripts/build-freerdp.sh device|simulator [work dir]
#
# The work dir (default ~/Developer/slimeos-ios) holds:
#   FreeRDP/  a checkout of the same FreeRDP version as
#             android/third_party/FreeRDP, with ios/freerdp-patches applied
#   .team     the Apple developer team id
# and gets build-ios-device/ or build-ios-simulator/.
#
# The simulator build has no OpenH264 (its makefile can't target the arm64
# simulator): the simulator is for layout and the Demo Brain, not sessions.
set -euo pipefail

KIND="${1:-}"
WORK="${2:-$HOME/Developer/slimeos-ios}"
SRC="$WORK/FreeRDP"

case "$KIND" in
    device)    PLATFORM=OS64;           H264=ON ;;
    simulator) PLATFORM=SIMULATORARM64; H264=OFF ;;
    *) echo "usage: $0 device|simulator [work dir]" >&2; exit 1 ;;
esac
BUILD="$WORK/build-ios-$KIND"

[[ -d "$SRC/client/iOS" ]] || { echo "no FreeRDP checkout at $SRC" >&2; exit 1; }
[[ -s "$WORK/.team" ]] || { echo "put the team id in $WORK/.team" >&2; exit 1; }

cmake -S "$SRC/client/iOS" -B "$BUILD" -G Xcode \
    -DCMAKE_TOOLCHAIN_FILE="$SRC/cmake/ios.toolchain.cmake" \
    -DPLATFORM="$PLATFORM" -DDEPLOYMENT_TARGET=15.0 \
    -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM="$(cat "$WORK/.team")" \
    -DWITH_FFMPEG=OFF -DWITH_OPUS=OFF -DWITH_PNG=OFF -DWITH_WEBP=OFF -DWITH_JPEG=OFF \
    -DWITH_OPENH264="$H264"
cmake --build "$BUILD" --config Release --target freerdp

# The super-build doesn't pass these on to FreeRDP itself: sound through
# iOS's audio API, and no debug-only assert logging.
cmake -DWITH_IOSAUDIO=ON -DWITH_VERBOSE_WINPR_ASSERT=OFF "$BUILD/freerdp-prefix/src/freerdp-build"
cmake --build "$BUILD" --config Release --target freerdp

echo "Built FreeRDP for the $KIND in $BUILD/deps"
