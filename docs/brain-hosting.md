# Brain Hosting Guide

The Slime OS Brain runs on **any Linux host with Docker**. The stack is a standard Docker Compose application — if a provider gives you a Linux VM with root access and a public IP, it works.

**Only two ports need to be public:**
- `UDP 51820` — WireGuard VPN (Membrane devices connect here)
- `TCP 443 / 80` — HTTPS (Authelia SSO portal, Caddy auto-TLS)

**RDP (TCP 3389) is never exposed.** It lives inside the WireGuard network only.

---

## Prerequisites (all providers)

```bash
# Ubuntu 22.04 LTS (recommended on any provider)

# Install Docker
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker $USER && newgrp docker

# Enable IP forwarding (required for WireGuard routing)
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# Deploy
git clone https://github.com/mulai/slimeos.git /opt/slimeos
cd /opt/slimeos/brain
cp .env.example .env
nano .env   # set DOMAIN, secrets, WG_SERVER_URL, SMTP
docker compose up -d
```

---

## Hyperscalers

### AWS EC2

| Use case | Instance | vCPU | RAM | ~Cost/mo |
|---|---|---|---|---|
| Dev / single user | t3.medium | 2 | 4 GB | $30 |
| Small team | t3.xlarge | 4 | 16 GB | $120 |
| Heavy workloads | c6i.2xlarge | 8 | 16 GB | $240 |

**AMI:** Ubuntu Server 22.04 LTS (x86_64)

**Security Group inbound rules:**

| Protocol | Port | Source | Purpose |
|---|---|---|---|
| TCP | 80 | 0.0.0.0/0 | Caddy HTTP→HTTPS redirect |
| TCP | 443 | 0.0.0.0/0 | Caddy HTTPS (Authelia portal) |
| UDP | 51820 | 0.0.0.0/0 | WireGuard VPN |
| TCP | 22 | Your IP only | SSH admin |

**Storage:** Attach a separate EBS `gp3` volume for Docker volumes to avoid filling the root disk.

**DNS:** Assign an Elastic IP. Point `your-domain.com`, `auth.your-domain.com`, `vpn.your-domain.com` to it.

**Terraform:** A Terraform module for AWS is planned in `brain/terraform/aws/`.

---

### Google Cloud (GCP)

| Use case | Machine | vCPU | RAM | ~Cost/mo |
|---|---|---|---|---|
| Dev / single user | e2-medium | 2 | 4 GB | $25 |
| Small team | e2-standard-4 | 4 | 16 GB | $95 |

**Boot disk:** Ubuntu 22.04 LTS, 50 GB balanced persistent disk.

**VPC Firewall rules:**

```
allow-http        TCP:80   0.0.0.0/0
allow-https       TCP:443  0.0.0.0/0
allow-wireguard   UDP:51820 0.0.0.0/0
allow-ssh-admin   TCP:22   <your-IP>/32
```

**Reserve a static external IP:** VPC Network → External IP addresses → Reserve.

---

### Microsoft Azure

| Use case | Size | vCPU | RAM | ~Cost/mo |
|---|---|---|---|---|
| Dev / single user | B2s | 2 | 4 GB | $35 |
| Small team | B4ms | 4 | 16 GB | $140 |

**Image:** Ubuntu Server 22.04 LTS

**Network Security Group inbound rules:** Same ports as AWS above.

**Note:** Azure's default outbound SNAT can interfere with WireGuard keepalives on idle connections. Set `PersistentKeepalive = 25` in the WireGuard client config (already the default in Slime OS).

---

### Oracle Cloud (Free Tier)

Oracle's Always Free tier is sufficient for **single-user testing** at zero cost.

| Shape | vCPU | RAM | Disk | Cost |
|---|---|---|---|---|
| VM.Standard.E2.1.Micro | 1 OCPU | 1 GB | 47 GB | Free |
| VM.Standard.A1.Flex (ARM) | Up to 4 | Up to 24 GB | 200 GB | Free |

