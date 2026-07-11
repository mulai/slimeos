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
   `coordinator.sh` owns all state and behavior.
5. On selection, `coordinator.sh` calls `do_connect <brain-id>` (defined in
   `connect.sh`, now a sourced function library rather than a standalone
   script), which prompts for credentials on first use (saved per-Brain,
   encrypted) and launches FreeRDP.
6. FreeRDP opens a WireGuard-tunneled RDP session to the chosen Brain,
   displayed by cage exactly as before (xwayland is still installed for
   this). A clean logout returns `do_connect` to `coordinator.sh`, which
   shows the Connect screen again so the user can switch Brains.

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

### Infrastructure files
| File | Purpose |
|---|---|
| `brain/docker-compose.yml` | Full stack orchestration |
| `brain/wireguard/provision-peer.sh` | Add a new device peer, prints WireGuard config + QR code |
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
