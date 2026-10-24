# Slime OS for iOS

SwiftUI app + a WireGuard packet tunnel extension + FreeRDP 3, the iOS
counterpart of `android/`, for iPhone and iPad: app PIN, Slime ID, the Brain
list, pairing, waking a Brain, sessions with sound, and the Demo Brain.

## Build

Needs Xcode 26+, Homebrew `cmake`, `xcodegen` and `go`, and an Apple
developer account signed in to Xcode. A real device is required for the
tunnel (Network Extensions don't run in the simulator).

1. FreeRDP for iOS (Release), with FreeRDP's own super-build: a checkout of
   the same FreeRDP version as `android/third_party/FreeRDP` in
   `~/Developer/slimeos-ios/FreeRDP`, with
   `git apply <repo>/ios/freerdp-patches/*.patch` first, and the team id in
   `~/Developer/slimeos-ios/.team`. Then, about 15 minutes each:

       scripts/build-freerdp.sh device
       scripts/build-freerdp.sh simulator

   The simulator build has no OpenH264; the simulator is for layout and the
   Demo Brain (no tunnel there).

2. `scripts/stage-freerdp.sh` packages both into `Vendor/FreeRDP`
   (gitignored): one `.xcframework` per library (the App Store refuses loose
   dylibs) and the headers.
3. `scripts/fetch-wireguard.sh` checks out WireGuardKit into
   `Vendor/wireguard-apple` (gitignored), with two small fixes for current
   Xcode.
4. `Config/Local.xcconfig` (gitignored): `DEVELOPMENT_TEAM = <your team id>`.
5. `xcodegen`, then open `SlimeOS.xcodeproj`, or build with `xcodebuild
   -scheme SlimeOS -allowProvisioningUpdates`.

## Not yet

Our other FreeRDP patches (UDP transport, keep-last-picture), camera and
microphone, feedback and crash reports.
