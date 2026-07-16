#!/usr/bin/env bash
# Slime OS — Membrane Installer
# Runs after a minimal Debian trixie base install.
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

# CPU microcode packages are amd64-only (no equivalent on arm64, e.g. VMs on
# Apple Silicon) — apt-get install is all-or-nothing, so pulling them in on an
# unsupported arch would abort the whole install.
MICROCODE_PKGS=""
if [[ "$(dpkg --print-architecture)" == "amd64" ]]; then
    MICROCODE_PKGS="intel-microcode amd64-microcode"
fi

# xwayland: cage unconditionally tries to start an XWayland server on launch
# (this build has Xwayland support compiled in) and aborts the whole session
# if /usr/bin/Xwayland is missing -- --no-install-recommends below means it
# won't get pulled in as cage's own recommended dependency otherwise. xfreerdp3
# still opens its own Xwayland-backed top-level window when launched, cage
# displays it exactly as before -- the cog swap below doesn't change that.
#
# cog + libwpewebkit-2.0-1 replace weston + whiptail: the Connect screen is
# now the kiosk HTML bundle in membrane/lockscreen/ (rendered by cog, WPE
# WebKit's kiosk launcher) instead of a whiptail dialog stack running inside
# weston-terminal. Neither weston nor whiptail has any other user left in
# this repo once brain-select.sh is gone.
#
# wpasupplicant: NetworkManager's actual WiFi backend. Normally pulled in as
# a Recommends of network-manager, but --no-install-recommends (below) means
# it never gets pulled in on its own -- without it, NetworkManager installs
# and its service enables fine, but `nmcli device wifi list`/`connect` see
# no usable WiFi device at all (network-setup.sh's do_network_setup()).
#
# udisks2 + udiskie: `usbmount` (the classic headless auto-mounter) no
# longer exists in Debian trixie -- udisks2 is the modern replacement, but
# it only exposes a D-Bus API; nothing mounts a plugged-in drive on its own
# without a client listening for its signals. udiskie is that client (does
# NOT need a desktop/tray -- see slimeos-automount.service below, which
# runs it headless with --no-tray --no-notify).
#
# ntfs-3g + exfatprogs: udisks2 can only automount filesystems it has
# tooling for -- without these, NTFS/exFAT drives (i.e. most external HDDs
# and large sticks) silently fail to mount and never appear in the Brain's
# "usb on <hostname>" share, while FAT32 works. Confirmed live 2026-07-16.
#
# alsa-utils: the /sound and /microphone redirection in connect.sh needs no
# extra libraries (freerdp3-x11 already depends on libasound2 transitively)
# -- but a fresh kernel leaves the mixer's Master channel MUTED at 0%, and
# with no sound server installed, nothing ever unmutes it. alsa-utils
# provides alsactl for the first-boot init below (slimeos-audio-init) plus
# its own alsa-restore.service for every boot after.
log "Installing core dependencies..."
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    curl wget git ca-certificates gnupg \
    sudo ufw apparmor apparmor-utils \
    systemd-resolved systemd-timesyncd \
    wireguard wireguard-tools \
    freerdp3-x11 \
    cage cog libwpewebkit-2.0-1 wayland-utils xwayland \
    polkitd pkexec dbus dbus-user-session \
    network-manager wpasupplicant \
    udisks2 udiskie \
    ntfs-3g exfatprogs \
    alsa-utils \
    ${MICROCODE_PKGS} \
    ethtool \
    qrencode \
    jq \
    2>/dev/null
ok "Dependencies installed"

# ── 2. Create session user if not exists ─────────────────────────────────────
# `render` (not just `video`) is required for GPU-accelerated rendering:
# /dev/dri/renderD128 is group-owned by `render`, separately from card0's
# `video` ownership. Without it, wlroots/cog fail outright ("Permission
# denied" on renderD128 -> EGL init failure -> cage never starts), not just
# fall back to software rendering.
# The preseed's own d-i passwd/user-default-groups already creates this user
# before install.sh ever runs, so the `useradd` branch below is frequently
# skipped -- `usermod -aG` runs unconditionally so required groups are always
# guaranteed regardless of which path created the user.
if ! id "$SESSION_USER" &>/dev/null; then
    log "Creating session user '$SESSION_USER'..."
    useradd -m -s /bin/bash -G audio,video,render,netdev,sudo "$SESSION_USER"
    ok "User '$SESSION_USER' created"
