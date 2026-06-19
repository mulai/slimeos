#!/usr/bin/env bash
# Slime OS — Membrane Installer
# Runs after a minimal Debian bookworm base install.
# Sets up cage (Wayland kiosk), FreeRDP, WireGuard client, and systemd services.
#
# Usage:
#   Automated (called from preseed late_command):
#     /opt/slimeos/install.sh --preseed-mode
#
#   Interactive (run on an existing Debian system):
#     curl -fsSL https://raw.githubusercontent.com/mulai/slimeos/main/membrane/installer/install.sh | sudo bash

set -euo pipefail

SLIMEOS_VERSION="0.1.0"
REPO_BASE="https://raw.githubusercontent.com/mulai/slimeos/main"
INSTALL_DIR="/opt/slimeos"
CONFIG_DIR="/etc/slimeos"
SYSTEMD_DIR="/etc/systemd/system"
SESSION_USER="slime"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()  { echo -e "${CYAN}[slimeos]${RESET} $*"; }
ok()   { echo -e "${GREEN}[slimeos] ✓${RESET} $*"; }
warn() { echo -e "${YELLOW}[slimeos] ⚠${RESET} $*"; }
die()  { echo -e "${RED}[slimeos] ✗${RESET} $*" >&2; exit 1; }

PRESEED_MODE=false
[[ "${1:-}" == "--preseed-mode" ]] && PRESEED_MODE=true

# ── Must be root ──────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run as root (sudo bash install.sh)"

echo ""
echo -e "${BOLD}${CYAN}"
echo "  ┌─────────────────────────────────────────┐"
echo "  │   Slime OS Membrane Installer v${SLIMEOS_VERSION}   │"
echo "  │   The Infinite Life Desktop OS          │"
echo "  └─────────────────────────────────────────┘"
echo -e "${RESET}"

# ── 1. System update ──────────────────────────────────────────────────────────
log "Updating package lists..."
apt-get update -qq

log "Installing core dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl wget git ca-certificates gnupg \
    sudo ufw apparmor apparmor-utils \
    systemd-resolved \
    wireguard wireguard-tools \
    freerdp2-x11 \
    cage weston wayland-utils \
    policykit-1 dbus dbus-user-session \
    network-manager \
    intel-microcode amd64-microcode \
    ethtool \
    qrencode \
    jq \
    2>/dev/null
ok "Dependencies installed"

# ── 2. Create session user if not exists ─────────────────────────────────────
if ! id "$SESSION_USER" &>/dev/null; then
    log "Creating session user '$SESSION_USER'..."
    useradd -m -s /bin/bash -G audio,video,netdev,sudo "$SESSION_USER"
    ok "User '$SESSION_USER' created"
fi

# ── 3. Install Slime OS files ─────────────────────────────────────────────────
log "Installing Slime OS system files..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$INSTALL_DIR/hardware-profiles"

# Download hardware detection and profiles
for f in detect.sh 000-generic-x86_64.sh 001-gigabyte-h97.sh; do
    curl -fsSL "$REPO_BASE/membrane/hardware-profiles/$f" \
         -o "$INSTALL_DIR/hardware-profiles/$f"
    chmod +x "$INSTALL_DIR/hardware-profiles/$f"
done

# Download session and FreeRDP scripts
curl -fsSL "$REPO_BASE/membrane/session/slimeos-session.sh" \
     -o "$INSTALL_DIR/slimeos-session.sh"
curl -fsSL "$REPO_BASE/membrane/freerdp/connect.sh" \
     -o "$INSTALL_DIR/connect.sh"
chmod +x "$INSTALL_DIR/slimeos-session.sh" "$INSTALL_DIR/connect.sh"
ok "Slime OS files installed to $INSTALL_DIR"

# ── 4. Hardware profile detection and application ─────────────────────────────
log "Detecting hardware profile..."
bash "$INSTALL_DIR/hardware-profiles/detect.sh"
ok "Hardware profile applied"

# ── 5. Default config ─────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_DIR/config" ]]; then
    log "Writing default config..."
    cat > "$CONFIG_DIR/config" <<'CONF'
# Slime OS Membrane Configuration
# Edit this file to point to your Slime Brain server.
# After editing, restart: sudo systemctl restart slimeos-session

# Cloud VM host (IP or hostname behind WireGuard)
VM_HOST="10.10.0.1"
VM_PORT="3389"

