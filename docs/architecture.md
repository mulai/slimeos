# Slime OS — System Architecture

## Overview

Slime OS is a two-component system:

```
┌─────────────────────────────────────────────────────────────┐
│                    THE MEMBRANE (Local)                      │
│  Debian minimal → cage (Wayland) → FreeRDP client → WireGuard│
│  RAM: ~512 MB    Disk: ~4 GB    CPU: any x86_64             │
└──────────────────────────┬──────────────────────────────────┘
                           │  WireGuard VPN tunnel
                           │  FreeRDP stream (TLS 1.2/1.3)
┌──────────────────────────▼──────────────────────────────────┐
│                      THE BRAIN (Cloud)                       │
│  Authelia MFA → xRDP/Windows VM  or  xRDP/Linux VM          │
│  Docker Compose    vCPU: 4–64    RAM: 8–128 GB (per profile) │
└─────────────────────────────────────────────────────────────┘
```

---

## The Membrane

### Boot sequence
1. GRUB boots Debian (read-only rootfs, OverlayFS).
2. `systemd` starts `slimeos-bridge.service` and `slimeos-session.service`
   (soft-ordered: cage waits on the bridge but starts regardless if it's
   slow, see below).
3. `cage` (Wayland compositor) starts in kiosk mode with `cog` — WPE
   WebKit's kiosk launcher — as its sole client, pointed at the local kiosk
   HTML bundle in `membrane/lockscreen/index.html`. Chosen over a Chromium
   kiosk for a much lower memory footprint and because it's purpose-built
   for exactly this embedded/wlroots-kiosk scenario.