fi
usermod -aG audio,video,render,netdev,sudo "$SESSION_USER"

# slimeos-session.sh runs as $SESSION_USER (unprivileged) and logs to a file
# for on-device troubleshooting without journalctl -- /var/log itself isn't
# writable by a non-root user, so it needs its own owned subdirectory.
mkdir -p /var/log/slimeos
chown "$SESSION_USER:$SESSION_USER" /var/log/slimeos
chmod 750 /var/log/slimeos

# ── 2b. Hostname ──────────────────────────────────────────────────────────────
# Both preseeds set netcfg/get_hostname to "slimeos", but on a real
# network-fetched install d-i asks the hostname question BEFORE it can
# download the preseed (it needs the network up first), so the preseeded
# answer never applies and the box ends up with d-i's own "debian" default.
# The hostname is user-visible product surface — the Brain's RDP session
# shows the USB share as "usb on <hostname>" — so honor the preseed's
# intent here instead. Only the known d-i fallback is replaced: anything
# else was deliberately chosen by whoever ran the installer.
if [[ "$(cat /etc/hostname 2>/dev/null)" == "debian" ]]; then
    log "Renaming default 'debian' hostname to 'slimeos'..."
    echo "slimeos" > /etc/hostname
    sed -i 's/\bdebian\b/slimeos/g' /etc/hosts
    ok "Hostname set to 'slimeos' (takes effect on first real boot)"
fi

# ── 3. Install Slime OS files ─────────────────────────────────────────────────
log "Installing Slime OS system files..."
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$INSTALL_DIR/hardware-profiles" "$INSTALL_DIR/lockscreen/fonts"

# Download hardware detection and profiles
# NOTE: add new profile files here as they're validated (see membrane/hardware-profiles/)
for f in detect.sh 000-generic.sh 001-gigabyte-h97.sh 006-apple-mac-intel.sh 008-gigabyte-78lmt-s2p.sh; do
    curl -fsSL "$REPO_BASE/membrane/hardware-profiles/$f" \
         -o "$INSTALL_DIR/hardware-profiles/$f"
    chmod +x "$INSTALL_DIR/hardware-profiles/$f"
done

# Download session, coordinator, and FreeRDP scripts. brain-select.sh is
# gone -- coordinator.sh (event-driven, talks to slimeos-bridge) replaces
# its whiptail menu loop; connect.sh is no longer a standalone entry point,
# it's `source`d by coordinator.sh as a function library, but is still
# fetched and chmod +x the same way for manual on-device debugging.
curl -fsSL "$REPO_BASE/membrane/session/slimeos-session.sh" \
     -o "$INSTALL_DIR/slimeos-session.sh"
curl -fsSL "$REPO_BASE/membrane/session/coordinator.sh" \
     -o "$INSTALL_DIR/coordinator.sh"
curl -fsSL "$REPO_BASE/membrane/freerdp/connect.sh" \
     -o "$INSTALL_DIR/connect.sh"
curl -fsSL "$REPO_BASE/membrane/session/network-setup.sh" \
     -o "$INSTALL_DIR/network-setup.sh"
curl -fsSL "$REPO_BASE/membrane/session/pair.sh" \
     -o "$INSTALL_DIR/pair.sh"
chmod +x "$INSTALL_DIR/slimeos-session.sh" "$INSTALL_DIR/coordinator.sh" "$INSTALL_DIR/connect.sh" "$INSTALL_DIR/network-setup.sh" "$INSTALL_DIR/pair.sh"

# Download the kiosk lock screen bundle (self-contained HTML/CSS/JS + local
# fonts -- zero other network requests at runtime, see the file's own header
# comment) that cog renders as the Connect screen.
for f in index.html; do
    curl -fsSL "$REPO_BASE/membrane/lockscreen/$f" -o "$INSTALL_DIR/lockscreen/$f"
done
for f in space-grotesk.woff2 plus-jakarta-sans.woff2 jetbrains-mono.woff2; do
    curl -fsSL "$REPO_BASE/membrane/lockscreen/fonts/$f" -o "$INSTALL_DIR/lockscreen/fonts/$f"
done

