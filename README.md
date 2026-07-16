# Slime OS

**The Infinite Life Desktop OS** — an open-source, cloud-first operating system that rescues legacy hardware from e-waste.

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
# Flash Debian 13 netinstall to USB, boot it, then at the GRUB prompt:
# Advanced options → Automated install
# Add to boot parameters:
#   auto=true url=https://raw.githubusercontent.com/mulai/slimeos/main/membrane/preseed/slimeos.preseed.cfg

# Or, on an existing minimal Debian 13 install:
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
sudo systemctl restart slimeos-session
```

On boot, the Membrane shows a **Connect screen** — pick "+ Add new Brain", enter
its IP/hostname (the WireGuard address you just configured, e.g. `10.10.0.1`),
and it's saved for future boots. You can save multiple Brains and switch
between them from the same screen.

---

## Cloud Hosting

The Brain runs on **any Linux host with Docker** — a single VPS, a hyperscaler VM, or a telco edge node. The only public ports required are UDP 51820 (WireGuard) and TCP 443 (HTTPS). RDP never touches the public internet.

### Hyperscalers
| Provider | Notes |
|---|---|
| **AWS EC2** | t3.medium+; Security Groups expose UDP 51820 + TCP 443 only |
| **Google Cloud** | e2-medium+; VPC Firewall rules |
| **Microsoft Azure** | B2s+; Network Security Groups |
| **Oracle Cloud** | Always-Free tier (VM.Standard.E2.1) works for single-user testing |
| **Alibaba Cloud** | ecs.t6-c1m2.large+; for Asia-Pacific deployments |
| **IBM Cloud** | cx2-2x4+; Virtual Server for VPC |

### Developer VPS (great value, easy to self-host)
| Provider | Notes |
|---|---|
| **Hetzner** | CPX21 (€7/mo) — best price-performance in Europe |
| **DigitalOcean** | Basic 2 vCPU / 4 GB Droplet |
| **Linode / Akamai** | Nanode or Linode 4 GB |
| **Vultr** | Regular Cloud Compute 2 vCPU / 4 GB |
| **OVHcloud** | VPS Comfort — European and Asia-Pacific PoPs |
| **Scaleway** | DEV1-M; ARM and x86 options in Europe |
| **UpCloud** | 2 vCPU / 4 GB — strong EU/APAC coverage |

### Telco & Edge (partnership targets)
This is where Slime OS is headed. A telco partner hosts the Brain on their edge infrastructure, uses their idle compute, and sells Slime OS as a managed cloud desktop subscription on top of their existing 5G/fiber plans.

| Provider type | Examples |
|---|---|
| **Telco operators** | Maxis, Celcom, Digi, Singtel, AIS, Telkomsel, PLDT, Globe |
| **Edge / CDN** | Cloudflare Workers (future WebRTC path), Fastly, Akamai |
| **Regional DCs** | AIMS DC, Equinix, NTT |
| **Hyperscaler edge** | AWS Wavelength, GCP Distributed Cloud Edge, Azure Edge Zones |

> If you're a hosting provider or telco interested in partnering, reach out via [slimeos.com](https://www.slimeos.com) or open a GitHub Discussion.

See [`docs/brain-hosting.md`](docs/brain-hosting.md) for platform-specific setup guides.

---

## Hardware Tested

| Device | Profile | Boot mode | Status |
|---|---|---|---|
| Gigabyte H97-Gaming 3 / i7-4790 / 16 GB (Win 10) | 001 | UEFI | ✅ Reference device — full install → kiosk → WireGuard tunnel → RDP connect confirmed |
| Gigabyte GA-78LMT-S2P / AMD FX-6100 / 8 GB (Win 10) | 008 | Legacy BIOS | ✅ Full install → kiosk → tunnel → RDP connect confirmed; mouse input, WiFi onboarding, WireGuard self-pairing (persists across reboot), and power off/restart all confirmed on real hardware |
| Generic (any arch) | 000 | — | ✅ Fallback — any uncatalogued machine |
| Huawei Mate 30 Pro (Android) | — | — | 🔄 Phase 2 |

**Minimum local specs:** x86_64, 512 MB RAM, 4 GB disk, network connection.

**Validated end-to-end so far:** the automated Debian preseed install (both
UEFI and Legacy BIOS variants), the cog/WPE kiosk lock screen driving a
real WireGuard tunnel to a cloud Brain, RDP connect through to both a
Linux (xRDP) and Windows Brain, mouse input, WiFi onboarding (including
switching from Ethernet to WiFi with the network-settings screen correctly
naming which network is active), account-free WireGuard self-pairing (real
pairing code → real Brain, tunnel persists across reboot), the
on-screen power off/restart controls, peripheral redirection into a
Windows Brain (local speakers, a USB microphone, and hot-plugged USB
storage all working inside the remote session), and cloud Brain power
management (an idle Azure VM deallocates itself to stop billing and
wakes automatically on connect, ~2 minutes to desktop) — all confirmed
on real hardware, not just in a VM.

Adding support for a new device = one new file in `membrane/hardware-profiles/`. See [Profile 001](membrane/hardware-profiles/001-gigabyte-h97.sh) as a template.

---

## Security Architecture (Zero-Trust Stack)

```
Local Device  ──(FreeRDP · TLS 1.2/1.3)──▶  WireGuard VPN  ──▶  Authelia MFA  ──▶  Cloud VM (xRDP)
```

1. **Layer 1** — negotiated TLS 1.2/1.3 or NLA inside FreeRDP (NLA for Windows Brains, TLS for xRDP Brains — xRDP does not support NLA; legacy RDP security is disabled). Blocks intercept vectors.
2. **Layer 2** — WireGuard VPN wraps the entire RDP stream. Cloud ports invisible from the public internet.
3. **Layer 3** — Authelia reverse-proxy identity gateway with TOTP MFA. Lost or stolen hardware? Revoke access instantly — no one can reconnect without the second factor.

---

## Licensing (BYOL)

- **Windows cloud VM** — bring your own 25-digit transferable Retail/Digital key. The installer captures it before wiping the local drive, maps it to your Slime account, and activates a single-user cloud node.
- **No transferable key?** The system auto-provisions a free Linux cloud desktop (Ubuntu + XFCE) instead.
- **Slime OS itself** — Apache License 2.0. Forever free and open source.

---

## Contributing

PRs welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) — read
[`docs/architecture.md`](docs/architecture.md) first.

- Membrane issues → label `membrane`
- Brain infra → label `brain`
- Android → label `android`

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md).

---

## License

Apache License 2.0 © Slime OS Contributors — see [`LICENSE`](LICENSE).

---

<p align="center">
  <em>E-waste, revitalized.</em><br>
  <strong>slimeos.com · github.com/mulai/slimeos</strong>
</p>
