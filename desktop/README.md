# Slime OS desktop app

Windows and macOS first, then Linux (#18): sign in with Slime ID, pick a
Brain, and its desktop opens in a window, without replacing the PC's OS.

- `core/` (Go): pairing, the userspace tunnel, Slime ID, wake, and a
  loopback forward the PC's remote-desktop client connects to. mstsc on
  Windows; FreeRDP's SDL client on macOS (bundled) and Linux (the system's).
- `app/` (Tauri 2): one window showing `app/ui/` (plain HTML/JS in the
  Membrane kiosk's look), which runs the core as a sidecar and talks to it
  over stdin/stdout (`core/serve.go` has the protocol).

## Tunnel

Userspace WireGuard (wireguard-go on gVisor's netstack): no driver, no admin
rights, no VPN adapter, nothing else on the PC routed. The tunnel config,
Slime ID session and `desktop.log` live in the user's config folder under
`SlimeOS/` (`%APPDATA%` on Windows, `~/Library/Application Support` on macOS).

A paid Brain's Windows sign-in comes from Slime ID before every connect and
is never stored: on Windows it sits in Credential Manager (`TERMSRV/…`) only
while mstsc runs; FreeRDP gets it over stdin.

## Building

Needs Go and Rust (`rustup`), plus the Tauri CLI (`cargo install tauri-cli --version "^2"`).

```sh
cd desktop/app
./build-core.sh                                  # core sidecar for this machine
(cd src-tauri && cargo tauri build --debug --bundles app)
```

- Windows installer: `.github/workflows/desktop.yml` (artifact `windows-installer`).
- macOS: the same workflow builds FreeRDP (artifact `freerdp-macos`); then on
  the Mac with the Developer ID certificate, `./package-macos.sh freerdp-macos.tar.gz`
  makes a signed, notarized `dist/Slime-OS.dmg`.
- Release: push a tag `desktop-v<version>` (after bumping `version` in
  `app/src-tauri/tauri.conf.json` and `Cargo.toml`); the workflow publishes
  the installer, `package-macos.sh … desktop-v<version>` adds the .dmg.

## Command line (testing)

```sh
cd desktop/core && go build -o slimeos-desktop-core .
./slimeos-desktop-core pair <code>                 # code from the dashboard's "Pair a device"
./slimeos-desktop-core connect <brain tunnel IP>   # wakes the Brain, then forwards
```

`connect` listens on `127.0.0.2:33890` (`127.0.0.1:33890` on macOS). On
Windows: `mstsc /v:127.0.0.2:33890`.

Not yet: RDP over UDP through the tunnel (TCP only), auto-update, signed
Windows installer (SmartScreen warns), Linux packages.