# Download the slimeos-bridge static binary (committed prebuilt, see
# membrane/bridge/README.md -- the Membrane never runs a Go toolchain).
BRIDGE_ARCH="$(dpkg --print-architecture)"
curl -fsSL "$REPO_BASE/membrane/bridge/bin/slimeos-bridge-linux-${BRIDGE_ARCH}" \
     -o "$INSTALL_DIR/slimeos-bridge"
chmod +x "$INSTALL_DIR/slimeos-bridge"
ok "Slime OS files installed to $INSTALL_DIR"

# ── 3b. NetworkManager (WiFi/Ethernet backend for network-setup.sh) ───────────
# Unconditional here, not left to hardware-profiles/*.sh: only
# 000-generic.sh ever enabled NetworkManager, so any machine matching a
# *named* profile (001, 006, 008, ...) never got it enabled at all --
# nmcli would silently do nothing on exactly the hardware this feature
# needs to work on. Every profile gets it now, unconditionally.
log "Enabling NetworkManager..."
systemctl enable NetworkManager 2>/dev/null || true

# Debian's ifupdown and NetworkManager can both try to own the same
# interface; when ifupdown wins, `nmcli device status` shows it
# "unmanaged" and nmcli can't touch it at all. Force NetworkManager to
# manage everything regardless of /etc/network/interfaces.
mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/10-slimeos-managed.conf <<'NMCONF'
[ifupdown]
managed=true
NMCONF

# network-setup.sh runs nmcli as the unprivileged $SESSION_USER (netdev
# group). This kiosk deliberately skips PAMName=login on its systemd units
# (see slimeos-session.service below -- it broke cog's WebKit sandbox), so
# the session may never register as an "active" logind session, which is
# what polkit's default NetworkManager authorization normally keys off.
# Without this rule, nmcli as $SESSION_USER can silently fail with an
# "Insufficient privileges" denial.
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-slimeos-network-manager.rules <<'POLKIT'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") == 0 &&
        subject.isInGroup("netdev")) {
        return polkit.Result.YES;
    }
});
POLKIT
ok "NetworkManager enabled for Wi-Fi/Ethernet onboarding"

# ── 3c. Polkit rule: power off / restart from the kiosk UI ───────────────────
# Same root cause as the NetworkManager rule above: coordinator.sh calls
# `systemctl poweroff`/`systemctl reboot` as $SESSION_USER in response to the
# lock screen's power icon, but without an active logind session (no
# PAMName=login, see above), polkit's default "allow the active local user"
# authorization for these actions doesn't apply -- without this rule they'd
# fail with "Insufficient privileges" and the button would silently do
# nothing beyond the client-side "Shutting down..."/"Restarting..." overlay.
cat > /etc/polkit-1/rules.d/51-slimeos-power.rules <<POLKIT
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.power-off" ||
         action.id == "org.freedesktop.login1.power-off-multiple-sessions" ||
         action.id == "org.freedesktop.login1.reboot" ||
         action.id == "org.freedesktop.login1.reboot-multiple-sessions") &&
        subject.user == "${SESSION_USER}") {
        return polkit.Result.YES;
    }
});
POLKIT
ok "Power off/restart enabled for the kiosk UI"

# ── 3d. Polkit rule: WireGuard pairing from the kiosk UI ─────────────────────
# pair.sh's do_pair() calls `systemctl enable --now wg-quick@wg0` as
# $SESSION_USER after fetching a config via the enrollment endpoint. Same
# missing-active-session root cause as the two rules above. Two separate
# systemd action IDs are needed, not one: manage-units covers start/stop,
# manage-unit-files covers enable/disable (the [Install] symlink) --
# granting only the first would bring the tunnel up now but silently fail
# to make it survive a reboot.
#
# manage-unit-files does NOT reliably expose a per-unit action.lookup("unit")
# detail the way manage-units does (confirmed live: a rule requiring it never
# matched, `systemctl enable` fell through to polkit's default deny with
# "Interactive authentication required" -- no interactive agent exists in
# this headless kiosk, so it just failed). Scoped to $SESSION_USER only for
# that action, not per-unit; manage-units keeps the tighter per-unit scope
# since that one does support it.
cat > /etc/polkit-1/rules.d/52-slimeos-wireguard.rules <<POLKIT
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.systemd1.manage-units" &&
        action.lookup("unit") == "wg-quick@wg0.service" &&
        subject.user == "${SESSION_USER}") {
        return polkit.Result.YES;
    }
    if (action.id == "org.freedesktop.systemd1.manage-unit-files" &&
        subject.user == "${SESSION_USER}") {
        return polkit.Result.YES;
    }
});
POLKIT
ok "WireGuard pairing enabled for the kiosk UI"

