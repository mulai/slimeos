#!/usr/bin/env bash
# Packages FreeRDP and its dependencies, as built by build-freerdp.sh for the
# device and the simulator, into ios/Vendor/FreeRDP (gitignored): one
# .xcframework per library, plus the headers.
#
# Frameworks, not bare dylibs: the App Store rejects loose .dylib files in an
# iOS app. Each library becomes <name>.framework/<name>, loading itself and
# its dependencies from @rpath (the super-build leaves OpenSSL with absolute
# install names and FreeRDP pointing at /usr/local/lib/libopenh264). OpenSSL
# gets its own privacy manifest (Apple lists it as a commonly used SDK).
#
# The simulator build has no OpenH264, so its openh264 slice is an empty
# stub: nothing there links to it, it only satisfies the xcframework.
#
# Each xcframework is signed (we are the SDK's provider): the App Store
# refuses a commonly used SDK such as OpenSSL without a signature (ITMS-91065).
# The identity is the keychain's Apple Distribution certificate, or
# SIGN_IDENTITY.
#
# Usage: ios/scripts/stage-freerdp.sh [work dir, default ~/Developer/slimeos-ios]
set -euo pipefail

WORK="${1:-$HOME/Developer/slimeos-ios}"
IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$IOS_DIR/Vendor/FreeRDP"
MIN_OS=15.0

# dylib name -> framework name
LIBS=(libfreerdp3.3:freerdp3 libfreerdp-client3.3:freerdp-client3 libwinpr3.3:winpr3
      libcjson.1:cjson liburiparser.1:uriparser libssl.4:ssl libcrypto.4:crypto libopenh264.8:openh264)

fw_for() {   # basename of a dylib (any version suffix) -> framework name, or empty
    local base="${1##*/}" pair
    for pair in "${LIBS[@]}"; do
        [[ "${base%%.*}" == "${pair%%.*}" ]] && { echo "${pair#*:}"; return; }
    done
    return 0
}

write_plist() {   # framework dir, name, platform
    cat > "$1/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$2</string>
	<key>CFBundleIdentifier</key><string>com.slimeos.app.lib.${2//[^A-Za-z0-9]/-}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$2</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$3</string></array>
	<key>MinimumOSVersion</key><string>$MIN_OS</string>
</dict>
</plist>
EOF
}

write_openssl_privacy() {   # framework dir
    cat > "$1/PrivacyInfo.xcprivacy" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key><false/>
	<key>NSPrivacyTrackingDomains</key><array/>
	<key>NSPrivacyCollectedDataTypes</key><array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
			<key>NSPrivacyAccessedAPITypeReasons</key><array><string>C617.1</string></array>
		</dict>
	</array>
</dict>
</plist>
EOF
}

make_slice() {   # kind (device|simulator), out dir
    local kind="$1" dir="$2" deps="$WORK/build-ios-$1/deps" platform pair lib fw bin dep depfw
    [[ "$kind" == device ]] && platform=iPhoneOS || platform=iPhoneSimulator
    [[ -d "$deps/Frameworks" ]] || { echo "no $kind build at $deps (run build-freerdp.sh $kind)" >&2; exit 1; }
    for pair in "${LIBS[@]}"; do
        lib="${pair%%:*}" fw="${pair#*:}"
        mkdir -p "$dir/$fw.framework"
        bin="$dir/$fw.framework/$fw"
        if [[ -e "$deps/Frameworks/$lib.dylib" ]]; then
            cp -L "$deps/Frameworks/$lib.dylib" "$bin"
        elif [[ "$fw" == openh264 && "$kind" == simulator ]]; then
            echo 'void slimeos_openh264_stub(void) {}' \
                | xcrun --sdk iphonesimulator clang -x c - -dynamiclib -target "arm64-apple-ios$MIN_OS-simulator" \
                    -install_name "@rpath/$fw.framework/$fw" -o "$bin"
        else
            echo "missing $deps/Frameworks/$lib.dylib" >&2; exit 1
        fi
        chmod u+w "$bin"
        install_name_tool -id "@rpath/$fw.framework/$fw" "$bin" 2>/dev/null
        otool -L "$bin" | tail -n +2 | awk '{print $1}' | while read -r dep; do
            depfw="$(fw_for "$dep")"
            [[ -n "$depfw" && "$depfw" != "$fw" ]] || continue
            install_name_tool -change "$dep" "@rpath/$depfw.framework/$depfw" "$bin" 2>/dev/null
        done
        # Bitcode (OpenH264's makefile embeds it) is refused by the App Store.
        if otool -l "$bin" | grep -q __LLVM; then
            xcrun bitcode_strip -r "$bin" -o "$bin"
        fi
        write_plist "$dir/$fw.framework" "$fw" "$platform"
        if [[ "$fw" == ssl || "$fw" == crypto ]]; then
            write_openssl_privacy "$dir/$fw.framework"
        fi
    done
}

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Distribution/ {print $2; exit}')}"
[[ -n "$SIGN_IDENTITY" ]] || { echo "no Apple Distribution certificate in the keychain (or set SIGN_IDENTITY)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
make_slice device "$TMP/device"
make_slice simulator "$TMP/simulator"

rm -rf "$OUT"
mkdir -p "$OUT/include"
cp -R "$WORK/build-ios-device/deps/include/freerdp3" "$WORK/build-ios-device/deps/include/winpr3" "$OUT/include/"
for pair in "${LIBS[@]}"; do
    fw="${pair#*:}"
    xcodebuild -create-xcframework -framework "$TMP/device/$fw.framework" \
        -framework "$TMP/simulator/$fw.framework" -output "$OUT/$fw.xcframework" >/dev/null
    codesign --timestamp -s "$SIGN_IDENTITY" "$OUT/$fw.xcframework"
done

echo "Staged ${#LIBS[@]} frameworks in $OUT"
