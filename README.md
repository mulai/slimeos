# Slime OS

**The Infinite Life Desktop OS** — an open-source, cloud-first operating system that rescues legacy hardware from e-waste.

```
  ⬤S
  SLIME OS
```

> *"Liquid Rejuvenation."* Strip your old machine down to a featherweight local client, stream a full cloud desktop at 60fps over FreeRDP — and keep your hardware alive for another decade.

---

## What Is Slime OS?

Slime OS turns any x86_64 PC or Android phone into a **zero-client terminal**. All storage, processing, and applications run in the cloud. If the local machine loses power, your cloud session stays frozen and active — reconnecting from any device restores it down to the exact cursor position.

| Component | Role |
|---|---|
| **The Membrane** | Hardened, minimal Debian Linux local layer. Boots cage (Wayland) → FreeRDP stream. Zero local user storage. |
| **The Brain** | Cloud VMs serving Windows (xRDP) or Linux desktops, wrapped in WireGuard + Authelia zero-trust security. Deployable on AWS, GCP, or any VPS. |
| **The App** | Android launcher APK for legacy smartphones (Phase 2). |

Website: [slimeos.com](https://www.slimeos.com)

---

## Repository Structure

```
slimeos/
├── membrane/          # Local client (Debian preseed + installer + FreeRDP session)
├── brain/             # Cloud infrastructure (Docker Compose, WireGuard, xRDP, Authelia)
├── android/           # Android launcher APK (Phase 2)
└── docs/              # Architecture docs, install guides, telco pitch deck
```

---

## Quickstart

### 1. Install Slime OS on a legacy PC

```bash
# Flash Debian 12 netinstall to USB, boot it, then at the GRUB prompt:
# Advanced options → Automated install
# Add to boot parameters:
#   auto=true url=https://raw.githubusercontent.com/mulai/slimeos/main/membrane/preseed/slimeos.preseed.cfg

# Or, on an existing minimal Debian 12 install:
curl -fsSL https://raw.githubusercontent.com/mulai/slimeos/main/membrane/installer/install.sh | sudo bash
```

### 2. Deploy the Cloud Brain

The Brain runs on any Linux host (AWS EC2, GCP Compute Engine, or a cPanel VPS).

```bash
# On your cloud host (Ubuntu 22.04 LTS recommended):
git clone https://github.com/mulai/slimeos.git
cd slimeos/brain
cp .env.example .env       # fill in domain, secrets, SMTP
docker compose up -d       # starts Caddy + Authelia + WireGuard + xRDP desktop
```

### 3. Connect the Membrane to the Brain

```bash
# On the cloud host — generate a WireGuard config for the device:
docker exec slimeos-wireguard /config/provision-peer.sh my-device
# → prints a client wg0.conf and QR code

# On the Membrane device:
sudo cp wg0.conf /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0

# Edit the Slime OS config:
sudo nano /etc/slimeos/config   # set VM_HOST and SLIME_USERNAME
sudo systemctl restart slimeos-session
```

---

## Cloud Hosting

The Brain is tested and deployable on:

| Platform | Notes |
|---|---|
| **AWS EC2** | t3.medium or larger recommended; use Security Groups to expose only UDP 51820 (WireGuard) and 443 (HTTPS) |
| **GCP Compute Engine** | e2-medium or larger; use VPC Firewall rules |
| **cPanel VPS** | Any VPS with Docker support; enable IP forwarding for WireGuard |

See [`docs/brain-hosting.md`](docs/brain-hosting.md) for platform-specific setup guides.

---

## Hardware Tested

| Device | Profile | Status |
|---|---|---|
| Gigabyte H97-Gaming 3 / i7-4790 / 16 GB (Win 10) | 001 | ✅ Reference device |
| Generic x86\_64 | 000 | ✅ Fallback — any uncatalogued machine |
| Huawei Mate 30 Pro (Android) | — | 🔄 Phase 2 |

**Minimum local specs:** x86_64, 512 MB RAM, 4 GB disk, network connection.

Adding support for a new device = one new file in `membrane/hardware-profiles/`. See [Profile 001](membrane/hardware-profiles/001-gigabyte-h97.sh) as a template.

---

## Security Architecture (Zero-Trust Stack)

```
Local Device  ──(FreeRDP · NLA · TLS 1.3)──▶  WireGuard VPN  ──▶  Authelia MFA  ──▶  Cloud VM (xRDP)
```

1. **Layer 1** — NLA + TLS 1.3 inside FreeRDP. Blocks DDoS and intercept vectors.
2. **Layer 2** — WireGuard VPN wraps the entire RDP stream. Cloud ports invisible from the public internet.
3. **Layer 3** — Authelia reverse-proxy identity gateway with TOTP MFA. Lost or stolen hardware? Revoke access instantly — no one can reconnect without the second factor.

---

## Licensing (BYOL)

- **Windows cloud VM** — bring your own 25-digit transferable Retail/Digital key. The installer captures it before wiping the local drive, maps it to your Slime account, and activates a single-user cloud node.
- **No transferable key?** The system auto-provisions a free Linux cloud desktop (Ubuntu + XFCE) instead.
- **Slime OS itself** — MIT license. Forever free and open source.

---

## Contributing

PRs welcome. Read [`docs/architecture.md`](docs/architecture.md) first.

- Membrane issues → label `membrane`
- Brain infra → label `brain`
- Android → label `android`

---

## License

MIT © Slime OS Contributors

---

<p align="center">
  <em>E-waste, revitalized.</em><br>
  <strong>slimeos.com · github.com/mulai/slimeos</strong>
</p>