# ── 3e. Polkit rule: USB storage automount (udiskie) for the Brain's /drive redirect ──
# Same missing-active-session root cause as the three rules above: udiskie
# runs as $SESSION_USER (slimeos-automount.service, below) and calls
# udisks2 to mount/unmount plugged-in USB drives so connect.sh's
# /drive:usb,/media/<user> flag has something to redirect. Without this,
# udisks2's default policy falls back to requiring an interactive
# authentication agent, which doesn't exist in this headless kiosk, and
# every plug-in would silently fail to mount.
cat > /etc/polkit-1/rules.d/53-slimeos-udisks2.rules <<POLKIT
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.udisks2.") == 0 &&
        subject.user == "${SESSION_USER}") {
        return polkit.Result.YES;
    }
});
POLKIT
ok "USB storage automount enabled for the kiosk UI"

# ── 4. Hardware profile detection and application ─────────────────────────────
log "Detecting hardware profile..."
bash "$INSTALL_DIR/hardware-profiles/detect.sh"
ok "Hardware profile applied"

# ── 5. Default config ─────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_DIR/config" ]]; then
    log "Writing default config..."
    cat > "$CONFIG_DIR/config" <<'CONF'
# Slime OS Membrane Configuration
# Session-wide display/network preferences. Brains themselves (host, port,
# username) are managed from the on-screen Connect screen, saved to
# /etc/slimeos/brains.json — no need to edit this file for that.

# RDP display resolution (leave blank for fullscreen/auto)
RDP_WIDTH=""
RDP_HEIGHT=""

# Connection quality profile: auto | lan | broadband | wan
# "auto" lets FreeRDP measure the real path; "lan" (the old default) told
# it to assume LAN-grade bandwidth, which oversends badly on a real
# internet path to a cloud Brain and shows up as choppy video/audio.
RDP_NETWORK="auto"

# Auto-reconnect on disconnect (seconds, 0 = disabled)
RECONNECT_DELAY="5"
CONF
    ok "Default config written to $CONFIG_DIR/config"
fi
# connect.sh sources this file as $SESSION_USER (unprivileged) -- root-only
# 600 makes every connection attempt die on the source line under set -e.
# Root keeps ownership (it's admin-edited); the session user gets group read.
chown "root:$SESSION_USER" "$CONFIG_DIR/config"
chmod 640 "$CONFIG_DIR/config"

if [[ ! -f "$CONFIG_DIR/brains.json" ]]; then
    echo '[]' > "$CONFIG_DIR/brains.json"
    chmod 600 "$CONFIG_DIR/brains.json"
fi
mkdir -p "$CONFIG_DIR/brains"
chmod 700 "$CONFIG_DIR/brains"
# The Connect screen (brain-select.sh) runs as $SESSION_USER and owns this
# data: it reads/rewrites brains.json and creates per-Brain .cred files in
# brains/. Left owned by root (this script runs as root), brain-select.sh
# dies on its first chmod/read and the session crash-loops with a black
# screen. /etc/slimeos itself stays root-owned -- the session user gets
# exactly these two entries, nothing else.
chown "$SESSION_USER:$SESSION_USER" "$CONFIG_DIR/brains.json" "$CONFIG_DIR/brains"

# pair.sh's do_pair() writes /etc/wireguard/wg0.conf directly as
# $SESSION_USER once it fetches a config from the enrollment endpoint --
# same reasoning as the brains.json/brains chown above, this is a plain
# filesystem write, not a D-Bus action, so no polkit rule covers it.
# wireguard-tools (already in the package list) creates /etc/wireguard on
# install; this only needs to hand it to the session user.
mkdir -p /etc/wireguard
chown "$SESSION_USER:$SESSION_USER" /etc/wireguard
chmod 700 /etc/wireguard

