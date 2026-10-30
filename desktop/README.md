# Slime OS desktop app

Windows first, then Linux and macOS (#18): sign in with Slime ID, pick a
Brain, and its desktop opens in a window, without replacing the PC's OS.

Plan: a Tauri shell showing the Membrane kiosk UI, with `core/` as its
sidecar. The PC's own remote-desktop client (mstsc on Windows, FreeRDP
elsewhere) connects to a loopback port that `core/` forwards to the Brain.

## core/ (spike)

Userspace WireGuard (wireguard-go on gVisor's netstack): no driver, no admin
rights, no VPN adapter, nothing else on the PC routed.

```sh
cd desktop/core
go build -o slimeos-desktop-core .                 # GOOS=windows for the .exe
./slimeos-desktop-core pair <code>                 # code from the dashboard's "Pair a device"
./slimeos-desktop-core connect <brain tunnel IP>   # wakes the Brain, then forwards
```

`connect` listens on `127.0.0.2:33890` (`127.0.0.1:33890` on macOS). On
Windows: `mstsc /v:127.0.0.2:33890`. The tunnel config is saved under the
user's config folder as `SlimeOS/tunnel.conf`.

Not yet: RDP over UDP (TCP only), the coordinator protocol, the Tauri shell.