# Your Slime account username
SLIME_USERNAME=""

# RDP display resolution (leave blank for fullscreen/auto)
RDP_WIDTH=""
RDP_HEIGHT=""

# Connection quality profile: lan | broadband | wan
RDP_NETWORK="lan"

# Auto-reconnect on disconnect (seconds, 0 = disabled)
RECONNECT_DELAY="5"
CONF
    chmod 600 "$CONFIG_DIR/config"
    ok "Default config written to $CONFIG_DIR/config"
fi

# ── 6. Systemd service: slimeos-session ───────────────────────────────────────
log "Installing systemd service..."
cat > "$SYSTEMD_DIR/slimeos-session.service" <<SERVICE
[Unit]
Description=Slime OS — Kiosk Session (cage + FreeRDP)
After=network-online.target graphical.target
Wants=network-online.target

[Service]
User=${SESSION_USER}
Group=${SESSION_USER}
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u ${SESSION_USER})
ExecStartPre=/bin/sleep 2
ExecStart=${INSTALL_DIR}/slimeos-session.sh
Restart=always
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=graphical.target
SERVICE

# ── 7. Systemd service: NIC tuning (Profile 001 only if present) ───────────────
if [[ -f "$CONFIG_DIR/nic-tune.sh" ]]; then
    cat > "$SYSTEMD_DIR/slimeos-network-tune.service" <<NIC
[Unit]
Description=Slime OS — NIC latency tuning
After=network.target

[Service]
Type=oneshot
ExecStart=${CONFIG_DIR}/nic-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
NIC
    systemctl enable slimeos-network-tune.service
fi

# ── 8. Disable unused services ────────────────────────────────────────────────
log "Hardening: disabling unused services..."
for svc in bluetooth avahi-daemon cups ModemManager; do
    systemctl disable --now "$svc" 2>/dev/null || true
    systemctl mask "$svc" 2>/dev/null || true
done
ok "Unused services disabled"

# ── 9. Firewall ───────────────────────────────────────────────────────────────
log "Configuring firewall (ufw)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# Allow WireGuard outbound (UDP to Brain server — added when WG config is loaded)
ufw --force enable
ok "Firewall configured"

# ── 10. AppArmor ──────────────────────────────────────────────────────────────
log "Enabling AppArmor..."
systemctl enable apparmor 2>/dev/null || true

# ── 11. Disable autologin to desktop (we handle it via systemd) ───────────────
# Remove any existing display managers — cage handles everything
for dm in gdm3 lightdm sddm xdm; do
    systemctl disable "$dm" 2>/dev/null || true
    systemctl mask "$dm" 2>/dev/null || true
done

# ── 12. Enable slimeos-session ────────────────────────────────────────────────
systemctl daemon-reload
systemctl enable slimeos-session.service
ok "slimeos-session.service enabled"

# ── 13. Recovery PIN ─────────────────────────────────────────────────────────
RECOVERY_PIN=$(tr -dc '0-9' < /dev/urandom | head -c 8)
echo "${SESSION_USER}:${RECOVERY_PIN}" | chpasswd
mkdir -p "$CONFIG_DIR"
echo "$RECOVERY_PIN" > "$CONFIG_DIR/recovery-pin"
chmod 600 "$CONFIG_DIR/recovery-pin"
ok "Recovery PIN set (stored in $CONFIG_DIR/recovery-pin)"

# ── 14. Final summary ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}  Slime OS Membrane installed successfully!${RESET}"
echo ""
echo -e "  ${CYAN}Next steps:${RESET}"
echo "  1. Edit $CONFIG_DIR/config — set VM_HOST and SLIME_USERNAME"
echo "  2. Install WireGuard config:  sudo cp client.conf /etc/wireguard/wg0.conf"
echo "  3. Enable VPN:                sudo systemctl enable --now wg-quick@wg0"
echo "  4. Reboot:                    sudo reboot"
echo ""
echo -e "  ${YELLOW}Recovery PIN: ${RECOVERY_PIN}${RESET}  (keep this safe — needed for tty1 login)"
echo ""

if $PRESEED_MODE; then
    log "Preseed mode: skipping interactive reboot prompt."
else
    read -rp "  Reboot now? [Y/n]: " ans
    [[ "${ans:-Y}" =~ ^[Yy]$ ]] && reboot
fi