# ── 6. Systemd service: slimeos-session ───────────────────────────────────────
# WantedBy=multi-user.target, not graphical.target: with no display manager
# installed (all of them are masked below), the system's default boot target
# stays multi-user.target, so graphical.target is never reached and the unit
# would never start. Conflicts=getty@tty1.service hands us tty1 cleanly
# instead of racing the default console login prompt for it.
#
# Deliberately NOT using PAMName=login / TTYPath=/dev/tty1 / StandardInput=tty
# (an earlier version of this unit did): that combination puts the session
# under systemd-logind's seat0/console handling, which left the calling
# process in a capability state that made bubblewrap abort with "Unexpected
# capabilities but not setuid, old file caps config?" — breaking cog's
# WebKit sandbox (bwrap + xdg-dbus-proxy) before it could even open a
# window. Confirmed by direct A/B test: removing these three lines (keeping
# everything else identical) let cage/cog start and the kiosk UI's WebSocket
# reach slimeos-bridge successfully; re-adding them reproduced the failure
# every time. logind still assigns the session to seat0 without an explicit
# TTYPath as long as nothing else (getty) is contesting the console, which
# Conflicts=getty@tty1.service already guarantees.
log "Installing systemd service..."
# After=/Wants= slimeos-bridge.service is soft ordering only (Wants, not
# Requires): a bridge failure must never prevent cage from starting --
# the lock screen's own WS glue shows a "Reconnecting to Slime OS..."
# placeholder and retries with backoff if the bridge isn't up yet.
cat > "$SYSTEMD_DIR/slimeos-session.service" <<SERVICE
[Unit]
Description=Slime OS — Kiosk Session (cage + FreeRDP)
After=network-online.target getty@tty1.service slimeos-bridge.service
Conflicts=getty@tty1.service
Wants=network-online.target slimeos-bridge.service

[Service]
User=${SESSION_USER}
Group=${SESSION_USER}
# Without PAMName=login, nothing else creates /run/user/<uid> for us --
# that used to be pam_systemd's job. RuntimeDirectory= is systemd's own
# PAM-independent equivalent: it creates and owns the directory itself
# before ExecStart runs.
RuntimeDirectory=user/$(id -u ${SESSION_USER})
RuntimeDirectoryMode=0700
Environment=XDG_RUNTIME_DIR=/run/user/$(id -u ${SESSION_USER})
ExecStartPre=/bin/sleep 2
ExecStart=${INSTALL_DIR}/slimeos-session.sh
Restart=always
RestartSec=5
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
SERVICE

# ── 6b. Systemd service: slimeos-bridge ───────────────────────────────────────
# Independent Restart=always lifecycle, deliberately not tied to cage/cog's
# own restart cycle -- a 2s coordinator hiccup should show a brief
# "Reconnecting to Slime OS..." placeholder, not restart the whole kiosk
# session. Listens on loopback only (enforced by slimeos-bridge itself at
# startup) -- no firewall rule needed, ufw always permits lo traffic.
log "Installing slimeos-bridge service..."
cat > "$SYSTEMD_DIR/slimeos-bridge.service" <<SERVICE
[Unit]
Description=Slime OS — Local WS bridge (kiosk UI <-> Brain coordinator)
After=network.target

[Service]
User=${SESSION_USER}
Group=${SESSION_USER}
ExecStart=${INSTALL_DIR}/slimeos-bridge --listen=127.0.0.1:7770 --coordinator=${INSTALL_DIR}/coordinator.sh --log=/var/log/slimeos/coordinator.log
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable slimeos-bridge.service
ok "slimeos-bridge.service enabled"

# ── 6c. Systemd service: slimeos-automount (udiskie) ──────────────────────────
# Headless USB-storage automounter for connect.sh's /drive:usb,/media/<user>
# redirection (see the udisks2/udiskie package comment above). --no-tray:
# no systray protocol exists in this cage/cog kiosk to host an icon in.
# --no-notify: skips libnotify session-bus calls -- no notification daemon
# is installed either, and none of this needs a session bus at all, only
# the system bus (where udisks2 lives), so no RuntimeDirectory/
# XDG_RUNTIME_DIR is needed here unlike slimeos-session.service.
log "Installing slimeos-automount service..."
cat > "$SYSTEMD_DIR/slimeos-automount.service" <<SERVICE
[Unit]
Description=Slime OS — USB storage automount (udiskie)
After=systemd-udevd.service
Wants=systemd-udevd.service

