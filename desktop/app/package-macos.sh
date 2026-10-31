#!/usr/bin/env bash
# The macOS app: universal build, FreeRDP inside, signed, notarized, as a .dmg.
#
#   ./package-macos.sh <freerdp-macos.tar.gz> [desktop-v<version>]
#
# The tarball is the freerdp-macos artifact of .github/workflows/desktop.yml.
# With a tag, the .dmg is also added to that GitHub release. NOTARIZE=0 stops
# after signing the app (a local test build: no .dmg, no Apple round trip).
#
# Needs, on the Mac that builds it: the Developer ID Application certificate
# in the keychain, and notarytool credentials stored once as a profile:
#   xcrun notarytool store-credentials slimeos-notary --apple-id <id> --team-id <team>
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"
tarball="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
tag="${2:-}"
identity="${IDENTITY:-Developer ID Application: Mulai Pte. Ltd.}"
profile="${NOTARY_PROFILE:-slimeos-notary}"
entitlements="$PWD/src-tauri/Entitlements.plist"

rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
./build-core.sh universal-apple-darwin
(cd src-tauri && cargo tauri build --target universal-apple-darwin --bundles app)
app="$PWD/src-tauri/target/universal-apple-darwin/release/bundle/macos/Slime OS.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"

# FreeRDP as a nested helper app: its binaries find their libraries at
# @loader_path/../Frameworks, and a process started from a bundle's
# Contents/MacOS takes that bundle's name and icon.
helper="$app/Contents/Helpers/FreeRDP.app"
rm -rf "$app/Contents/Helpers"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar xzf "$tarball" -C "$work"
cp -R "$work/Contents/Frameworks" "$helper/Contents/"
# Only the client: no server, proxy or OpenSSL engines.
rm -rf "$helper/Contents/Frameworks/"{freerdp3,engines-3} \
    "$helper/Contents/Frameworks/"libfreerdp-server* "$helper/Contents/Frameworks/"libwinpr-tools*
client="$work/Contents/MacOS/sdl-freerdp"
[[ -f "$client" ]] || client="$(ls "$work"/Contents/MacOS/sdl*-freerdp* | head -1)"
cp "$client" "$helper/Contents/MacOS/sdl-freerdp"
cp "$app/Contents/Resources/icon.icns" "$helper/Contents/Resources/"
cat > "$helper/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.slimeos.desktop.session</string>
	<key>CFBundleName</key><string>Slime OS Session</string>
	<key>CFBundleExecutable</key><string>sdl-freerdp</string>
	<key>CFBundleIconFile</key><string>icon.icns</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$version</string>
	<key>CFBundleVersion</key><string>$version</string>
	<key>LSMinimumSystemVersion</key><string>12.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Slime OS passes your microphone to your Brain.</string>
	<key>NSCameraUsageDescription</key><string>Slime OS passes your camera to your Brain.</string>
</dict>
</plist>
PLIST

# Inside out: libraries, the helper, the core, then the app.
# IDENTITY=- signs ad hoc: enough to run on this Mac, with NOTARIZE=0. No
# hardened runtime then: its library validation wants one Team ID throughout.
opts=(--timestamp --options runtime)
[[ "$identity" == - ]] && opts=(--timestamp=none)
sign() { codesign --force "${opts[@]}" --sign "$identity" "$@"; }
find "$helper/Contents/Frameworks" -type f \( -name '*.dylib' -o -perm -u+x \) -print0 | while IFS= read -r -d '' f; do sign "$f"; done
sign --entitlements "$entitlements" "$helper"
sign "$app/Contents/MacOS/slimeos-desktop-core"
sign --entitlements "$entitlements" "$app"
codesign --verify --deep --strict "$app"
if [[ "${NOTARIZE:-1}" == 0 ]]; then
    echo "signed $app ($version), not notarized"
    exit 0
fi

mkdir -p dist
dmg="$PWD/dist/Slime-OS.dmg"
stage="$work/dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Slime OS" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
sign "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
echo "built $dmg ($version)"

if [[ -n "$tag" ]]; then
    gh release upload "$tag" "$dmg" --clobber
fi
