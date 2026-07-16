#!/usr/bin/env bash
# Slime OS — debug/support tool: enable SSH access to a Membrane over its
# WireGuard tunnel, from the installer USB's Rescue-mode chroot.
#
# A kiosk Membrane has no interactive access path once cage owns the console
# (VT switching is blocked while the lock screen is up), so remote support
# needs sshd reachable through the Brain hub. This script sets that up from
# the only shell always available on a real device: Rescue mode.
#
# Usage — boot the installer USB → Advanced options → Rescue mode → pick the
# root partition → "Execute a shell" (you are root; no sudo). Then:
#
#   passwd slime      # pick a password; SSH uses it
#   rm -f /etc/resolv.conf; echo "nameserver 1.1.1.1" > /etc/resolv.conf
#   curl -fsSL https://raw.githubusercontent.com/mulai/slimeos/main/membrane/tools/rescue-enable-ssh.sh | bash
#
# then exit the shell and reboot without the USB. Everything below takes
# effect on that next real boot:
#   * openssh-server installed
#   * ssh.service enabled via a direct symlink (a rescue chroot has no live
#     systemd to `enable --now` with — see the 2026-07-12 bring-up notes)
#   * a self-disabling oneshot unit opens ufw port 22 to the WireGuard
#     subnet ONLY (ufw itself cannot run inside the chroot: it needs the
#     real target kernel, same reason install.sh defers firewall setup).
#     The LAN still sees nothing — ufw's default deny incoming stands; only
#     Brain-hub-side WireGuard peers (10.10.0.0/24) can reach sshd.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root (you already are in a rescue chroot — don't use sudo)" >&2; exit 1; }

# d-i's rescue chroot usually has /proc & /sys mounted; some paths in apt
# maintainer scripts want them. Mount defensively if missing.
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys  2>/dev/null || mount -t sysfs sys /sys 2>/dev/null || true

echo "Installing openssh-server..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server

# Belt and braces: the package postinst normally enables ssh.service itself
# (deb-systemd-helper works offline), but make sure regardless.
ln -sf /lib/systemd/system/ssh.service \
    /etc/systemd/system/multi-user.target.wants/ssh.service

cat > /etc/systemd/system/slimeos-allow-wg-ssh.service <<'UNIT'
[Unit]
Description=Slime OS — one-time ufw allow: SSH from the WireGuard subnet
# After the firewall oneshot so `ufw allow` lands on the reset ruleset
# rather than being wiped by it.
After=network.target slimeos-firewall.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/ufw allow from 10.10.0.0/24 to any port 22 proto tcp
# The rule persists in ufw's own config once added; this unit only needs
# to succeed once, then takes itself out of future boots.
ExecStartPost=/usr/bin/systemctl disable slimeos-allow-wg-ssh.service

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/slimeos-allow-wg-ssh.service \
    /etc/systemd/system/multi-user.target.wants/slimeos-allow-wg-ssh.service

echo ""
echo "  ✓ SSH enabled for the next boot (WireGuard peers only, port 22)"
echo "  ✓ Make sure you've set a password:  passwd slime"
echo ""
echo "  Now: exit this shell, remove the USB, and reboot normally."
echo "  Reach it from the Brain hub side, e.g.:  ssh slime@<this-device's-wg-ip>"
echo ""
