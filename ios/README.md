# Slime OS for iOS (early)

SwiftUI app + a WireGuard packet tunnel extension + FreeRDP 3, the iOS
counterpart of `android/`. Today it has a test screen: pair with a hub
pairing code, turn the tunnel on, connect to a Brain by address.

## Build

Needs Xcode 26+, Homebrew `cmake`, `xcodegen` and `go`, and an Apple
developer account signed in to Xcode. A real device is required for the
tunnel (Network Extensions don't run in the simulator).

1. FreeRDP for iOS, with FreeRDP's own super-build (from a checkout of the
   same FreeRDP version as `android/third_party/FreeRDP`):

       cmake -S client/iOS -B <build> -DCMAKE_TOOLCHAIN_FILE="$PWD/cmake/ios.toolchain.cmake" \
         -DPLATFORM=OS64 -DDEPLOYMENT_TARGET=15.0 -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=<team> \
         -DWITH_FFMPEG=OFF -DWITH_OPUS=OFF -DWITH_PNG=OFF -DWITH_WEBP=OFF -DWITH_JPEG=OFF -G Xcode
       cmake --build <build>

2. `scripts/stage-freerdp.sh <build>/deps` copies the libraries into
   `Vendor/FreeRDP` (gitignored) and makes them load from the app.
3. `scripts/fetch-wireguard.sh` checks out WireGuardKit into
   `Vendor/wireguard-apple` (gitignored), with two small fixes for current
   Xcode.
4. `Config/Local.xcconfig` (gitignored): `DEVELOPMENT_TEAM = <your team id>`.
5. `xcodegen`, then open `SlimeOS.xcodeproj`, or build with `xcodebuild
   -scheme SlimeOS -allowProvisioningUpdates`.

## Not yet

Sound (FreeRDP needs `WITH_IOSAUDIO`), a drawn mouse pointer, certificate
pinning (the test build accepts any certificate), Slime ID and the Brain
list, our FreeRDP patches (UDP transport, keep-last-picture), and packaging
the libraries as frameworks for the App Store.
