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
                           │  FreeRDP stream (TLS 1.3 + NLA)
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
2. `systemd` runs `slimeos-session.target`.
3. `cage` (Wayland compositor) starts in kiosk mode.
4. `slimeos-connect.sh` reads `/etc/slimeos/config` and launches FreeRDP.
5. FreeRDP opens a WireGuard-tunneled RDP session to the assigned cloud VM.

### Key files
| File | Purpose |
|---|---|
| `membrane/preseed/slimeos.preseed.cfg` | Debian automated installer config |
| `membrane/installer/install.sh` | Post-install setup script |
| `membrane/installer/extract-windows-license.ps1` | Windows key extractor — run on Windows before install, saves to USB |
| `membrane/session/slimeos-session.sh` | cage session startup |
| `membrane/freerdp/connect.sh` | FreeRDP connection with security flags |

### Security hardening
- `noexec`, `nosuid` mount flags on `/tmp` and `/var`.
- AppArmor profile on the FreeRDP process.
- No local user home directory. All config in `/etc/slimeos/`.
- SSH disabled. Local console requires a recovery PIN.

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
xfreerdp \
  /v:${VM_HOST}:3389 \
  /u:${USERNAME} \
  /p:${PASSWORD} \
  /sec:nla \          # Network Level Authentication
  /tls-seclevel:2 \   # TLS 1.2 minimum, TLS 1.3 preferred
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