[Service]
User=${SESSION_USER}
Group=${SESSION_USER}
ExecStart=/usr/bin/udiskie --automount --no-tray --no-notify
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable slimeos-automount.service
ok "slimeos-automount.service enabled"

# ── 6d. Systemd service: slimeos-audio-init (first-boot mixer unmute) ─────────
# A fresh HDA kernel driver initializes the mixer with Master MUTED at 0%,
# and this kiosk deliberately runs no sound server (PulseAudio/PipeWire)
# that would otherwise unmute it -- so every fresh install is born silent:
# the Brain's RDP audio arrives (Windows-side level meters move) and dies
# at the last inch. Confirmed live on real hardware 2026-07-16.
#
# `alsactl init` applies ALSA's own per-driver sane defaults (unmutes
# Master/PCM, moderate volumes); `alsactl store` persists them so
# alsa-utils' stock alsa-restore.service takes over on every later boot.
# Gated on the state file so user-adjusted levels are never clobbered:
# this runs meaningfully once, then no-ops forever.
#
# Runs at boot (not from this installer): install.sh executes under the
# installer kernel in a chroot, where the target's sound modules aren't
# loaded -- same reason firewall-setup.sh (section 9) is deferred to a
# boot-time oneshot instead of running here.
log "Installing slimeos-audio-init service..."
cat > "$SYSTEMD_DIR/slimeos-audio-init.service" <<'SERVICE'
[Unit]
Description=Slime OS — one-time ALSA mixer init (unmute) on first boot
ConditionPathExists=!/var/lib/alsa/asound.state

[Service]
Type=oneshot
# alsactl init exits 99 for cards it deems "nothing worth initializing"
# (e.g. HDMI-only codecs) — harmless, don't let it fail the unit.
ExecStart=/bin/sh -c '/usr/sbin/alsactl init || true; /usr/sbin/alsactl store'

[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable slimeos-audio-init.service
ok "slimeos-audio-init.service enabled"

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
# Deferred to first real boot via systemd, not run here directly: when
# install.sh executes from preseed/late_command, it runs inside `in-target`
# (chroot) under the still-live installer kernel, not the freshly installed
# target kernel -- iptables can't determine kernel/netfilter module support
# in that environment ("Couldn't determine iptables version"), and ufw
# dies under set -e before any of the steps below it ever run. Enabling a
# oneshot unit here is safe (pure unit-file symlinking); actually running
# ufw waits until the real kernel is up.
log "Configuring firewall (ufw) for first boot..."
cat > "$CONFIG_DIR/firewall-setup.sh" <<'FWSCRIPT'
#!/usr/bin/env bash
set -euo pipefail
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
# Allow WireGuard outbound (UDP to Brain server — added when WG config is loaded)
ufw --force enable
FWSCRIPT
chmod +x "$CONFIG_DIR/firewall-setup.sh"

cat > "$SYSTEMD_DIR/slimeos-firewall.service" <<SERVICE
[Unit]
Description=Slime OS — Firewall setup (ufw)
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${CONFIG_DIR}/firewall-setup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICE
systemctl enable slimeos-firewall.service
ok "Firewall service installed (applies on first real boot)"

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
# set +o pipefail locally: `tr` reads /dev/urandom indefinitely, so `head -c 8`
# exiting after 8 bytes sends it SIGPIPE (exit 141) -- harmless here, but
# `set -o pipefail` (on globally) would otherwise fail this whole assignment
# under set -e.
RECOVERY_PIN=$(set +o pipefail; tr -dc '0-9' < /dev/urandom | head -c 8)
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
echo "  1. Install WireGuard config:  sudo cp client.conf /etc/wireguard/wg0.conf"
echo "  2. Enable VPN:                sudo systemctl enable --now wg-quick@wg0"
echo "  3. Reboot:                    sudo reboot"
echo "  4. On the Connect screen, add your Brain's IP address"
echo ""
echo -e "  ${YELLOW}Recovery PIN: ${RECOVERY_PIN}${RESET}  (keep this safe — needed for tty1 login)"
echo ""

if $PRESEED_MODE; then
    log "Preseed mode: skipping interactive reboot prompt."
else
    read -rp "  Reboot now? [Y/n]: " ans
    [[ "${ans:-Y}" =~ ^[Yy]$ ]] && reboot
fi
