# Slime OS

**The Infinite Life Desktop OS** — an open-source, cloud-first operating system that rescues legacy hardware from e-waste.

```
  ⬤S
  SLIME OS
```

> *"Liquid Rejuvenation."* Strip your old machine down to a featherweight local client, stream a full cloud desktop at 60fps over FreeRDP/WebRTC — and keep your hardware alive for another decade.

---

## What Is Slime OS?

Slime OS turns any x86_64 PC or Android phone into a **zero-client terminal**. All storage, processing, and applications run in the cloud. If the local machine loses power, your cloud session stays frozen and active — reconnecting from any device restores it down to the exact cursor position.

| Component | Role |
|---|---|
| **The Membrane** | Hardened, minimal Debian Linux local layer. Boots cage (Wayland) → FreeRDP stream. Zero local user storage. |
| **The Brain** | Cloud VMs serving Windows (xRDP) or Linux desktops, wrapped in WireGuard + Authelia zero-trust security. |
| **The Website** | SlimeOS.com — interactive OS-emulator marketing site (Next.js). |
| **The App** | Android launcher APK for legacy smartphones (coming soon). |

---

## Repository Structure

```
slimeos/
├── membrane/          # Local client (Debian preseed + installer + FreeRDP session)
├── brain/             # Cloud infrastructure (Docker Compose, WireGuard, xRDP, Authelia)
├── android/           # Android launcher APK (Phase 2)
├── website/           # SlimeOS.com marketing site (Next.js + React + TypeScript)
└── docs/              # Architecture docs, install guides, telco pitch deck
```

---

## Quickstart

### Boot the website locally
```bash
cd website
npm install
npm run dev
# → http://localhost:3000
```

### Install Slime OS on a legacy PC (e.g. Intel NUC / i7-4790)
```bash
# 1. Flash the Debian netinstall ISO to a USB stick
# 2. Boot from USB, choose "Advanced options → Automated install"
# 3. At the boot prompt add: auto=true url=https://raw.githubusercontent.com/mulai/slimeos/main/membrane/preseed/slimeos.preseed.cfg
# OR run the interactive installer after a minimal Debian install:
curl -fsSL https://raw.githubusercontent.com/mulai/slimeos/main/membrane/installer/install.sh | sudo bash
```

### Spin up the cloud brain
```bash
cd brain
cp .env.example .env  # fill in secrets
docker compose up -d
```

---

## Hardware Tested

| Device | Status |
|---|---|
| Intel NUC (i7-4790, 16 GB RAM, Win 10 → Slime OS) | ✅ Primary test bed |
| Huawei Mate 30 Pro (Android) | 🔄 Android launcher Phase 2 |

**Minimum specs:** x86_64, 512 MB RAM, 4 GB disk, wired/WiFi network.

---

## Security Architecture (Zero-Trust Stack)

```
User Device  ──(FreeRDP/TLS 1.3)──▶  WireGuard VPN  ──▶  Authelia MFA  ──▶  Cloud VM (xRDP/Windows)
                                                                              └──▶  Cloud VM (Linux)
```

1. **Layer 1** — NLA + TLS 1.3 inside FreeRDP. Blocks DDoS and intercept vectors.  
2. **Layer 2** — WireGuard VPN wraps the RDP stream. Datacenter ports invisible from the public internet.  
3. **Layer 3** — Authelia reverse-proxy identity gateway with MFA. Lost hardware? Revoke access instantly from the dashboard.

---

## Licensing (BYOL)

- **Windows cloud VM** — bring your own 25-digit transferable Retail/Digital license. The installer wizard captures it before wiping the local drive, maps it to your Slime account, and activates a dedicated cloud node.  
- **No transferable key?** The system auto-provisions a free Linux cloud desktop instead.  
- **Slime OS itself** — MIT license. Forever free and open source.

---

## Contributing

PRs welcome. Please read [`docs/architecture.md`](docs/architecture.md) before diving in.

- **Membrane** bugs → label `membrane`  
- **Brain** infra → label `brain`  
- **Website** → label `website`  
- **Android** → label `android`

---

## License

MIT © Slime OS Contributors

---

<p align="center">
  <em>E-waste, revitalized.</em><br>
  <strong>github.com/mulai/slimeos</strong>
</p>