**Note:** The A1.Flex ARM instances are the better free option (more RAM). The Brain stack runs on ARM — Docker images are multi-arch.

**Ingress rules (Security List):** Add TCP 80, TCP 443, UDP 51820.

**Also add iptables rules** (Oracle's firewall is layered):
```bash
sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 51820 -j ACCEPT
sudo netfilter-persistent save
```

---

### Alibaba Cloud (Asia-Pacific)

Best choice for users in Southeast Asia, China, and East Asia.

| Instance | vCPU | RAM | ~Cost/mo |
|---|---|---|---|
| ecs.t6-c1m2.large | 2 | 4 GB | $20–25 |
| ecs.c7.xlarge | 4 | 8 GB | $70 |

**Security Group:** Same ports (TCP 80, 443; UDP 51820).

**Regions of interest:** Singapore (ap-southeast-1), Kuala Lumpur, Jakarta, Hong Kong.

---

### IBM Cloud

| Profile | vCPU | RAM | ~Cost/mo |
|---|---|---|---|
| cx2-2x4 | 2 | 4 GB | $40 |
| cx2-4x8 | 4 | 8 GB | $80 |

Use **Virtual Server for VPC** (not Classic). Apply ACL/Security Group rules as above.

---

## Developer VPS

These providers offer the best value for self-hosted and community deployments.

### Hetzner (Recommended for EU)

Exceptional price-performance. GDPR-compliant, EU-based.

| Server | vCPU | RAM | Disk | ~Cost/mo |
|---|---|---|---|---|
| CX21 | 2 | 4 GB | 40 GB SSD | €4.85 |
| CPX21 | 3 | 4 GB | 80 GB NVMe | €7.49 |
| CX32 | 4 | 8 GB | 80 GB SSD | €10.29 |

**Firewall:** Create a firewall rule set in the Hetzner console — same ports.

**Locations:** Nuremberg, Falkenstein, Helsinki, Ashburn (US), Singapore.

```bash
# Hetzner CLI (optional)
hcloud server create --name slimeos-brain \
  --type cpx21 --image ubuntu-22.04 \
  --location fsn1 --ssh-key your-key
```

---

### DigitalOcean

| Droplet | vCPU | RAM | ~Cost/mo |
|---|---|---|---|
| Basic | 2 | 4 GB | $24 |
| General Purpose | 2 | 8 GB | $63 |

**Firewall:** DigitalOcean Cloud Firewalls → Create Firewall → add the three inbound rules.

**1-click deploy** (planned): A DigitalOcean Marketplace 1-click app is on the roadmap.

---

### Linode / Akamai

| Plan | vCPU | RAM | ~Cost/mo |
|---|---|---|---|
| Nanode 1 GB | 1 | 1 GB | $5 (testing only) |
| Linode 4 GB | 2 | 4 GB | $24 |

**Firewall:** Cloud Firewalls in the Linode dashboard. Same ports.

---

### Vultr

| Plan | vCPU | RAM | ~Cost/mo |
|---|---|---|---|
| Regular Cloud | 2 | 4 GB | $24 |
| High Frequency | 2 | 4 GB | $30 |

Vultr has locations in Southeast Asia (Singapore, Tokyo, Seoul) — useful for low-latency connections in the region.

---

### OVHcloud

| Plan | vCPU | RAM | ~Cost/mo |
|---|---|---|---|
| VPS Comfort | 4 | 8 GB | ~€17 |
| VPS Elite | 8 | 16 GB | ~€35 |

Strong presence in EU, Canada, Singapore, and Australia. GDPR-compliant.

---

### Scaleway

| Instance | vCPU | RAM | ~Cost/mo |
|---|---|---|---|
| DEV1-M | 3 | 4 GB | €12 |
| GP1-XS | 4 | 16 GB | €38 |

Offers ARM (Ampere) instances — works with the Brain stack (multi-arch Docker images).

---

### UpCloud

| Plan | vCPU | RAM | ~Cost/mo |
|---|---|---|---|
| 2 vCPU / 4 GB | 2 | 4 GB | $25 |

Locations: Helsinki, Amsterdam, Singapore, Sydney, Chicago, Dallas.

---

### cPanel VPS

Most cPanel-managed VPS hosts allow Docker if you have root SSH access.

```bash
# Check CSF firewall (common on cPanel hosts):
# /etc/csf/csf.conf — add 51820 to UDP_IN
# Also required to allow WireGuard + Docker to coexist:
# /etc/csf/csf.conf: DOCKER=1
# /etc/csf/csfpost.sh:
#   iptables -I DOCKER-USER -i wg0 -j ACCEPT
#   iptables -I DOCKER-USER -o wg0 -j ACCEPT
csf -r
```

---

## Telco & Edge (Partnership Targets)

This is the long-term infrastructure model for Slime OS. Telco and DC partners host the Brain on their existing edge infrastructure, monetise idle compute, and offer Slime OS as a managed desktop-as-a-service subscription layered on their 5G/fiber plans.

### Why this works for the partner

- **High sustained bandwidth** — each active Slime OS user streams ~10–30 Mbps continuously, filling last-mile capacity
- **Recurring revenue** — subscription share on top of existing broadband plan
- **Green Tech PR** — "We're keeping 1M laptops out of landfill" is a strong ESG story
- **Zero capital outlay** — Slime OS runs on the compute they already own

### Potential telco partners (Southeast Asia & beyond)

| Region | Operators |
|---|---|
| Malaysia | Maxis, Celcom Digi, TM (Unifi), U Mobile |
| Singapore | Singtel, StarHub, M1 |
| Thailand | AIS, DTAC (True), NT |
| Indonesia | Telkomsel, Indosat Ooredoo, XL Axiata, Smartfren |
| Philippines | PLDT/Smart, Globe |
| Vietnam | Viettel, VNPT, Mobifone |
| India | Jio, Airtel, Vi |
| ANZ | Telstra, Optus, Vodafone NZ |
| Europe | Deutsche Telekom, Orange, Vodafone, Telefónica |
| Global edge | Cloudflare (future WebRTC path), Fastly, Akamai |
| Hyperscaler edge | AWS Wavelength, GCP Distributed Cloud Edge, Azure Edge Zones |

### Regional DC partners

| Region | Providers |
|---|---|
| Southeast Asia | AIMS DC, Equinix (SG/KL/JK), NTT, Bridge Data Centres |
| Europe | Equinix, Interxion, Hetzner DC |
| US | Equinix, CoreSite, QTS |

> **Interested in a partnership?** Open a GitHub Discussion or reach out via [slimeos.com](https://www.slimeos.com). We provide the Brain stack deployment playbook, revenue-share model, and co-branding materials.

---

## Minimum Spec Reference

| Role | vCPU | RAM | Disk | Network |
|---|---|---|---|---|
| Single user (dev/test) | 1 | 2 GB | 20 GB | 100 Mbps |
| 1–5 users | 2 | 4 GB | 50 GB | 500 Mbps |
| 5–20 users | 4 | 16 GB | 100 GB | 1 Gbps |
| 20–100 users | 8+ | 32 GB+ | 500 GB+ | 1–10 Gbps |

Each active RDP session uses approximately **10–30 Mbps** downstream and **1–5 Mbps** upstream.

---

## Scaling Path

| Stage | Approach |
|---|---|
| 1 user | Docker Compose on a single VPS (current) |
| 2–20 users | Scale up the VPS; add more `desktop` service replicas |
| 20–200 users | Docker Swarm across 2–3 nodes |
| 200+ users | Kubernetes (GKE / EKS / self-hosted k3s); migrate with Kompose |
| Telco partner | Deploy on partner bare-metal/edge with Ansible playbook (planned) |
