# Slime OS — Android Launcher (Phase 2)

Target device: **Huawei Mate 30 Pro** (Android 10, EMUI 10)  
Broader target: Any Android 8.0+ device.

## Approach

A custom **launcher APK** that replaces the Android home screen. No bootloader unlock required — runs over stock AOSP / EMUI as a default launcher, keeping all native hardware drivers intact (camera, cellular, GPS, sensors).

## What it will do

1. Replace the home screen with the Slime OS mobile shell UI.
2. Establish a WireGuard tunnel to the Brain.
3. Launch an RDP/WebRTC client in kiosk mode.
4. Show the Slime OS lock screen, clock, and app grid as a native Android UI.

## Architecture

```
Android Home Screen (Launcher Activity)
  └── Slime OS Shell UI (Jetpack Compose)
        ├── WireGuard tunnel (via wireguard-android library)
        └── RDP Client (FreeRDP Android / bVNC)
              └── Cloud VM session
```

## Stack

- Language: **Kotlin**
- UI: **Jetpack Compose**
- VPN: [wireguard-android](https://github.com/WireGuard/wireguard-android)
- RDP: FreeRDP Android bindings (or bVNC as fallback)
- Distribution: Play Store + APK Gallery (Huawei AppGallery)

## Status

🔄 Phase 2 — starts after the Membrane (desktop) reaches v0.1 stable.

Developer accounts ready:
- Google Play Store
- Apple App Store  
- Huawei AppGallery

## M1 spike (in progress, separate from Phase 2 above)

`android/app` is a different, lighter product than the Phase 2 launcher above: a normal
foreground app (issue #18) — pairing code -> WireGuard tunnel -> RDP session — with no
home-screen takeover, no device wipe. Android/tablet first, closer to Chrome Remote
Desktop than to a device replacement. See `.claude/plans/fizzy-wobbling-cosmos.md` and
`.claude/FUTURE_SESSION_NOTES.md` for current status.

FreeRDP is vendored as a git submodule at `android/third_party/FreeRDP` (pinned to
release `3.31.1`); `android/app` depends on its `freeRDPCore` module directly rather than
embedding a copy of FreeRDP's source in this repo.
