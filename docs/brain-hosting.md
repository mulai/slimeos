# Brain Hosting Guide

The Slime OS Brain runs on any Linux host with Docker. Below are setup notes for the three platforms we use.

---

## Prerequisites (all platforms)

- Ubuntu 22.04 LTS (recommended) or Debian 12
- Docker + Docker Compose v2
- Ports open: **UDP 51820** (WireGuard) and **TCP 443 / 80** (HTTPS)
- A domain pointing to the host (e.g. `slimeos.com`, `vpn.slimeos.com`, `auth.slimeos.com`)

Install Docker on a fresh Ubuntu server:
```bash
curl -fsSL https://get.docker.com | bash
sudo usermod -aG docker $USER
# log out and back in
```

Enable IP forwarding (required for WireGuard routing):
```bash
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

---

## AWS EC2

### Recommended instance
| Use case | Instance | vCPU | RAM |
|---|---|---|---|
| Single user / dev | t3.medium | 2 | 4 GB |
| Multi-user | t3.xlarge | 4 | 16 GB |
| Heavy workloads | c6i.2xlarge | 8 | 16 GB |

**AMI:** Ubuntu Server 22.04 LTS (64-bit x86)

### Security Group rules
| Type | Protocol | Port | Source |
|---|---|---|---|
| HTTPS | TCP | 443 | 0.0.0.0/0 |
| HTTP (redirect only) | TCP | 80 | 0.0.0.0/0 |
| WireGuard | UDP | 51820 | 0.0.0.0/0 |
| SSH (admin only) | TCP | 22 | Your IP only |

**Do NOT open TCP 3389 (RDP) to the internet.** It is only reachable via WireGuard.

### Storage
Attach a separate EBS volume (`/dev/xvdf`) for Docker volumes:
```bash
sudo mkfs.ext4 /dev/xvdf
sudo mkdir /data
sudo mount /dev/xvdf /data
echo "/dev/xvdf /data ext4 defaults 0 2" | sudo tee -a /etc/fstab
# Point Docker to it:
sudo mkdir -p /data/docker
echo '{"data-root": "/data/docker"}' | sudo tee /etc/docker/daemon.json
sudo systemctl restart docker
```

### DNS
Point these A records to your EC2 Elastic IP:
```
slimeos.com       → <Elastic IP>
auth.slimeos.com  → <Elastic IP>
vpn.slimeos.com   → <Elastic IP>
```

### Deploy
```bash
git clone https://github.com/mulai/slimeos.git /opt/slimeos
cd /opt/slimeos/brain
cp .env.example .env
nano .env   # fill in domain, secrets, SMTP
docker compose up -d
```

---

## GCP Compute Engine

### Recommended machine type
| Use case | Machine | vCPU | RAM |
|---|---|---|---|
| Single user / dev | e2-medium | 2 | 4 GB |
| Multi-user | e2-standard-4 | 4 | 16 GB |

**Boot disk:** Ubuntu 22.04 LTS, 50 GB SSD

### VPC Firewall rules
Create these in **VPC Network → Firewall**:

```
Name: allow-https       Ingress TCP:443    0.0.0.0/0
Name: allow-http        Ingress TCP:80     0.0.0.0/0
Name: allow-wireguard   Ingress UDP:51820  0.0.0.0/0
Name: allow-ssh-admin   Ingress TCP:22     <your-IP>/32
```

### Static IP
Reserve a static external IP and attach it to the instance:
**VPC Network → External IP addresses → Reserve static address**

### Deploy
Same steps as AWS above. Use the static external IP for DNS.

---

## cPanel VPS

Most cPanel-managed VPS hosts allow Docker if you have root SSH access.

### Check Docker availability
```bash
ssh root@your-vps
docker --version || apt-get install -y docker.io docker-compose-v2
```

### Firewall (WHM / iptables)
In WHM → ConfigServer Security & Firewall (CSF), add to `TCP_IN` / `UDP_IN`:
```
# /etc/csf/csf.conf
TCP_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,2077,2078,2082,2083,2086,2087,2095,2096"
UDP_IN = "20,21,53,51820"
```
Then: `csf -r`

### Important: IP forwarding with CSF
CSF blocks IP forwarding by default. Add to `/etc/csf/csf.conf`:
```
ETH_DEVICE_SKIP = "wg0"
DOCKER = "1"
```
And in `/etc/csf/csfpost.sh`:
```bash
iptables -I DOCKER-USER -i wg0 -j ACCEPT
iptables -I DOCKER-USER -o wg0 -j ACCEPT
```

### Deploy
```bash
git clone https://github.com/mulai/slimeos.git /opt/slimeos
cd /opt/slimeos/brain
cp .env.example .env
nano .env
docker compose up -d
```

---

## Post-deployment checklist (all platforms)

```bash
# 1. Verify all services are healthy
docker compose ps

# 2. Check Caddy got a TLS cert (may take ~60s first time)
curl -I https://auth.slimeos.com

# 3. Provision first WireGuard peer (your H97 device)
docker exec slimeos-wireguard /config/provision-peer.sh tommy-h97
# → outputs wg0.conf + QR code

# 4. Generate Authelia password hash for your user
docker run --rm authelia/authelia:latest \
    authelia crypto hash generate argon2 --password 'your-password'
# → paste the hash into brain/authelia/users_database.yml

# 5. Reload Authelia
docker compose restart authelia

# 6. Test login at https://auth.slimeos.com
```

---

## Scaling (future)

When a single host is not enough:

| Tier | Approach |
|---|---|
| Single host | Docker Compose (current) |
| Multi-host | Docker Swarm (same Compose file, `docker swarm init`) |
| Cloud-native | Kubernetes (GKE / EKS) — migrate Compose with Kompose |
| Telco partner | Deploy the Brain stack on partner edge infrastructure |