4. That page opens a WebSocket to `slimeos-bridge` on `127.0.0.1:7770`,
   which is a thin relay (a small vendored static Go binary — see
   `membrane/bridge/`) to `coordinator.sh`, a persistent bash process that
   owns the actual **Connect screen** logic: adding/selecting/removing a
   saved Brain (`/etc/slimeos/brains.json`, add by IP or hostname) — the
   open source connect path, no Slime account required. Whatever the page
   shows, `coordinator.sh` drives via JSON lines
   (`SlimeUI.setState`/`setStatus`), which is what `brain-select.sh`'s
   whiptail menu loop used to do directly; the bridge only relays,
   `coordinator.sh` owns all state and behavior. Before showing the normal
   Connect screen, `coordinator.sh` checks for a working network and shows
   a Wi-Fi/Ethernet setup screen instead if none exists yet (see "Network
   setup" below) — also reachable later from a settings icon.
5. On selection, `coordinator.sh` calls `do_connect <brain-id>` (defined in
   `connect.sh`, now a sourced function library rather than a standalone
   script), which prompts for credentials on first use (saved per-Brain,
   encrypted) and launches FreeRDP.
6. FreeRDP opens a WireGuard-tunneled RDP session to the chosen Brain,
   displayed by cage exactly as before (xwayland is still installed for
   this). A clean logout returns `do_connect` to `coordinator.sh`, which
   shows the Connect screen again so the user can switch Brains.

### Peripheral redirection
`connect.sh`'s `xfreerdp3` invocation redirects three classes of local
hardware into the Brain session:
- **Speaker/mic** — `/sound:sys:alsa` + `/microphone:sys:alsa`. ALSA
  talks to the kernel driver directly; the Membrane has no PulseAudio/
  PipeWire daemon installed, and none is needed — `freerdp3-x11` already
  pulls in `libasound2`/`libpulse0` transitively. One consequence of
  having no sound server: nothing would ever unmute the kernel's
  default-muted mixer, so `slimeos-audio-init.service` (oneshot,
  first boot only) runs `alsactl init` + `store`; alsa-utils' stock
  `alsa-restore.service` maintains the state on every boot after.
  Playback and capture use ALSA's *default* device — a USB microphone
  (its own separate ALSA card) needs an `/etc/asound.conf` routing
  default capture to it by card name (see the repo's issue history for
  a working `type asym` example); making that automatic is an open item.
- **USB storage** — `/drive:usb,/media/<user>`, one dynamic network
  drive covering whatever `udiskie` (`slimeos-automount.service`) has
  auto-mounted under `/media/<user>` at the moment, including drives
  plugged in mid-session (refresh the Explorer window to see them).
  `ntfs-3g`/`exfatprogs` are installed so NTFS/exFAT external drives
  mount too, not just FAT32. Encrypted (LUKS) volumes aren't supported —
  there's no unlock-prompt UI on this kiosk.
- **Webcam** — `/dvc:rdpecam` (MS-RDPECAM), **on by default** when a
  `/dev/video*` device exists (opt out with `SLIMEOS_ENABLE_CAMERA=0`
  in `/etc/slimeos/config`). Debian's stock `freerdp3` ships without
  the camera channel compiled in (a packaging bug — the code builds but
  never lands in a binary package), and its source carries three camera
  bugs besides, so `install.sh` installs a checksum-pinned patched
  rebuild (`+slimeos5`): sample-response buffer growth, MJPG preferred
  over broken H264 passthrough (upstream #11198), and a fix for a
  first-frame libswscale deadlock introduced by the CVE-2026-24677
  backport that dropped every frame. Details in
  `membrane/freerdp/camera-patches/README.md`. Confirmed working
  end-to-end 2026-07-17 (Logitech C920 → Azure Windows Brain, live
  picture in the Camera app). Frames are MJPG-decoded and
  H264-re-encoded in software on the Membrane — expect CPU load and
  some lag on weak hardware while an app is actively capturing.
- **Other USB devices** (printers, generic HID/serial) — not
  yet wired up. FreeRDP's `urbdrc` channel (`/usb:id,dev:<vid>:<pid>`)
  supports this but needs per-device vendor/product IDs, unlike the
  automatic cases above; deferred until there's a concrete device to
  test against.

Both xrdp (Linux) and native Windows RDP Brains accept all three flags —
audio and drive redirection are RDP-standard channels, not xrdp-specific
extensions — but this hasn't yet been verified against a real xrdp Brain
end-to-end (xrdp's channel support has historically had more gaps than a
real Windows RDP host's).

If `slimeos-bridge` itself is ever down or restarting (independent
`Restart=always` lifecycle, deliberately not tied to cage/cog's own restart
cycle), the lock screen shows a plain "Reconnecting to Slime OS…"
placeholder and reconnects with backoff — a coordinator hiccup never
restarts the whole kiosk session.

> **Planned:** a "Sign in with Slime ID" entry point (already present as an
> inert "Coming soon" affordance in the kiosk HTML) for the managed-service
> path — one Slime ID authenticating against multiple Brains via a Slime
> account API (auth, brain listing, WireGuard peer auto-provisioning). Not
> yet built. The open source Connect (manual IP) path ships first.

### Kiosk UI ↔ backend bridge
The lock screen speaks a small JSON-Lines protocol over its WebSocket
connection — full schema documented in `membrane/lockscreen/index.html`'s
own header comment (browser → backend) and `membrane/session/coordinator.sh`'s
own header comment (both directions, plus the bridge-synthesized
`_clientConnected`/`_clientDisconnected` lifecycle events). `slimeos-bridge`
itself has no product logic — it's a dumb relay between one WebSocket
client and one persistent `coordinator.sh` subprocess, restarting the
latter on crash and resyncing whatever client is attached.

### Network setup (WiFi + Ethernet onboarding)
The whole Connect flow above assumes a working network already exists.
`coordinator.sh` checks that assumption once per process, on the first
`_clientConnected` event: if `ip route show default` comes up empty after a
short retry window (`have_default_route()`), it calls `do_network_setup
boot` — defined in `membrane/session/network-setup.sh`, `source`d the same
way `connect.sh` is — *before* showing the normal picker. That function
takes over the event loop exactly like `do_connect()` does, driving three
new lock-screen states (`wifiList` → `wifiPassword` for secured networks →
`wifiConnecting`) via `nmcli`, with a `wifiError` recovery screen that
reuses the existing `slime:retry`/`slime:reenter-password`/`slime:back`
events (same semantics as the Brain-connect error screen, no new events
needed there). A gear icon in the status strip (`slime:network-settings`)
reaches the same function in `settings` mode — non-blocking, reachable any
time a network already works, for switching WiFi networks — the only
difference from `boot` mode is a Back button instead of a Skip button.

`nmcli` needs `wpasupplicant` (its actual WiFi backend) and NetworkManager
itself enabled unconditionally in `install.sh` (previously only the
generic fallback hardware profile enabled it — a latent gap that meant any
machine matching a *named* profile never got it enabled at all). Because
this kiosk's systemd units deliberately skip `PAMName=login` (see the
`slimeos-session.service` comment below on why — it broke cog's WebKit
sandbox), the session never registers as an "active" logind session, which
is what polkit's default NetworkManager authorization normally keys off —
`install.sh` also drops a polkit rule authorizing the `netdev` group (the
session user's own group) for `org.freedesktop.NetworkManager.*` actions,
without which `nmcli` would silently fail with "Insufficient privileges."

### WireGuard pairing
Like network setup above, this is part of the open-source, account-free
**Connect** path — it does not touch Authelia or `dashboard.slimeos.com`,
which stay reserved for the separate, not-yet-built "Sign in with Slime ID"
managed path referenced above. It replaces the previously fully-manual flow
(admin runs `provision-peer.sh` on the Brain, hand-copies the resulting
`wg0.conf` onto the device over USB/rescue-mode shell access) with an
on-screen "enter a pairing code" step.

`coordinator.sh` checks for an existing tunnel once per process, on the
first `_clientConnected` event, the same way it checks for a default route:
`have_wg_tunnel()` (a plain `/etc/wireguard/wg0.conf` existence check, not
`ip link show wg0` — link state is transient and already reported
separately by the tunnel status indicator) gates an automatic `do_pair
boot` call — defined in `membrane/session/pair.sh`, `source`d the same way
`network-setup.sh` is. A dedicated pairing icon in the status strip
(`slime:pair-settings`) reaches the same function in `settings` mode any
time, for re-pairing or adding a second Brain network.

`do_pair()` takes a host (an enrollment endpoint, e.g. `enroll.slimeos.com`)
and a short-lived code, entered on the new `pairEntry` screen. It POSTs the
code to that host's `brain/enroll/` service — a small standalone Go binary
(zero third-party dependencies, same rationale as `membrane/bridge/`, since
it sits right next to WireGuard peer configs) that does an atomic Redis
`GETDEL` against a code an admin generated with `brain/wireguard/
pair-peer.sh` (single-use, 15-minute TTL — the actual security control, not
the code's length). On success, `pair.sh` writes `/etc/wireguard/wg0.conf`
and runs `systemctl enable --now wg-quick@wg0`; a `pairError` screen (reusing
the existing `slime:retry`/`slime:back` events, no new ones needed) handles
an invalid/expired code or an unreachable host.

Same logind/polkit gap as network setup and power off above: `install.sh`
drops a third polkit rule (`org.freedesktop.systemd1.manage-units` +
`.manage-unit-files`, scoped to the `wg-quick@wg0.service` unit and
`$SESSION_USER`) — both action IDs are required, since the first alone
would bring the tunnel up now but silently fail to survive a reboot.
Writing `wg0.conf` itself is a plain filesystem write, not a D-Bus action,
so `install.sh` instead just hands `/etc/wireguard` to `$SESSION_USER`
(same pattern as `brains.json`/`brains/`).

### Power off / restart
A power icon in the status strip (next to the network-settings gear)
opens a confirm modal (Restart / Shut Down / Cancel) — the same
`showRemoveConfirm`-style modal pattern used for removing a saved Brain.
Once confirmed, the page immediately shows a local, client-only "Shutting
down…"/"Restarting…" overlay (there's nothing left to route a backend
response to) and emits `slime:power-shutdown`/`slime:power-restart`,
which `coordinator.sh` handles by calling `systemctl poweroff`/`systemctl
reboot` directly. Same logind/polkit gap as NetworkManager above — these
actions normally rely on an "active" logind session, which this kiosk's
`slime` user doesn't have (no `PAMName=login`) — so `install.sh` drops a
second polkit rule (`org.freedesktop.login1.power-off`/`.reboot`,
scoped to the `$SESSION_USER` directly) authorizing it.

### Key files
| File | Purpose |
|---|---|
| `membrane/preseed/slimeos.preseed.cfg` | Debian automated installer config |
| `membrane/installer/install.sh` | Post-install setup script |
| `membrane/installer/extract-windows-license.ps1` | Windows key extractor — run on Windows before install, saves to USB |
| `membrane/session/slimeos-session.sh` | cage session startup (launches cog) |
| `membrane/lockscreen/index.html` | Connect screen UI — self-contained kiosk HTML/CSS/JS rendered by cog |
| `membrane/bridge/` | `slimeos-bridge` — local WS↔stdio relay between the kiosk UI and coordinator.sh (committed prebuilt static binary) |
| `membrane/session/coordinator.sh` | Connect screen backend — saved-Brain picker (add/select/remove), drives the kiosk UI over the bridge |
| `membrane/freerdp/connect.sh` | FreeRDP connection function library (`do_connect`), sourced by coordinator.sh, with security flags |
| `membrane/session/network-setup.sh` | WiFi/Ethernet onboarding function library (`do_network_setup`), sourced by coordinator.sh |
| `membrane/session/pair.sh` | WireGuard self-pairing function library (`do_pair`), sourced by coordinator.sh |
| `slimeos-automount.service` (written by install.sh) | Runs `udiskie` headlessly so USB drives auto-mount under `/media/<user>` for connect.sh's `/drive` redirect |

### Security hardening
- `noexec`, `nosuid` mount flags on `/tmp` and `/var`.
- AppArmor profile on the FreeRDP process.
- No local user home directory. All config in `/etc/slimeos/`.
- SSH disabled. Local console requires a recovery PIN.
- `slimeos-bridge` listens on loopback (`127.0.0.1`) only, enforced at its
  own startup — no new network-facing attack surface, no firewall rule
  needed.

---

## The Brain

### Service topology

```
Internet
  │
  ▼
[Nginx / Caddy reverse proxy]  ←── TLS termination
  │
  ├──▶ [Authelia]           ←── MFA / identity gateway
  │       │
  │       └──▶ [WireGuard]  ←── VPN gateway (UDP 51820)
  │               │
  │               ├──▶ [xRDP + Windows VM]   (BYOL path)
  │               └──▶ [xRDP + Linux VM]     (free path)
  │
  └──▶ [Slime API]          ←── Account mgmt, license activation, telemetry
```

### Cloud VM profiles

| Profile | vCPU | RAM | GPU | Use case |
|---|---|---|---|---|
| Life-Standard | 4 | 8 GB | — | Daily productivity |
| Life-Dev | 8 | 16 GB | — | Development workloads |
| Life-Lite | 2 | 4 GB | — | Schoolwork / light use |

Measured floor (real hardware, 2026-07-16): full-screen video playback
needs 4 vCPU — on 2 vCPU the VM's own video decode and the RDP encode
saturate both cores and playback is choppy regardless of codec.

### Cloud Brain power management (auto-deallocate / wake-on-connect)

A cloud Brain that runs 24/7 bills 24/7. The `power` service
(`brain/power/`, in docker-compose) closes that gap with no agent on the
Windows VM and no Membrane-side configuration:

- **Wake-on-connect** — before every RDP attempt, `connect.sh`
  (`wake_brain()`) POSTs the Brain's host to
  `http://10.10.0.1:7677/wake`. Unmanaged hosts return `{managed:false}`
  instantly; hubs without the service refuse the connection — both fall
  through to the normal connect path. For a managed, powered-off VM the
  service issues an ARM start while the lock screen shows
  "Waking up your Brain… (about a minute)", then
  "Brain is up — starting the desktop…" while Windows boots
  (wake-to-desktop is typically 1–2 minutes).
- **Idle auto-deallocate** — the service shares the WireGuard container's
  network namespace and requires **two independent signals to both say
  idle**, every minute for `POWER_IDLE_MINUTES` (default 20), before
  acting:
  1. Zero live RDP flows in `/proc/net/nf_conntrack` (read three times
     per check — this file is a racy iteration over a live hash table
     and was caught live returning a transiently *empty* view while a
     session's entry demonstrably existed, which once deallocated a VM
     under a connected user). Entries carry a decaying timeout refreshed
     by every packet; the watchdog ignores entries with no packets for
     over an hour, so a Membrane hard-powered-off mid-session can't hold
     the VM awake for the kernel's 5-day entry lifetime.
  2. The VM peer's WireGuard transfer counters (`wg show wg0 transfer`,
     netlink — immune to the procfs race) moving less than
     `POWER_IDLE_XFER_BYTES` (default 4096) per minute. Measured live:
     an idle-but-connected session moves ~15 KB/min; a session-less
     peer only WireGuard's own keepalives (~700 B/min).
  Either signal unreadable or ambiguous ⇒ no progress toward
  deallocation.
- **Guest shutdown coverage** — a VM shut down from inside Windows stays
  allocated (and billed) on Azure; the watchdog deallocates it.

Security model: the listener binds the WireGuard interface address
explicitly, so **being a tunnel peer is the authentication** — the same
model as RDP itself. It is deliberately not exposed through Caddy (a
public unauthenticated VM-start endpoint invites cost-griefing), and no
stop/deallocate HTTP endpoint exists at all: a hostile peer could at
worst keep the VM awake. Azure credentials are a service principal
scoped to the single VM, living only in the hub's `.env`.

Fail-safe posture: unreadable conntrack, an absent PowerState, ARM/token
errors, or the service being down all mean "leave power alone" — the
failure mode is a higher bill, never a killed session.

⚠ Azure operational notes: deallocation **destroys the temporary disk
(`D:\`)** — treat it as scratch space only; dynamic IPs are released
(harmless here — the VM's WireGuard dials out and the NSG has zero
inbound rules); the service principal's client secret expires (default
1 year) — record the date, since an expired secret stops both wakes and
auto-deallocation.

### Infrastructure files
| File | Purpose |
|---|---|
| `brain/docker-compose.yml` | Full stack orchestration |
| `brain/wireguard/provision-peer.sh` | Add a new device peer, prints WireGuard config + QR code |
| `brain/wireguard/pair-peer.sh` | Same, plus stashes the config in Redis behind a single-use pairing code for self-enrollment |
| `brain/enroll/` | `slimeos-enroll` — account-free HTTPS endpoint serving pairing codes to Membrane devices |
| `brain/power/` | `slimeos-power` — cloud Brain auto-deallocate + wake-on-connect (tunnel-only, port 7677) |
| `brain/xrdp/Dockerfile` | Ubuntu + xRDP + desktop image |
| `brain/authelia/configuration.yml` | Zero-trust identity config |

---

## FreeRDP Security Configuration

```bash
xfreerdp3 \
  /v:${VM_HOST}:3389 \
  /u:${USERNAME} \
  /p:${PASSWORD} \
  /sec:rdp:off \      # negotiate NLA (Windows) or TLS (xRDP), never legacy
                      # RDP security. xRDP has no NLA/CredSSP support, Windows
                      # requires NLA — forcing either breaks the other.
  /cert:tofu \        # Trust on first use, pin thereafter
  /network:lan \      # Bandwidth optimization
  /gfx \             # GFX pipeline for efficient streaming
  /rfx \             # RemoteFX codec
  /f                  # Fullscreen kiosk
```

WireGuard wraps this entire stream. The RDP port (3389) is never exposed publicly — only WireGuard UDP 51820 is reachable from the internet.

---

## Streaming Protocol Decision

| Protocol | Choice | Reason |
|---|---|---|
| Client library | FreeRDP (open source) | No vendor lock-in, LGPL, active development |
| Windows VM backend | xRDP → native RDP | Best Windows streaming performance |
| Linux VM backend | xRDP + Xorg | Same client, clean open-source stack |
| Future | WebRTC / RustDesk | Browser-native clients, Phase 3 |

---

## BYOL License Flow

```
Installer detects Windows license key
  │
  ├── Retail/MAK key? ─────▶ Upload to Slime account
  │                           │
  │                           └──▶ Cloud backend calls MS KMS
  │                                Activates single-user VM
  │
  └── OEM/embedded key? ───▶ Provision free Linux desktop instead
                              (no Microsoft licensing liability)
```

---

## Android Client (Phase 2)

The Android component is a custom launcher APK that:
1. Runs over stock AOSP / LineageOS (no bootloader unlock required).
2. Replaces the home screen with the Slime OS shell UI.
3. Establishes a WireGuard tunnel and launches FreeRDP (or a WebRTC client) in kiosk mode.
4. Keeps all native Android hardware drivers intact (camera, cellular, sensors).

Target: Huawei Mate 30 Pro + any Android 8+ device.

---

## Telco Partnership Model

Slime OS is designed to run **on partner infrastructure**, not Slime-owned datacenters:

1. Telco / ISP / Regional DC provides edge compute + high-speed connectivity.
2. Slime OS installs the Brain stack on their infrastructure (Docker Compose → Kubernetes).
3. Revenue split: Slime OS subscription revenue shared with the infra partner.
4. PR value: Partner gains "Green Tech / Sustainability" credentials.
5. Bandwidth benefit: Each active user streams ~10–30 Mbps constantly.
